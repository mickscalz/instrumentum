import CoreMIDI
import Foundation
import os

public enum MIDIInputError: Error { case clientFailed(OSStatus), portFailed(OSStatus) }

/// Listens to every connected MIDI keyboard (except ones switched off). Raw MIDI 1.0 bytes are passed on
/// unchanged (parsing happens in InStrumCore) on the CoreMIDI thread.
public final class MIDIInput {
    /// Every MIDI input the Mac can see, switched on or off.
    public private(set) var sourceNames: [String] = []

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    /// Sources being listened to.
    private var connected: [MIDIUniqueID: MIDIEndpointRef] = [:]
    /// Sources seen at the last look (to notice removals).
    private var present: Set<MIDIUniqueID> = []
    /// A small number per source, handed to CoreMIDI so each message says where it came from.
    private var tags: [MIDIUniqueID: Int] = [:]
    private var tagNames: [Int: String] = [:]
    private var nextTag = 0
    private var disabled: Set<String> = []
    private var sawRemoval = false
    private let onSourcesChanged: ([String], Bool) -> Void
    /// When each source last sent a note or controller (system uptime), written on the CoreMIDI thread.
    private let activity = OSAllocatedUnfairLock(initialState: [Int: Double]())
    /// The tags of the sources that are a controller (a bank of knobs, not a keyboard): read on the CoreMIDI thread.
    private let controllerTags = OSAllocatedUnfairLock(initialState: Set<Int>())
    private let isController: (String) -> Bool
    /// For lighting the controller's buttons.
    private var outPort = MIDIPortRef()

    /// - onBytes: raw bytes plus a timestamp in seconds (system uptime), on the CoreMIDI thread.
    /// - onSourcesChanged: current source names, and whether a source was removed.
    /// - isController: whether the input with this name is a controller; its bytes then go to `onControllerBytes` (on
    ///   the CoreMIDI thread) and never to `onBytes`, so its buttons and knobs can't play or disturb the instrument.
    public init(onBytes: @escaping ([UInt8], Double) -> Void,
                onSourcesChanged: @escaping (_ names: [String], _ sourceRemoved: Bool) -> Void,
                isController: @escaping (String) -> Bool = { _ in false },
                onControllerBytes: @escaping ([UInt8], Double) -> Void = { _, _ in }) throws {
        self.onSourcesChanged = onSourcesChanged
        self.isController = isController
        var status = MIDIClientCreateWithBlock("In Strum Meants" as CFString, &client) { [weak self] note in
            let id = note.pointee.messageID
            if Thread.isMainThread { self?.handle(id) } else { DispatchQueue.main.async { self?.handle(id) } }
        }
        guard status == noErr else { throw MIDIInputError.clientFailed(status) }
        let activity = self.activity
        let controllerTags = self.controllerTags
        status = MIDIInputPortCreateWithProtocol(client, "In Strum Meants In" as CFString, ._1_0, &port) { list, refCon in
            let time = ProcessInfo.processInfo.systemUptime
            let tag = Int(bitPattern: refCon)
            let fromController = tag != 0 && controllerTags.withLock { $0.contains(tag) }
            for bytes in MIDIInput.messages(in: list) where !bytes.isEmpty {
                // Notes and controllers light the activity dot (clock and active sensing don't).
                if tag != 0, let status = bytes.first, status >= 0x80, status < 0xF0 { activity.withLock { $0[tag] = time } }
                if fromController { onControllerBytes(bytes, time) } else { onBytes(bytes, time) }
            }
        }
        guard status == noErr else { throw MIDIInputError.portFailed(status) }
        MIDIOutputPortCreate(client, "In Strum Meants Out" as CFString, &outPort)   // lights only: fine to go without
        refresh()
    }

    deinit {
        MIDIPortDispose(port)
        if outPort != 0 { MIDIPortDispose(outPort) }
        MIDIClientDispose(client)
    }

    // MARK: - Choosing sources (main thread)

    /// Stops listening to the inputs with these names (and listens again to the rest).
    public func setDisabled(_ names: Set<String>) {
        guard names != disabled else { return }
        disabled = names
        refresh()
    }

    /// Reconnects every input from scratch (for a keyboard that isn't being heard).
    public func rescan() {
        for src in connected.values { MIDIPortDisconnectSource(port, src) }
        connected.removeAll()
        refresh(force: true)
    }

    /// When the input with this name last sent a note or controller (system uptime), if ever.
    public func lastActivity(_ name: String) -> Double? {
        let wanted = tagNames.filter { $0.value == name }.map(\.key)
        guard !wanted.isEmpty else { return nil }
        return activity.withLock { a in wanted.compactMap { a[$0] }.max() }
    }

    // MARK: - Sources

