// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "InStrumMeants",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "InStrumMeants", targets: ["InStrumMeants"])
    ],
    dependencies: [
        // The in-app updater ("Check for Updates…"): infrastructure only, nothing in the sound or picture path. Only the
        // app's executable links it, so the tests never load it.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.6.4"),
    ],
    targets: [
        // Optimised even in debug, so tests measure the real cost of the simulations (cloth, frost growth).
        .target(name: "InStrumCore", swiftSettings: [.unsafeFlags(["-O"])]),
        // Real-time DSP (C++17 behind a C header). Optimised even in debug so tests measure real cost.
        .target(name: "InStrumDSP", cxxSettings: [.unsafeFlags(["-O2", "-fno-math-errno"])]),
        .target(name: "InStrumAudio", dependencies: ["InStrumCore", "InStrumDSP"]),
        .target(name: "InStrumApp", dependencies: ["InStrumCore", "InStrumAudio"]),
        .executableTarget(name: "InStrumMeants", dependencies: ["InStrumApp", .product(name: "Sparkle", package: "Sparkle")]),
        .testTarget(name: "InStrumCoreTests", dependencies: ["InStrumCore"]),
        .testTarget(name: "InStrumAudioTests", dependencies: ["InStrumAudio", "InStrumCore", "InStrumDSP"]),
        .testTarget(name: "InStrumAppTests", dependencies: ["InStrumApp", "InStrumAudio", "InStrumCore", "InStrumDSP"]),
    ],
    cxxLanguageStandard: .cxx17
)
