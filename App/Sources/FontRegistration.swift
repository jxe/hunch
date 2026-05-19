import CoreText
import Foundation

enum FontRegistration {
    /// Registers Inter Variable from the app bundle so `Font.custom("Inter", size:)` resolves.
    /// Idempotent and silent — `alreadyRegistered` on relaunch is expected.
    static func registerInter() {
        guard let url = Bundle.main.url(forResource: "InterVariable", withExtension: "ttf") else {
            return
        }
        var error: Unmanaged<CFError>?
        _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        error?.release()
    }
}
