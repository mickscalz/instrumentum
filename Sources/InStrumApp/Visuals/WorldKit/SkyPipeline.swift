import Metal
import simd

/// The shared sky's two programs (Fire & Neon fix pass). Fire & Neon's storm weathers (the far storm and its sprites,
/// the supercell, the ash) are compiled into a sky only where its pipeline is specialised for them, by the function
/// constant `kSkyStorms` in `SkyShaders.common`: inlined into every sky, their code's registers slowed every plain sky
/// by about half a millisecond. A plain sky draws with the program that has none of it; a sky with a storm in its rows
/// draws with the other, made the first time one is needed and kept. Every library built on `SkyShaders.common` takes
/// its functions through `skyFunction`, so none is left unspecialised.
enum SkySpecialisation {
    /// The function constant's index (`kSkyStormsSet` in `SkyShaders.common`).
    static let stormsIndex = 20

    /// Whether a sky's rows (`SkyLayer.uniforms`) need the storm program: a supercell, ash, a far storm or a sprite in
    /// them (the shader draws each only where its row says so, so the choice is exact).
    static func needsStorms(_ u: [SIMD4<Float>]) -> Bool {
        guard u.count >= SkyLayer.uniformCount else { return false }
        if u[SkyLayer.cellARow].w > 0 || u[SkyLayer.ashRow].x > 0 || u[SkyLayer.stormRow].z > 0 { return true }
        for i in 0..<SkyLayer.spriteSlots where u[SkyLayer.spriteARow + i].w > 0 { return true }
        return false
    }
}

extension MTLLibrary {
    /// The function `name` of a library built on the shared sky: specialised for the storm program (`storms`) when it
    /// reads the sky's constant, as it is when it doesn't (no specialisation to compile).
    func skyFunction(_ name: String, storms: Bool = false) -> MTLFunction? {
        guard let plain = makeFunction(name: name) else { return nil }
        guard !plain.functionConstantsDictionary.isEmpty else { return plain }
        let values = MTLFunctionConstantValues()
        var on = storms
        values.setConstantValue(&on, type: .bool, index: SkySpecialisation.stormsIndex)
        return try? makeFunction(name: name, constantValues: values)
    }
}

/// A render pipeline whose fragment reads the shared sky: its plain program made at once (so a world that cannot build
/// it fails as before), its storm program the first time a frame needs it; both kept.
@MainActor
final class SkyPipeline {
    private let build: (Bool) -> MTLRenderPipelineState?
    private let plain: MTLRenderPipelineState
    private var stormy: MTLRenderPipelineState?
    /// How many times the storm program was built (tests: once, however many frames need it; a failed build is not
    /// tried again).
    private(set) var stormBuilds = 0

    /// `build(storms)` makes the pipeline with its functions taken through `skyFunction(_:storms:)`.
    init?(build: @escaping (Bool) -> MTLRenderPipelineState?) {
        guard let p = build(false) else { return nil }
        self.build = build
        plain = p
    }

    /// The program for a sky with (`storms`) or without its storm weathers. Should the storm program ever fail to build,
    /// the plain one draws (the sky without its storm, never a missing world).
    func state(storms: Bool) -> MTLRenderPipelineState {
        guard storms else { return plain }
        if let s = stormy { return s }
        guard stormBuilds == 0 else { return plain }
        stormBuilds += 1
        stormy = build(true)
        return stormy ?? plain
    }

    /// Whether the storm program has been made.
    var hasStormProgram: Bool { stormy != nil }
}
