import AppKit
import Metal
import CoreVideo
import Testing
@testable import Moomer

@MainActor
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct MetalRendererTests {
    private func fixture() throws -> (ZoomView, MetalRenderer) {
        let view = ZoomView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        let renderer = try MetalRenderer(view: view)
        // RGBA rows, top to bottom: red/green above blue/white.
        var data = [UInt8](repeating: 0, count: 64 * 64 * 4)
        for y in 0..<64 {
            for x in 0..<64 {
                let color: [UInt8] = y < 32
                    ? (x < 32 ? [255, 0, 0, 255] : [0, 255, 0, 255])
                    : (x < 32 ? [0, 0, 255, 255] : [255, 255, 255, 255])
                let offset = (y * 64 + x) * 4
                data.replaceSubrange(offset..<(offset + 4), with: color)
            }
        }
        let provider = try #require(CGDataProvider(data: Data(data) as CFData))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let image = try #require(CGImage(width: 64, height: 64, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 64 * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        try renderer.setImage(image)
        return (view, renderer)
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let data = try #require(image.dataProvider?.data)
        let bytes = try #require(CFDataGetBytePtr(data))
        let offset = y * image.bytesPerRow + x * 4
        // The renderer exports BGRA pixels to the clipboard.
        return [bytes[offset + 2], bytes[offset + 1], bytes[offset], bytes[offset + 3]]
    }

    @Test func metalShaderPreservesOrientationAndClipboardChannels() throws {
        let (view, renderer) = try fixture()
        let image = try renderer.renderedImage(width: 64, height: 64)
        #expect(try pixel(image, x: 8, y: 8) == [255, 0, 0, 255])
        #expect(try pixel(image, x: 56, y: 8) == [0, 255, 0, 255])
        #expect(try pixel(image, x: 8, y: 56) == [0, 0, 255, 255])
        #expect(try pixel(image, x: 56, y: 56) == [255, 255, 255, 255])
        withExtendedLifetime(view) {}
    }

    @Test func mirrorAndZoomOutRenderCorrectly() throws {
        let (view, renderer) = try fixture()
        view.camera.mirror = true
        let mirrored = try renderer.renderedImage(width: 64, height: 64)
        #expect(try pixel(mirrored, x: 8, y: 8) == [0, 255, 0, 255])
        view.camera.scale = 0.5
        let zoomedOut = try renderer.renderedImage(width: 64, height: 64)
        #expect(try pixel(zoomedOut, x: 0, y: 0) == [0, 0, 0, 255])
        #expect(try pixel(zoomedOut, x: 24, y: 24) == [0, 255, 0, 255])
    }

    @Test func flashlightFollowsCursorAndScalesForRetina() throws {
        let (view, renderer) = try fixture()
        view.camera.flashlight = true
        view.camera.radius = 16
        view.cursor = SIMD2(52, 52)
        let image = try renderer.renderedImage(width: 128, height: 128)
        #expect(try pixel(image, x: 104, y: 104) == [255, 255, 255, 255])
        let dark = try pixel(image, x: 16, y: 16)
        #expect((37...40).contains(Int(dark[0])))
        #expect(dark[1] == 0 && dark[2] == 0 && dark[3] == 255)
    }

    @Test func zoomAndPanSampleTheExpectedRegion() throws {
        let (view, renderer) = try fixture()
        view.camera.scale = 2
        view.camera.center = SIMD2(0.25, 0.25)
        let image = try renderer.renderedImage(width: 64, height: 64)
        #expect(try pixel(image, x: 16, y: 16) == [255, 0, 0, 255])
        #expect(try pixel(image, x: 48, y: 48) == [255, 0, 0, 255])
    }

    @Test func frozenFrameIsIndependentOfCaptureSurface() throws {
        let (view, renderer) = try fixture()
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &buffer) == kCVReturnSuccess)
        let surface = try #require(buffer)
        func fill(_ value: UInt8) {
            CVPixelBufferLockBaseAddress(surface, [])
            defer { CVPixelBufferUnlockBaseAddress(surface, []) }
            let base = CVPixelBufferGetBaseAddress(surface)!
            memset(base, Int32(value), CVPixelBufferGetBytesPerRow(surface) * 64)
        }
        fill(255)
        try renderer.setFrame(surface)
        try renderer.freeze()
        fill(0)
        let image = try renderer.renderedImage(width: 64, height: 64)
        #expect(try pixel(image, x: 32, y: 32) == [255, 255, 255, 255])
        withExtendedLifetime(view) {}
    }

    @Test func clipboardReadbackSupportsUnalignedImageWidths() throws {
        let (view, renderer) = try fixture()
        let image = try renderer.renderedImage(width: 127, height: 63)
        #expect(image.width == 127 && image.height == 63)
        #expect(try pixel(image, x: 8, y: 8) == [255, 0, 0, 255])
        #expect(try pixel(image, x: 110, y: 50) == [255, 255, 255, 255])
        withExtendedLifetime(view) {}
    }
}
