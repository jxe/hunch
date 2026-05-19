#if os(iOS)
import SwiftUI
import UIKit

struct ShakeDetector: UIViewControllerRepresentable {
    let onShake: () -> Void

    func makeUIViewController(context: Context) -> Controller {
        let vc = Controller()
        vc.onShake = onShake
        return vc
    }

    func updateUIViewController(_ vc: Controller, context: Context) {
        vc.onShake = onShake
    }

    final class Controller: UIViewController {
        var onShake: (() -> Void)?

        override var canBecomeFirstResponder: Bool { true }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            becomeFirstResponder()
        }

        override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
            super.motionEnded(motion, with: event)
            if motion == .motionShake { onShake?() }
        }
    }
}

extension View {
    func onShake(perform action: @escaping () -> Void) -> some View {
        background(ShakeDetector(onShake: action))
    }
}
#endif
