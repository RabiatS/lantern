import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Whether Apple's on-device model can be used here, in words a person can read.
nonisolated enum AppleIntelligence {
    enum Status: Equatable, Sendable {
        case available
        case notEligible
        case notEnabled
        case notReady
        case unsupportedOS

        var isAvailable: Bool { self == .available }

        var text: String {
            switch self {
            case .available: "Available. About 3 billion parameters, kept by iOS, no download."
            case .notEligible: "Not on this device. Apple Intelligence needs an iPhone 15 Pro or later, or an M-series iPad or Mac."
            case .notEnabled: "Turned off. Enable Apple Intelligence in Settings to use it here."
            case .notReady: "Still downloading or preparing. Try again in a few minutes."
            case .unsupportedOS: "Needs iOS 26 or macOS 26."
            }
        }
    }

    static func status() -> Status {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return .notEligible
                case .appleIntelligenceNotEnabled: return .notEnabled
                case .modelNotReady: return .notReady
                @unknown default: return .notEligible
                }
            }
        }
        #endif
        return .unsupportedOS
    }
}

/// Apple's built-in model behind the same events as the MLX engine, so the
/// chat, the benchmark and the compaction can use either without caring.
///
/// Apple does not expose token counts, so tokens are estimated at four
/// characters each and the stats say so.
actor AppleEngine: GenerationBackend {
    #if canImport(FoundationModels)
    @available(iOS 26, macOS 26, *)
    private final class Box {
        var session: LanguageModelSession?
    }
    private var box: Any?
    #endif
    private var instructions: String?
    private var history: [ChatMessage] = []

    /// Start (or restart) a conversation from the message list.
    func beginConversation(instructions: String?, history: [ChatMessage]) {
        self.instructions = instructions
        self.history = history
        #if canImport(FoundationModels)
        box = nil
        #endif
    }

    func dropContext() {
        #if canImport(FoundationModels)
        box = nil
        #endif
    }

    func stream(_ prompt: String) -> AsyncThrowingStream<GenerationEvent, Error> {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            let session = currentSession()
            return run(session: session, prompt: prompt, maxTokens: InferenceLimits.maxGeneratedTokens, record: true)
        }
        #endif
        return AsyncThrowingStream { $0.finish(throwing: EngineError.noModelLoaded) }
    }

    func generateOnce(_ prompt: String, maxTokens: Int) -> AsyncThrowingStream<GenerationEvent, Error> {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            let session = LanguageModelSession(instructions: nil as String?)
            return run(session: session, prompt: prompt, maxTokens: maxTokens, record: false)
        }
        #endif
        return AsyncThrowingStream { $0.finish(throwing: EngineError.noModelLoaded) }
    }

    /// A short summary, used by the MLX side for compaction when this model is
    /// available: it costs the downloaded model no memory and no time.
    func summarise(_ transcript: String) async throws -> String {
        var summary = ""
        let request = """
            Summarise the conversation below in under 150 words so that it can be continued later. \
            Keep every name, number, decision and open question exactly as stated. Write in the third person. \
            Reply with the summary only.

            \(transcript)
            """
        for try await event in generateOnce(request, maxTokens: 220) {
            if case .token(let text) = event { summary += text }
        }
        return summary.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    #if canImport(FoundationModels)
    @available(iOS 26, macOS 26, *)
    private func currentSession() -> LanguageModelSession {
        if let box = box as? Box, let session = box.session { return session }
        var entries: [Transcript.Entry] = []
        if let instructions, !instructions.isEmpty {
            entries.append(.instructions(Transcript.Instructions(
                segments: [.text(Transcript.TextSegment(content: instructions))],
                toolDefinitions: [])))
        }
        for message in history {
            switch message.role {
            case .user:
                entries.append(.prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: message.text))])))
            case .assistant:
                entries.append(.response(Transcript.Response(assetIDs: [], segments: [.text(Transcript.TextSegment(content: message.text))])))
            case .system:
                break
            }
        }
        let session = LanguageModelSession(transcript: Transcript(entries: entries))
        let box = Box()
        box.session = session
        self.box = box
        return session
    }

    @available(iOS 26, macOS 26, *)
    private func run(
        session: LanguageModelSession, prompt: String, maxTokens: Int, record: Bool
    ) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let started = ContinuousClock.now
                var firstToken: Duration?
                var previous = ""
                var options = GenerationOptions()
                options.maximumResponseTokens = maxTokens
                options.temperature = 0.6
                do {
                    for try await snapshot in session.streamResponse(to: prompt, options: options) {
                        let content = snapshot.content
                        guard content.count > previous.count else { continue }
                        let delta = String(content.dropFirst(previous.count))
                        previous = content
                        if firstToken == nil { firstToken = ContinuousClock.now - started }
                        continuation.yield(.token(delta))
                    }
                    let elapsed = Self.seconds(ContinuousClock.now - started)
                    let first = Self.seconds(firstToken ?? (ContinuousClock.now - started))
                    let tokens = max(1, previous.count / 4)
                    let generateSeconds = max(0.001, elapsed - first)
                    continuation.yield(.finished(GenerationStats(
                        promptTokens: max(1, prompt.count / 4),
                        generatedTokens: tokens,
                        tokensPerSecond: Double(tokens) / generateSeconds,
                        promptSeconds: first,
                        timeToFirstToken: first,
                        estimated: true)))
                    if record {
                        self.history.append(ChatMessage(role: .user, text: prompt))
                        self.history.append(ChatMessage(role: .assistant, text: previous))
                    }
                    continuation.finish()
                } catch {
                    if record {
                        // The window overflowed or the session is unusable; start
                        // the next turn from the message list.
                        self.box = nil
                        if !previous.isEmpty {
                            self.history.append(ChatMessage(role: .user, text: prompt))
                            self.history.append(ChatMessage(role: .assistant, text: previous))
                        }
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    #endif

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
