import SwiftUI

/// A bare working screen so the backend can be exercised on a device before any
/// design work: the device verdict, model install and load, and a streaming reply.
/// The real UI replaces this file.
struct RootView: View {
    @Environment(AppState.self) private var app
    @State private var draft = ""
    @FocusState private var composing: Bool

    var body: some View {
        NavigationStack {
            List {
                deviceSection
                LiveSection()
                modelsSection
                personaSection
                benchmarkSection
                chatSection
                historySection
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Lantern")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New chat") { app.newConversation() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { composing = false }
                }
            }
            .safeAreaInset(edge: .bottom) { composer }
        }
    }

    private var deviceSection: some View {
        Section("This phone") {
            LabeledContent("Memory", value: gb(app.device.physicalMemory))
            LabeledContent("Available now", value: gb(app.device.availableMemory))
            LabeledContent("Free disk", value: gb(app.device.freeDisk))
            LabeledContent("Tier", value: "\(app.device.tier)")
            LabeledContent("Engine", value: "\(app.engineState)")
            LabeledContent("Ready to go offline", value: app.readyForOffline ? "Yes" : "No")
            if !app.readyForOffline {
                Text("Download a model while you have Wi-Fi. After that the app needs no network.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if app.unloadedByPressure {
                Text("Model was unloaded under memory pressure. It reloads on the next send.")
                    .foregroundStyle(.orange)
            }
            if let error = app.lastError {
                Text(error).foregroundStyle(.red)
            }
        }
    }

    private var modelsSection: some View {
        Section("Models") {
            @Bindable var store = app.store
            Toggle("Download on Wi-Fi only", isOn: $store.wifiOnly)
            ForEach(ModelCatalog.all) { entry in
                ModelRow(entry: entry)
            }
        }
    }

    @ViewBuilder
    private var historySection: some View {
        let past = app.history.filter { $0.id != app.current.id }
        if !past.isEmpty {
            Section("History, kept \(ConversationStore.retentionDays) days") {
                ForEach(past) { conversation in
                    Button {
                        app.open(conversation)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(conversation.title)
                            Text("\(conversation.messages.count) messages, deletes in \(app.daysLeft(for: conversation)) days")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .tint(.primary)
                }
                .onDelete { offsets in
                    for index in offsets { app.delete(past[index]) }
                }
            }
        }
    }

    private var personaSection: some View {
        Section("Persona") {
            @Bindable var app = app
            Picker("Persona", selection: $app.persona) {
                ForEach(Persona.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Text(app.persona.summary).font(.caption).foregroundStyle(.secondary)
            Button("Try: \(app.persona.suggestedPrompt)") {
                app.newConversation()
                app.send(app.persona.suggestedPrompt)
            }
            .font(.caption)
            .disabled(app.isGenerating || app.store.installedModel(for: app.selectedEntry) == nil)
        }
    }

    private var benchmarkSection: some View {
        Section("Benchmark") {
            if let progress = app.benchmarkProgress {
                HStack {
                    ProgressView()
                    Text(progress)
                    Spacer()
                    Button("Stop") { app.stopBenchmark() }
                }
            } else {
                HStack {
                    Button("Quick") { app.runBenchmark(.quick) }
                    Button("Sustained 2 min") { app.runBenchmark(.sustained(minutes: 2)) }
                }
                .buttonStyle(.bordered)
                .disabled(app.store.installedModel(for: app.selectedEntry) == nil)
            }
            if let report = app.lastBenchmark {
                Text(report.note).font(.caption)
                if let first = report.samples.first {
                    Text(String(format: "TTFT %.2fs, %.1f tok/s, peak %@", first.timeToFirstToken, first.tokensPerSecond, gb(first.mlxPeakBytes)))
                        .font(.caption)
                }
                if let last = report.sustained.last {
                    Text(String(format: "Last window %.1f tok/s, thermal %@", last.tokensPerSecond, last.thermalState))
                        .font(.caption)
                }
                Text("Saved to Files > Lantern > Benchmarks").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var chatSection: some View {
        Section(app.current.title) {
            ForEach(app.current.messages) { message in
                MessageRow(message: message)
            }
        }
    }

    private var composer: some View {
        HStack {
            TextField("Say something", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .focused($composing)
                .submitLabel(.send)
            if app.isGenerating {
                Button("Stop") { app.stop() }
            } else {
                Button("Send") { send() }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .background(.bar)
    }

    private func send() {
        app.send(draft)
        draft = ""
    }

    private func gb(_ bytes: Int64) -> String {
        String(format: "%.2f GB", Double(bytes) / Double(1 << 30))
    }
}

/// One message. The row for the reply being written reads the streaming text,
/// so it is the only row that redraws while tokens arrive.
private struct MessageRow: View {
    @Environment(AppState.self) private var app
    let message: ChatMessage

    var body: some View {
        let streaming = app.streamingMessageId == message.id
        let text = streaming ? (app.streamingText ?? "") : message.text
        VStack(alignment: .leading, spacing: 4) {
            Text(message.role.rawValue).font(.caption).foregroundStyle(.secondary)
            if text.isEmpty {
                Text("…").foregroundStyle(.secondary)
            } else {
                Text(MarkdownLite.attributed(text))
                    .textSelection(.enabled)
            }
            if let stats = message.stats {
                Text(String(format: "%.1f tok/s, %d tokens, first token %.2fs",
                            stats.tokensPerSecond, stats.generatedTokens, stats.timeToFirstToken))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// The instrument readout. Its own view so the five-times-a-second update
/// touches this section and nothing else.
private struct LiveSection: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if let live = app.live {
            Section("Live") {
                LabeledContent("Tokens", value: "\(live.tokens)")
                LabeledContent("Rate", value: String(format: "%.1f tok/s", live.tokensPerSecond))
                LabeledContent("MLX active", value: gb(live.memory.mlxActive))
                LabeledContent("MLX peak", value: gb(live.memory.mlxPeak))
                LabeledContent("App may still use", value: gb(live.memory.available))
                LabeledContent("Thermal", value: BenchmarkRunner.name(live.memory.thermalState))
            }
        }
    }

    private func gb(_ bytes: Int64) -> String {
        String(format: "%.2f GB", Double(bytes) / Double(1 << 30))
    }
}

private struct ModelRow: View {
    @Environment(AppState.self) private var app
    let entry: ModelEntry

    var body: some View {
        let verdict = app.verdict(for: entry)
        let status = app.store.status(for: entry)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.displayName).bold()
                Spacer()
                light(for: verdict)
            }
            Text(entry.id).font(.caption).foregroundStyle(.secondary)
            switch verdict {
            case .go: EmptyView()
            case .caution(let why): Text(why).font(.caption).foregroundStyle(.orange)
            case .no(let why): Text(why).font(.caption).foregroundStyle(.red)
            }
            statusView(status)
            HStack {
                switch status {
                case .installed:
                    Button(app.selectedEntry == entry ? "Selected" : "Use") { app.select(entry) }
                        .disabled(app.selectedEntry == entry)
                    Button("Delete", role: .destructive) { app.removeModel(entry) }
                case .notInstalled, .failed:
                    Button("Download") { app.store.install(entry) }
                        .disabled(!verdict.allowsDownload)
                default:
                    Button("Cancel") { app.store.cancel(entry) }
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func light(for verdict: Verdict) -> some View {
        switch verdict {
        case .go: Circle().fill(.green).frame(width: 12, height: 12)
        case .caution: Circle().fill(.orange).frame(width: 12, height: 12)
        case .no: Circle().fill(.red).frame(width: 12, height: 12)
        }
    }

    @ViewBuilder
    private func statusView(_ status: ModelStore.Status) -> some View {
        switch status {
        case .notInstalled:
            Text("Not downloaded").font(.caption)
        case .fetchingManifest:
            Text("Checking files…").font(.caption)
        case .downloading(let written, let total, let file):
            ProgressView(value: Double(written), total: Double(max(total, 1))) {
                Text(file).font(.caption2)
            }
        case .waitingForNetwork(let file):
            Text("Waiting for Wi-Fi to fetch \(file)…").font(.caption).foregroundStyle(.orange)
        case .verifying(let file):
            Text("Verifying \(file)…").font(.caption)
        case .installed(let model):
            Text(String(format: "Installed, %.2f GB", Double(model.totalBytes) / Double(1 << 30))).font(.caption)
        case .failed(let why):
            Text(why).font(.caption).foregroundStyle(.red)
        }
    }
}
