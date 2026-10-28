import Foundation
import CoreGraphics
import Testing
@testable import MoomerCore

struct CameraTests {
    private let size = SIMD2<Float>(1920, 1080)

    @Test(arguments: [false, true])
    func zoomStaysAnchoredWhenMirrored(mirrored: Bool) {
        var camera = Camera()
        camera.mirror = mirrored
        let cursor = SIMD2<Float>(1430, 170)
        let anchor = camera.imagePoint(at: cursor, size: size)
        camera.zoom(5)
        for _ in 0..<300 { camera.animate(dt: 1 / 60, cursor: cursor, size: size, dragging: false) }
        let result = camera.imagePoint(at: cursor, size: size)
        #expect(abs(result.x - anchor.x) < 0.00001)
        #expect(abs(result.y - anchor.y) < 0.00001)
        #expect(camera.scale > 1)
        let settled = camera.settle()
        #expect(settled)
    }

    @Test(arguments: [Float(-10000), Float(10000)])
    func zoomIsBounded(delta: Float) {
        var camera = Camera()
        for _ in 0..<100 {
            camera.zoom(delta)
            camera.animate(dt: 0.1, cursor: size / 2, size: size, dragging: false)
        }
        #expect(camera.targetScale >= Camera.minScale)
        #expect(camera.targetScale <= Camera.maxScale)
        #expect(camera.zoomVelocity == 0)
    }

    @Test func mirroredDragKeepsGrabDirection() {
        var normal = Camera()
        var mirrored = Camera()
        mirrored.mirror = true
        normal.drag(SIMD2(100, 50), size: size, dt: 0.02)
        mirrored.drag(SIMD2(100, 50), size: size, dt: 0.02)
        #expect(normal.targetCenter.x < 0.5)
        #expect(mirrored.targetCenter.x > 0.5)
        #expect(normal.targetCenter.y == mirrored.targetCenter.y)
    }

    @Test func releasingDragCoastsAndSettles() {
        var camera = Camera()
        camera.drag(SIMD2(100, 0), size: size, dt: 0.02)
        let released = camera.targetCenter.x
        for _ in 0..<300 { camera.animate(dt: 1 / 60, cursor: size / 2, size: size, dragging: false) }
        #expect(camera.targetCenter.x < released)
        #expect(camera.velocity == .zero)
        let settled = camera.settle()
        #expect(settled)
    }

    @Test func draggingDoesNotIntegrateCoastTwice() {
        var camera = Camera()
        camera.drag(SIMD2(100, 0), size: size, dt: 0.02)
        let target = camera.targetCenter
        camera.animate(dt: 1 / 60, cursor: size / 2, size: size, dragging: true)
        #expect(camera.targetCenter == target)
    }

    @Test(arguments: [1, 30, 120])
    func inertiaIsIndependentOfFrameRate(fps: Int) {
        func advance(fps: Int) -> Camera {
            var camera = Camera()
            camera.zoom(3)
            camera.velocity = SIMD2(0.2, -0.1)
            for _ in 0..<fps {
                camera.animate(dt: 1 / Float(fps), cursor: size / 2, size: size, dragging: false)
            }
            return camera
        }
        let slow = advance(fps: 30)
        let fast = advance(fps: fps)
        #expect(abs(slow.targetScale - fast.targetScale) < 0.00001)
        #expect(abs(slow.targetCenter.x - fast.targetCenter.x) < 0.00001)
        #expect(abs(slow.targetCenter.y - fast.targetCenter.y) < 0.00001)
    }

    @Test func radiusAndReset() {
        var camera = Camera()
        camera.adjustRadius(10000)
        #expect(camera.targetRadius == 4000)
        camera.adjustRadius(-10000)
        #expect(camera.targetRadius == 40)
        camera.zoom(10)
        camera.pan(SIMD2(140, -140), size: size)
        camera.resetForDisplay()
        #expect(camera.scale == 1)
        #expect(camera.center == SIMD2(repeating: 0.5))
        #expect(camera.velocity == .zero)
        #expect(camera.zoomVelocity == 0)
    }
}

struct DisplayGeometryTests {
    private let screens = [
        DisplayGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
        DisplayGeometry(id: 2, frame: CGRect(x: -1440, y: 100, width: 1440, height: 900)),
        DisplayGeometry(id: 3, frame: CGRect(x: 0, y: 1080, width: 2560, height: 1440))
    ]

    @Test func selectsScreenWithNegativeCoordinates() {
        #expect(DisplayGeometry.containing(CGPoint(x: -800, y: 500), in: screens)?.id == 2)
    }

    @Test func selectsScreenAboveMainDisplay() {
        #expect(DisplayGeometry.containing(CGPoint(x: 1000, y: 1600), in: screens)?.id == 3)
    }

    @Test func sharedEdgeIsUnambiguous() {
        #expect(DisplayGeometry.containing(CGPoint(x: 0, y: 500), in: screens)?.id == 1)
        #expect(DisplayGeometry.containing(CGPoint(x: 100, y: 1080), in: screens)?.id == 3)
    }

    @Test func gapsDoNotChooseAnUnrelatedDisplay() {
        #expect(DisplayGeometry.containing(CGPoint(x: -1000, y: 50), in: screens) == nil)
    }

    @Test func convertsGlobalAppKitPointToTopLeftCoordinates() {
        #expect(screens[1].localPoint(CGPoint(x: -1340, y: 900)) == SIMD2(100, 100))
    }
}

struct OptionsTests {
    @Test func defaultsAndLive() throws {
        let defaults = try Options(arguments: [])
        #expect(!defaults.live && defaults.followCursor && defaults.frameRate == .automatic)
        let live = try Options(arguments: ["--live", "--fps", "30", "--no-follow-cursor"])
        #expect(live.live && !live.followCursor && live.frameRate == .fixed(30))
    }

    @Test func explicitDisplayPinsSelection() throws {
        let options = try Options(arguments: ["--display", "42"])
        #expect(options.displayID == 42)
        #expect(!options.followCursor)
    }

    @Test(arguments: [["--fps"], ["--fps", "0"], ["--fps", "1001"], ["--fps", "fast"], ["--display", "-1"], ["--display"], ["--wat"]])
    func rejectsInvalidArguments(arguments: [String]) {
        #expect(throws: OptionError.self) { try Options(arguments: arguments) }
    }

    @Test func acceptsAutomaticAndHighRefreshRates() throws {
        #expect(try Options(arguments: ["--fps", "auto"]).frameRate == .automatic)
        #expect(try Options(arguments: ["--fps", "144"]).frameRate == .fixed(144))
        #expect(try Options(arguments: ["--fps", "240"]).frameRate == .fixed(240))
    }
}
