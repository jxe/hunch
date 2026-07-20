import Foundation
import Testing
@testable import Hunch

@Suite("Workspace banners")
@MainActor
struct BannerTests {
    @Test func saveFailureBannerIsErrorSeverity() {
        let error = NSError(domain: "Save", code: 7, userInfo: [NSLocalizedDescriptionKey: "disk full"])
        let banner = Workspace.Banner.saveFailed(page: "Draft", error: error)

        #expect(banner.kind == .error)
        #expect(banner.systemImage == "exclamationmark.triangle.fill")
        #expect(banner.dismissAfter == .seconds(10))
        #expect(banner.message.contains("Draft"))
        #expect(banner.message.contains("disk full"))
    }

    @Test func actionBannersCompareByLabelNotClosure() {
        let a = Workspace.Banner(message: "m", action: .init(label: "Rename", handler: {}))
        let b = Workspace.Banner(message: "m", action: .init(label: "Rename", handler: {}))
        // Different UUIDs → not equal as banners, but the Action itself
        // compares by label so the closure identity never matters.
        #expect(a.action == b.action)
        let c = Workspace.Banner.Action(label: "Undo", handler: {})
        #expect(a.action != c)
    }
}
