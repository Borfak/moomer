import Foundation

public enum FrameRate: Equatable, Sendable {
    case automatic
    case fixed(Int)

    public static let maximumOverride = 1000

    /// A mode may report zero for a variable-refresh display. In that case use
    /// AppKit's supported maximum; actual scheduling still follows display sync.
    public func targetFPS(displayRefreshRate: Double, maximumFramesPerSecond: Int) -> Double {
        let native: Double
        if displayRefreshRate.isFinite && displayRefreshRate > 0 {
            native = displayRefreshRate
        } else if maximumFramesPerSecond > 0 {
            native = Double(maximumFramesPerSecond)
        } else {
            native = 60
        }
        switch self {
        case .automatic: return native
        case .fixed(let rate): return min(native, Double(min(Self.maximumOverride, max(1, rate))))
        }
    }
}
