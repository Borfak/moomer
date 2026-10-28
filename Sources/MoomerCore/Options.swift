import Foundation

public struct Options {
    public var live = false
    public var followCursor = true
    public var displayID: UInt32?
    public var frameRate: FrameRate = .automatic
    public var listDisplays = false
    public var help = false
    public var version = false

    public init(arguments: [String]) throws {
        var args = arguments.makeIterator()
        while let arg = args.next() {
            switch arg {
            case "--live": live = true
            case "--no-follow-cursor": followCursor = false
            case "--display":
                guard let value = args.next(), let id = UInt32(value) else {
                    throw OptionError.message("--display requires a numeric display ID")
                }
                displayID = id
                followCursor = false
            case "--fps":
                guard let value = args.next() else {
                    throw OptionError.message("--fps requires auto or an integer from 1 to 1000")
                }
                if value == "auto" {
                    frameRate = .automatic
                } else if let rate = Int(value), (1...FrameRate.maximumOverride).contains(rate) {
                    frameRate = .fixed(rate)
                } else {
                    throw OptionError.message("--fps requires auto or an integer from 1 to 1000")
                }
            case "--list-displays": listDisplays = true
            case "--help", "-h": help = true
            case "--version": version = true
            default: throw OptionError.message("Unknown argument: \(arg)")
            }
        }
    }

    public static let usage = """
    Usage: moomer [options]
      --live              Start with a live desktop instead of a frozen image
      --no-follow-cursor  Stay on the monitor selected at launch
      --display ID        Use this display and disable cursor following
      --fps auto|N        Match monitor refresh rate (default), or cap at 1–1000
      --list-displays     Print display IDs and exit
      --help, -h          Show this help
      --version           Print version

    Scroll / + / -: zoom   Drag: pan   Arrows / hjkl: pan
    Space: live/freeze     Tab: follow cursor on/off
    f: flashlight         Ctrl+scroll: flashlight size
    m: mirror             c: copy current view
    0: reset camera       Esc / q: quit
    """
}

public enum OptionError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let message): message }
    }
}
