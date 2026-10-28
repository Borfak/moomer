import Foundation
import CoreGraphics

public struct DisplayGeometry: Equatable {
    public let id: UInt32
    public let frame: CGRect

    public init(id: UInt32, frame: CGRect) {
        self.id = id
        self.frame = frame
    }

    /// Both the point and frames must use AppKit's global, bottom-left coordinates.
    /// Half-open bounds give adjacent screens an unambiguous shared edge.
    public static func containing(_ point: CGPoint, in displays: [Self]) -> Self? {
        displays.first {
            point.x >= $0.frame.minX && point.x < $0.frame.maxX
                && point.y >= $0.frame.minY && point.y < $0.frame.maxY
        }
    }

    public func localPoint(_ point: CGPoint) -> SIMD2<Float> {
        SIMD2(Float(point.x - frame.minX), Float(frame.maxY - point.y))
    }
}
