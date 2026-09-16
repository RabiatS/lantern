import Foundation
import Observation

/// The one object the UI talks to. Wires the device gate, the store, the engine
/// and the memory monitor together and holds the conversation being viewed.
@Observable
final class AppState {
    let store: ModelStore
    let engine = InferenceEngine()
    let pressure = MemoryPressureMonitor()
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

    private var reply: Task<Void, Never>?
    private var benchmark: Task<Void, Never>?

    init(store: ModelStore = ModelStore(), conversations: ConversationStore = ConversationStore()) {
        self.store = store
        self.conversations = conversations
        self.device = DeviceCapability.current()
        let entry = Self.rememberedEntry() ?? ModelCatalog.defaultEntry
        self.selectedEntry = entry
        self.current = Conversation(modelId: entry.id)
        self.history = conversations.loadAll()
        wirePressure()
        pressure.start()
    }

    // MARK: Device gate

    func refreshDevice() {
        device = DeviceCapability.current()
    }

    func verdict(for entry: ModelEntry) -> Verdict {
        DeviceCapability.verdict(for: entry, report: device)
    }

    /// Models this phone may run, in catalog order.
    var offeredEntries: [ModelEntry] {
        ModelCatalog.entries(for: device.tier)
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

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    private func syncEngineState() async {
        engineState = await engine.state
    }

    // MARK: Conversations

    func newConversation() {
        reply?.cancel()
        current = Conversation(modelId: selectedEntry.id)
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
        guard !prompt.isEmpty, !isGenerating else { return }
        lastError = nil
        current.messages.append(ChatMessage(role: .user, text: prompt))
        let assistant = ChatMessage(role: .assistant, text: "")
        current.messages.append(assistant)
        persist()
        isGenerating = true

        reply = Task {
            defer {
                isGenerating = false
                live = nil
            }
            do {
                try await ensureLoaded()
                var buffer = ""
                var tokens = 0
                let started = ContinuousClock.now
                var lastFlush = started
                live = LiveStats(tokens: 0, elapsed: 0, tokensPerSecond: 0, memory: InferenceEngine.memorySnapshot())
                for try await event in await engine.stream(prompt) {
                    switch event {
                    case .token(let piece):
                        buffer += piece
                        tokens += 1
                        // Coalesce UI updates to roughly 30 per second.
                        let now = ContinuousClock.now
                        if now - lastFlush > .milliseconds(33) {
                            update(assistant.id) { $0.text = buffer }
                            let elapsed = Self.seconds(now - started)
                            live = LiveStats(
                                tokens: tokens,
                                elapsed: elapsed,
                                tokensPerSecond: elapsed > 0 ? Double(tokens) / elapsed : 0,
                                memory: InferenceEngine.memorySnapshot())
                            lastFlush = now
                        }
                    case .finished(let stats):
                        update(assistant.id) { $0.text = buffer; $0.stats = stats }
                    }
                }
                update(assistant.id) { $0.text = buffer }
            } catch is CancellationError {
                // Stopped by the user or by a pressure unload; keep what arrived.
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
            self?.refreshDevice()
            self?.pressure.clear()
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
                let runner = BenchmarkRunner(engine: engine)
                let report = try await runner.run(
                    mode: mode,
                    entry: selectedEntry,
                    directory: store.directory(for: selectedEntry),
                    tier: device.tier,
                    loadSeconds: lastLoadSeconds
                ) { [weak self] message in
                    Task { @MainActor in self?.benchmarkProgress = message }
                }
                lastBenchmark = report
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

/// What the assistant is for. The system prompt is the one place the app has a
/// point of view, so it is a setting rather than a constant.
nonisolated enum Persona: String, CaseIterable, Codable, Sendable {
    case general
    case electronicsTutor

    var title: String {
        switch self {
        case .general: "General"
        case .electronicsTutor: "Electronics tutor"
        }
    }

    var instructions: String {
        switch self {
        case .general:
            "You are a helpful assistant running entirely on this phone, with no internet. Be concise."
        case .electronicsTutor:
            "You are a patient electronics tutor running entirely on this phone, with no internet. "
                + "Teach circuits, components and measurement the way a good lab partner would: ask what "
                + "the learner has on the bench, work in SI units, show the arithmetic, and warn about "
                + "mains voltage and charged capacitors before anything else. Keep answers short and "
                + "end with one question that checks understanding."
        }
    }

    private static let key = "lantern.persona"

    static func remembered() -> Persona {
        guard let raw = UserDefaults.standard.string(forKey: key) else { return .general }
        return Persona(rawValue: raw) ?? .general
    }

    func remember() {
        UserDefaults.standard.set(rawValue, forKey: Self.key)
    }
}
