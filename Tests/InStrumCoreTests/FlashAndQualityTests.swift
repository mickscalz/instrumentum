import XCTest
@testable import InStrumCore

final class FlashLimiterTests: XCTestCase {
    /// Counts rises of more than 0.25 within 0.1 s inside each 1 s window.
    private func maxFlashesPerSecond(_ series: [Float], dt: Double) -> Int {
        var flashTimes: [Double] = []
        var lastFlash = -1.0
        for i in 1..<series.count {
            let back = max(0, i - Int(0.1 / dt))
            if series[i] - series[back] > 0.25, Double(i) * dt - lastFlash > 0.1 {
                flashTimes.append(Double(i) * dt); lastFlash = Double(i) * dt
            }
        }
        var best = 0
        for t in flashTimes { best = max(best, flashTimes.filter { $0 >= t && $0 < t + 1 }.count) }
        return best
    }

    func testStrobeLimitedToThreeFlashesPerSecond() {
        var f = FlashLimiter()
        let dt = 1.0 / 60
        var out: [Float] = []
        for i in 0..<180 {
            let strobe: Float = (i / 3) % 2 == 0 ? 0 : 1          // 10 Hz
            out.append(f.limit(exposure: strobe, sparkle: 0, dt: dt).exposure)
        }
        XCTAssertLessThanOrEqual(maxFlashesPerSecond(out, dt: dt), 3)
    }
    func testSmoothSwellUnaffected() {
        var f = FlashLimiter()
        for i in 0..<120 {
            let v = Float(i) / 120
            XCTAssertEqual(f.limit(exposure: v, sparkle: 0, dt: 1.0 / 60).exposure, v, accuracy: 0.001)
        }
    }
    func testFallsAreNeverLimited() {
        var f = FlashLimiter()
        _ = f.limit(exposure: 1, sparkle: 0, dt: 1.0 / 60)
        XCTAssertEqual(f.limit(exposure: 0, sparkle: 0, dt: 1.0 / 60).exposure, 0, accuracy: 0.001)
    }
    func testGentleHalvesSparkle() {
        var f = FlashLimiter(gentle: true)
        XCTAssertEqual(f.limit(exposure: 0.5, sparkle: 0.8, dt: 1.0 / 60).sparkle, 0.4, accuracy: 0.001)
    }
}

final class AutoQualityTests: XCTestCase {
    func testAutoStartsSmooth() {
        var q = AutoQuality(setting: .auto)
        XCTAssertEqual(q.record(frameTime: 1.0 / 60), .lite)
    }
    func testAutoStepsUpAfterTenGoodSeconds() {
        var q = AutoQuality(setting: .auto)
        var level = QualityLevel.lite
        for _ in 0..<(10 * 60 + 2) { level = q.record(frameTime: 1.0 / 60) }
        XCTAssertEqual(level, .high)
        for _ in 0..<(30 * 60) { level = q.record(frameTime: 1.0 / 60) }
        XCTAssertEqual(level, .high, "Auto never goes above High")
    }
    func testAutoStepsDownAfterOneSlowSecond() {
        var q = AutoQuality(setting: .auto)
        for _ in 0..<(10 * 60 + 2) { _ = q.record(frameTime: 1.0 / 60) }
        var level = QualityLevel.high
        for _ in 0..<(1 * 40 + 2) { level = q.record(frameTime: 1.0 / 40) }
        XCTAssertEqual(level, .lite)
    }
    func testShortHiccupIsTolerated() {
        var q = AutoQuality(setting: .auto)
        for _ in 0..<(10 * 60 + 2) { _ = q.record(frameTime: 1.0 / 60) }
        var level = QualityLevel.high
        for _ in 0..<20 { level = q.record(frameTime: 1.0 / 40) }
        for _ in 0..<60 { level = q.record(frameTime: 1.0 / 60) }
        XCTAssertEqual(level, .high)
    }
    func testFixedSettingNeverChangesWhenMerelySlow() {
        var q = AutoQuality(setting: .ultra)
        var level = QualityLevel.lite
        for _ in 0..<300 { level = q.record(frameTime: 1.0 / 20) }
        XCTAssertEqual(level, .ultra)
    }
    func testSafetyNetDropsAnySettingWhenFramesStall() {
        var q = AutoQuality(setting: .ultra)
        _ = q.record(frameTime: 1.0 / 60)
        _ = q.record(frameTime: 2.0)
        XCTAssertEqual(q.record(frameTime: 30.0), .lite)
        XCTAssertEqual(q.record(frameTime: 1.0 / 60), .lite, "stays safe for the session")
        XCTAssertTrue(q.rescued)
        q.setting = .high
        XCTAssertEqual(q.record(frameTime: 1.0 / 60), .high, "choosing again clears the safety net")
    }
    func testOneSlowFrameIsNotAStall() {
        var q = AutoQuality(setting: .high)
        _ = q.record(frameTime: 0.5)
        XCTAssertEqual(q.record(frameTime: 1.0 / 60), .high)
    }

    // MARK: The graphics chip's clock (12 Nov: Supercell Sky froze an Intel MacBook Pro)

    /// One frame that keeps the GPU busy for a tenth of a second drops any setting to Smooth at once and halves the
    /// picture, with no second frame needed.
    func testOneHeavyGPUFrameDropsToSmoothAtOnce() {
        var q = AutoQuality(setting: .ultra)
        XCTAssertEqual(q.record(frameTime: 1.0 / 60, gpuTime: 0.008), .ultra)
        XCTAssertEqual(q.record(frameTime: 1.0 / 60, gpuTime: 0.12), .lite)
        XCTAssertTrue(q.rescued)
        XCTAssertEqual(q.pixelScale, 0.5, accuracy: 1e-9)
        XCTAssertEqual(q.record(frameTime: 1.0 / 60, gpuTime: 0), .lite, "stays safe for the session")
    }

