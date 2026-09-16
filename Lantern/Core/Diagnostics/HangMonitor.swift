import Foundation
import Observation

/// Records main-thread stalls so "it freezes sometimes" becomes a list of
/// timestamps with what the app was doing at the time.
///
/// A timer on the main run loop is meant to fire every fifty milliseconds,
/// including while the user scrolls. If it fires late, the gap is the length of
/// time the main thread was busy with something else. Anything over a quarter
/// second is a visible hitch and gets written to `Documents/Diagnostics/hangs.jsonl`.
@Observable
final class HangMonitor {
    nonisolated struct Hang: Codable, Sendable {
        let at: Date
        let milliseconds: Int
        let engine: String
        let generating: Bool
        let compacting: Bool
    }

    private(set) var count = 0
    private(set) var longestMilliseconds = 0
    private(set) var last: Hang?

    /// What to record alongside a stall. Set by the app state.
    var context: () -> (engine: String, generating: Bool, compacting: Bool) = { ("", false, false) }

    private var timer: Timer?
    private var lastBeat = ContinuousClock.now
    static let interval: Duration = .milliseconds(50)
    static let threshold: Duration = .milliseconds(250)

    nonisolated static var fileURL: URL {
        URL.documentsDirectory.appending(path: "Diagnostics", directoryHint: .isDirectory)
            .appending(path: "hangs.jsonl")
    }

    func start() {
        guard timer == nil else { return }
        lastBeat = ContinuousClock.now
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.beat() }
        }
        // Common modes so the timer keeps firing during scrolling and gestures.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func beat() {
        let now = ContinuousClock.now
        let gap = now - lastBeat
        lastBeat = now
        guard gap > Self.threshold else { return }
        let milliseconds = Int(gap / .milliseconds(1))
        let (engine, generating, compacting) = context()
        let hang = Hang(at: Date(), milliseconds: milliseconds, engine: engine, generating: generating, compacting: compacting)
        count += 1
        longestMilliseconds = max(longestMilliseconds, milliseconds)
        last = hang
        Task.detached(priority: .utility) { Self.append(hang) }
    }

    nonisolated private static func append(_ hang: Hang) {
        let url = fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(hang) else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url)
        }
    }
}
