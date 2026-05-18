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

/// Capture a start instant. Pair with `perfEnd` when start and end straddle
/// structural boundaries (e.g. timing a function from entry to "all kickoff
/// tasks scheduled"). For single-expression timings prefer `perfTime`.
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

/// Time a synchronous expression and log `<label> elapsed=<ms>ms`. Returns
/// the closure's value so it composes inside `let x = perfTime(...) { ... }`.
@inline(__always)
@discardableResult
func perfTime<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
    let start = perfStart()
    let result = try body()
    perfEnd(start, label)
    return result
}

/// Async overload of `perfTime`. Logs end-to-end wall-clock including
/// suspension time, which is exactly what we want for "user-visible delay"
/// timings.
@inline(__always)
@discardableResult
func perfTimeAsync<T>(_ label: String, _ body: () async throws -> T) async rethrows -> T {
    let start = perfStart()
    let result = try await body()
    perfEnd(start, label)
    return result
}
