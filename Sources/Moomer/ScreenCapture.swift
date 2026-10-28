import AppKit
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import MoomerCore

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    var refreshRate: Double {
        FrameRate.automatic.targetFPS(displayRefreshRate: CGDisplayCopyDisplayMode(displayID)?.refreshRate ?? 0,
            maximumFramesPerSecond: maximumFramesPerSecond)
    }
}

enum MoomerError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): text }
    }
}

@MainActor
struct CaptureTarget {
    let filter: SCContentFilter
    let configuration: SCStreamConfiguration

    static func prepare(screen: NSScreen, frameRate: FrameRate, overlayVisible: Bool) async throws -> Self {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
            throw MoomerError.message("Display \(screen.displayID) is no longer available.")
        }
        // Match the process rather than the bundle ID: swift run and a bare CLI
        // executable don't have an application bundle identifier.
        let pid = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == pid }
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == pid }
        let filter: SCContentFilter
        if !ownApps.isEmpty {
            filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        } else {
            guard !overlayVisible || !ownWindows.isEmpty else {
                throw MoomerError.message("Cannot exclude moomer from screen capture. Close and relaunch moomer.")
            }
            filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        }
        if #available(macOS 14.2, *) { filter.includeMenuBar = true }
        let config = SCStreamConfiguration()
        config.width = Int((screen.frame.width * screen.backingScaleFactor).rounded())
        config.height = Int((screen.frame.height * screen.backingScaleFactor).rounded())
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false
        config.capturesAudio = false
        config.queueDepth = 3
        switch frameRate {
        case .automatic:
            // ScreenCaptureKit interprets zero as the display's native cadence,
            // including refresh-rate changes and variable-refresh displays.
            config.minimumFrameInterval = .zero
        case .fixed:
            let fps = frameRate.targetFPS(displayRefreshRate: screen.refreshRate,
                maximumFramesPerSecond: screen.maximumFramesPerSecond)
            config.minimumFrameInterval = CMTime(seconds: 1 / fps, preferredTimescale: 1_000_000_000)
        }
        config.captureResolution = .best
        return Self(filter: filter, configuration: config)
    }

    func screenshot() async throws -> CGImage {
        try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}

/// One pending frame, protected by a lock. Capture never queues an unbounded
/// number of callbacks or IOSurfaces on the main thread when rendering is slow.
final class CaptureOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let onUpdate: @Sendable () -> Void
    private var latest: CVPixelBuffer?
    private var failure: String?
    private var stopping = false

    init(onUpdate: @escaping @Sendable () -> Void = {}) {
        self.onUpdate = onUpdate
        super.init()
    }

    func takeFrame() -> CVPixelBuffer? {
        lock.withLock {
            defer { latest = nil }
            return latest
        }
    }

    func takeError() -> String? {
        lock.withLock {
            defer { failure = nil }
            return failure
        }
    }

    func willStop() {
        let old = lock.withLock {
            stopping = true
            let old = latest
            latest = nil
            return old
        }
        withExtendedLifetime(old) {}
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        autoreleasepool {
            guard type == .screen, sampleBuffer.isValid,
                  let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]],
                  let status = attachments.first?[.status] as? Int,
                  status == SCFrameStatus.complete.rawValue,
                  let buffer = sampleBuffer.imageBuffer else { return }
            let (old, notify): (CVPixelBuffer?, Bool) = lock.withLock {
                guard !stopping else { return (nil, false) }
                let old = latest
                latest = buffer
                // One wake per empty-to-full transition, not per replacement.
                // The UI can pause its display link while capture is idle.
                return (old, old == nil)
            }
            // Returning an old IOSurface to its pool can perform framework work;
            // keep that release outside the lock shared with the UI thread.
            withExtendedLifetime(old) {}
            if notify { onUpdate() }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let message = error.localizedDescription
        let notify = lock.withLock {
            guard !stopping else { return false }
            let notify = failure == nil
            failure = message
            return notify
        }
        if notify { onUpdate() }
    }
}

@MainActor
final class LiveCapture {
    let output: CaptureOutput
    private let stream: SCStream
    private let queue = DispatchQueue(label: "moomer.capture", qos: .userInteractive, autoreleaseFrequency: .workItem)
    private var hasStopped = false

    init(target: CaptureTarget, onUpdate: @escaping @Sendable () -> Void = {}) throws {
        output = CaptureOutput(onUpdate: onUpdate)
        stream = SCStream(filter: target.filter, configuration: target.configuration, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
    }

    func start() async throws {
        guard !hasStopped else { throw MoomerError.message("This capture session has already stopped.") }
        try await stream.startCapture()
        if hasStopped {
            try? await stream.stopCapture()
            throw CancellationError()
        }
    }

    func stop() async {
        guard !hasStopped else { return }
        hasStopped = true
        output.willStop()
        do { try await stream.stopCapture() }
        catch {
            if (error as? SCStreamError)?.code != .attemptToStopStreamState {
                fputs("moomer: stopping capture: \(error.localizedDescription)\n", stderr)
            }
        }
        try? stream.removeStreamOutput(output, type: .screen)
    }
}
