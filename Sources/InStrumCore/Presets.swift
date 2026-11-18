import Foundation

/// A theme's look: its setting values and macros.
public struct LookPreset: Codable, Equatable, Identifiable {
    public var id: String { "\(themeID)/\(name)" }
    public var name: String
    public var themeID: String
    public var state: ThemeState
    public var favourite: Bool
    public var version: Int = 1
    public init(name: String, themeID: String, state: ThemeState, favourite: Bool = false) {
        self.name = name; self.themeID = themeID; self.state = state; self.favourite = favourite
    }
}

/// A reaction style: which inputs drive which roles. Works in every theme.
public struct ReactionPreset: Codable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var map: ReactionMap
    public var favourite: Bool
    public var version: Int = 1
    public init(name: String, map: ReactionMap, favourite: Bool = false) {
        self.name = name; self.map = map; self.favourite = favourite
    }
}

/// Saves presets as small JSON files under look/ and reaction/.
public final class PresetStore {
    private let lookDir: URL, reactionDir: URL, soundDir: URL
    /// File names that couldn't be read during the last listing.
    public private(set) var unreadable: [String] = []

    public init(directory: URL) {
        lookDir = directory.appendingPathComponent("look", isDirectory: true)
        reactionDir = directory.appendingPathComponent("reaction", isDirectory: true)
        try? FileManager.default.createDirectory(at: lookDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: reactionDir, withIntermediateDirectories: true)
        soundDir = directory.appendingPathComponent("sound", isDirectory: true)
    }

    static func fileName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let safe = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        let hash = String(UInt32(truncatingIfNeeded: name.utf8.reduce(5381) { ($0 << 5) &+ $0 &+ Int($1) }), radix: 16)
        return "\(safe)-\(hash).json"
    }

    private func list<T: Decodable>(_ dir: URL, _ type: T.Type) -> [T] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var out: [T] = []
        for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where f.pathExtension == "json" {
            if let data = try? Data(contentsOf: f), let p = try? JSONDecoder().decode(T.self, from: data) {
                out.append(p)
            } else if !unreadable.contains(f.lastPathComponent) {
                unreadable.append(f.lastPathComponent)
            }
        }
        return out
    }

    public func looks(for themeID: String) -> [LookPreset] {
        list(lookDir, LookPreset.self).filter { $0.themeID == themeID }
    }

    public func reactions() -> [ReactionPreset] { list(reactionDir, ReactionPreset.self) }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(value).write(to: url, options: .atomic)
    }

    public func save(_ p: LookPreset) throws {
        try write(p, to: lookDir.appendingPathComponent(Self.fileName("\(p.themeID)--\(p.name)")))
    }
    public func save(_ p: ReactionPreset) throws {
        try write(p, to: reactionDir.appendingPathComponent(Self.fileName(p.name)))
    }
    public func delete(look name: String, themeID: String) throws {
        try FileManager.default.removeItem(at: lookDir.appendingPathComponent(Self.fileName("\(themeID)--\(name)")))
    }
    public func delete(reaction name: String) throws {
        try FileManager.default.removeItem(at: reactionDir.appendingPathComponent(Self.fileName(name)))
    }

    /// Saved sounds, by name (the folder is made the first time one is saved).
    public func sounds() -> [SoundPreset] {
        list(soundDir, SoundPreset.self).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public func save(_ p: SoundPreset) throws {
        try FileManager.default.createDirectory(at: soundDir, withIntermediateDirectories: true)
        try write(p, to: soundDir.appendingPathComponent(Self.fileName(p.name)))
    }
    public func delete(sound name: String) throws {
        try FileManager.default.removeItem(at: soundDir.appendingPathComponent(Self.fileName(name)))
    }
}

/// Random but tasteful looks: only settings marked surprisable, within their ranges.
public enum Surprise {
    public static func look(specs: [ParamSpec], seed: UInt64) -> ThemeState {
        var rng = SeededRandom(seed: seed &+ 0x5EED)
        var values: [String: ParamValue] = [:]
        for s in specs {
            guard let r = s.surprise else { continue }
            let candidate: ParamValue
            switch s.kind {
            case .slider: candidate = .number(Double(rng.range(Float(r.lowerBound), Float(r.upperBound))))
            case .integer: candidate = .number(Double(rng.range(Float(r.lowerBound), Float(r.upperBound))).rounded())
            case let .choice(options): candidate = .choice(options[Int(rng.unit() * Float(options.count)) % options.count])
            case .toggle: candidate = .bool(rng.unit() < 0.5)
            case .color:
                let h = Double(rng.unit())
                let (r, g, b) = hsv(h, 0.55, 1)
                candidate = .color(RGBA(r, g, b))
            case .gradient: continue
            }
            if let v = s.validated(candidate) { values[s.id] = v }
        }
        return ThemeState(values: values)
    }

    static func hsv(_ h: Double, _ s: Double, _ v: Double) -> (Double, Double, Double) {
        func f(_ n: Double) -> Double {
            let k = (n + h * 6).truncatingRemainder(dividingBy: 6)
            return v - v * s * max(0, min(k, 4 - k, 1))
        }
        return (f(5), f(3), f(1))
    }
}

/// Blends two looks: sliders and colours glide, choices and switches flip at the halfway point.
public func morph(_ a: ThemeState, _ b: ThemeState, specs: [ParamSpec], t: Double) -> ThemeState {
    let t = max(0, min(1, t))
    func lerp(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
    func mix(_ x: RGBA, _ y: RGBA) -> RGBA { RGBA(lerp(x.r, y.r), lerp(x.g, y.g), lerp(x.b, y.b), lerp(x.a, y.a)) }
    var values: [String: ParamValue] = [:]
    for s in specs {
        let va = a.values[s.id] ?? s.defaultValue, vb = b.values[s.id] ?? s.defaultValue
        switch (va, vb) {
        case let (.number(x), .number(y)): values[s.id] = s.validated(.number(lerp(x, y))) ?? va
        case let (.color(x), .color(y)): values[s.id] = .color(mix(x, y))
        case let (.gradient(x), .gradient(y)) where x.count == y.count:
            values[s.id] = .gradient(zip(x, y).map { GradientStop(position: lerp($0.position, $1.position), color: mix($0.color, $1.color)) })
        default: values[s.id] = t < 0.5 ? va : vb
        }
    }
    var macros: [Macro: Double] = [:]
    for m in Macro.allCases {
        let v = lerp(a.macros[m] ?? 0, b.macros[m] ?? 0)
        if v != 0 { macros[m] = v }
    }
    return ThemeState(values: values, macros: macros)
}
