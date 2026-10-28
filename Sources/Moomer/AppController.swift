import AppKit
import MoomerCore
import OSLog
import QuartzCore

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private(set) var failed = false
    private let options: Options
    private let terminateApplication: () -> Void
    private let logger = Logger(subsystem: "com.borfak.moomer", category: "app")
    private var window: OverlayWindow?
    private var view: ZoomView?
    private var renderer: MetalRenderer?
    private var capture: LiveCapture?
    private var desiredScreen: NSScreen?
    private var currentGeometry: DisplayGeometry?
    private var currentBackingScale: CGFloat = 0
    private var wantsLive: Bool
    private var followsCursor: Bool
    private var revision = 0
    private var captureRevision = 0
    private var appliedCaptureRevision = -1
    private var reconciler: Task<Void, Never>?
    private var cursorTimer: Timer?
    private var displayLink: CADisplayLink?
    private var renderScreen: NSScreen?
    private var lastFrameTime = CACurrentMediaTime()
    private var dirty = true
    private var revealPending = false
    private var terminating = false
    private var terminationReady = false

    init(options: Options, terminateApplication: @escaping () -> Void = { NSApp.terminate(nil) }) {
        self.options = options
        self.terminateApplication = terminateApplication
        wantsLive = options.live
        followsCursor = options.followCursor
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let screen: NSScreen
            if let id = options.displayID {
                guard let selected = NSScreen.screens.first(where: { $0.displayID == id }) else {
                    throw MoomerError.message("Display \(id) not found. Run moomer --list-displays for available IDs.")
                }
                screen = selected
            } else {
                guard let selected = screenUnderCursor() ?? NSScreen.screens.first else {
                    throw MoomerError.message("No display is available.")
                }
                screen = selected
            }
            desiredScreen = screen
            let window = OverlayWindow(screen: screen)
            let view = ZoomView(frame: CGRect(origin: .zero, size: screen.frame.size))
            let renderer = try MetalRenderer(view: view)
            self.window = window
            self.view = view
            self.renderer = renderer
            window.contentView = view
            window.delegate = self
            window.makeFirstResponder(view)
            view.autoresizingMask = [.width, .height]
            view.onChange = { [weak self] in self?.wake() }
            view.onAction = { [weak self] action in self?.handle(action) }
            renderer.onError = { [weak self] error in self?.fail(error) }

            // Polling mouseLocation doesn't need Accessibility or Input Monitoring.
            // It also works while the pointer is outside our single overlay window.
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.trackCursor() }
            }
            cursorTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                name: NSApplication.didChangeScreenParametersNotification, object: nil)
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spaceChanged),
                name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spaceChanged),
                name: NSWorkspace.didWakeNotification, object: nil)
            requestReconcile()
        } catch { fail(error) }
    }

    private func geometry(of screen: NSScreen) -> DisplayGeometry {
        DisplayGeometry(id: screen.displayID, frame: screen.frame)
    }

    private func screenUnderCursor() -> NSScreen? {
        let screens = NSScreen.screens
        guard let found = DisplayGeometry.containing(NSEvent.mouseLocation, in: screens.map(geometry)) else { return nil }
        return screens.first { $0.displayID == found.id }
    }

    private func trackCursor() {
        guard !terminating, followsCursor, let screen = screenUnderCursor() else { return }
        if desiredScreen.map({ geometry(of: $0) }) != geometry(of: screen) {
            view?.cancelDrag()
            desiredScreen = screen
            requestReconcile()
        }
    }

    @objc private func screensChanged() {
        let screens = NSScreen.screens
        guard let screen = (followsCursor ? screenUnderCursor() : nil)
            ?? screens.first(where: { $0.displayID == desiredScreen?.displayID }) ?? screens.first else {
            fail(MoomerError.message("All displays were disconnected."))
            return
        }
        desiredScreen = screen
        captureRevision += 1
        requestReconcile()
    }

    @objc private func spaceChanged() {
        if followsCursor, let screen = screenUnderCursor() { desiredScreen = screen }
        // A frozen screenshot belongs to the Space in which it was taken.
        captureRevision += 1
        requestReconcile()
    }

    private func requestReconcile() {
        guard !terminating else { return }
        revision += 1
        guard reconciler == nil else { return }
        reconciler = Task { [weak self] in await self?.reconcile() }
    }

    /// Serialize capture changes, coalescing rapid cursor crossings and mode
    /// toggles. Only the newest requested display may replace the visible image.
    private func reconcile() async {
        defer { reconciler = nil }
        var handled = -1
        while !terminating, handled != revision {
            let requested = revision
            let requestedCapture = captureRevision
            guard let screen = desiredScreen, let view, let renderer, let window else { return }
            let targetGeometry = geometry(of: screen)
            do {
                let needsImage = currentGeometry != targetGeometry
                    || currentBackingScale != screen.backingScaleFactor
                    || appliedCaptureRevision != requestedCapture
                if needsImage {
                    let target = try await CaptureTarget.prepare(screen: screen, frameRate: options.frameRate, overlayVisible: window.isVisible)
                    let image = try await target.screenshot()
                    guard !terminating else { return }
                    if requested != revision { continue }
                    await stopCapture()
                    guard !terminating else { return }
                    if requested != revision { continue }
                    try renderer.setImage(image)
                    view.cancelDrag()
                    view.camera.resetForDisplay()
                    window.setFrame(screen.frame, display: false)
                    view.drawableSize = CGSize(width: screen.frame.width * screen.backingScaleFactor,
                        height: screen.frame.height * screen.backingScaleFactor)
                    view.updateCursorFromScreen()
                    currentGeometry = targetGeometry
                    currentBackingScale = screen.backingScaleFactor
                    appliedCaptureRevision = requestedCapture
                    displayLink?.invalidate()
                    displayLink = nil
                    renderScreen = screen
                    view.showPlaceholder(image)
                    revealPending = true
                    if !window.isVisible {
                        window.makeKeyAndOrderFront(nil)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    wake()
                }

                if wantsLive && capture == nil {
                    // Transparent, not-yet-presented windows may be absent from
                    // ScreenCaptureKit's application list. Finish revealing the
                    // first frame before constructing the self-exclusion filter.
                    while revealPending && !terminating && requested == revision {
                        try await Task.sleep(for: .milliseconds(16))
                    }
                    if requested != revision || terminating { continue }
                    // Refresh after showing the overlay so the content list can
                    // identify and exclude our process, including CLI launches.
                    let target = try await CaptureTarget.prepare(screen: screen, frameRate: options.frameRate, overlayVisible: window.isVisible)
                    if requested != revision || terminating { continue }
                    let next = try LiveCapture(target: target, onUpdate: { [weak self] in
                        _ = Task { @MainActor in self?.wake() }
                    })
                    do { try await next.start() }
                    catch { await next.stop(); throw error }
                    if requested != revision || terminating {
                        await next.stop()
                        continue
                    }
                    capture = next
                    wake()
                } else if !wantsLive && capture != nil {
                    if let buffer = capture?.output.takeFrame() { try renderer.setFrame(buffer) }
                    try renderer.freeze()
                    await stopCapture()
                    wake()
                }
                updateTitle()
                handled = requested
            } catch {
                guard !terminating else { return }
                if requested != revision { continue }
                if currentGeometry == nil { fail(error); return }
                // Keep the last good image usable after a runtime capture error.
                try? renderer.freeze()
                await stopCapture()
                wantsLive = false
                fputs("moomer: \(error.localizedDescription)\n", stderr)
                logger.error("Capture failed: \(error.localizedDescription, privacy: .public)")
                NSSound.beep()
                updateTitle()
                handled = requested
                wake()
            }
        }
    }

    private func stopCapture() async {
        let old = capture
        capture = nil
        await old?.stop()
    }

    private func updateTitle() {
        let fps = renderScreen.map {
            options.frameRate.targetFPS(displayRefreshRate: $0.refreshRate, maximumFramesPerSecond: $0.maximumFramesPerSecond)
        } ?? 60
        window?.title = "moomer — \(capture == nil ? "frozen" : "live") — \(Int(fps.rounded())) FPS target — cursor following \(followsCursor ? "on" : "off")"
    }

    private func wake() {
        guard !terminating else { return }
        dirty = true
        if let displayLink {
            if displayLink.isPaused {
                lastFrameTime = CACurrentMediaTime()
                displayLink.isPaused = false
            }
            return
        }
        guard let screen = renderScreen else { return }
        lastFrameTime = CACurrentMediaTime()
        let link = screen.displayLink(target: self, selector: #selector(displayTick(_:)))
        let fps = Float(options.frameRate.targetFPS(displayRefreshRate: screen.refreshRate,
            maximumFramesPerSecond: screen.maximumFramesPerSecond))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: fps, maximum: fps, preferred: fps)
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func displayTick(_ link: CADisplayLink) {
        guard let view, let renderer, !terminating else { return }
        let now = link.targetTimestamp
        let dt = Float(now - lastFrameTime)
        lastFrameTime = now
        if let error = capture?.output.takeError() {
            wantsLive = false
            fputs("moomer: live capture stopped: \(error)\n", stderr)
            logger.error("Live capture stopped: \(error, privacy: .public)")
            requestReconcile()
        }
        if let buffer = capture?.output.takeFrame() {
            do { try renderer.setFrame(buffer); dirty = true }
            catch { fail(error); return }
        }
        view.camera.animate(dt: dt, cursor: view.cursor, size: view.pointSize, dragging: view.dragging)
        let settled = view.camera.settle()
        if dirty || !settled || revealPending {
            var firstPresentation: (@Sendable () -> Void)?
            if revealPending {
                let generation = view.placeholderGeneration
                firstPresentation = { [weak view] in
                    _ = Task { @MainActor in view?.hidePlaceholder(ifGeneration: generation) }
                }
            }
            if renderer.render(didPresent: firstPresentation) {
                revealPending = false
                dirty = false
            } else {
                // Retry the latest camera state on the next display tick when
                // backpressure or drawable unavailability skips a submission.
                dirty = true
            }
        }
        // Capture wakes us when its mailbox becomes nonempty. A static live
        // desktop does not need display-rate polling; camera input still wakes
        // and animates independently of the capture frame rate.
        if settled && !dirty && !revealPending {
            displayLink?.isPaused = true
        }
    }

    private func handle(_ action: ViewAction) {
        switch action {
        case .quit: NSApp.terminate(nil)
        case .toggleLive:
            wantsLive.toggle()
            requestReconcile()
        case .toggleFollow:
            followsCursor.toggle()
            updateTitle()
            trackCursor()
        case .copy:
            guard let view, let renderer else { return }
            do {
                let image = try renderer.renderedImage(width: Int(view.drawableSize.width), height: Int(view.drawableSize.height))
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                guard pasteboard.writeObjects([NSImage(cgImage: image, size: view.bounds.size)]) else {
                    throw MoomerError.message("Cannot write image to clipboard.")
                }
            } catch { fputs("moomer: \(error.localizedDescription)\n", stderr); NSSound.beep() }
        }
    }

    func windowDidResignKey(_ notification: Notification) { view?.cancelDrag() }

    private func fail(_ error: Error) {
        guard !failed && !terminating else { return }
        failed = true
        fputs("moomer: \(error.localizedDescription)\n", stderr)
        logger.error("Fatal error: \(error.localizedDescription, privacy: .public)")
        window?.orderOut(nil)
        let alert = NSAlert()
        alert.messageText = "Moomer couldn't start or continue"
        alert.informativeText = "\(error.localizedDescription)\n\nFor screen capture errors, allow Moomer (or your terminal for CLI builds) in System Settings → Privacy & Security → Screen Recording, then relaunch."
        alert.runModal()
        // Leave the reconciliation task before termination waits for it.
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationReady { return .terminateNow }
        guard !terminating else { return .terminateCancel }
        terminating = true
        cursorTimer?.invalidate()
        renderer?.stopRendering()
        displayLink?.invalidate()
        displayLink = nil
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        window?.orderOut(nil)
        Task {
            await stopCapture()
            // A start/screenshot already in flight must finish and dispose of
            // its stream before AppKit exits the event loop.
            await reconciler?.value
            terminationReady = true
            terminateApplication()
        }
        // AppKit's terminateLater runs a nested loop that can prevent Swift's
        // main-actor cleanup task from executing. Leave that loop first, then
        // request synchronous termination once cleanup has actually finished.
        return .terminateCancel
    }
}
