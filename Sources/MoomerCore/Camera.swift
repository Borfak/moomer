import Foundation

/// Coordinates are top-left-origin display points; the camera center is image UV.
public struct Camera {
    public static let minScale: Float = 0.2
    public static let maxScale: Float = 20
    public var scale: Float = 1
    public var center = SIMD2<Float>(repeating: 0.5)
    public var targetScale: Float = 1
    public var targetCenter = SIMD2<Float>(repeating: 0.5)
    public var velocity = SIMD2<Float>.zero
    public var zoomVelocity: Float = 0
    public var radius: Float = 220
    public var targetRadius: Float = 220
    public var flashlight = false
    public var mirror = false
    private var previousCursorUV: SIMD2<Float>?
    private var zoomAnchoring = false

    public init() {}

    public mutating func zoom(_ delta: Float) {
        guard delta != 0 else { return }
        if delta * zoomVelocity < 0 {
            // A new direction supersedes the old coast and pending zoom, while
            // leaving the displayed camera exactly where it is for this frame.
            zoomVelocity = 0
            targetScale = scale
            targetCenter = center
        }
        zoomAnchoring = true
        zoomVelocity = min(40, max(-40, zoomVelocity + delta * 0.08 * 8))
    }

    public mutating func adjustRadius(_ delta: Float) {
        targetRadius = min(4000, max(40, targetRadius * exp(delta * 0.08)))
    }

    public mutating func drag(_ delta: SIMD2<Float>, size: SIMD2<Float>, dt: Float) {
        let movement = SIMD2(mirror ? -delta.x : delta.x, delta.y) / (size * targetScale)
        targetCenter -= movement
        velocity = -movement / max(0.001, min(0.1, dt))
    }

    public mutating func pan(_ delta: SIMD2<Float>, size: SIMD2<Float>) {
        velocity = .zero
        targetCenter += SIMD2(mirror ? -delta.x : delta.x, delta.y) / (size * targetScale)
    }

    public mutating func reset() {
        targetScale = 1
        targetCenter = SIMD2(repeating: 0.5)
        velocity = .zero
        zoomVelocity = 0
        zoomAnchoring = false
        previousCursorUV = nil
    }

    public mutating func resetForDisplay() {
        reset()
        scale = targetScale
        center = targetCenter
    }

    public func imagePoint(at cursor: SIMD2<Float>, size: SIMD2<Float>) -> SIMD2<Float> {
        var uv = cursor / size
        if mirror { uv.x = 1 - uv.x }
        return targetCenter + (uv - SIMD2(repeating: 0.5)) / targetScale
    }

    public func renderedImagePoint(at cursor: SIMD2<Float>, size: SIMD2<Float>) -> SIMD2<Float> {
        var uv = cursor / size
        if mirror { uv.x = 1 - uv.x }
        return center + (uv - SIMD2(repeating: 0.5)) / scale
    }

    public mutating func animate(dt elapsed: Float, cursor: SIMD2<Float>, size: SIMD2<Float>, dragging: Bool) {
        let dt = max(0, min(1, elapsed))
        var uv = cursor / size
        if mirror { uv.x = 1 - uv.x }
        if zoomAnchoring, !dragging, let previousCursorUV {
            // Move the zoom pivot without turning the remaining scale smoothing
            // into an unintended pan when the pointer moves during a zoom.
            targetCenter += (uv - previousCursorUV) * (1 / scale - 1 / targetScale)
        }
        previousCursorUV = uv
        if zoomVelocity != 0 {
            let decay = exp(-8 * dt)
            let nextScale = min(Self.maxScale, max(Self.minScale,
                targetScale * exp(zoomVelocity * (1 - decay) / 8)))
            let anchor = imagePoint(at: cursor, size: size)
            targetCenter = anchor - (uv - SIMD2(repeating: 0.5)) / nextScale
            targetScale = nextScale
            zoomVelocity *= decay
            if nextScale == Self.minScale || nextScale == Self.maxScale || abs(zoomVelocity) < 0.0001 {
                zoomVelocity = 0
            }
        }
        if !dragging && velocity != .zero {
            let decay = exp(-6 * dt)
            targetCenter += velocity * (1 - decay) / 6
            velocity *= decay
            if (velocity.x * velocity.x + velocity.y * velocity.y) < 0.00000001 {
                velocity = .zero
            }
        }
        let amount = 1 - exp(-10 * dt)
        // Interpolate the image point under the pointer, rather than independently
        // interpolating center and scale (which moves that point between frames).
        let offset = uv - SIMD2<Float>(repeating: 0.5)
        let pivot = center + offset / scale
        let targetPivot = targetCenter + offset / targetScale
        let zoomAmount = 1 - exp(-18 * dt)
        scale = exp(log(scale) + (log(targetScale) - log(scale)) * zoomAmount)
        center = pivot + (targetPivot - pivot) * amount - offset / scale
        radius += (targetRadius - radius) * amount
    }

    @discardableResult
    public mutating func settle() -> Bool {
        let done = velocity == .zero && zoomVelocity == 0
            && abs(scale - targetScale) < 0.0001
            && abs(center.x - targetCenter.x) < 0.00001
            && abs(center.y - targetCenter.y) < 0.00001
            && abs(radius - targetRadius) < 0.25
        if done {
            scale = targetScale
            center = targetCenter
            radius = targetRadius
            zoomAnchoring = false
        }
        return done
    }
}
