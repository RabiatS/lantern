import Foundation
import Observation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The keyboard's height over the screen, tracked by hand.
///
/// SwiftUI's automatic keyboard avoidance left the composer under the keyboard
/// on a real phone, twice, with layouts that looked right in the simulator. So
/// the chat opts out of the automatic behaviour and pads its bottom by this
/// height instead: one number, read from the system notification, animated
/// with the keyboard's own curve. Zero on the Mac.
@Observable
final class KeyboardObserver {
    /// Height of the keyboard (with its accessory bar) above the bottom of the
    /// window, already minus the home indicator area.
    private(set) var height: CGFloat = 0
    private var observers: [NSObjectProtocol] = []

    func start() {
        #if canImport(UIKit)
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardWillHideNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                // Pull plain values out of the notification here; it is not Sendable.
                let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
                let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
                let hiding = note.name == UIResponder.keyboardWillHideNotification
                MainActor.assumeIsolated { self?.handle(frame: frame, duration: duration, hiding: hiding) }
            })
        }
        #endif
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    #if canImport(UIKit)
    private func handle(frame: CGRect?, duration: Double, hiding: Bool) {
        guard let frame,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let window = scene.windows.first else { return }
        let hidden = hiding || frame.minY >= window.bounds.maxY
        let covered = hidden ? 0 : max(0, window.bounds.maxY - frame.minY - window.safeAreaInsets.bottom)
        withAnimation(.easeOut(duration: duration)) {
            height = covered
        }
    }
    #endif
}
