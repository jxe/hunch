import Foundation
import os

/// App-side `os.Logger` instances for the Hunch host. Mirrors `Diag` in the
/// Editor package: same `subsystem`, distinct categories so log filters land
/// on host-only call sites without pulling in editor noise. All interpolated
/// values use `, privacy: .public` so they aren't redacted as `<private>` in
/// the unified log.
///
/// Tail with:
///
///     log stream --predicate 'subsystem == "org.nxhx.Hunch"'
///
/// or filter by category:
///
///     log stream --predicate 'subsystem == "org.nxhx.Hunch" AND category == "subpage"'
enum Diag {
    static let subpage = Logger(subsystem: "org.nxhx.Hunch", category: "subpage")
    static let speech  = Logger(subsystem: "org.nxhx.Hunch", category: "speech")
    static let merge   = Logger(subsystem: "org.nxhx.Hunch", category: "merge")
    static let log     = Logger(subsystem: "org.nxhx.Hunch", category: "log")
    /// Workspace-open / mount / reconcile timings. Filter with
    /// `log stream --predicate 'subsystem == "org.nxhx.Hunch" AND category == "perf"'`.
    static let perf    = Logger(subsystem: "org.nxhx.Hunch", category: "perf")
}

/// Capture a start instant. Pair with `perfEnd` to log a span that crosses
/// structural boundaries (e.g. function entry through "all kickoff tasks
/// scheduled").
@inline(__always)
func perfStart() -> DispatchTime { DispatchTime.now() }

@inline(__always)
func perfEnd(_ start: DispatchTime, _ label: String, _ extras: String = "") {
    let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    if extras.isEmpty {
        Diag.perf.log("\(label, privacy: .public) elapsed=\(ms, privacy: .public)ms")
    } else {
        Diag.perf.log("\(label, privacy: .public) elapsed=\(ms, privacy: .public)ms \(extras, privacy: .public)")
    }
}
