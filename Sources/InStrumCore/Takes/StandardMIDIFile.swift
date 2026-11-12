import Foundation

/// A kept take as a Standard MIDI File (Small Wins spec §2): type 0, one track, 480 ticks a quarter note. The track
/// opens with its name (the set's) and its tempo (the set's credit, or 120), and every event carries its own status byte.
/// Ticks round from each event's absolute time at the tempo the file states, so every time reads back within half a
/// tick (0.92 ms at 68 BPM, the slowest credit).
public enum StandardMIDIFile {
    public static let ppq: UInt16 = 480

    /// The tempo as the file states it: microseconds a quarter note (120 BPM for a tempo that can't be).
    public static func microseconds(bpm: Double) -> UInt32 {
        let b = bpm.isFinite && bpm > 0 ? bpm : 120
        return UInt32(min(Double(0xFF_FFFF), max(1, (60_000_000 / b).rounded())))
    }

    public static func write(_ take: Take, name: String, bpm: Double) -> Data {
        let tempo = microseconds(bpm: bpm)
        let ticksPerSecond = 1_000_000 * Double(ppq) / Double(tempo)
        func tick(_ seconds: Double) -> UInt32 {
            let t = (max(0, seconds) * ticksPerSecond).rounded()
            return t.isFinite ? UInt32(min(t, Double(0x0FFF_FFFF))) : 0
        }
        var track: [UInt8] = []
        track.reserveCapacity(take.events.count * 4 + 64)
        let title = Array(name.utf8)
        track.append(contentsOf: [0x00, 0xFF, 0x03] as [UInt8])
        track.append(contentsOf: vlq(UInt32(title.count)))
        track.append(contentsOf: title)
        track.append(contentsOf: [0x00, 0xFF, 0x51, 0x03] as [UInt8])
        track.append(UInt8((tempo >> 16) & 0xFF))
        track.append(UInt8((tempo >> 8) & 0xFF))
        track.append(UInt8(tempo & 0xFF))
        var previous: UInt32 = 0
        for e in take.events {
            let bytes = e.message.bytes
            guard !bytes.isEmpty else { continue }
            let at = max(previous, tick(e.time))
            track.append(contentsOf: vlq(at - previous))
            track.append(contentsOf: bytes)
            previous = at
        }
        let end = max(previous, tick(take.duration))   // the take's last moments ring on to its end
        track.append(contentsOf: vlq(end - previous))
        track.append(contentsOf: [0xFF, 0x2F, 0x00] as [UInt8])

        var file: [UInt8] = Array("MThd".utf8)
        file.append(contentsOf: [0, 0, 0, 6, 0, 0, 0, 1] as [UInt8])   // 6 bytes: type 0, one track
        file.append(UInt8(ppq >> 8))
        file.append(UInt8(ppq & 0xFF))
        file.append(contentsOf: Array("MTrk".utf8))
        file.append(contentsOf: bigEndian(UInt32(track.count)))
        file.append(contentsOf: track)
        return Data(file)
    }

    /// The first track of a Standard MIDI File (running status and tempo changes understood): its name, its first tempo
    /// (120 when it states none) and its channel messages in seconds. Nil for anything that isn't one.
    public static func read(_ data: Data) -> (name: String, bpm: Double, events: [TakeEvent])? {
        let b = [UInt8](data)
        guard b.count >= 14, Array(b[0..<4]) == Array("MThd".utf8) else { return nil }
        let headerLength = Int(readBigEndian(b, at: 4))
        guard headerLength >= 6, b.count >= 8 + headerLength else { return nil }
        let division = Int(b[12]) << 8 | Int(b[13])
        guard division & 0x8000 == 0, division > 0 else { return nil }   // not SMPTE time
        var p = 8 + headerLength
        while p + 8 <= b.count {
            let isTrack = Array(b[p..<(p + 4)]) == Array("MTrk".utf8)
            let length = Int(readBigEndian(b, at: p + 4))
            p += 8
            if isTrack { return readTrack(b, from: p, to: min(b.count, p + length), division: Double(division)) }
            p += length
        }
        return nil
    }

