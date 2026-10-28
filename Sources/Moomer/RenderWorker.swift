import Foundation
import Metal
import QuartzCore

struct RenderSnapshot: @unchecked Sendable {
    let source: MTLTexture
    let uniforms: RenderUniforms
    let captureLifetime: CaptureLease?
    let presented: (@Sendable (Double) -> Void)?
    let completed: (@Sendable (Double) -> Void)?
}

// Release the capture buffer at GPU completion, even if Metal keeps its
// completion handler alive for longer than the work itself.
final class CaptureLease: @unchecked Sendable {
    private var resource: AnyObject?
    init(_ resource: AnyObject) { self.resource = resource }
    func release() { resource = nil }
}

/// AppKit owns the camera; this queue owns drawable acquisition and GPU
/// submissions. At most one latest snapshot waits while nextDrawable blocks.
final class RenderWorker: @unchecked Sendable {
    private let lock = NSLock()
    private let execution = DispatchQueue(label: "moomer.render", qos: .userInteractive, autoreleaseFrequency: .workItem)
    private let layer: CAMetalLayer
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let errorHandler: @Sendable (Error) -> Void
    private let retryHandler: @Sendable () -> Void
    private var latest: RenderSnapshot?
    private var firstPresentation: (@Sendable () -> Void)?
    private var running = false
    private var stopped = false

    init(layer: CAMetalLayer, queue: MTLCommandQueue, pipeline: MTLRenderPipelineState,
         errorHandler: @escaping @Sendable (Error) -> Void, retryHandler: @escaping @Sendable () -> Void) {
        self.layer = layer
        self.queue = queue
        self.pipeline = pipeline
        self.errorHandler = errorHandler
        self.retryHandler = retryHandler
    }

    func submit(_ frame: RenderSnapshot, didPresent: (@Sendable () -> Void)?) -> Bool {
        var old: RenderSnapshot?
        let launch: Bool? = lock.withLock {
            guard !stopped else { return nil }
            old = latest
            latest = frame
            if let didPresent { firstPresentation = didPresent }
            guard !running else { return false }
            running = true
            return true
        }
        withExtendedLifetime(old) {}
        guard let launch else { return false }
        if launch { execution.async { self.drain() } }
        return true
    }

    func stop() {
        let old = lock.withLock {
            stopped = true
            let old = latest
            latest = nil
            firstPresentation = nil
            return old
        }
        withExtendedLifetime(old) {}
    }

    private func drain() {
        while lock.withLock({ !stopped && latest != nil }) {
            let rendered = autoreleasepool { () -> Bool in
                // This is intentionally off the AppKit/input thread. Acquire
                // first, then latch the freshest camera state, not a stale one.
                guard let drawable = layer.nextDrawable() else { retryHandler(); return false }
                let work: (RenderSnapshot, (@Sendable () -> Void)?)? = lock.withLock {
                    guard !stopped, let frame = latest else { return nil }
                    let first = firstPresentation
                    latest = nil
                    firstPresentation = nil
                    return (frame, first)
                }
                guard let (frame, first) = work else { return true }
                do {
                    guard let command = queue.makeCommandBuffer() else {
                        throw MoomerError.message("Cannot allocate a render command buffer.")
                    }
                    try Self.encode(frame, to: drawable.texture, command: command, pipeline: pipeline)
                    if let completed = frame.completed {
                        command.addCompletedHandler { completed($0.gpuEndTime - $0.gpuStartTime) }
                    }
                    let errorHandler = errorHandler
                    command.addCompletedHandler { command in
                        if let error = command.error { errorHandler(error) }
                    }
                    if frame.presented != nil || first != nil {
                        let presented = frame.presented
                        drawable.addPresentedHandler { drawable in
                            presented?(drawable.presentedTime)
                            first?()
                        }
                    }
                    command.present(drawable)
                    command.commit()
                } catch { errorHandler(error) }
                return true
            }
            if !rendered {
                // An occluded/resizing window can temporarily lack drawables.
                // Keep one pending frame and avoid spinning or blocking AppKit.
                execution.asyncAfter(deadline: .now() + .milliseconds(16)) { self.drain() }
                return
            }
        }
        let restart = lock.withLock {
            running = false
            if !stopped && latest != nil { running = true; return true }
            return false
        }
        if restart { execution.async { self.drain() } }
    }

    static func encode(_ frame: RenderSnapshot, to target: MTLTexture, command: MTLCommandBuffer,
                       pipeline: MTLRenderPipelineState) throws {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            throw MoomerError.message("Cannot create a Metal render encoder.")
        }
        var uniforms = frame.uniforms
        let resolution = SIMD2(Float(target.width), Float(target.height))
        let ratio = resolution / uniforms.resolution
        uniforms.resolution = resolution
        uniforms.cursor *= ratio
        uniforms.radius *= ratio.y
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(frame.source, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<RenderUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        if let lease = frame.captureLifetime {
            command.addCompletedHandler { _ in lease.release() }
        }
    }
}
