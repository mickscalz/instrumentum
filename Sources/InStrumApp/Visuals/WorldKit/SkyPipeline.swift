import Metal
import simd

/// The shared sky's programs (Fire & Neon fix pass). Fire & Neon's storm weathers (the far storm and its sprites, the
/// supercell, the ash) are compiled into a sky only where its pipeline is specialised for them, by the function constants
/// `kSkyStorms` and `kSkyCell` in `SkyShaders.common`: inlined into every sky, their code's registers slowed every plain
/// sky by about half a millisecond. A plain sky draws with the program that has none of it; a sky with a storm in its
/// rows draws with the whole storm program, or (where its world reads the supercell's impostor) with the supercell's
/// alone when that is its only storm weather; each made the first time one is needed and kept. Every library built on
/// `SkyShaders.common` takes its functions through `skyFunction`, so none is left unspecialised.
enum SkySpecialisation {
    /// The function constants' indices (`kSkyStormsSet` and `kSkyCellSet` in `SkyShaders.common`).
    static let stormsIndex = 20, cellIndex = 21

    /// Whether a sky's rows (`SkyLayer.uniforms`) need the storm program: a supercell, ash, a far storm or a sprite in
    /// them (the shader draws each only where its row says so, so the choice is exact).
    static func needsStorms(_ u: [SIMD4<Float>]) -> Bool { program(u) != .plain }

    /// The program a sky's rows need: the supercell's alone when it is the only storm weather in them (the sky reads its
    /// impostor and nothing of the far storm, the sprites or the ash), the whole storm program when any of those is.
    static func program(_ u: [SIMD4<Float>]) -> SkyProgram {
        guard u.count >= SkyLayer.uniformCount else { return .plain }
        var others = u[SkyLayer.ashRow].x > 0 || u[SkyLayer.stormRow].z > 0
        for i in 0..<SkyLayer.spriteSlots where u[SkyLayer.spriteARow + i].w > 0 { others = true }
        if others { return .storms }
        return u[SkyLayer.cellARow].w > 0 ? .cell : .plain
    }
}

/// A sky's program: none of the storm weathers, the supercell's alone, or all of them.
enum SkyProgram { case plain, cell, storms }

extension MTLLibrary {
    /// The function `name` of a library built on the shared sky: specialised for the storm program (`storms`) when it
    /// reads the sky's constant, as it is when it doesn't (no specialisation to compile).
    func skyFunction(_ name: String, storms: Bool = false) -> MTLFunction? {
        skyFunction(name, program: storms ? .storms : .plain)
    }

    /// The function `name` specialised for `program` (both constants set).
    func skyFunction(_ name: String, program: SkyProgram) -> MTLFunction? {
        guard let plain = makeFunction(name: name) else { return nil }
        guard !plain.functionConstantsDictionary.isEmpty else { return plain }
        let values = MTLFunctionConstantValues()
        var storms = program == .storms, cell = program != .plain
        values.setConstantValue(&storms, type: .bool, index: SkySpecialisation.stormsIndex)
        values.setConstantValue(&cell, type: .bool, index: SkySpecialisation.cellIndex)
        return try? makeFunction(name: name, constantValues: values)
    }
}

/// A render pipeline whose fragment reads the shared sky: its plain program made at once (so a world that cannot build
/// it fails as before), its storm programs the first time a frame needs each; all kept.
///
/// Any thread (real-Mac performance, 14 Nov). In the app (`ShaderWork.defersDrawPathBuilds`) a storm program a frame finds
/// missing is made on `ShaderWork.queue`, and frames draw with the fallback until it lands (the plain sky, or for the
/// supercell's own program the whole storm program); previews and tests make it at once, as before. A pipeline made on
/// `ShaderWork.queue` (a world the warm-up made) is listed for the warm-up, which makes its storm programs there once
/// every world is made (`nextUnwarmed`, `warm`).
final class SkyPipeline: @unchecked Sendable {
    private let build: (SkyProgram) -> MTLRenderPipelineState?
    private let plain: MTLRenderPipelineState
    /// Made from a storms flag (`init(build:)`): its supercell program is the whole storm program, so it is never made
    /// twice.
    private let cellIsStorms: Bool
    private let lock = NSLock()
    private var stormy: MTLRenderPipelineState?
    private var cellOnly: MTLRenderPipelineState?
    /// Asked for (made, on its way, or failed: a failed build is not tried again).
    private var stormTried = false, cellTried = false
    private var builds = 0
    /// How many times a storm program (the whole one or the supercell's alone) was built (tests: once each, however many
    /// frames need it; a failed build is not tried again).
    var stormBuilds: Int { lock.lock(); defer { lock.unlock() }; return builds }

