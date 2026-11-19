import Foundation

/// A take's note is a plain value (strings, numbers, a dictionary of numbers and the sensed key), so it crosses threads
/// with the recording layer that carries it.
extension TakeNote: @unchecked Sendable {}

/// One layer of a recording (Recorder spec §3, §4): a stem file in the session folder, with its volume, its mute and
/// the offset that lines it up with what was heard. Saved in `session.json`: fields that are nil are left out, and a
/// file written before a field existed reads with that field's default.
public struct RecordingLayer: Codable, Equatable, Identifiable, Sendable {
    /// 1-based, in recording order. A kept layer's number is never given to a new one.
    public var id: Int
    public var kind: StemKind
    /// What it came from: the instrument ("Felt Glass"), the input ("Microphone"), "Play-along" or "Ambience".
    public var name: String
    /// The stem in the session folder: "Layer 1 — Felt Glass.wav", "Play-along.wav", "Ambience.wav".
    public var fileName: String
    /// An instrument layer's notes ("Layer 1.mid"); nil for every other kind.
    public var midiFileName: String?
    /// 0…2, linear.
    public var volume: Double = 1
    public var muted = false
    /// Where the stem's first frame sits on the recording's clock; negative is earlier (§4: moved by the latency).
    public var offsetFrames: Int = 0
    /// The stem's length.
    public var frames: Int = 0
    /// The Keep That note of the moment it was recorded.
    public var note: TakeNote?

    public init(id: Int, kind: StemKind, name: String, fileName: String, midiFileName: String? = nil, volume: Double = 1,
                muted: Bool = false, offsetFrames: Int = 0, frames: Int = 0, note: TakeNote? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.fileName = fileName
        self.midiFileName = midiFileName
        self.volume = volume
        self.muted = muted
        self.offsetFrames = offsetFrames
        self.frames = frames
        self.note = note
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, name, fileName, midiFileName, volume, muted, offsetFrames, frames, note
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        kind = try c.decode(StemKind.self, forKey: .kind)
        name = try c.decode(String.self, forKey: .name)
        fileName = try c.decode(String.self, forKey: .fileName)
        midiFileName = (try? c.decodeIfPresent(String.self, forKey: .midiFileName)) ?? nil
        volume = (try? c.decodeIfPresent(Double.self, forKey: .volume)) ?? 1
        muted = (try? c.decodeIfPresent(Bool.self, forKey: .muted)) ?? false
        offsetFrames = (try? c.decodeIfPresent(Int.self, forKey: .offsetFrames)) ?? 0
        frames = (try? c.decodeIfPresent(Int.self, forKey: .frames)) ?? 0
        // A note this build can't read is dropped rather than losing the whole recording.
        note = (try? c.decodeIfPresent(TakeNote.self, forKey: .note)) ?? nil
    }
}

/// A recording (Recorder spec §3, §4): its layers in recording order, the sample rate its stems were written at, and the
/// app version that made it. Up to eight played layers (instrument or live input), each up to an hour; the play-along
/// and the ambience are recorded once, on the first pass, and don't count toward the eight.
public struct RecordingSession: Codable, Equatable, Sendable {
    public static let maxLayers = 8, maxSeconds = 3600.0

    public var title: String
    public var sampleRate: Double
    public var layers: [RecordingLayer]
    public var appVersion: String

    public init(title: String, sampleRate: Double, appVersion: String) {
        self.title = title
        self.sampleRate = sampleRate
        self.layers = []
        self.appVersion = appVersion
    }

    /// The kinds that count toward `maxLayers` and are numbered: what he plays, through the app or an input.
    private static func isPlayed(_ kind: StemKind) -> Bool { kind == .instrument || kind == .liveInput }

    /// True while there are fewer than eight instrument and live-input layers.
    public var canAddLayer: Bool {
        var played = 0
        for layer in layers where Self.isPlayed(layer.kind) { played += 1 }
        return played < Self.maxLayers
    }

    /// Where the last layer ends, in seconds (0 with none, or with a bad sample rate).
    public var duration: Double {
        guard sampleRate > 0 else { return 0 }
        var end = 0
        for layer in layers { end = max(end, layer.offsetFrames + layer.frames) }
        return Double(end) / sampleRate
    }

    public var hasPlayAlong: Bool { layers.contains { $0.kind == .playAlong } }
    public var hasAmbience: Bool { layers.contains { $0.kind == .ambience } }

    /// Adds a layer after the others and returns it: the next number after the highest kept (so a deleted newest
    /// layer's number is used again by its retake, and a kept stem is never written over), and its file names. A
    /// played layer is "Layer N — <name>.wav" (an instrument's notes "Layer N.mid"); the play-along is "Play-along.wav"
    /// and the ambience "Ambience.wav", one of each: asking for a second returns the first. Callers check `canAddLayer`.
    @discardableResult
    public mutating func addLayer(kind: StemKind, name: String, note: TakeNote?) -> RecordingLayer {
        if !Self.isPlayed(kind), let existing = layers.first(where: { $0.kind == kind }) { return existing }
        var highest = 0
        for layer in layers { highest = max(highest, layer.id) }
        let id = highest + 1
        let layer: RecordingLayer
        switch kind {
        case .instrument:
            layer = RecordingLayer(id: id, kind: kind, name: name, fileName: Self.playedFileName(id: id, name: name),
                                   midiFileName: "Layer \(id).mid", note: note)
        case .liveInput:
            layer = RecordingLayer(id: id, kind: kind, name: name, fileName: Self.playedFileName(id: id, name: name), note: note)
        case .playAlong:
            layer = RecordingLayer(id: id, kind: kind, name: name, fileName: "Play-along.wav", note: note)
        case .ambience:
            layer = RecordingLayer(id: id, kind: kind, name: name, fileName: "Ambience.wav", note: note)
        }
        layers.append(layer)
        return layer
    }

    /// Removes the layer with that id (nothing if there is none); the others keep theirs.
    public mutating func removeLayer(id: Int) {
        layers.removeAll { $0.id == id }
    }

    /// "Layer 1 — Felt Glass.wav", with the characters a file name can't hold (/ and :) as hyphens, as Keep That names
    /// its takes; "Layer 1.wav" for a blank name.
    private static func playedFileName(id: Int, name: String) -> String {
        var clean = String(name.map { $0 == "/" || $0 == ":" ? "-" : $0 })
        clean = clean.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return clean.isEmpty ? "Layer \(id).wav" : "Layer \(id) — \(clean).wav"
    }

    enum CodingKeys: String, CodingKey {
        case title, sampleRate, layers, appVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        sampleRate = try c.decode(Double.self, forKey: .sampleRate)
        layers = try c.decodeIfPresent([RecordingLayer].self, forKey: .layers) ?? []
        appVersion = (try? c.decodeIfPresent(String.self, forKey: .appVersion)) ?? ""
    }
}
