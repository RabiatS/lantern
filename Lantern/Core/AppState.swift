import Foundation
import Observation

/// The one object the UI talks to. Wires the device gate, the store, the engine
/// and the memory monitor together and holds the conversation being viewed.
@Observable
final class AppState {
    let store: ModelStore
    let engine = InferenceEngine()
    let apple = AppleEngine()
    /// Whether Apple's model can be used here, read at launch and on foreground.
    private(set) var appleStatus = AppleIntelligence.status()
    /// Who answers. Persisted. Falls back to the Lantern model if Apple's is unavailable.
    var backend: BackendKind = BackendKind(rawValue: UserDefaults.standard.string(forKey: "lantern.backend") ?? "") ?? .lantern {
        didSet {
            UserDefaults.standard.set(backend.rawValue, forKey: "lantern.backend")
            resetEngineConversation()
        }
    }
    var usingApple: Bool { backend == .apple && appleStatus.isAvailable }
    /// The last benchmark per backend, for the side by side.
    private(set) var benchmarks: [BackendKind: BenchmarkReport] = [:]
    let pressure = MemoryPressureMonitor()
    let hangs = HangMonitor()
    let impact = Impact()
    /// The "did you know" line for the current empty chat. Re-rolled per new chat.
    private(set) var fact = Facts.random()
    private let conversations: ConversationStore

    private(set) var device: DeviceReport
    private(set) var engineState: InferenceEngine.State = .empty
    private(set) var history: [Conversation] = []
    var current: Conversation
    var selectedEntry: ModelEntry
    private(set) var isGenerating = false
    private(set) var lastError: String?
    /// Set when memory pressure unloaded the model. Cleared on the next reload.
    private(set) var unloadedByPressure = false
    /// The instrument readout while a reply streams: tokens so far, rate, memory.
    private(set) var live: LiveStats?
    /// The reply being written, kept apart from `current.messages` so that each
    /// token re-renders one row instead of the whole list.
    private(set) var streamingText: String?
    private(set) var streamingMessageId: UUID?
    /// Seconds the last weight load took, reported with benchmarks.
    private(set) var lastLoadSeconds: Double = 0
    var persona: Persona = Persona.remembered() {
        didSet {
            persona.remember()
            resetEngineConversation()
        }
    }
    private(set) var benchmarkProgress: String?
    private(set) var lastBenchmark: BenchmarkReport?
    /// How full the context window is, refreshed after every turn.
    private(set) var context: ContextUsage?
    private(set) var isCompacting = false

    /// Anything that has the model's attention: a reply, a benchmark, a compaction.
    var isBusy: Bool { isGenerating || benchmark != nil || isCompacting }

    /// The welcome screen shows until a model is on the phone and the person
    /// has tapped Start once. Deleting every model brings it back.
    private var welcomed = UserDefaults.standard.bool(forKey: "lantern.welcomed")
    var showWelcome: Bool { !isPreview && (!welcomed || (store.installedEntries.isEmpty && !usingApple)) }

    /// `--preview` on the command line seeds a sample chat so the screens can be
    /// looked at in the simulator, where no model can run.
    let isPreview = CommandLine.arguments.contains("--preview")

    func finishWelcome() {
        welcomed = true
        UserDefaults.standard.set(true, forKey: "lantern.welcomed")
    }

    private var reply: Task<Void, Never>?
    private var benchmark: Task<Void, Never>?
    /// The bundled guides, built once off the main actor. Nil for the first
    /// moments after launch, in which case a send goes out ungrounded.
    private var library: GuideLibrary?

    init(store: ModelStore = ModelStore(), conversations: ConversationStore = ConversationStore()) {
        self.store = store
        self.conversations = conversations
        self.device = DeviceCapability.current()
        let entry = Self.rememberedEntry() ?? ModelCatalog.defaultEntry
        self.selectedEntry = entry
        self.current = Conversation(modelId: entry.id)
        conversations.purgeExpired()
        self.history = conversations.loadAll()
        if isPreview { seedPreview() }
        wirePressure()
        pressure.start()
        hangs.context = { [weak self] in
            guard let self else { return ("", false, false) }
            return ("\(self.engineState)", self.isGenerating, self.isCompacting)
        }
        hangs.start()
        Task.detached(priority: .utility) { [weak self] in
            let library = GuideLibrary()
            await MainActor.run { self?.library = library }
        }
    }

