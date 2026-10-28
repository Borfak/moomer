import AppKit
import QuartzCore
import Testing

@MainActor
private final class DisplayProbe: NSObject {
    var callbacks = 0
    var interval: TimeInterval = 0
    @objc func tick(_ link: CADisplayLink) {
        callbacks += 1
        interval = link.targetTimestamp - link.timestamp
    }
}

@MainActor
struct DisplayLinkTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOOMER_CAPTURE_TESTS"] == "1"))
    func displayLinkProducesNativeCallbacksForEveryMonitor() async throws {
        _ = NSApplication.shared
        for screen in NSScreen.screens {
            let probe = DisplayProbe()
            let link = screen.displayLink(target: probe, selector: #selector(DisplayProbe.tick(_:)))
            link.add(to: .main, forMode: .common)
            defer { link.invalidate() }
            for _ in 0..<40 {
                if probe.callbacks >= 5 { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(probe.callbacks >= 5, "No display callbacks for \(screen.localizedName)")
            #expect(probe.interval > 0 && probe.interval < 1)
        }
    }
}
