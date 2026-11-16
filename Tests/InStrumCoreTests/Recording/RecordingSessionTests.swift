import XCTest
@testable import InStrumCore

/// The Recorder's session (Recorder spec §3, §4; plan Task 1): layers in recording order and their file names, the
/// eight-layer limit (which counts only the instrument and live-input layers), and the length of the whole.
final class RecordingSessionTests: XCTestCase {
    private func session() -> RecordingSession {
        RecordingSession(title: "Moonlit Lake", sampleRate: 48_000, appVersion: "dev")
    }

    private func note() -> TakeNote {
        TakeNote(setID: "moonlit-lake", worldID: "moonlit-lake",
                 instrument: .init(patchID: "felt-glass", name: "Felt Glass", dials: ["Tone": 0.5]),
                 sky: nil, key: AmbienceKey(root: 2, major: true), appVersion: "dev", seconds: 64)
    }

    func testLayerNamesAndIDs() {
        var s = session()
        let first = s.addLayer(kind: .instrument, name: "Felt Glass", note: note())
        let second = s.addLayer(kind: .instrument, name: "Magma Bass", note: nil)
        XCTAssertEqual(first.id, 1)
        XCTAssertEqual(second.id, 2)
        XCTAssertEqual(first.fileName, "Layer 1 — Felt Glass.wav")
        XCTAssertEqual(first.midiFileName, "Layer 1.mid")
        XCTAssertEqual(second.fileName, "Layer 2 — Magma Bass.wav")
        XCTAssertEqual(second.midiFileName, "Layer 2.mid")
        XCTAssertEqual(first.note, note(), "the Keep That note of the moment rides with the layer")
        XCTAssertEqual(first.name, "Felt Glass")
        XCTAssertEqual(first.kind, .instrument)
        // A new layer starts at full volume, unmuted, unmoved and empty.
        XCTAssertEqual(first.volume, 1)
        XCTAssertFalse(first.muted)
        XCTAssertEqual(first.offsetFrames, 0)
        XCTAssertEqual(first.frames, 0)

        let mic = s.addLayer(kind: .liveInput, name: "Microphone", note: nil)
        XCTAssertEqual(mic.id, 3)
        XCTAssertEqual(mic.fileName, "Layer 3 — Microphone.wav")
        XCTAssertNil(mic.midiFileName, "a live input has no notes")

        // The play-along and the ambience have fixed names, no notes, and at most one of each.
        XCTAssertFalse(s.hasPlayAlong)
        XCTAssertFalse(s.hasAmbience)
        let along = s.addLayer(kind: .playAlong, name: "Play-along", note: nil)
        XCTAssertEqual(along.fileName, "Play-along.wav")
        XCTAssertNil(along.midiFileName)
        XCTAssertTrue(s.hasPlayAlong)
        let alongAgain = s.addLayer(kind: .playAlong, name: "Play-along", note: nil)
        XCTAssertEqual(alongAgain.id, along.id, "never a second play-along")
        let ambience = s.addLayer(kind: .ambience, name: "Ambience", note: nil)
        XCTAssertEqual(ambience.fileName, "Ambience.wav")
        XCTAssertNil(ambience.midiFileName)
        XCTAssertTrue(s.hasAmbience)
        let ambienceAgain = s.addLayer(kind: .ambience, name: "Ambience", note: nil)
        XCTAssertEqual(ambienceAgain.id, ambience.id, "never a second ambience")
        let count = s.layers.count
        XCTAssertEqual(count, 5)
        let ids = s.layers.map(\.id)
        XCTAssertEqual(ids, [1, 2, 3, 4, 5], "in recording order")

        // Neither counts toward the eight: five more played layers still fit (3 + 5), then no more.
        for n in 1...5 {
            XCTAssertTrue(s.canAddLayer, "played layer \(n + 3) fits")
            _ = s.addLayer(kind: .instrument, name: "Felt Glass", note: nil)
        }
        XCTAssertFalse(s.canAddLayer)

        // A name a file can't hold (/ and :) becomes hyphens in the file name, as Keep That's takes do; the name
        // itself is kept as it was.
        var other = session()
        let plugin = other.addLayer(kind: .instrument, name: "AU: Strings/Pad", note: nil)
        XCTAssertEqual(plugin.fileName, "Layer 1 — AU- Strings-Pad.wav")
        XCTAssertEqual(plugin.name, "AU: Strings/Pad")
        let unnamed = other.addLayer(kind: .liveInput, name: "  ", note: nil)
        XCTAssertEqual(unnamed.fileName, "Layer 2.wav", "a blank name leaves just the number")
    }

    func testEightLayersThenNoMore() {
        XCTAssertEqual(RecordingSession.maxLayers, 8)
        XCTAssertEqual(RecordingSession.maxSeconds, 3600)
        var s = session()
        for n in 1...8 {
            XCTAssertTrue(s.canAddLayer, "layer \(n) fits")
            let kind: StemKind = n % 2 == 0 ? .liveInput : .instrument
            _ = s.addLayer(kind: kind, name: "Felt Glass", note: nil)
        }
        XCTAssertFalse(s.canAddLayer, "eight is the most")
        let count = s.layers.count
        XCTAssertEqual(count, 8)
        s.removeLayer(id: 8)
        XCTAssertTrue(s.canAddLayer, "deleting one makes room again")
    }

    func testRemoveLayerKeepsOtherIDs() {
        var s = session()
        _ = s.addLayer(kind: .instrument, name: "Felt Glass", note: nil)
        _ = s.addLayer(kind: .instrument, name: "Magma Bass", note: nil)
        _ = s.addLayer(kind: .instrument, name: "Glass Harp", note: nil)
        s.removeLayer(id: 2)
        let ids = s.layers.map(\.id)
        XCTAssertEqual(ids, [1, 3])
        let files = s.layers.map(\.fileName)
        XCTAssertEqual(files, ["Layer 1 — Felt Glass.wav", "Layer 3 — Glass Harp.wav"])

        // The next layer never takes a kept layer's number, so it never writes over a kept stem.
        let next = s.addLayer(kind: .instrument, name: "Glass Harp", note: nil)
        XCTAssertEqual(next.id, 4)
        XCTAssertEqual(next.fileName, "Layer 4 — Glass Harp.wav")

        // An id that isn't there changes nothing.
        s.removeLayer(id: 99)
        let kept = s.layers.count
        XCTAssertEqual(kept, 3)

        // Deleting the newest (the undo for a bad take) frees its number for the retake.
        s.removeLayer(id: 4)
        let retake = s.addLayer(kind: .instrument, name: "Glass Harp", note: nil)
        XCTAssertEqual(retake.id, 4)
    }

    func testDurationIsTheLongestEnd() {
        var s = session()
        XCTAssertEqual(s.duration, 0, "no layers, no length")
        _ = s.addLayer(kind: .instrument, name: "Felt Glass", note: nil)
        _ = s.addLayer(kind: .playAlong, name: "Play-along", note: nil)
        s.layers[0].frames = 48_000
        s.layers[0].offsetFrames = -480
        s.layers[1].frames = 24_000
        XCTAssertEqual(s.duration, 0.99, accuracy: 1e-9, "1 s moved 10 ms earlier ends at 0.99 s")
        s.layers[1].frames = 96_000
        XCTAssertEqual(s.duration, 2, accuracy: 1e-9)
        s.layers[1].frames = 0
        s.layers[1].offsetFrames = 0
        s.layers[0].frames = 100
        s.layers[0].offsetFrames = -480
        XCTAssertEqual(s.duration, 0, "a layer that ends before the start adds no length")
    }
}
