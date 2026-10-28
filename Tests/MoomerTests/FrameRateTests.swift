import Foundation
import Testing
import MoomerCore

struct FrameRateTests {
    @Test(arguments: [59.94, 60, 75, 120, 144, 165, 240, 360])
    func automaticMatchesSelectedMode(hz: Double) {
        #expect(FrameRate.automatic.targetFPS(displayRefreshRate: hz, maximumFramesPerSecond: 360) == hz)
    }

    @Test func automaticUpdatesForEachMonitor() {
        let policy = FrameRate.automatic
        #expect(policy.targetFPS(displayRefreshRate: 144, maximumFramesPerSecond: 144) == 144)
        #expect(policy.targetFPS(displayRefreshRate: 60, maximumFramesPerSecond: 144) == 60)
    }

    @Test(arguments: [Double(0), -1, .nan, .infinity])
    func variableOrUnknownModeFallsBackToAppKit(hz: Double) {
        #expect(FrameRate.automatic.targetFPS(displayRefreshRate: hz, maximumFramesPerSecond: 120) == 120)
    }

    @Test func missingDisplayTimingFallsBackToSixty() {
        #expect(FrameRate.automatic.targetFPS(displayRefreshRate: 0, maximumFramesPerSecond: 0) == 60)
    }

    @Test func manualOverrideCapsNativeCadence() {
        #expect(FrameRate.fixed(60).targetFPS(displayRefreshRate: 144, maximumFramesPerSecond: 144) == 60)
        #expect(FrameRate.fixed(240).targetFPS(displayRefreshRate: 144, maximumFramesPerSecond: 144) == 144)
    }
}
