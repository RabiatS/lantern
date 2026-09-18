import SwiftUI

/// Models, the phone, the benchmark and the diagnostics. The instrument panel.
struct SettingsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDeleteAll = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        TransparencyView()
                    } label: {
                        Label("How Lantern works, in plain words", systemImage: "book.pages")
                            .foregroundStyle(Theme.ink)
                    }
                }
                .listRowBackground(Theme.surface)
                impactSection
                phoneSection
                modelsSection
                benchmarkSection
                diagnosticsSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Lantern")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .tint(Theme.accent)
        .onAppear { app.refreshDevice() }
    }

    // MARK: Impact

    private var impactSection: some View {
        Section {
            readout("Replies answered here", "\(app.impact.replies)")
            readout("Words never sent anywhere", "\(app.impact.charactersKeptOnPhone / 5)")
            readout("Energy saved, estimated", String(format: "%.1f Wh", app.impact.wattHoursSaved))
            if app.impact.wattHoursSaved >= 1 {
                readout("About the same as", String(format: "%.1f phone charges", app.impact.phoneChargesSaved))
            }
        } header: {
            Text("What staying on this phone has saved")
        } footer: {
            Text("Replies and words are counted. Energy is an estimate: a data-centre reply at about 0.3 Wh, against this phone at about 6 W for the seconds it spent writing. The assumptions are on the \"How Lantern works\" page.")
        }
        .listRowBackground(Theme.surface)
    }

    // MARK: Phone

    private var phoneSection: some View {
        Section {
            readout("Memory", app.device.physicalMemory.byteText)
            readout("App may use now", app.device.availableMemory.byteText)
            readout("Free disk", app.device.freeDisk.byteText)
            readout("Tier", "\(app.device.tier)")
            readout("Engine", engineText)
            if let context = app.context {
                readout("Context", "\(context.tokens) / \(context.limit) tokens")
            }
            LabeledContent("Ready to go offline") {
                Text(app.readyForOffline ? "Yes" : "No")
                    .foregroundStyle(app.readyForOffline ? .green : Theme.warn)
            }
        } header: {
            Text("This phone")
        } footer: {
            Text("\"App may use now\" is the ceiling iOS enforces for this app. It falls as other apps take memory.")
        }
        .listRowBackground(Theme.surface)
    }

    private var engineText: String {
        switch app.engineState {
        case .empty: "not loaded"
        case .loading: "loading"
        case .ready: "ready"
        case .generating: "generating"
        }
    }

    // MARK: Models

    private var modelsSection: some View {
        Section {
            @Bindable var store = app.store
            Toggle("Download on Wi-Fi only", isOn: $store.wifiOnly)
            ForEach(ModelCatalog.all) { entry in
                ModelRow(entry: entry)
            }
        } header: {
            Text("Models")
        } footer: {
            Text("Weights on disk: \(app.store.bytesOnDisk.byteText). Deleting a model frees its space; download it again any time on Wi-Fi.")
        }
        .listRowBackground(Theme.surface)
    }

    // MARK: Benchmark

    private var benchmarkSection: some View {
        Section {
            if let progress = app.benchmarkProgress {
                HStack {
                    ProgressView().tint(Theme.accent)
                    Text(progress)
                    Spacer()
                    Button("Stop") { app.stopBenchmark() }
                }
            } else {
                HStack {
                    Button("Quick") { app.runBenchmark(.quick) }
                    Button("Sustained, 2 min") { app.runBenchmark(.sustained(minutes: 2)) }
                }
                .buttonStyle(.bordered)
                .disabled(app.isBusy || !app.readyForOffline)
            }
            if let report = app.lastBenchmark {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(report.note).font(.caption)
                    if let first = report.samples.first {
                        Text(String(format: "%.2fs to first token · %.1f tok/s · peak %@", first.timeToFirstToken, first.tokensPerSecond, first.mlxPeakBytes.byteText))
                            .font(Theme.readout(.caption))
                    }
                    if let last = report.sustained.last {
                        Text(String(format: "Last window %.1f tok/s, thermal %@", last.tokensPerSecond, last.thermalState))
                            .font(Theme.readout(.caption))
                    }
                }
                .foregroundStyle(Theme.muted)
            }
        } header: {
            Text("Benchmark")
        } footer: {
            Text("Quick runs five prompts from a cold cache. Sustained generates for two minutes and samples the rate and thermal state every ten seconds. Results save to Files, Lantern, Benchmarks as JSON and CSV.")
        }
        .listRowBackground(Theme.surface)
    }

    // MARK: Diagnostics

    private var diagnosticsSection: some View {
        Section {
            readout("Main thread stalls", "\(app.hangs.count)")
            if app.hangs.count > 0 {
                readout("Longest", "\(app.hangs.longestMilliseconds) ms")
            }
            readout("Memory warnings", "\(app.pressure.warningCount)")
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Stalls over a quarter second are logged with what the app was doing, to Files, Lantern, Diagnostics.")
        }
        .listRowBackground(Theme.surface)
    }

    private var aboutSection: some View {
        Section {
            Button(role: .destructive) { confirmDeleteAll = true } label: {
                Label("Delete all chats", systemImage: "trash")
            }
            .disabled(app.history.isEmpty && app.current.messages.isEmpty)
            .confirmationDialog("Delete all chats?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button("Delete all", role: .destructive) { app.deleteAllConversations() }
            } message: {
                Text("Removes every chat from this phone now.")
            }
            readout("Version", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
            Link("Source on GitHub", destination: URL(string: "https://github.com/RabiatS/lantern")!)
        } header: {
            Text("About")
        } footer: {
            Text("Runs entirely on this phone with MLX. The only network use is downloading public model weights.")
        }
        .listRowBackground(Theme.surface)
    }

    private func readout(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value).font(Theme.readout(.body))
        }
    }
}

/// One model in the settings list: light, status, actions.
private struct ModelRow: View {
    @Environment(AppState.self) private var app
    let entry: ModelEntry

    var body: some View {
        let verdict = app.verdict(for: entry)
        let status = app.store.status(for: entry)
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                StatusLight(verdict: verdict)
                Text(entry.displayName).font(.body.weight(.semibold))
                if app.selectedEntry == entry, app.store.installedModel(for: entry) != nil {
                    Chip(text: "in use")
                }
                Spacer()
                Text(entry.approximateBytes.byteText)
                    .font(Theme.readout(.caption))
                    .foregroundStyle(Theme.muted)
            }
            switch verdict {
            case .go: EmptyView()
            case .caution(let why): Text(why).font(.caption).foregroundStyle(Theme.warn)
            case .no(let why): Text(why).font(.caption).foregroundStyle(Theme.danger)
            }
            switch status {
            case .installed:
                HStack {
                    if app.selectedEntry != entry {
                        Button("Use") { app.select(entry) }
                    }
                    Button("Delete", role: .destructive) { app.removeModel(entry) }
                }
                .buttonStyle(.bordered)
                .font(.subheadline)
            case .notInstalled:
                Button("Download") { app.store.install(entry) }
                    .buttonStyle(.bordered)
                    .font(.subheadline)
                    .disabled(!verdict.allowsDownload)
            case .failed(let why):
                Text(why).font(.caption).foregroundStyle(Theme.danger)
                Button("Try again") { app.store.install(entry) }
                    .buttonStyle(.bordered)
                    .font(.subheadline)
            default:
                DownloadProgress(entry: entry)
            }
        }
        .padding(.vertical, Theme.Space.xs)
    }
}
