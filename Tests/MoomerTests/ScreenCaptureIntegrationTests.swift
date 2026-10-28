import AppKit
import CoreGraphics
import Testing
import MoomerCore
import Metal
@testable import Moomer

/// Opt-in: reads each connected display, without opening any overlay or saving
/// captured content. Normal tests and CI never request Screen Recording access.
@MainActor
struct ScreenCaptureIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOOMER_CAPTURE_TESTS"] == "1"))
    func capturesConnectedMonitorsAndMapsLiveFramesToMetal() async throws {
        try #require(CGPreflightScreenCaptureAccess(), "Grant screen capture access to the terminal before this opt-in test.")
        let screens = NSScreen.screens
        #expect(!screens.isEmpty)
        for screen in screens {
            let target = try await CaptureTarget.prepare(screen: screen, frameRate: .automatic, overlayVisible: false)
            #expect(target.configuration.minimumFrameInterval == .zero)
            let image = try await target.screenshot()
            #expect(image.width == target.configuration.width)
            #expect(image.height == target.configuration.height)
            let view = ZoomView(frame: CGRect(origin: .zero, size: screen.frame.size))
            let renderer = try MetalRenderer(view: view)
            try renderer.setImage(image)
            let session = try LiveCapture(target: target)
            do {
                try await session.start()
                var frame: CVPixelBuffer?
                for _ in 0..<100 {
                    frame = session.output.takeFrame()
                    if frame != nil { break }
                    if let failure = session.output.takeError() { throw MoomerError.message(failure) }
                    try await Task.sleep(for: .milliseconds(30))
                }
                let buffer = try #require(frame, "No complete frame arrived for display \(screen.displayID).")
                try renderer.setFrame(buffer)
                try renderer.freeze()
                await session.stop()
                if ProcessInfo.processInfo.environment["MOOMER_BENCHMARK"] == "1" {
                    try benchmark(renderer: renderer, view: view, width: image.width, height: image.height,
                        name: screen.localizedName, hz: screen.refreshRate)
                }
                let output = try renderer.renderedImage(width: 64, height: 64)
                #expect(output.width == 64 && output.height == 64)
                withExtendedLifetime(view) {}
            } catch {
                await session.stop()
                throw error
            }
        }
    }

    private func benchmark(renderer: MetalRenderer, view: ZoomView, width: Int, height: Int,
                           name: String, hz: Double) throws {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: width, height: height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget]
        let target = try #require(renderer.device.makeTexture(descriptor: descriptor))
        let queue = try #require(renderer.device.makeCommandQueue())
        var gpuTimes: [Double] = []
        view.camera.zoom(10)
        for index in 0..<90 {
            view.camera.animate(dt: Float(1 / hz), cursor: view.pointSize * 0.8,
                size: view.pointSize, dragging: false)
            let command = try #require(queue.makeCommandBuffer())
            try renderer.encode(to: target, command: command)
            command.commit()
            command.waitUntilCompleted()
            if let error = command.error { throw error }
            if index >= 10 { gpuTimes.append((command.gpuEndTime - command.gpuStartTime) * 1000) }
        }
        gpuTimes.sort()
        print(String(format: "GPU benchmark %@ %dx%d @%.2fHz: median %.3fms, p95 %.3fms; budget %.3fms",
            name, width, height, hz, gpuTimes[gpuTimes.count / 2], gpuTimes[Int(Double(gpuTimes.count) * 0.95)], 1000 / hz))
    }
}
