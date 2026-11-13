import SwiftUI
import AppKit
import Metal
import InStrumCore

/// The top of Help > Copy Performance Report: which build this is and what Mac it runs on, so a pasted report says what
/// it was measured on. The owner pastes the report into a chat, so it holds no user name, no file path, no serial number
/// and no host name, and every character of it is ASCII.
enum PerformanceReport {
    /// The header lines: the title, the build, macOS, the Mac, one line for each graphics chip, the quality setting and
    /// how long the app has been running, then any `extra` lines (the shaders' warm-up, `ShaderWork.reportLine`).
    /// - Parameters:
    ///   - quality: the quality setting, as the Display section shows it.
    ///   - gentleVisuals: the Gentle visuals switch.
    ///   - runningSeconds: seconds since the app started.
    static func header(quality: QualitySetting, gentleVisuals: Bool, runningSeconds: Double, extra: [String] = []) -> [String] {
        var lines: [String] = []
        lines.append("In Strum Meants performance report")
        lines.append(buildLine())
        lines.append("macOS " + ProcessInfo.processInfo.operatingSystemVersionString)
        lines.append(macLine())
        lines.append(contentsOf: graphicsLines())
        let gentle = gentleVisuals ? "on" : "off"
        lines.append("Quality setting: " + qualityName(quality) + ", Gentle visuals " + gentle)
        lines.append("Running for \(wholeMinutes(runningSeconds)) min")
        lines += extra
        return lines.map { (line: String) -> String in PerformanceLog.asciiOnly(line) }
    }

    /// The quality setting's name in the Display section.
    static func qualityName(_ setting: QualitySetting) -> String {
        switch setting {
        case .auto: return "Auto"
        case .lite: return "Smooth"
        case .high: return "High"
        case .ultra: return "Ultra"
        }
    }

    /// Whole minutes in `seconds` (0 for anything negative or not a number).
    static func wholeMinutes(_ seconds: Double) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int(min(seconds, 1_000_000_000) / 60)
    }

    /// "Build 1.4 (231)", with "dev" for whatever the bundle does not say (an unpackaged build).
    static func buildLine() -> String {
        let short = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap { $0.isEmpty ? nil : $0 }
        let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap { $0.isEmpty ? nil : $0 }
        if short == nil, build == nil { return "Build dev" }
        return "Build " + (short ?? "dev") + " (" + (build ?? "dev") + ")"
    }

    /// "Mac: MacBookPro16,1, Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz, 16 GB".
    static func macLine() -> String {
        let model = sysctlString("hw.model") ?? "unknown model"
        let chip = sysctlString("machdep.cpu.brand_string") ?? "unknown processor"
        let gigabytes = Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
        return "Mac: \(model), \(chip), \(gigabytes) GB"
    }

    /// One line for each Metal device: "Graphics: AMD Radeon Pro 5500M, low power (in use)".
    static func graphicsLines() -> [String] {
        let inUse: UInt64? = MTLCreateSystemDefaultDevice()?.registryID
        var lines: [String] = []
        for device in MTLCopyAllDevices() {
            var line = "Graphics: " + device.name
            if device.isLowPower { line += ", low power" }
            if device.isRemovable { line += ", external" }
            if let inUse, device.registryID == inUse { line += " (in use)" }
            lines.append(line)
        }
        return lines
    }

    /// A string from sysctl (`hw.model`, `machdep.cpu.brand_string`), or nil where the Mac has none.
    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let text = String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

/// "Copy Performance Report" at the end of the Help menu.
struct PerformanceCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .help) {
            Button("Copy Performance Report") { model.copyPerformanceReport() }
        }
    }
}
