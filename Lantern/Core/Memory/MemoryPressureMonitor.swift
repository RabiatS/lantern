import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The part that decides whether the app survives on a 6 GB phone under load.
/// Two signals, because they fire at different times: UIKit's memory warning
/// arrives when the system wants memory back from this app now, and the kernel's
/// pressure source reports warning and critical levels for the whole device.
/// Going to the background is treated as a third, because a two gigabyte app in
/// the background is the first thing jetsam kills.
@Observable
final class MemoryPressureMonitor {
    enum Level: Sendable {
        case normal
        case warning
        case critical
    }

    private(set) var level: Level = .normal
    private(set) var lastWarning: Date?
    private(set) var warningCount = 0

    /// Called on the main actor for each event.
    var onWarning: (() -> Void)?
    var onCritical: (() -> Void)?
    var onBackground: (() -> Void)?
    var onForeground: (() -> Void)?

    private var source: DispatchSourceMemoryPressure?
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard source == nil else { return }
        #if canImport(UIKit)
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handle(.warning) }
        })
        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onBackground?() }
        })
        observers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onForeground?() }
        })
        #endif

        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let event = self.source?.data else { return }
                if event.contains(.critical) {
                    self.handle(.critical)
                } else if event.contains(.warning) {
                    self.handle(.warning)
                }
            }
        }
        source.activate()
        self.source = source
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        source?.cancel()
        source = nil
    }

    private func handle(_ level: Level) {
        self.level = level
        lastWarning = Date()
        warningCount += 1
        switch level {
        case .warning: onWarning?()
        case .critical: onCritical?()
        case .normal: break
        }
    }

    /// Reset after the pressure passes so the UI stops showing the badge.
    func clear() {
        level = .normal
    }
}
