import AppKit
import QuartzCore
import Metal
import Testing
import MoomerCore
@testable import Moomer

private final class GPUObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var times: [Double] = []
    private var presentations: [Double] = []
    func completed(_ seconds: Double) { lock.withLock { times.append(seconds * 1000) } }
    func presented(_ seconds: Double) { if seconds > 0 { lock.withLock { presentations.append(seconds) } } }
    func reset() { lock.withLock { times.removeAll(keepingCapacity: true); presentations.removeAll(keepingCapacity: true) } }
    func snapshot() -> (gpu: [Double], presentations: [Double]) { lock.withLock { (times, presentations.sorted()) } }
}

@MainActor
private final class AuditDriver: NSObject {
    let view: ZoomView
    let renderer: MetalRenderer
    var capture: LiveCapture?
    var link: CADisplayLink?
    let observations = GPUObservations()
    var ticks: [Double] = []
    var mapping: [Double] = []
    var rendering: [Double] = []
    var footprints: [Double] = []
    var submitted = 0
    var consumed = 0
    var activeTicks = 0
    var started = CACurrentMediaTime()
    var lastTick: Double = 0

    init(view: ZoomView, renderer: MetalRenderer) {
        self.view = view
        self.renderer = renderer
        super.init()
        let observations = observations
        renderer.onPresented = { observations.presented($0) }
        renderer.onGPUCompleted = { observations.completed($0) }
    }

    func reset() {
        observations.reset()
        ticks.removeAll(keepingCapacity: true)
        mapping.removeAll(keepingCapacity: true)
        rendering.removeAll(keepingCapacity: true)
        footprints.removeAll(keepingCapacity: true)
        submitted = 0
        consumed = 0
        activeTicks = 0
        started = CACurrentMediaTime()
        lastTick = 0
    }

    @objc func tick(_ link: CADisplayLink) {
        autoreleasepool {
            let now = CACurrentMediaTime()
            let time = now - started
            if NSApp.isActive { activeTicks += 1 }
            let dt = lastTick > 0 ? now - lastTick : 1 / 144
            if lastTick > 0 { ticks.append(dt * 1000) }
            lastTick = now
            if let frame = capture?.output.takeFrame() {
                let before = CACurrentMediaTime()
                do { try renderer.setFrame(frame) } catch { print("AUDIT frame error: \(error)") }
                mapping.append((CACurrentMediaTime() - before) * 1000)
                consumed += 1
            }
            view.cursor = view.pointSize * SIMD2(Float(0.5 + sin(time) * 0.25), Float(0.5 + cos(time) * 0.2))
            if ticks.count % 20 == 0 { view.camera.zoom(sin(time * 2) > 0 ? 1 : -1) }
            view.camera.pan(SIMD2(Float(sin(time * 3) * 2), Float(cos(time * 2) * 2)), size: view.pointSize)
            view.camera.animate(dt: Float(dt), cursor: view.cursor, size: view.pointSize, dragging: true)
            let before = CACurrentMediaTime()
            if renderer.render() { submitted += 1 }
            rendering.append((CACurrentMediaTime() - before) * 1000)
            if ticks.count % 72 == 0 { footprints.append(Self.footprintMB()) }
        }
    }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    func report(mode: String) -> [String: Any] {
        func percentile(_ values: [Double], _ p: Double) -> Double {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
        }
        let gpu = observations.snapshot()
        let presentedIntervals = zip(gpu.presentations.dropFirst(), gpu.presentations).map { ($0 - $1) * 1000 }
        let elapsed = CACurrentMediaTime() - started
        return ["mode": mode, "seconds": elapsed, "ticks": ticks.count, "submitted": submitted,
            "presented": gpu.presentations.count, "presentedFPS": Double(gpu.presentations.count) / elapsed,
            "captureFramesConsumed": consumed,
            "activeFraction": Double(activeTicks) / Double(max(1, ticks.count)),
            "tickP50Ms": percentile(ticks, 0.5), "tickP95Ms": percentile(ticks, 0.95), "tickP99Ms": percentile(ticks, 0.99),
            "presentP95Ms": percentile(presentedIntervals, 0.95), "presentP99Ms": percentile(presentedIntervals, 0.99),
            "mappingP95Ms": percentile(mapping, 0.95), "mappingP99Ms": percentile(mapping, 0.99),
            "renderCPUP95Ms": percentile(rendering, 0.95), "renderCPUP99Ms": percentile(rendering, 0.99),
            "gpuP95Ms": percentile(gpu.gpu, 0.95), "gpuP99Ms": percentile(gpu.gpu, 0.99),
            "footprintMB": footprints]
    }
}

