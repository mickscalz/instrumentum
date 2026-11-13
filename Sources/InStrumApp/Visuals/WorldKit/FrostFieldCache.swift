import Foundation
import InStrumCore

/// The windows' frost fields, grown once per process for each seed and pane layout on a background queue, and handed on
/// the main thread to every glass that asks (real-Mac performance, 14 Nov). The cabin's and the bedroom's fields have
/// fixed seeds, so they are the same for every renderer: a second renderer (the warm-up's, or one more in a test run) no
/// longer grows its own, which kept a core busy for seconds each and slowed whatever ran beside it. The field itself is
/// the same as before (`FrostField` is seeded), so the glass looks the same.
final class FrostFieldCache: @unchecked Sendable {
    static let shared = FrostFieldCache()

    private struct Key: Hashable {
        let seed: UInt64
        let columns: Int
        let rows: Int
        let bar: Float
    }

    private let lock = NSLock()
    private var grown: [Key: FrostField] = [:]
    private var waiting: [Key: [(FrostField) -> Void]] = [:]
    private var growthCount = 0

    /// How many fields have been grown so far (tests).
    var growths: Int { lock.lock(); defer { lock.unlock() }; return growthCount }

    /// Hands the field for these panes to `deliver` on the main thread: on the main queue's next turn when it has grown,
    /// else as soon as it has (one growth, however many ask meanwhile).
    func field(seed: UInt64, columns: Int, rows: Int, bar: Float, deliver: @escaping (FrostField) -> Void) {
        let key = Key(seed: seed, columns: columns, rows: rows, bar: bar)
        lock.lock()
        if let field = grown[key] {
            lock.unlock()
            DispatchQueue.main.async { deliver(field) }
            return
        }
        let first = waiting[key] == nil
        waiting[key, default: []].append(deliver)
        if first { growthCount += 1 }
        lock.unlock()
        guard first else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let field = FrostField(seed: seed, columns: columns, rows: rows, bar: bar)
            self.lock.lock()
            self.grown[key] = field
            let handlers = self.waiting.removeValue(forKey: key) ?? []
            self.lock.unlock()
            DispatchQueue.main.async { for handler in handlers { handler(field) } }
        }
    }
}
