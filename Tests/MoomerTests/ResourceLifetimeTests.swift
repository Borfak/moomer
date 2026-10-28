import AppKit
import Testing
@testable import Moomer

@MainActor
private final class WeakCaptureReferences {
    weak var session: LiveCapture?
    weak var output: CaptureOutput?
    init(_ capture: LiveCapture) { session = capture; output = capture.output }
}

@MainActor
struct ResourceLifetimeTests {
    @Test func rendererAndViewReleaseWithoutADelegateCycle() throws {
        weak var weakView: ZoomView?
        weak var weakRenderer: MetalRenderer?
        try autoreleasepool {
            let view = ZoomView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
            let renderer = try MetalRenderer(view: view)
            weakView = view
            weakRenderer = renderer
        }
        #expect(weakRenderer == nil)
        #expect(weakView == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOOMER_CAPTURE_TESTS"] == "1"))
    func repeatedStartStopReleasesSessionsAndOutputs() async throws {
        try #require(CGPreflightScreenCaptureAccess())
        let screen = try #require(NSScreen.screens.first { $0.displayID == CGMainDisplayID() })
        let target = try await CaptureTarget.prepare(screen: screen, frameRate: .automatic, overlayVisible: false)
        let view = ZoomView(frame: CGRect(origin: .zero, size: screen.frame.size))
        let renderer = try MetalRenderer(view: view)
        var results: [[String: Any]] = []
        for cycle in 0..<10 {
            let weakRefs = try await captureCycle(target: target, renderer: renderer)
            for _ in 0..<100 {
                if weakRefs.session == nil && weakRefs.output == nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(weakRefs.session == nil, "Capture session retained after cycle \(cycle)")
            #expect(weakRefs.output == nil, "Stream output retained after cycle \(cycle)")
            results.append(["cycle": cycle, "sessionReleased": weakRefs.session == nil,
                "outputReleased": weakRefs.output == nil])
        }
        let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: "/tmp/moomer-resource-lifetimes.json"))
        withExtendedLifetime(view) {}
    }

    private func captureCycle(target: CaptureTarget, renderer: MetalRenderer) async throws -> WeakCaptureReferences {
        var capture: LiveCapture? = try LiveCapture(target: target)
        let references = WeakCaptureReferences(capture!)
        do {
            try await capture!.start()
            var received = false
            for _ in 0..<100 {
                if let frame = capture!.output.takeFrame() {
                    try autoreleasepool { try renderer.setFrame(frame); try renderer.freeze() }
                    received = true
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(received)
            await capture!.stop()
            await capture!.stop() // Repeated mode/quit cleanup must be idempotent.
            capture = nil
            return references
        } catch {
            await capture?.stop()
            throw error
        }
    }
}
