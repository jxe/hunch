import Foundation
@testable import Quagmire
import Testing

@Suite("Bundled resources")
struct ResourceTests {
    @MainActor
    @Test func soundAssetsLoadFromPackageBundle() throws {
        for effect in [SoundFX.Effect.pinchOpen, .drop, .delete] {
            let url = try #require(SoundFX.resourceURL(for: effect))
            #expect(try Data(contentsOf: url).isEmpty == false)
        }
    }
}