    private func seedPreview() {
        persona = .firstAid
        var chat = Conversation(modelId: ModelCatalog.qwen2_5_1_5B.id)
        chat.messages = [
            ChatMessage(role: .user, text: "Someone has a deep cut on their hand that will not stop bleeding."),
            ChatMessage(role: .assistant, text: "Call emergency services now if the bleeding is heavy or they feel faint.\n\n1. Press hard and directly on the cut with a clean cloth.\n2. Do not lift it to look; add more cloth on top.\n3. Keep pressing for ten minutes and raise the hand.\n4. Watch for pale, cold or faint signs of shock.\n\nIs the cloth soaking through?",
                        stats: GenerationStats(promptTokens: 412, generatedTokens: 78, tokensPerSecond: 81.4, promptSeconds: 0.31, timeToFirstToken: 0.38),
                        sources: ["Severe bleeding", "Shock"]),
            ChatMessage(role: .user, text: "Yes, a lot."),
            ChatMessage(role: .assistant, text: "Keep the first cloth in place and add more on top. If the hand is still bleeding heavily after ten minutes of firm pressure, that is an emergency: call now and keep pressing until help arrives.",
                        stats: GenerationStats(promptTokens: 530, generatedTokens: 44, tokensPerSecond: 83.0, promptSeconds: 0.12, timeToFirstToken: 0.16),
                        sources: ["Severe bleeding"]),
        ]
        chat.refreshTitle()
        current = chat
        history = [chat]
        context = ContextUsage(tokens: 1_204, limit: 8_192)
        live = LiveStats(tokens: 44, elapsed: 0.53, tokensPerSecond: 83.0,
                         memory: MemorySnapshot(mlxActive: 760_000_000, mlxCache: 0, mlxPeak: 790_000_000,
                                                available: 6_100_000_000, thermalState: .nominal))
    }

    // MARK: Device gate

    func refreshDevice() {
        device = DeviceCapability.current()
        appleStatus = AppleIntelligence.status()
    }

    /// Switch to Apple's model without downloading anything.
    func startWithApple() {
        backend = .apple
        finishWelcome()
    }

    func verdict(for entry: ModelEntry) -> Verdict {
        DeviceCapability.verdict(for: entry, report: device)
    }

    /// Models this phone may run, in catalog order.
    var offeredEntries: [ModelEntry] {
        ModelCatalog.entries(for: device.tier)
    }

    /// The thing to check before leaving Wi-Fi: is the chosen model on the phone.
    /// Apple's model counts once it is available; iOS keeps it resident.
    var readyForOffline: Bool {
        usingApple || store.installedModel(for: selectedEntry) != nil
    }

    /// Days until a conversation is deleted, rounded up. Zero means today.
    func daysLeft(for conversation: Conversation) -> Int {
        let seconds = ConversationStore.expiry(of: conversation).timeIntervalSinceNow
        return max(0, Int((seconds / 86_400).rounded(.up)))
    }

    // MARK: Model selection

    func select(_ entry: ModelEntry) {
        guard entry != selectedEntry else { return }
        selectedEntry = entry
        UserDefaults.standard.set(entry.id, forKey: Self.selectedKey)
        Task {
            await engine.unload()
            await syncEngineState()
        }
    }

    private static let selectedKey = "lantern.selectedModel"

    private static func rememberedEntry() -> ModelEntry? {
        guard let id = UserDefaults.standard.string(forKey: selectedKey) else { return nil }
        return ModelCatalog.entry(id: id)
    }

    func removeModel(_ entry: ModelEntry) {
        Task {
            if await engine.loadedEntry == entry { await engine.unload() }
            do { try store.remove(entry) } catch { lastError = error.localizedDescription }
            await syncEngineState()
        }
    }

    // MARK: Loading

    /// Load the selected model if it is not already resident. Reload on demand is
    /// this: after a pressure unload the next send lands here.
    func ensureLoaded() async throws {
        if usingApple {
            await apple.beginConversation(instructions: persona.instructions, history: current.messages)
            return
        }
        guard store.installedModel(for: selectedEntry) != nil else {
            throw ModelStoreError.notInstalled(selectedEntry.id)
        }
        let already = await engine.loadedEntry
        if already == selectedEntry, engineState != .empty { return }
        await syncEngineState()
        let started = ContinuousClock.now
        try await engine.load(selectedEntry, from: store.directory(for: selectedEntry), tier: device.tier)
        lastLoadSeconds = Self.seconds(ContinuousClock.now - started)
        unloadedByPressure = false
        try await engine.beginConversation(instructions: persona.instructions, history: current.messages)
        await syncEngineState()
    }

    /// Ask the engine where the context stands. Cheap; called after each turn.
    private func syncContext() async {
        if usingApple {
            context = nil
            return
        }
        context = await engine.loadedEntry == nil ? nil : await engine.contextUsage
    }

