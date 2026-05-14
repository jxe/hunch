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
}
