import Testing
import Darwin

/// Let the diagnostic host run a real NSApplication event loop. SwiftPM's
/// generic async test runner is suitable for unit tests, but doesn't reproduce
/// AppKit's presentation scheduling for an onscreen frame-pacing benchmark.
@_cdecl("moomer_audit_begin")
public func moomerAuditBegin() {
    _ = Task { @MainActor in
        let status: CInt = await Testing.__swiftPMEntryPoint()
        exit(status)
    }
}
