import AppKit
import Testing
import MoomerCore
@testable import Moomer

@MainActor
struct AppLifecycleTests {
    @Test func terminationLetsMainActorCleanupRunBeforeExiting() async throws {
        var terminationRequests = 0
        let controller = AppController(options: try Options(arguments: [])) {
            terminationRequests += 1
        }
        let app = NSApplication.shared
        #expect(controller.applicationShouldTerminate(app) == .terminateCancel)
        #expect(controller.applicationShouldTerminate(app) == .terminateCancel)
        for _ in 0..<100 {
            if terminationRequests > 0 { break }
            await Task.yield()
        }
        #expect(terminationRequests == 1)
        #expect(controller.applicationShouldTerminate(app) == .terminateNow)
    }
}