    private struct Listed { weak var pipeline: SkyPipeline? }
    private static let listLock = NSLock()
    private static var listed: [Listed] = []

    /// `build(program)` makes the pipeline with its functions taken through `skyFunction(_:program:)`.
    init?(program build: @escaping (SkyProgram) -> MTLRenderPipelineState?, cellIsStorms: Bool = false) {
        guard let p = build(.plain) else { return nil }
        self.build = build
        self.cellIsStorms = cellIsStorms
        plain = p
        if ShaderWork.onQueue {
            Self.listLock.lock()
            Self.listed.removeAll { $0.pipeline == nil }
            Self.listed.append(Listed(pipeline: self))
            Self.listLock.unlock()
        }
    }

    /// `build(storms)` makes the pipeline with its functions taken through `skyFunction(_:storms:)` (a world that never
    /// asks for the supercell's program alone).
    convenience init?(build: @escaping (Bool) -> MTLRenderPipelineState?) {
        self.init(program: { build($0 != .plain) }, cellIsStorms: true)
    }

    /// The program for a sky with (`storms`) or without its storm weathers.
    func state(storms: Bool) -> MTLRenderPipelineState { state(storms ? .storms : .plain) }

    /// The program for `program`. Should a storm program ever fail to build, the plain one draws (the sky without its
    /// storm, never a missing world); should the supercell's alone, the whole storm program does. In the app, the same
    /// stand in while a missing one is made off the main thread.
    func state(_ program: SkyProgram) -> MTLRenderPipelineState {
        if program == .plain { return plain }
        if program == .cell && cellIsStorms { return state(.storms) }
        let storms = program == .storms
        lock.lock()
        if let ready = storms ? stormy : cellOnly {
            lock.unlock()
            return ready
        }
        let tried = storms ? stormTried : cellTried
        if !tried {
            if storms { stormTried = true } else { cellTried = true }
            builds += 1
        }
        lock.unlock()
        if tried { return fallback(program) }
        if ShaderWork.defersDrawPathBuilds {
            ShaderWork.queue.async { self.make(program) }
            return fallback(program)
        }
        ShaderWork.noteBuild("a sky storm program")
        return make(program) ?? fallback(program)
    }

    private func fallback(_ program: SkyProgram) -> MTLRenderPipelineState {
        program == .cell ? state(.storms) : plain
    }

    @discardableResult
    private func make(_ program: SkyProgram) -> MTLRenderPipelineState? {
        let made = build(program)
        lock.lock()
        defer { lock.unlock() }
        if program == .storms { stormy = made } else { cellOnly = made }
        return made
    }

    /// Makes `program` now unless something has asked for it already (the warm-up, on `ShaderWork.queue`).
    func warm(_ program: SkyProgram) {
        guard program != .plain, !(program == .cell && cellIsStorms) else { return }
        let storms = program == .storms
        lock.lock()
        let tried = storms ? stormTried : cellTried
        if !tried {
            if storms { stormTried = true } else { cellTried = true }
            builds += 1
        }
        lock.unlock()
        if !tried { make(program) }
    }

    /// The storm programs nothing has asked for yet.
    var unasked: [SkyProgram] {
        lock.lock()
        defer { lock.unlock() }
        var out: [SkyProgram] = []
        if !stormTried { out.append(.storms) }
        if !cellIsStorms && !cellTried { out.append(.cell) }
        return out
    }

    /// The next storm program the warm-up should make: the whole storm programs first (a far storm or a sprite can come
    /// to any world), then the supercell's own; nil when every pipeline made on `ShaderWork.queue` has all of its.
    static func nextUnwarmed() -> (pipeline: SkyPipeline, program: SkyProgram)? {
        listLock.lock()
        listed.removeAll { $0.pipeline == nil }
        let live = listed.compactMap { $0.pipeline }
        listLock.unlock()
        for wanted in [SkyProgram.storms, .cell] {
            for p in live where p.unasked.contains(wanted) { return (p, wanted) }
        }
        return nil
    }

    /// Whether a storm program (the whole one or the supercell's alone) has been made.
    var hasStormProgram: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stormy != nil || cellOnly != nil
    }
}
