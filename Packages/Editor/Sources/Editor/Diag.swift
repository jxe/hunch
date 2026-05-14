import os

/// Editor-side `os.Logger` instances. Interpolated values use
/// `, privacy: .public` so they survive macOS's default redaction in
/// the unified log — `NSLog` calls land as `<private>` and are useless
/// for live debugging.
///
/// Tail with:
///
///     log stream --predicate 'subsystem == "org.nxhx.Hunch"'
///
/// or filter by category:
///
///     log stream --predicate 'subsystem == "org.nxhx.Hunch" AND category == "navkey"'
enum Diag {
    static let navkey  = Logger(subsystem: "org.nxhx.Hunch", category: "navkey")
    static let mode    = Logger(subsystem: "org.nxhx.Hunch", category: "mode")
    static let subpage = Logger(subsystem: "org.nxhx.Hunch", category: "subpage")
}
