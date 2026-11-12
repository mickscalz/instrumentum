import Metal
import simd

/// The shared sky's two programs (Fire & Neon fix pass). Fire & Neon's storm weathers (the far storm and its sprites,
/// the supercell, the ash) are compiled into a sky only where its pipeline is specialised for them, by the function
/// constant `kSkyStorms` in `SkyShaders.common`: inlined into every sky, their code's registers slowed every plain sky
/// by about half a millisecond. A plain sky draws with the program that has none of it; a sky with a storm in its rows
/// draws with the other, made the first time one is needed and kept. Every library built on `SkyShaders.common` takes
/// its functions through `skyFunction`, so none is left unspecialised.
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
/// it fails as before), its storm program the first time a frame needs it; both kept.
@MainActor
final class SkyPipeline {
    private let build: (SkyProgram) -> MTLRenderPipelineState?
    private let plain: MTLRenderPipelineState
    private var stormy: MTLRenderPipelineState?
    private var cellOnly: MTLRenderPipelineState?
    private var stormTried = false, cellTried = false
    /// How many times a storm program (the whole one or the supercell's alone) was built (tests: once each, however many
    /// frames need it; a failed build is not tried again).
    private(set) var stormBuilds = 0

    /// `build(program)` makes the pipeline with its functions taken through `skyFunction(_:program:)`.
    init?(program build: @escaping (SkyProgram) -> MTLRenderPipelineState?) {
        guard let p = build(.plain) else { return nil }
        self.build = build
        plain = p
    }

    /// `build(storms)` makes the pipeline with its functions taken through `skyFunction(_:storms:)` (a world that never
    /// asks for the supercell's program alone).
    convenience init?(build: @escaping (Bool) -> MTLRenderPipelineState?) {
        self.init(program: { build($0 != .plain) })
    }

    /// The program for a sky with (`storms`) or without its storm weathers.
    func state(storms: Bool) -> MTLRenderPipelineState { state(storms ? .storms : .plain) }

    /// The program for `program`. Should a storm program ever fail to build, the plain one draws (the sky without its
    /// storm, never a missing world); should the supercell's alone, the whole storm program does.
    func state(_ program: SkyProgram) -> MTLRenderPipelineState {
        switch program {
        case .plain:
            return plain
        case .storms:
            if let s = stormy { return s }
            guard !stormTried else { return plain }
            stormTried = true
            stormBuilds += 1
            stormy = build(.storms)
            return stormy ?? plain
        case .cell:
            if let c = cellOnly { return c }
            guard !cellTried else { return state(.storms) }
            cellTried = true
            stormBuilds += 1
            cellOnly = build(.cell)
            return cellOnly ?? state(.storms)
        }
    }

    /// Whether a storm program (the whole one or the supercell's alone) has been made.
    var hasStormProgram: Bool { stormy != nil || cellOnly != nil }
}
