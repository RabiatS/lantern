import CoreGraphics
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM

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
    /// True when the engine cannot count tokens and they were estimated from
    /// characters, which is the case for Apple's model.
    let estimated: Bool?

    init(promptTokens: Int, generatedTokens: Int, tokensPerSecond: Double, promptSeconds: Double, timeToFirstToken: Double, estimated: Bool? = nil) {
        self.promptTokens = promptTokens
        self.generatedTokens = generatedTokens
        self.tokensPerSecond = tokensPerSecond
        self.promptSeconds = promptSeconds
        self.timeToFirstToken = timeToFirstToken
        self.estimated = estimated
    }
}

nonisolated struct MemorySnapshot: Sendable, Equatable {
    let mlxActive: Int64
    let mlxCache: Int64
    let mlxPeak: Int64
    let available: Int64
    let thermalState: ProcessInfo.ThermalState
}

/// How full the conversation's context window is.
nonisolated struct ContextUsage: Sendable, Equatable {
    let tokens: Int
    let limit: Int

    var fraction: Double { limit > 0 ? Double(tokens) / Double(limit) : 0 }
    /// Worth offering the user a compaction.
    var isHigh: Bool { fraction >= 0.6 }
    /// Compact before the next turn or the oldest context starts falling out.
    var isCritical: Bool { fraction >= 0.85 }
}