    private static func snapshotOffMain() async -> MemorySnapshot {
        await Task.detached(priority: .utility) { InferenceEngine.memorySnapshot() }.value
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    private func syncEngineState() async {
        engineState = await engine.state
        await syncContext()
    }

    // MARK: Conversations

    func newConversation() {
        reply?.cancel()
        current = Conversation(modelId: selectedEntry.id)
        fact = Facts.random()
        resetEngineConversation()
    }

    /// Everything in history, including the chat on screen.
    func deleteAllConversations() {
        reply?.cancel()
        for conversation in history { try? conversations.delete(conversation.id) }
        history.removeAll()
        current = Conversation(modelId: selectedEntry.id)
        fact = Facts.random()
        resetEngineConversation()
    }

    func open(_ conversation: Conversation) {
        reply?.cancel()
        current = conversation
        if let entry = ModelCatalog.entry(id: conversation.modelId) { selectedEntry = entry }
        resetEngineConversation()
    }

    /// Point the engine at the conversation on screen. Cheap: the KV cache is
    /// dropped and rebuilt from the message list on the next send.
    private func resetEngineConversation() {
        let messages = current.messages
        let instructions = persona.instructions
        Task {
            await apple.beginConversation(instructions: instructions, history: messages)
            if await engine.loadedEntry == selectedEntry {
                try? await engine.beginConversation(instructions: instructions, history: messages)
            }
            await engine.dropContext()
        }
    }

    func delete(_ conversation: Conversation) {
        try? conversations.delete(conversation.id)
        history.removeAll { $0.id == conversation.id }
        if current.id == conversation.id { newConversation() }
    }

    private func persist() {
        current.updatedAt = Date()
        current.refreshTitle()
        try? conversations.save(current)
        history.removeAll { $0.id == current.id }
        history.insert(current, at: 0)
    }

    // MARK: Sending

    func send(_ text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isBusy else { return }
        lastError = nil
        current.messages.append(ChatMessage(role: .user, text: prompt))
        let assistant = ChatMessage(role: .assistant, text: "")
        current.messages.append(assistant)
        persist()
        isGenerating = true

        streamingMessageId = assistant.id
        streamingText = ""
        let guide = persona.guide
        let library = library

        reply = Task {
            defer {
                isGenerating = false
                live = nil
                streamingText = nil
                streamingMessageId = nil
            }
            do {
                try await ensureLoaded()
                // Near the end of the window, fold the older turns into a summary
                // first, so the person does not have to start a new chat.
                if let context, context.isCritical {
                    await compactNow()
                }
                // Grounding: the safety personas answer from the bundled guide.
                // Retrieval is a few milliseconds of BM25 plus one sentence
                // embedding, off the main actor.
                var modelPrompt = prompt
                if let guide, let library {
                    let hits = await Task.detached { library.retrieve(prompt, in: guide) }.value
                    if !hits.isEmpty {
                        modelPrompt = GuideLibrary.groundedPrompt(question: prompt, passages: hits)
                        update(assistant.id) { $0.sources = hits.map(\.passage.title) }
                    }
                }
                var buffer = ""
                var tokens = 0
                let started = ContinuousClock.now
                var lastText = started
                var lastLive = started
                live = LiveStats(tokens: 0, elapsed: 0, tokensPerSecond: 0, memory: await Self.snapshotOffMain())
                let events = usingApple ? await apple.stream(modelPrompt) : await engine.stream(modelPrompt)
                for try await event in events {
                    switch event {
                    case .token(let piece):
                        buffer += piece
                        tokens += 1
                        // Text at about 20 updates a second, the readout at 5. The
                        // model produces 80 tokens a second; the screen cannot use that.
                        let now = ContinuousClock.now
                        if now - lastText > .milliseconds(50) {
                            streamingText = buffer
                            lastText = now
                        }
                        if now - lastLive > .milliseconds(250) {
                            let elapsed = Self.seconds(now - started)
                            // MLX's memory counters take the allocator lock; never
                            // wait for that on the main thread.
                            let memory = await Self.snapshotOffMain()
                            live = LiveStats(
                                tokens: tokens,
                                elapsed: elapsed,
                                tokensPerSecond: elapsed > 0 ? Double(tokens) / elapsed : 0,
                                memory: memory)
                            lastLive = now
                        }
                    case .finished(let stats):
                        update(assistant.id) { $0.text = buffer; $0.stats = stats }
                        impact.record(stats: stats, promptCharacters: prompt.count + buffer.count)
                    }
                }
                update(assistant.id) { $0.text = buffer }
            } catch is CancellationError {
                // Stopped by the user or by a pressure unload; keep what arrived.
                if let partial = streamingText { update(assistant.id) { $0.text = partial } }
            } catch {
                lastError = error.localizedDescription
                update(assistant.id) { message in
                    if message.text.isEmpty { message.text = "(no reply: \(error.localizedDescription))" }
                }
            }
            persist()
            await syncEngineState()
        }
    }

    func stop() {
        reply?.cancel()
        Task { await engine.cancelGeneration() }
    }

    /// Text for one message's stats line: Apple's numbers are estimates.
    static func statsLine(_ stats: GenerationStats) -> String {
        let prefix = stats.estimated == true ? "~" : ""
        return String(format: "%@%.0f tok/s · %@%d tokens · %.2fs to first", prefix, stats.tokensPerSecond, prefix, stats.generatedTokens, stats.timeToFirstToken)
    }

    // MARK: Compaction

    /// Fold everything but the last two turns into a summary and keep going.
    /// The full transcript stays on disk; a system line in the chat marks where
    /// the summary took over.
    func compact() {
        guard !isBusy, context?.tokens ?? 0 > 0 else { return }
        Task { await compactNow() }
    }

    private func compactNow() async {
        isCompacting = true
        defer { isCompacting = false }
        do {
            try await ensureLoaded()
            if usingApple {
                // Apple's session manages its own window; nothing to fold.
                return
            }
            // When Apple's model is available it writes the summary: the
            // downloaded model keeps its memory and the phone its time.
            let summary = try await engine.compact(using: appleStatus.isAvailable ? apple : nil)
            current.messages.append(ChatMessage(
                role: .system,
                text: "Older messages were summarised to keep the conversation going: " + summary))
            persist()
        } catch EngineError.nothingToCompact {
            // Too short to matter; the rotating cache handles it.
        } catch {
            lastError = error.localizedDescription
        }
        await syncEngineState()
    }

    private func update(_ id: UUID, _ change: (inout ChatMessage) -> Void) {
        guard let index = current.messages.firstIndex(where: { $0.id == id }) else { return }
        change(&current.messages[index])
    }

    // MARK: Memory pressure policy

    /// Warning while a reply is streaming: keep the weights, drop the KV cache and
    /// MLX's buffer pool so the reply can finish. Warning while idle, or critical
    /// at any time: unload the weights entirely. Background: drop the context,
    /// because a resident model is the first thing jetsam takes. Either way the
    /// next send reloads what it needs.
    private func wirePressure() {
        pressure.onWarning = { [weak self] in
            guard let self else { return }
            Task {
                if self.isGenerating {
                    await self.engine.dropContext()
                } else {
                    await self.unloadForPressure()
                }
            }
        }
        pressure.onCritical = { [weak self] in
            guard let self else { return }
            self.reply?.cancel()
            self.benchmark?.cancel()
            Task { await self.unloadForPressure() }
        }
        pressure.onBackground = { [weak self] in
            guard let self else { return }
            Task { await self.engine.dropContext() }
        }
        pressure.onForeground = { [weak self] in
            guard let self else { return }
            self.refreshDevice()
            self.pressure.clear()
            if self.conversations.purgeExpired() > 0 {
                self.history = self.conversations.loadAll()
            }
        }
    }

    private func unloadForPressure() async {
        await engine.unload()
        unloadedByPressure = true
        await syncEngineState()
    }

    // MARK: Benchmark

    func runBenchmark(_ mode: BenchmarkMode) {
        guard benchmark == nil, !isGenerating else { return }
        benchmarkProgress = "Loading model"
        benchmark = Task {
            defer {
                benchmark = nil
                benchmarkProgress = nil
            }
            do {
                try await ensureLoaded()
                let kind = usingApple ? BackendKind.apple : .lantern
                let runner = BenchmarkRunner(engine: usingApple ? apple : engine, backend: kind)
                let report = try await runner.run(
                    mode: mode,
                    modelId: usingApple ? "apple/foundation-model" : selectedEntry.id,
                    tier: device.tier,
                    loadSeconds: usingApple ? 0 : lastLoadSeconds
                ) { [weak self] message in
                    Task { @MainActor in self?.benchmarkProgress = message }
                }
                lastBenchmark = report
                benchmarks[kind] = report
                // The benchmark's sessions were throwaway; put the conversation back.
                try await engine.beginConversation(instructions: persona.instructions, history: current.messages)
            } catch is CancellationError {
                // Stopped by the user.
            } catch {
                lastError = error.localizedDescription
            }
            await syncEngineState()
        }
    }

    func stopBenchmark() {
        benchmark?.cancel()
        Task { await engine.cancelGeneration() }
    }
}

/// Readout during generation. Refreshed with the text, about thirty times a second.
nonisolated struct LiveStats: Sendable, Equatable {
    let tokens: Int
    let elapsed: Double
    let tokensPerSecond: Double
    let memory: MemorySnapshot
}