    private func handle(_ id: MIDINotificationMessageID) {
        switch id {
        case .msgObjectRemoved:
            sawRemoval = true
            refresh()
        case .msgObjectAdded, .msgSetupChanged:
            refresh()
        default:
            break
        }
    }

    private func refresh(force: Bool = false) {
        var names: [String] = []
        var seen: Set<MIDIUniqueID> = []
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            guard src != 0 else { continue }
            var uid: MIDIUniqueID = 0
            if MIDIObjectGetIntegerProperty(src, kMIDIPropertyUniqueID, &uid) != noErr { uid = MIDIUniqueID(bitPattern: src) }
            seen.insert(uid)
            let name = Self.name(of: src)
            names.append(name)
            let tag: Int
            if let t = tags[uid] { tag = t } else { nextTag += 1; tag = nextTag; tags[uid] = tag }
            tagNames[tag] = name
            let controller = isController(name)
            controllerTags.withLock { tags in
                if controller { tags.insert(tag) } else { tags.remove(tag) }
            }
            if !disabled.contains(name) {
                if connected[uid] == nil, MIDIPortConnectSource(port, src, UnsafeMutableRawPointer(bitPattern: tag)) == noErr {
                    connected[uid] = src
                }
            } else if let old = connected.removeValue(forKey: uid) {
                MIDIPortDisconnectSource(port, old)
            }
        }
        for uid in connected.keys where !seen.contains(uid) { connected[uid] = nil }
        let removed = sawRemoval || !present.subtracting(seen).isEmpty
        sawRemoval = false
        present = seen
        guard names != sourceNames || removed || force else { return }
        sourceNames = names
        onSourcesChanged(names, removed)
    }

    // MARK: - The controller's lights

    /// Sends short MIDI messages (three bytes each: a status and two data bytes) to every MIDI output that is a
    /// controller, to light its buttons. Main thread. Does nothing when there is none.
    public func sendToController(_ messages: [[UInt8]]) {
        guard outPort != 0, !messages.isEmpty else { return }
        for i in 0..<MIDIGetNumberOfDestinations() {
            let destination = MIDIGetDestination(i)
            guard destination != 0, isController(Self.name(of: destination)) else { continue }
            for bytes in messages where bytes.count == 3 {
                var word: UInt32 = 0x2000_0000 | UInt32(bytes[0]) << 16 | UInt32(bytes[1] & 0x7F) << 8 | UInt32(bytes[2] & 0x7F)
                var list = MIDIEventList()
                let packet = MIDIEventListInit(&list, ._1_0)
                _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, 1, &word)
                MIDISendEventList(outPort, destination, &list)
            }
        }
    }

    private static func name(of endpoint: MIDIEndpointRef) -> String {
        var cf: Unmanaged<CFString>?
        if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &cf) == noErr, let s = cf?.takeRetainedValue() {
            return s as String
        }
        if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &cf) == noErr, let s = cf?.takeRetainedValue() {
            return s as String
        }
        return "MIDI Device"
    }

    // MARK: - Universal MIDI Packet → MIDI 1.0 bytes

    static func messages(in list: UnsafePointer<MIDIEventList>) -> [[UInt8]] {
        var out: [[UInt8]] = []
        for packet in list.unsafeSequence() {
            let count = Int(packet.pointee.wordCount)
            withUnsafeBytes(of: packet.pointee.words) { raw in
                let words = raw.bindMemory(to: UInt32.self)
                var i = 0
                while i < min(count, words.count) {
                    let w = words[i]
                    out.append(bytes(fromUMP: w))
                    i += wordsInMessage(type: UInt8(w >> 28))
                }
            }
        }
        return out
    }

    static func wordsInMessage(type: UInt8) -> Int {
        switch type {
        case 0x0, 0x1, 0x2, 0x6, 0x7: return 1
        case 0x3, 0x4, 0x8, 0x9, 0xA: return 2
        case 0xB, 0xC: return 3
        default: return 4
        }
    }

    /// Converts one 32-bit MIDI 1.0 UMP word (types 1 and 2) to raw bytes; other types give [].
    static func bytes(fromUMP w: UInt32) -> [UInt8] {
        let type = w >> 28
        let status = UInt8((w >> 16) & 0xFF)
        let d1 = UInt8((w >> 8) & 0x7F), d2 = UInt8(w & 0x7F)
        switch type {
        case 0x1:
            switch status {
            case 0xF1, 0xF3: return [status, d1]
            case 0xF2: return [status, d1, d2]
            default: return [status]
            }
        case 0x2:
            switch status & 0xF0 {
            case 0xC0, 0xD0: return [status, d1]
            default: return [status, d1, d2]
            }
        default:
            return []
        }
    }
}
