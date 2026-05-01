#if os(iOS)
import UIKit

private typealias ImpactStyle = UIImpactFeedbackGenerator.FeedbackStyle
#else
private enum ImpactStyle {
    case light
    case medium
    case heavy
}
#endif

enum Haptics {
    static func light() {
        impact(.light)
    }

    static func medium() {
        impact(.medium)
    }

    static func heavy() {
        impact(.heavy)
    }

    private static func impact(_ style: ImpactStyle) {
        #if os(iOS)
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
        #endif
    }
}
