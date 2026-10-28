import AppKit
import QuartzCore

/// A separate process is intentional: the app being benchmarked excludes its
/// own windows from capture. This produces repeatable high-update-rate content.
@MainActor
final class LoadGenerator: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var link: CADisplayLink?
    private var shutdownTimer: Timer?
    private var bars: [CALayer] = []
    private var started = CACurrentMediaTime()
    private var seconds: Double = 90

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        let id = args.count > 1 ? UInt32(args[1]) : nil
        if args.count > 2, let value = Double(args[2]), value.isFinite { seconds = min(180, max(1, value)) }
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }) ?? NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID()
        }) else { NSApp.terminate(nil); return }
        let frame = CGRect(x: screen.frame.minX + 100, y: screen.frame.minY + 120, width: 1100, height: 760)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Moomer capture load — closes automatically"
        window.delegate = self
        window.isReleasedWhenClosed = false
        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        for index in 0..<24 {
            let layer = CALayer()
            layer.backgroundColor = NSColor(calibratedHue: CGFloat(index) / 24,
                saturation: 0.8, brightness: 0.95, alpha: 1).cgColor
            view.layer?.addSublayer(layer)
            bars.append(layer)
        }
        window.contentView = view
        self.window = window
        window.setFrame(frame, display: false)
        window.orderFrontRegardless()
        let actual = (window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        print("Capture load requested display \(id ?? CGMainDisplayID()), actual display \(actual), frame \(window.frame)")
        fflush(stdout)
        started = CACurrentMediaTime()
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        self.link = link
        link.add(to: .main, forMode: .common)
        // Display callbacks may stop on an occluded/disconnected display.
        // Keep automatic shutdown independent of animation delivery.
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        shutdownTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func tick(_ link: CADisplayLink) {
        let time = CACurrentMediaTime() - started
        if time >= seconds { stop(); return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            let x = 500 + sin(time * 3 + Double(index) * 0.2) * 430
            bar.frame = CGRect(x: x, y: Double(index) * 31, width: 150, height: 27)
        }
        CATransaction.commit()
    }

    private func stop() {
        shutdownTimer?.invalidate()
        link?.invalidate()
        NSApp.terminate(nil)
    }

    func windowWillClose(_ notification: Notification) { stop() }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = LoadGenerator()
app.delegate = delegate
withExtendedLifetime(delegate) { app.run() }