@MainActor
struct LivePerformanceAuditTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOOMER_LIVE_AUDIT"] == "1"))
    func compareFrozenAndLiveOnScreen() async throws {
        try #require(CGPreflightScreenCaptureAccess())
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let requestedID = ProcessInfo.processInfo.environment["MOOMER_AUDIT_DISPLAY_ID"].flatMap(UInt32.init) ?? CGMainDisplayID()
        let screen = try #require(NSScreen.screens.first { $0.displayID == requestedID })
        let screenshotTarget = try await CaptureTarget.prepare(screen: screen, frameRate: .automatic, overlayVisible: false)
        let image = try await screenshotTarget.screenshot()
        let window = OverlayWindow(screen: screen)
        let view = ZoomView(frame: CGRect(origin: .zero, size: screen.frame.size))
        let renderer = try MetalRenderer(view: view)
        try renderer.setImage(image)
        window.contentView = view
        window.setFrame(screen.frame, display: false)
        view.drawableSize = CGSize(width: image.width, height: image.height)
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        #expect(window.screen?.displayID == requestedID, "Capture and overlay must use the requested physical monitor")
        let driver = AuditDriver(view: view, renderer: renderer)
        let link = screen.displayLink(target: driver, selector: #selector(AuditDriver.tick(_:)))
        let fps = Float(screen.refreshRate)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: fps, maximum: fps, preferred: fps)
        driver.link = link
        link.add(to: .main, forMode: .common)
        defer { link.invalidate(); driver.link = nil; window.orderOut(nil) }
        try await Task.sleep(for: .seconds(1))
        driver.reset()
        try await Task.sleep(for: .seconds(5))
        let frozen = driver.report(mode: "frozen")
        let capturePolicy = ProcessInfo.processInfo.environment["MOOMER_AUDIT_CAPTURE_FPS"].flatMap(Int.init)
            .map(FrameRate.fixed) ?? .automatic
        let target = try await CaptureTarget.prepare(screen: screen, frameRate: capturePolicy, overlayVisible: true)
        let capture = try LiveCapture(target: target)
        try await capture.start()
        driver.capture = capture
        try await Task.sleep(for: .seconds(1))
        driver.reset()
        try await Task.sleep(for: .seconds(12))
        let live = driver.report(mode: "live")
        #expect(driver.consumed > 0, "The live comparison must actually receive capture frames")
        let report: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier, "displayID": requestedID,
            "appKitEventLoopRunning": app.isRunning,
            "metalLayer": ["transactionPresentation": view.metalLayer.presentsWithTransaction,
                "vsync": view.metalLayer.displaySyncEnabled, "drawableCount": view.metalLayer.maximumDrawableCount,
                "width": view.metalLayer.drawableSize.width, "height": view.metalLayer.drawableSize.height],
            "windowDisplayID": window.screen?.displayID ?? 0,
            "windowFrame": ["x": window.frame.minX, "y": window.frame.minY, "width": window.frame.width, "height": window.frame.height],
            "display": screen.localizedName, "hz": screen.refreshRate,
            "width": image.width, "height": image.height, "scenarios": [frozen, live]]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let path = ProcessInfo.processInfo.environment["MOOMER_AUDIT_OUTPUT"] ?? "/tmp/moomer-live-audit.json"
        try data.write(to: URL(fileURLWithPath: path))
        print("LIVE AUDIT report: \(path)")
        print(String(data: data, encoding: .utf8)!)
        if let hold = ProcessInfo.processInfo.environment["MOOMER_AUDIT_HOLD_SECONDS"].flatMap(Double.init), hold > 0 {
            print("LIVE AUDIT holding process \(ProcessInfo.processInfo.processIdentifier) for memory inspection")
            fflush(stdout)
            let until = CACurrentMediaTime() + hold
            while CACurrentMediaTime() < until {
                if let release = ProcessInfo.processInfo.environment["MOOMER_AUDIT_RELEASE_FILE"],
                   FileManager.default.fileExists(atPath: release) { break }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        try renderer.freeze()
        driver.capture = nil
        await capture.stop()
        renderer.stopRendering()
        window.close()
    }
}