nonisolated enum EngineError: LocalizedError {
    case noModelLoaded
    case nothingToCompact

    var errorDescription: String? {
        switch self {
        case .noModelLoaded: "No model is loaded."
        case .nothingToCompact: "The conversation is too short to compact."
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
///
/// Requests are serialised: a new one cancels and waits for the one in flight.
/// The previous design refused with "busy", which surfaced as a lost reply any
/// time a tap landed while the benchmark or a stale turn was still running.
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
    /// Whether a picture is part of the conversation. After a picture turn the
    /// next text turn rebuilds the session with the picture in its history, so
    /// Qwen2-VL works out every position in one pass. Carrying on from the cache
    /// instead leaves the text after the picture at the wrong positions, which
    /// the library does not correct until a later release.
    private var conversationHasImage = false
    private var generation: Task<Void, Never>?
    private(set) var contextTokens = 0

    var loadedEntry: ModelEntry? { loaded }

    var contextUsage: ContextUsage {
        ContextUsage(tokens: contextTokens, limit: InferenceLimits.maxKVTokens(for: tier))
    }

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
            let loader = TransformersTokenizerLoader()
            let context: ModelContext = switch entry.kind {
            case .text: try await LLMModelFactory.shared._load(configuration: configuration, tokenizerLoader: loader)
            case .vision: try await VLMModelFactory.shared._load(configuration: configuration, tokenizerLoader: loader)
            }
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
        let hadModel = container != nil
        container = nil
        loaded = nil
        state = .empty
        // Touching MLX's allocator starts Metal. Never do that for nothing: it
        // costs time on a phone and aborts in the simulator, which has no MLX device.
        if hadModel { Memory.clearCache() }
    }

    /// Keep the weights, throw away the conversation's KV cache and the buffer
    /// pool. Costs one prefill on the next turn; frees most of what is not weights.
    func dropContext() {
        session = nil
        if container != nil { Memory.clearCache() }
    }

    /// Start (or restart) a conversation. Past turns are prefilled on the first
    /// send rather than now.
    /// `pictureURL` finds the file for a message's picture, so a vision model
    /// sees earlier pictures again when the conversation is rebuilt.
    func beginConversation(
        instructions: String?, history: [ChatMessage], pictureURL: (@Sendable (String) -> URL)? = nil
    ) async throws {
        guard container != nil else { throw EngineError.noModelLoaded }
        self.instructions = instructions
        let sees = loaded?.kind == .vision
        self.history = history.compactMap { message in
            switch message.role {
            case .user:
                let pictures: [UserInput.Image] = if sees, let name = message.imageName, let pictureURL {
                    [.url(pictureURL(name))]
                } else {
                    []
                }
                return .user(message.text, images: pictures)
            case .assistant: return .assistant(message.text)
            case .system: return nil
            }
        }
        conversationHasImage = self.history.contains { !$0.images.isEmpty }
        session = nil
        await recountContext()
    }

    static func generateParameters(for tier: DeviceTier) -> GenerateParameters {
        var parameters = GenerateParameters(temperature: 0.6, topP: 0.9)
        parameters.maxTokens = InferenceLimits.maxGeneratedTokens
        parameters.maxKVSize = InferenceLimits.maxKVTokens(for: tier)
        #if DEBUG
        if let temperature = LaunchArguments.value(for: "temp").flatMap(Float.init) { parameters.temperature = temperature }
        if LaunchArguments.has("no-kv-limit") { parameters.maxKVSize = nil }
        if let penalty = LaunchArguments.value(for: "repeat").flatMap(Float.init) { parameters.repetitionPenalty = penalty }
        #endif
        return parameters
    }

    /// Stream a reply in the current conversation. Tokens arrive as they are
    /// sampled; the last event carries the timing. Cancel by cancelling the task
    /// that iterates.
    /// `imageURL` is a picture for a vision model to look at with this turn.
    /// Pictures are resized to 512 on the long side before they reach the model,
    /// which keeps their token cost in the hundreds.
    func stream(_ prompt: String, imageURL: URL? = nil) -> AsyncThrowingStream<GenerationEvent, Error> {
        guard let container else {
            return AsyncThrowingStream { $0.finish(throwing: EngineError.noModelLoaded) }
        }
        if imageURL == nil, conversationHasImage { self.session = nil }
        let session = self.session ?? ChatSession(
            container,
            instructions: instructions,
            history: history,
            generateParameters: Self.generateParameters(for: tier),
            processing: Self.imageProcessing)
        self.session = session
        return run(session: session, prompt: prompt, images: imageURL.map { [.url($0)] } ?? [], recordInHistory: true)
    }

    static var imageProcessing: UserInput.Processing {
        #if DEBUG
        if let size = LaunchArguments.value(for: "resize") {
            if size == "none" { return .init() }
            if let side = Double(size) { return .init(resize: CGSize(width: side, height: side)) }
        }
        #endif
        return .init(resize: CGSize(width: 512, height: 512))
    }

    /// Generate once against a fresh session, outside the conversation. Used by
    /// the benchmark and by compaction so each request starts from an empty KV cache.
    func generateOnce(_ prompt: String, maxTokens: Int) -> AsyncThrowingStream<GenerationEvent, Error> {
        guard let container else {
            return AsyncThrowingStream { $0.finish(throwing: EngineError.noModelLoaded) }
        }
        var parameters = Self.generateParameters(for: tier)
        parameters.maxTokens = maxTokens
        let session = ChatSession(container, instructions: nil, generateParameters: parameters)
        return run(session: session, prompt: prompt, images: [], recordInHistory: false)
    }

    private func run(
        session: ChatSession, prompt: String, images: [UserInput.Image], recordInHistory: Bool
    ) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            guard let loaded else {
                continuation.finish(throwing: EngineError.noModelLoaded)
                return
            }
            let previous = generation
            state = .generating(loaded.id)
            let task = Task {
                // One request at a time. Whatever was running is cancelled and
                // allowed to wind down before this one touches the model.
                if let previous {
                    previous.cancel()
                    await previous.value
                }
                let started = ContinuousClock.now
                var firstToken: Duration?
                var reply = ""
                do {
                    try Task.checkCancellation()
                    for try await event in session.streamDetails(to: prompt, images: images) {
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
                        self.history.append(.user(prompt, images: images))
                        self.history.append(.assistant(reply))
                        if !images.isEmpty { self.conversationHasImage = true }
                        await self.recountContext()
                    }
                    self.finishGeneration(loaded)
                    continuation.finish()
                } catch {
                    // A cancelled or failed turn leaves the session's cache in an
                    // unknown state. Rebuild from the list next time.
                    if recordInHistory {
                        self.session = nil
                        if !reply.isEmpty {
                            self.history.append(.user(prompt, images: images))
                            if !images.isEmpty { self.conversationHasImage = true }
                            self.history.append(.assistant(reply))
                            await self.recountContext()
                        }
                    }
                    self.finishGeneration(loaded)
                    continuation.finish(throwing: error)
                }
            }
            generation = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Back to ready, unless a newer request has already taken over or the
    /// model was unloaded underneath us.
    private func finishGeneration(_ entry: ModelEntry) {
        guard loaded == entry, case .generating = state else { return }
        state = .ready(entry.id)
    }

    func cancelGeneration() {
        generation?.cancel()
    }

    #if DEBUG
    /// A fingerprint of a picture after the model's own preprocessing, for
    /// telling a random preprocessing fault from a random model fault.
    func debugImageFingerprint(_ url: URL) async throws -> String {
        guard let container else { throw EngineError.noModelLoaded }
        return try await container.perform { context in
            var input = UserInput(prompt: "Describe this.", images: [.url(url)])
            input.processing = .init(resize: CGSize(width: 512, height: 512))
            let prepared = try await context.processor.prepare(input: input)
            guard let pixels = prepared.image?.pixels else { return "no pixels" }
            let sum = pixels.sum().item(Float.self)
            let magnitude = abs(pixels).sum().item(Float.self)
            let finite = isNaN(pixels).any().item(Bool.self) ? "has NaN" : "finite"
            return "shape=\(pixels.shape) sum=\(sum) abs=\(magnitude) \(finite) tokens=\(prepared.text.tokens.size)"
        }
    }
    #endif

    // MARK: Context

    /// Tokens the conversation occupies, measured with the real tokenizer so the
    /// number means the same thing the KV cache limit does.
    private func recountContext() async {
        guard let container else {
            contextTokens = 0
            return
        }
        let transcript = ([instructions ?? ""] + history.map { "\($0.role.rawValue): \($0.content)" })
            .joined(separator: "\n")
        contextTokens = await container.encode(transcript).count
    }

    /// Summarise everything but the last two turns and continue from the summary.
    /// The KV cache is dropped; the next send prefills the summary plus the
    /// recent turns, which is far cheaper than the window it replaces. Returns
    /// the summary for the caller to show.
    func compact(using summariser: AppleEngine? = nil) async throws -> String {
        guard container != nil else { throw EngineError.noModelLoaded }
        let keep = 4
        guard history.count > keep + 1 else { throw EngineError.nothingToCompact }
        let older = history.prefix(history.count - keep)
        let recent = Array(history.suffix(keep))

        let transcript = older
            .map { "\($0.role.rawValue.capitalized): \($0.content)" }
            .joined(separator: "\n\n")
        let request = """
            Summarise the conversation below in under 150 words so that it can be continued later. \
            Keep every name, number, decision and open question exactly as stated. Write in the third person. \
            Reply with the summary only.

            \(transcript)
            """
        var summary = ""
        if let summariser {
            summary = try await summariser.summarise(transcript)
        } else {
            for try await event in generateOnce(request, maxTokens: 220) {
                if case .token(let text) = event { summary += text }
            }
        }
        summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { throw EngineError.nothingToCompact }

        history = [
            .user("Here is a summary of our conversation so far, so we can continue it: \(summary)"),
            .assistant("Understood. Let's continue from there."),
        ] + recent
        session = nil
        Memory.clearCache()
        await recountContext()
        return summary
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
            available: Self.availableMemory(),
            thermalState: ProcessInfo.processInfo.thermalState)
    }

    nonisolated static func availableMemory() -> Int64 {
        #if os(iOS)
        Int64(os_proc_available_memory())
        #else
        Int64(ProcessInfo.processInfo.physicalMemory) * 3 / 4
        #endif
    }

    nonisolated static func resetPeakMemory() {
        Memory.peakMemory = 0
    }
}
