import AppKit
import CoreVideo
import MetalKit
import MoomerCore

struct RenderUniforms: Sendable {
    var resolution: SIMD2<Float>
    var cursor: SIMD2<Float>
    var center: SIMD2<Float>
    var scale: Float
    var radius: Float
    var flashlight: Float
    var shadow: Float = 0.85
    var mirror: Float
    var padding: Float = 0
}

/// Retain the CV wrapper and its IOSurface until every GPU submission using it
/// has completed, even if the next capture frame replaces the source texture.
private final class VideoTexture: @unchecked Sendable {
    let buffer: CVPixelBuffer
    let wrapper: CVMetalTexture
    let texture: MTLTexture
    init(buffer: CVPixelBuffer, wrapper: CVMetalTexture, texture: MTLTexture) {
        self.buffer = buffer
        self.wrapper = wrapper
        self.texture = texture
    }
}

@MainActor
final class MetalRenderer: NSObject {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let loader: MTKTextureLoader
    private var textureCache: CVMetalTextureCache
    private var source: MTLTexture?
    private var videoTexture: VideoTexture?
    private weak var view: ZoomView?
    private var worker: RenderWorker?
    var onError: ((Error) -> Void)?
    var onPresented: (@Sendable (Double) -> Void)?
    var onGPUCompleted: (@Sendable (Double) -> Void)?

    init(view: ZoomView) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw MoomerError.message("Metal is unavailable on this Mac.")
        }
        self.device = device
        self.queue = queue
        self.view = view
        loader = MTKTextureLoader(device: device)
        let shaderBundle: Bundle
        if let url = Bundle.main.url(forResource: "Moomer_Moomer", withExtension: "bundle"),
           let embedded = Bundle(url: url) {
            shaderBundle = embedded
        } else {
            shaderBundle = Bundle.module
        }
        guard let url = shaderBundle.url(forResource: "Zoom", withExtension: "metal", subdirectory: "Shaders") else {
            throw MoomerError.message("Missing Metal shader resource. Keep the SwiftPM resource bundle beside moomer.")
        }
        let library = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "zoomVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "zoomFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else {
            throw MoomerError.message("Cannot create a Metal video texture cache (\(status)).")
        }
        textureCache = cache
        super.init()
        view.metalLayer.device = device
        view.metalLayer.pixelFormat = .bgra8Unorm
        view.metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        view.metalLayer.framebufferOnly = true
        view.metalLayer.maximumDrawableCount = 3
        view.metalLayer.presentsWithTransaction = false
        worker = RenderWorker(layer: view.metalLayer, queue: queue, pipeline: pipeline, errorHandler: { [weak self] error in
            _ = Task { @MainActor in self?.onError?(error) }
        }, retryHandler: { [weak view] in
            _ = Task { @MainActor in view?.onChange?() }
        })
    }

    deinit { worker?.stop() }

    func stopRendering() { worker?.stop() }

    func setImage(_ image: CGImage) throws {
        source = try loader.newTexture(cgImage: image, options: [
            .SRGB: false, .origin: MTKTextureLoader.Origin.topLeft.rawValue,
            .textureStorageMode: MTLStorageMode.private.rawValue
        ])
        videoTexture = nil
    }

    func setFrame(_ buffer: CVPixelBuffer) throws {
        var wrapper: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, buffer, nil,
            .bgra8Unorm, CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &wrapper)
        guard status == kCVReturnSuccess, let wrapper, let texture = CVMetalTextureGetTexture(wrapper) else {
            throw MoomerError.message("Cannot map captured frame to Metal (\(status)).")
        }
        videoTexture = VideoTexture(buffer: buffer, wrapper: wrapper, texture: texture)
        source = texture
    }

    /// Copy an IOSurface before stopping capture; a frozen image must not retain
    /// a stream-owned surface that ScreenCaptureKit may recycle.
    func freeze() throws {
        guard videoTexture != nil, let source else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: source.width, height: source.height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead]
        guard let frozen = device.makeTexture(descriptor: descriptor),
              let command = queue.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder() else {
            throw MoomerError.message("Cannot allocate a frozen frame.")
        }
        blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: source.width, height: source.height, depth: 1),
            to: frozen, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error { throw error }
        self.source = frozen
        videoTexture = nil
        CVMetalTextureCacheFlush(textureCache, 0)
    }

    private func snapshot() -> RenderSnapshot? {
        guard let source, let view else { return nil }
        let size = view.drawableSize
        let resolution = SIMD2(max(1, Float(size.width)), max(1, Float(size.height)))
        let pixelScale = resolution / view.pointSize
        let uniforms = RenderUniforms(resolution: resolution, cursor: view.cursor * pixelScale,
            center: view.camera.center, scale: view.camera.scale,
            radius: view.camera.radius * pixelScale.y, flashlight: view.camera.flashlight ? 1 : 0,
            mirror: view.camera.mirror ? 1 : 0)
        return RenderSnapshot(source: source, uniforms: uniforms, captureLifetime: videoTexture.map(CaptureLease.init), presented: onPresented, completed: onGPUCompleted)
    }

    func encode(to target: MTLTexture, command: MTLCommandBuffer) throws {
        guard let frame = snapshot() else { throw MoomerError.message("No captured image to render.") }
        try RenderWorker.encode(frame, to: target, command: command, pipeline: pipeline)
    }

    func render(didPresent: (@Sendable () -> Void)? = nil) -> Bool {
        guard let frame = snapshot() else { return false }
        return worker?.submit(frame, didPresent: didPresent) ?? false
    }

    func renderedImage(width: Int, height: Int) throws -> CGImage {
        guard width > 0, height > 0 else { throw MoomerError.message("Invalid clipboard image dimensions.") }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: width, height: height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget]
        let rowBytes = (width * 4 + 255) & ~255
        guard let texture = device.makeTexture(descriptor: descriptor),
              let buffer = device.makeBuffer(length: rowBytes * height, options: .storageModeShared),
              let command = queue.makeCommandBuffer() else {
            throw MoomerError.message("Cannot allocate a clipboard image.")
        }
        try encode(to: texture, command: command)
        guard let blit = command.makeBlitCommandEncoder() else {
            throw MoomerError.message("Cannot create a clipboard readback encoder.")
        }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * height)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error { throw error }
        let data = Data(bytes: buffer.contents(), count: rowBytes * height)
        guard let provider = CGDataProvider(data: data as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: rowBytes, space: colorSpace,
                bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)],
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw MoomerError.message("Cannot create a clipboard image.")
        }
        return image
    }
}