    /// A fixed setting that is merely slow on the GPU (under the stall line) is left alone, as before.
    func testMerelySlowGPUKeepsAFixedSetting() {
        var q = AutoQuality(setting: .high)
        var level = QualityLevel.lite
        for _ in 0..<300 { level = q.record(frameTime: 1.0 / 20, gpuTime: 0.05) }
        XCTAssertEqual(level, .high)
        XCTAssertEqual(q.pixelScale, 1)
    }

    /// At Smooth, frames still heavy on the GPU shrink the picture (never below the floor, at most every 0.3 s), and
    /// five seconds of easy frames let it grow back.
    func testSmoothShrinksWhileHeavyAndGrowsBack() {
        var q = AutoQuality(setting: .lite)
        for _ in 0..<20 { _ = q.record(frameTime: 0.06, gpuTime: 0.06) }   // 1.2 s of heavy frames
        XCTAssertLessThan(q.pixelScale, 0.7)
        XCTAssertGreaterThan(q.pixelScale, 0.3, "at most one step every 0.3 s")
        for _ in 0..<2000 { _ = q.record(frameTime: 0.06, gpuTime: 0.09) }
        XCTAssertEqual(q.pixelScale, AutoQuality.minPixelScale, accuracy: 1e-9, "never below the floor")
        let shrunk = q.pixelScale
        for _ in 0..<(6 * 60) { _ = q.record(frameTime: 1.0 / 60, gpuTime: 0.01) }
        XCTAssertGreaterThan(q.pixelScale, shrunk)
        for _ in 0..<(60 * 60) { _ = q.record(frameTime: 1.0 / 60, gpuTime: 0.01) }
        XCTAssertEqual(q.pixelScale, 1, "all the way back")
    }

    /// Frames with no GPU time yet (none finished) neither shrink nor grow anything, and nonsense never sticks.
    func testNoGPUTimeChangesNothing() {
        var q = AutoQuality(setting: .auto)
        for _ in 0..<100 { _ = q.record(frameTime: 1.0 / 60, gpuTime: 0) }
        _ = q.record(frameTime: .nan, gpuTime: .infinity)
        XCTAssertEqual(q.pixelScale, 1)
        XCTAssertFalse(q.rescued)
    }
}

final class RenderScaleTests: XCTestCase {
    func testSmoothDrawsFewerPixels() {
        // 1440x900 pt window on a Retina screen.
        let lite = RenderScale.pixels(points: (1440, 900), backingScale: 2, quality: .lite)
        let high = RenderScale.pixels(points: (1440, 900), backingScale: 2, quality: .high)
        let ultra = RenderScale.pixels(points: (1440, 900), backingScale: 2, quality: .ultra)
        XCTAssertEqual(ultra.width, 2880); XCTAssertEqual(ultra.height, 1800)
        XCTAssertLessThan(high.width * high.height, ultra.width * ultra.height)
        XCTAssertLessThanOrEqual(lite.width * lite.height, 1_000_000)
        XCTAssertEqual(Double(lite.width) / Double(lite.height), 1.6, accuracy: 0.01)
    }
    func testNeverZero() {
        let p = RenderScale.pixels(points: (0, 0), backingScale: 2, quality: .lite)
        XCTAssertGreaterThan(p.width, 0); XCTAssertGreaterThan(p.height, 0)
        let q = RenderScale.pixels(points: (0, 0), backingScale: 2, quality: .high, pixelScale: 0, appleGPU: false)
        XCTAssertGreaterThan(q.width, 0); XCTAssertGreaterThan(q.height, 0)
    }

    /// On an Intel or AMD graphics chip every quality is capped (a 16-inch MacBook Pro full screen is 6 MP at Ultra).
    func testOtherGPUsAreCapped() {
        for quality in [QualityLevel.lite, .high, .ultra] {
            let p = RenderScale.pixels(points: (1728, 1117), backingScale: 2, quality: quality, appleGPU: false)
            XCTAssertLessThanOrEqual(Double(p.width * p.height), RenderScale.otherGPUMaxPixels[quality]!, "\(quality)")
            XCTAssertEqual(Double(p.width) / Double(p.height), 1728.0 / 1117.0, accuracy: 0.01)
        }
        let apple = RenderScale.pixels(points: (1728, 1117), backingScale: 2, quality: .ultra)
        XCTAssertEqual(apple.width, 3456, "Apple GPUs keep the full factor")
    }

    /// The safety net's pixel scale takes that share of the pixels (by area) at any quality.
    func testPixelScaleTakesItsShare() {
        let full = RenderScale.pixels(points: (1440, 900), backingScale: 2, quality: .lite)
        let half = RenderScale.pixels(points: (1440, 900), backingScale: 2, quality: .lite, pixelScale: 0.5)
        XCTAssertEqual(Double(half.width * half.height) / Double(full.width * full.height), 0.5, accuracy: 0.01)
        let high = RenderScale.pixels(points: (1440, 900), backingScale: 2, quality: .high, pixelScale: 0.25)
        XCTAssertEqual(Double(high.width * high.height), 2160.0 * 1350.0 * 0.25, accuracy: 2160.0 * 1350.0 * 0.01)
    }
}
