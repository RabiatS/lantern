import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// What the engine reports back while a reply is being written.
nonisolated enum GenerationEvent: Sendable {
    case token(String)
    case finished(GenerationStats)
}

nonisolated struct GenerationStats: Sendable, Equatable, Codable {
    let promptTokens: Int
    let generatedTokens: Int
    let tokensPerSecond: Double
    /// Prefill: how long the prompt took before the first token could be sampled.
    let promptSeconds: Double
    /// Wall clock from the request to the first visible token.
    let timeToFirstToken: Double
}

nonisolated struct MemorySnapshot: Sendable, Equatable {
    let mlxActive: Int64
    let mlxCache: Int64
    let mlxPeak: Int64
    let available: Int64
    let thermalState: ProcessInfo.ThermalState
}

nonisolated enum EngineError: LocalizedError {
    case noModelLoaded
    case busy

    var errorDescription: String? {
        switch self {
        case .noModelLoaded: "No model is loaded."
        case .busy: "A reply is still being written."
        }
    }
}

/// Owns the loaded model. Load and unload weights, keep one chat session with its
/// KV cache, stream tokens out. An actor so the non-Sendable session is only ever
/// touched from one place.
///
/// The conversation lives here twice: as the session's KV cache, which makes a
/// follow-up turn cheap, and as a plain message list, which is what survives when
/// memory pressure throws the cache away. Dropping the context is just `session = nil`;
/// the next turn rebuilds it from the list with one prefill.
actor InferenceEngine {
    enum State: Equatable, Sendable {
        case empty
        case loading(String)
        case ready(String)
        case generating(String)
    }

    private(set) var state: State = .empty
    private var container: ModelContainer?
    private var session: ChatSession?
    private var loaded: ModelEntry?
    private var tier: DeviceTier = .standard
    private var instructions: String?
    private var history: [Chat.Message] = []
    private var generation: Task<Void, Never>?

    var loadedEntry: ModelEntry? { loaded }

    /// Read weights from disk into unified memory. Two to five seconds for a 3B model.
    func load(_ entry: ModelEntry, from directory: URL, tier: DeviceTier) async throws {
        if loaded == entry, container != nil { return }
        unload()
        state = .loading(entry.id)
        self.tier = tier
        Memory.cacheLimit = InferenceLimits.mlxCacheLimitBytes
        do {
            let configuration = ResolvedModelConfiguration(
                modelDirectory: directory,
                tokenizerDirectory: directory,
                name: entry.id,
                defaultPrompt: "",
                extraEOSTokens: entry.extraEOSTokens,
                stopStrings: nil,
                eosTokenIds: [],
                toolCallFormat: nil)
            let context = try await LLMModelFactory.shared._load(
                configuration: configuration,
                tokenizerLoader: TransformersTokenizerLoader())
            container = ModelContainer(context: context)
            loaded = entry
            state = .ready(entry.id)
        } catch {
            state = .empty
            throw error
        }
    }

    /// Drop the weights and every buffer MLX was holding. The next send reloads.
    func unload() {
        generation?.cancel()
        generation = nil
        session = nil
        container = nil
        loaded = nil
        state = .empty
        Memory.clearCache()
    }

    /// Keep the weights, throw away the conversation's KV cache and the buffer
    /// pool. Costs one prefill on the next turn; frees most of what is not weights.
    func dropContext() {
        session = nil
        Memory.clearCache()
    }

    /// Start (or restart) a conversation. Past turns are prefilled on the first
    /// send rather than now.
    func beginConversation(instructions: String?, history: [ChatMessage]) throws {
        guard container != nil else { throw EngineError.noModelLoaded }
        self.instructions = instructions
        self.history = history.compactMap { message in
            switch message.role {
            case .user: .user(message.text)
            case .assistant: .assistant(message.text)
            case .system: nil
            }
        }
        session = nil
    }

    static func generateParameters(for tier: DeviceTier) -> GenerateParameters {
        var parameters = GenerateParameters(temperature: 0.6, topP: 0.9)
        parameters.maxTokens = InferenceLimits.maxGeneratedTokens
        parameters.maxKVSize = InferenceLimits.maxKVTokens(for: tier)
        return parameters
    }

    /// Stream a reply in the current conversation. Tokens arrive as they are
    /// sampled; the last event carries the timing. Cancel by cancelling the task
    /// that iterates.
    func stream(_ prompt: String) -> AsyncThrowingStream<GenerationEvent, Error> {
        guard let container else {
            return AsyncThrowingStream { $0.finish(throwing: EngineError.noModelLoaded) }
        }
        let session = self.session ?? ChatSession(
            container,
            instructions: instructions,
            history: history,
            generateParameters: Self.generateParameters(for: tier))
        self.session = session
        return run(session: session, prompt: prompt, recordInHistory: true)
    }

    /// Generate once against a fresh session, outside the conversation. Used by
    /// the benchmark so each prompt starts from an empty KV cache.
    func generateOnce(_ prompt: String, maxTokens: Int) -> AsyncThrowingStream<GenerationEvent, Error> {
        guard let container else {
            return AsyncThrowingStream { $0.finish(throwing: EngineError.noModelLoaded) }
        }
        var parameters = Self.generateParameters(for: tier)
        parameters.maxTokens = maxTokens
        let session = ChatSession(container, instructions: nil, generateParameters: parameters)
        return run(session: session, prompt: prompt, recordInHistory: false)
    }

    private func run(
        session: ChatSession, prompt: String, recordInHistory: Bool
    ) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            guard let loaded else {
                continuation.finish(throwing: EngineError.noModelLoaded)
                return
            }
            if case .generating = state {
                continuation.finish(throwing: EngineError.busy)
                return
            }
            state = .generating(loaded.id)
            let task = Task {
                // `ready` is set before `finish()` on every path. A consumer that sends
                // again the instant its loop ends must not find the engine still busy.
                let started = ContinuousClock.now
                var firstToken: Duration?
                var reply = ""
                do {
                    for try await event in session.streamDetails(to: prompt) {
                        switch event {
                        case .chunk(let text):
                            if firstToken == nil { firstToken = ContinuousClock.now - started }
                            reply += text
                            continuation.yield(.token(text))
                        case .info(let info):
                            let seconds = info.generateTime
                            let rate = seconds > 0 ? Double(info.generationTokenCount) / seconds : 0
                            continuation.yield(.finished(GenerationStats(
                                promptTokens: info.promptTokenCount,
                                generatedTokens: info.generationTokenCount,
                                tokensPerSecond: rate,
                                promptSeconds: info.promptTime,
                                timeToFirstToken: Self.seconds(firstToken ?? (ContinuousClock.now - started)))))
                        case .toolCall:
                            break
                        }
                    }
                    if recordInHistory {
                        self.history.append(.user(prompt))
                        self.history.append(.assistant(reply))
                    }
                    self.state = .ready(loaded.id)
                    continuation.finish()
                } catch {
                    // A cancelled or failed turn leaves the session's cache in an
                    // unknown state. Rebuild from the list next time.
                    if recordInHistory {
                        self.session = nil
                        if !reply.isEmpty {
                            self.history.append(.user(prompt))
                            self.history.append(.assistant(reply))
                        }
                    }
                    self.state = .ready(loaded.id)
                    continuation.finish(throwing: error)
                }
            }
            generation = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func cancelGeneration() {
        generation?.cancel()
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    /// MLX's own view of memory plus what the process may still allocate. Cheap
    /// enough to poll while generating; this is the live readout.
    nonisolated static func memorySnapshot() -> MemorySnapshot {
        let snapshot = Memory.snapshot()
        return MemorySnapshot(
            mlxActive: Int64(snapshot.activeMemory),
            mlxCache: Int64(snapshot.cacheMemory),
            mlxPeak: Int64(snapshot.peakMemory),
            available: Int64(os_proc_available_memory()),
            thermalState: ProcessInfo.processInfo.thermalState)
    }

    nonisolated static func resetPeakMemory() {
        Memory.peakMemory = 0
    }
}
