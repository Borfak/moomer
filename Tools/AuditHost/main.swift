import Foundation
import Darwin
import AppKit

// SwiftPM's Apple-signed testing helper restricts heap inspection. Load our own
// test bundle in an ordinary local development executable for leak diagnostics.
guard let path = ProcessInfo.processInfo.environment["MOOMER_TEST_BUNDLE"],
      let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL),
      let entry = dlsym(handle, "moomer_audit_begin") else {
    fputs("Set MOOMER_TEST_BUNDLE to the compiled MoomerPackageTests test bundle.\n", stderr)
    if let error = dlerror() { fputs(String(cString: error) + "\n", stderr) }
    exit(2)
}
typealias TestBegin = @convention(c) () -> Void
let begin = unsafeBitCast(entry, to: TestBegin.self)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
begin()
app.run()
