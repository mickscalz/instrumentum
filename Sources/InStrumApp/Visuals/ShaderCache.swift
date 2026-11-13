import Foundation
import Metal

/// Shader work kept off the draw path (real-Mac performance, 14 Nov 2026).
///
/// Michael's MacBook Pro (Radeon Pro 560, build 214) showed a worst frame of 740–900 ms and a stall of 2–10 s in nearly
/// every world: each world's renderer compiled its MSL and built its pipelines on the main thread, inside the first frame
/// that showed it, and the sky's storm programs were built inside the first frame that needed them. Now every library is
/// compiled once per process and shared (`ShaderCache`), the shared layers' pipelines are made once and shared, the worlds'
/// renderers are made on `queue` (`WorldRenderers`), and in the app a storm program a frame finds missing is made on
/// `queue` too while that frame draws without it.
enum ShaderWork {
    /// Marks `queue`, so a pipeline can tell it is being made there (the warm-up's own).
    static let queueKey = DispatchSpecificKey<Bool>()
    /// The one queue the background shader work runs on: one job at a time, below the main thread's priority.
    static let queue: DispatchQueue = {
        let q = DispatchQueue(label: "In Strum Meants shader work", qos: .utility)
        q.setSpecific(key: queueKey, value: true)
        return q
    }()
    /// True on `queue`.
    static var onQueue: Bool { DispatchQueue.getSpecific(key: queueKey) == true }

    /// True in the app (the canvas sets it as it starts): a storm program or the supercell's kernel a frame finds missing
    /// is made on `queue`, and that frame draws without it (the plain sky; the supercell drawn in the sky itself). False
    /// in previews and tests, which make it at once, so every frame there is exactly as it always was. Main thread.
    static var defersDrawPathBuilds = false
    /// True while the canvas draws a frame (main thread).
    static var drawing = false
    /// Libraries, pipelines and renderers made on the main thread while the canvas was drawing a frame: each one held
    /// that frame up. Zero once the warm-up is done (Tea House Snow and Zen Rock Garden, made on the main thread when
    /// first entered, count one each).
    private(set) static var drawPathBuilds = 0
    /// What the last of them was (for tests' messages).
    private(set) static var lastDrawPathBuild = ""

    /// Counts a library, pipeline or renderer about to be made now, if it is on the draw path (the main thread, inside a
    /// frame). Any thread.
    static func noteBuild(_ what: String) {
        guard Thread.isMainThread, drawing else { return }
        drawPathBuilds += 1
        lastDrawPathBuild = what
    }

    /// Tests: start counting again.
    static func resetCounts() {
        drawPathBuilds = 0
        lastDrawPathBuild = ""
    }

    // MARK: - The warm-up's progress, for Help > Copy Performance Report (main thread)

    /// When the warm-up started and finished (system uptime; nil before), and how many worlds it has made of how many.
    static var warmStarted: Double?
    static var warmFinished: Double?
    static var worldsReady = 0
    static var worldsToWarm = 0

    /// The report's line: how far the warm-up got and how many builds held a frame up.
    static func reportLine() -> String {
        var line = "Shaders: "
        if let start = warmStarted {
            line += "\(worldsReady) of \(worldsToWarm) worlds made in the background"
            if let end = warmFinished {
                line += ", all made \(Int(max(0, end - start).rounded())) s after launch"
            } else {
                line += " so far"
            }
        } else {
            line += "no warm-up"
        }
        return line + "; \(drawPathBuilds) built while drawing"
    }
}

/// Compiled shader libraries (one per shader source) and pipelines made once and shared, for the life of the process.
/// Any thread: what a thread asks for is made on that thread the first time, outside the lock, then shared (two threads
/// asking at once for the same thing may both make it; the first kept wins).
final class ShaderCache: @unchecked Sendable {
    static let shared = ShaderCache()

    private struct LibraryKey: Hashable {
        let device: UInt64
        let source: String
    }
    /// What was made for a key (nil when it couldn't be made, so it isn't tried again and again).
    private final class Made {
        let value: Any?
        init(_ value: Any?) { self.value = value }
    }

    private let lock = NSLock()
    private var libraries: [LibraryKey: MTLLibrary] = [:]
    private var made: [String: Made] = [:]
    private var requested: Set<String> = []
    private var compiles = 0
    private var makes = 0

    /// Libraries compiled and things made so far (tests).
    var libraryCompiles: Int { lock.lock(); defer { lock.unlock() }; return compiles }
    var madeCount: Int { lock.lock(); defer { lock.unlock() }; return makes }

    /// `source` compiled for `device`: on the thread that first asks, then shared by everyone.
    static func library(_ device: MTLDevice, source: String) -> MTLLibrary? {
        shared.library(device, source: source)
    }

    func library(_ device: MTLDevice, source: String) -> MTLLibrary? {
        let key = LibraryKey(device: device.registryID, source: source)
        lock.lock()
        if let found = libraries[key] {
            lock.unlock()
            return found
        }
        lock.unlock()
        ShaderWork.noteBuild("a shader library")
        guard let compiled = try? device.makeLibrary(source: source, options: nil) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        compiles += 1
        if let first = libraries[key] { return first }
        libraries[key] = compiled
        return compiled
    }

    private static func key(_ key: String, _ device: MTLDevice) -> String { "\(device.registryID) \(key)" }

    /// What `make` makes for `key` on `device` (a pipeline, or a set of them), made the first time any thread asks and
    /// shared from then on; nil when it can't be made (not tried again).
    func memo<T>(_ key: String, device: MTLDevice, _ make: () -> T?) -> T? {
        let k = Self.key(key, device)
        lock.lock()
        if let found = made[k] {
            lock.unlock()
            return found.value as? T
        }
        lock.unlock()
        ShaderWork.noteBuild(key)
        let value = make()
        lock.lock()
        defer { lock.unlock() }
        if let first = made[k] { return first.value as? T }
        makes += 1
        made[k] = Made(value)
        return value
    }

    /// Whether `key` has been made (or tried), and what was made, without making it.
    func peek<T>(_ key: String, device: MTLDevice, as type: T.Type) -> (known: Bool, value: T?) {
        let k = Self.key(key, device)
        lock.lock()
        defer { lock.unlock() }
        guard let found = made[k] else { return (false, nil) }
        return (true, found.value as? T)
    }

    /// Starts making `key` on `ShaderWork.queue`, unless it is made or already on its way.
    func request<T>(_ key: String, device: MTLDevice, _ make: @escaping () -> T?) {
        let k = Self.key(key, device)
        lock.lock()
        if made[k] != nil || requested.contains(k) {
            lock.unlock()
            return
        }
        requested.insert(k)
        lock.unlock()
        ShaderWork.queue.async { _ = self.memo(key, device: device, make) }
    }
}
