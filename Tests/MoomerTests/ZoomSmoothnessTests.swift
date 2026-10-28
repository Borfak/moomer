import Testing
import MoomerCore

struct ZoomSmoothnessTests {
    @Test(arguments: [false, true])
    func visibleAnchorDoesNotDriftDuringZoom(mirrored: Bool) {
        let size = SIMD2<Float>(2560, 1440)
        let cursor = SIMD2<Float>(2200, 220)
        var camera = Camera()
        camera.mirror = mirrored
        let anchor = camera.renderedImagePoint(at: cursor, size: size)
        camera.zoom(12)
        var largestError: Float = 0
        for _ in 0..<300 {
            camera.animate(dt: 1 / 144, cursor: cursor, size: size, dragging: false)
            let point = camera.renderedImagePoint(at: cursor, size: size)
            largestError = max(largestError, abs(point.x - anchor.x), abs(point.y - anchor.y))
        }
        #expect(largestError < 0.000002, "A fixed cursor must hold the same image point throughout the animation")
    }

    @Test func reversingWheelRespondsOnTheNextFrame() {
        let size = SIMD2<Float>(2560, 1440)
        let cursor = size / 2
        var camera = Camera()
        camera.zoom(10)
        for _ in 0..<15 { camera.animate(dt: 1 / 144, cursor: cursor, size: size, dragging: false) }
        let before = camera.scale
        camera.zoom(-1)
        #expect(camera.scale == before, "Input must not jump the displayed scale")
        camera.animate(dt: 1 / 144, cursor: cursor, size: size, dragging: false)
        #expect(camera.scale < before, "Reversing the wheel must cancel the previous zoom's coast")
    }

    @Test(arguments: [false, true])
    func movingPointerDoesNotIntroduceAnExtraPan(mirrored: Bool) {
        let size = SIMD2<Float>(2560, 1440)
        var camera = Camera()
        camera.mirror = mirrored
        camera.zoom(10)
        var largestError: Float = 0
        for step in 0..<200 {
            let cursor = SIMD2<Float>(500 + Float(step) * 6, 250 + Float(step) * 2)
            let before = camera.renderedImagePoint(at: cursor, size: size)
            camera.animate(dt: 1 / 144, cursor: cursor, size: size, dragging: false)
            let after = camera.renderedImagePoint(at: cursor, size: size)
            largestError = max(largestError, abs(after.x - before.x), abs(after.y - before.y))
        }
        #expect(largestError < 0.000002)
    }
}
