import CoreText
import Foundation

enum FontRegistration {
    /// Registers Inter Variable from the app bundle so `Font.custom("Inter", size:)` resolves.
    /// Idempotent and silent on success; logs the resolved family/face names on first run.
    static func registerInter() {
        guard let url = Bundle.main.url(forResource: "InterVariable", withExtension: "ttf") else {
            print("[FontRegistration] InterVariable.ttf not found in bundle")
            return
        }
        var error: Unmanaged<CFError>?
        let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        if !ok {
            // Already-registered errors are fine to ignore on subsequent launches.
            if let cfErr = error?.takeRetainedValue() {
                let domain = CFErrorGetDomain(cfErr) as String
                let code = CFErrorGetCode(cfErr)
                if domain == kCTFontManagerErrorDomain as String, code == CTFontManagerError.alreadyRegistered.rawValue {
                    return
                }
                print("[FontRegistration] failed: \(cfErr)")
            }
        }
    }
}