    /// A variable-length quantity: seven bits a byte, the highest first, each but the last with its top bit set. Values
    /// above 0x0FFFFFFF (the largest a file can say) say that.
    public static func vlq(_ v: UInt32) -> [UInt8] {
        var value = min(v, 0x0FFF_FFFF)
        var out: [UInt8] = [UInt8(value & 0x7F)]
        value >>= 7
        while value > 0 {
            out.insert(UInt8(value & 0x7F) | 0x80, at: 0)
            value >>= 7
        }
        return out
    }

    // MARK: - Reading

    private static func readTrack(_ b: [UInt8], from start: Int, to end: Int, division: Double) -> (name: String, bpm: Double, events: [TakeEvent])? {
        var p = start
        var name = ""
        var firstTempo: Double?
        var tempo = 500_000.0   // µs a quarter until the track says otherwise
        // Time is worked out from the last tempo change, so it never drifts.
        var ticks = 0, changeTick = 0
        var changeSeconds = 0.0
        var status: UInt8 = 0
        var events: [TakeEvent] = []
        func seconds() -> Double { changeSeconds + Double(ticks - changeTick) * tempo / (division * 1_000_000) }
        while p < end {
            guard let delta = readVLQ(b, &p, end) else { return nil }
            ticks += delta
            guard p < end else { return nil }
            let byte = b[p]
            if byte == 0xFF {   // a meta event: it ends any running status
                guard p + 1 < end else { return nil }
                let type = b[p + 1]
                p += 2
                guard let length = readVLQ(b, &p, end), p + length <= end else { return nil }
                let body = Array(b[p..<(p + length)])
                p += length
                status = 0
                switch type {
                case 0x03 where name.isEmpty: name = String(decoding: body, as: UTF8.self)
                case 0x51 where length == 3:
                    let micro = Double(Int(body[0]) << 16 | Int(body[1]) << 8 | Int(body[2]))
                    guard micro > 0 else { break }
                    changeSeconds = seconds()
                    changeTick = ticks
                    tempo = micro
                    if firstTempo == nil { firstTempo = 60_000_000 / micro }
                case 0x2F: return (name, firstTempo ?? 120, events)
                default: break
                }
                continue
            }
            if byte == 0xF0 || byte == 0xF7 {   // system exclusive: skipped
                p += 1
                guard let length = readVLQ(b, &p, end), p + length <= end else { return nil }
                p += length
                status = 0
                continue
            }
            if byte >= 0x80 {
                status = byte
                p += 1
            }
            guard status >= 0x80, status < 0xF0 else { return nil }   // a data byte with no status to run on
            let kind = status & 0xF0
            let count = kind == 0xC0 || kind == 0xD0 ? 1 : 2
            guard p + count <= end else { return nil }
            let d0 = b[p] & 0x7F, d1 = count > 1 ? b[p + 1] & 0x7F : 0
            p += count
            events.append(TakeEvent(time: seconds(), message: message(status, d0, d1)))
        }
        return (name, firstTempo ?? 120, events)
    }

    /// A channel message as the app's MIDI input reads it (a note-on at velocity 0 is a note-off).
    private static func message(_ status: UInt8, _ d0: UInt8, _ d1: UInt8) -> MIDIMessage {
        let c = status & 0x0F
        switch status & 0xF0 {
        case 0x90: return d1 == 0 ? .noteOff(channel: c, note: d0) : .noteOn(channel: c, note: d0, velocity: d1)
        case 0x80: return .noteOff(channel: c, note: d0, velocity: d1)
        case 0xA0: return .polyPressure(channel: c, note: d0, value: d1)
        case 0xB0: return .controlChange(channel: c, controller: d0, value: d1)
        case 0xD0: return .channelPressure(channel: c, value: d0)
        case 0xE0: return .pitchBend(channel: c, value: UInt16(d0) | UInt16(d1) << 7)
        default: return .other
        }
    }

    private static func readVLQ(_ b: [UInt8], _ p: inout Int, _ end: Int) -> Int? {
        var value = 0
        for _ in 0..<4 {
            guard p < end else { return nil }
            let byte = b[p]
            p += 1
            value = value << 7 | Int(byte & 0x7F)
            if byte & 0x80 == 0 { return value }
        }
        return nil
    }

    private static func bigEndian(_ v: UInt32) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    private static func readBigEndian(_ b: [UInt8], at i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }
}
