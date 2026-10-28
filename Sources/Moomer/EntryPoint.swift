import AppKit
import MoomerCore

@main
struct Moomer {
    @MainActor
    static func main() {
        do {
            let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
            if options.help { print(Options.usage); return }
            if options.version { print("moomer 2.0.0"); return }
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            if options.listDisplays {
                for screen in NSScreen.screens {
                    let frame = screen.frame
                    let hz = String(format: "%.2f", screen.refreshRate)
                    print("\(screen.displayID)\t\(screen.localizedName)\t\(Int(frame.width))×\(Int(frame.height)) points\t\(screen.backingScaleFactor)×\t\(hz) Hz\t(\(Int(frame.minX)), \(Int(frame.minY)))")
                }
                return
            }
            let delegate = AppController(options: options)
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
            if delegate.failed { exit(1) }
        } catch {
            fputs("moomer: \(error.localizedDescription)\nRun moomer --help for usage.\n", stderr)
            exit(2)
        }
    }
}
