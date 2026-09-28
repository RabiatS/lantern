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
                    NavigationLink {
                        AboutYouView()
                    } label: {
                        LabeledContent {
                            Text(app.profile.isActive ? "On" : app.profile.isEmpty ? "Not set" : "Paused")
                                .foregroundStyle(Theme.muted)
                        } label: {
                            Label("About you", systemImage: "person.crop.circle")
                                .foregroundStyle(Theme.ink)
                        }
                    }
                }
                .listRowBackground(Theme.surface)
                backendSection
                impactSection
                phoneSection
                modelsSection
                pictureSection
                benchmarkSection
                diagnosticsSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Lantern")
            #if os(iOS)
            // The Mac shows this in its own Settings window, which closes itself.
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            #endif
        }
        .tint(Theme.accent)
        .onAppear { app.refreshDevice() }
    }

    // MARK: Backend

    private var backendSection: some View {
        Section {
            @Bindable var app = app
            Picker("Answer with", selection: $app.backend) {
                ForEach(BackendKind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(!app.appleStatus.isAvailable)
            Text(app.backend.summary)
                .font(.caption)
                .foregroundStyle(Theme.muted)
            LabeledContent("Apple Intelligence") {
                Text(app.appleStatus.isAvailable ? "Available" : "Not available")
                    .foregroundStyle(app.appleStatus.isAvailable ? .green : Theme.muted)
            }
            Text(app.appleStatus.text)
                .font(.caption)
                .foregroundStyle(Theme.muted)
            comparison
        } header: {
            Text("Who answers")
        } footer: {
            Text(app.appleStatus.isAvailable
                 ? "Even when the Lantern model answers, Apple's model writes the summaries that keep long chats going, so the downloaded model keeps its memory."
                 : "The Lantern model is the only option on this device.")
        }
        .listRowBackground(Theme.surface)
    }

    @ViewBuilder
    private var comparison: some View {
        if !app.benchmarks.isEmpty {
            Grid(alignment: .leading, horizontalSpacing: Theme.Space.l, verticalSpacing: Theme.Space.xs) {
                GridRow {
                    Text("Quick benchmark").font(.caption.weight(.semibold))
                    Text("Lantern").font(.caption.weight(.semibold))
                    Text("Apple").font(.caption.weight(.semibold))
                }
                comparisonRow("To first token") { String(format: "%.2fs", $0.timeToFirstToken) }
                comparisonRow("Tokens per second") { String(format: "%.0f", $0.tokensPerSecond) }
                comparisonRow("Peak memory in app") { $0.mlxPeakBytes.byteText }
            }
            .font(Theme.readout(.caption))
            .foregroundStyle(Theme.muted)
            Text("Apple's token figures are estimated from characters; iOS does not report them. Its memory is held by the system, not the app.")
                .font(.caption2)
                .foregroundStyle(Theme.muted)
        }
    }

    private func comparisonRow(_ label: String, _ value: @escaping (BenchmarkSample) -> String) -> some View {
        GridRow {
            Text(label)
            Text(app.benchmarks[.lantern]?.samples.first.map(value) ?? "–")
            Text(app.benchmarks[.apple]?.samples.first.map(value) ?? "–")
        }
    }

    // MARK: Impact

    private var impactSection: some View {
        Section {
            readout("Replies answered here", "\(app.impact.replies)")
            readout("Words never sent anywhere", "\(app.impact.charactersKeptOnPhone / 5)")
            readout("Water saved, estimated", Self.water(app.impact.waterSavedMillilitres))
            if app.impact.glassesOfWaterSaved >= 0.1 {
                readout("About the same as", String(format: "%.1f glasses of water", app.impact.glassesOfWaterSaved))
            }
            readout("Energy saved, estimated", String(format: "%.1f Wh", app.impact.wattHoursSaved))
            if app.impact.wattHoursSaved >= 1 {
                readout("About the same as", String(format: "%.1f phone charges", app.impact.phoneChargesSaved))
            }
        } header: {
            Text("What staying on this \(Platform.device) has saved")
        } footer: {
            Text("Replies and words are counted. Water and energy are estimates: a data-centre reply uses about 0.26 mL of cooling water and 0.3 Wh, against this \(Platform.device) at about \(Int(Platform.wattsWhileGenerating)) W for the seconds it spent writing. The assumptions are on the \"How Lantern works\" page.")
        }
        .listRowBackground(Theme.surface)
    }

    /// Millilitres under a litre, litres after.
    static func water(_ millilitres: Double) -> String {
        millilitres < 1000 ? String(format: "%.0f mL", millilitres) : String(format: "%.2f L", millilitres / 1000)
    }

    // MARK: Phone

    private var phoneSection: some View {
        Section {
            readout("Hardware", app.device.hardwareModel)
            readout("Memory", app.device.physicalMemory.byteText)
            readout("App may use now", app.device.availableMemory.byteText)
            readout("Free disk", app.device.freeDisk.byteText)
            readout("Chip", app.device.gpuName.replacingOccurrences(of: " GPU", with: ""))
            readout("GPU family", app.device.gpuFamily)
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
            Text("This \(Platform.device)")
        } footer: {
            #if os(macOS)
            Text("\"App may use now\" is how much memory macOS recommends the graphics chip keep in use at once on this Mac.")
            #else
            Text("\"App may use now\" is the ceiling iOS enforces for this app. It falls as other apps take memory.")
            #endif
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
            if Platform.hasCellular {
                Toggle("Download on Wi-Fi only", isOn: $store.wifiOnly)
            }
            ForEach(ModelCatalog.builtIn + app.customModels) { entry in
                ModelRow(entry: entry)
            }
            if app.showsAdvanced {
                NavigationLink {
                    AddModelView()
                } label: {
                    Label("Add a model from Hugging Face", systemImage: "plus.circle")
                        .foregroundStyle(Theme.ink)
                }
            }
        } header: {
            Text("Models")
        } footer: {
            Text("Weights on disk: \(app.store.bytesOnDisk.byteText). Deleting a model frees its space; download it again any time on Wi-Fi.")
        }
        .listRowBackground(Theme.surface)
    }

    // MARK: Pictures

    private var pictureSection: some View {
        let verdict = PictureModel.verdict(report: app.device)
        return Section {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.s) {
                    StatusLight(verdict: verdict)
                    Text(PictureModel.displayName).font(.body.weight(.semibold))
                    Chip(text: "draws", systemImage: "paintbrush")
                    Spacer()
                    Text(PictureModel.totalBytes.byteText).font(Theme.readout(.caption)).foregroundStyle(Theme.muted)
                }
                switch verdict {
                case .go: EmptyView()
                case .caution(let why): Text(why).font(.caption).foregroundStyle(Theme.warn)
                case .no(let why): Text(why).font(.caption).foregroundStyle(Theme.danger)
                }
                switch app.pictures.status {
                case .installed:
                    HStack {
                        Text("Installed").font(.caption).foregroundStyle(Theme.muted)
                        Spacer()
                        Button("Delete", role: .destructive) { try? app.pictures.remove() }
                            .buttonStyle(.bordered).font(.subheadline)
                    }
                case .notInstalled:
                    Button("Download") { app.pictures.wifiOnly = app.store.wifiOnly; app.pictures.install() }
                        .buttonStyle(.bordered).font(.subheadline)
                        .disabled(!verdict.allowsDownload)
                case .failed(let why):
                    Text(why).font(.caption).foregroundStyle(Theme.danger)
                    Button("Try again") { app.pictures.install() }.buttonStyle(.bordered).font(.subheadline)
                case .downloading(let written, let total, _):
                    ProgressView(value: Double(written), total: Double(max(total, 1))).tint(Theme.accent)
                    HStack {
                        Text("\(written.byteText) of \(total.byteText)").font(Theme.readout(.caption)).foregroundStyle(Theme.muted)
                        Spacer()
                        Button("Cancel", role: .cancel) { app.pictures.cancel() }.font(.caption)
                    }
                case .waitingForNetwork:
                    Label("Waiting for Wi-Fi…", systemImage: "wifi.slash").font(.caption).foregroundStyle(Theme.warn)
                case .verifying:
                    Label("Verifying…", systemImage: "checkmark.shield").font(.caption).foregroundStyle(Theme.muted)
                }
            }
            .padding(.vertical, Theme.Space.xs)
        } header: {
            Text("Drawing pictures")
        } footer: {
            Text("Stability's SD-Turbo draws a 512 pixel picture in four steps on this \(Platform.device). It is the heaviest thing in the app: the chat model steps aside while it runs, and on 6 GB phones it is compressed and unloaded after each picture. Type a description, then choose \"Draw a picture from this text\" from the camera button.")
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
                Text("Runs on whichever is answering. Run it once with each to fill the comparison above.")
                    .font(.caption).foregroundStyle(Theme.muted)
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
                Text("Removes every chat from this \(Platform.device) now.")
            }
            @Bindable var app = app
            Toggle("Show advanced options", isOn: $app.showsAdvanced)
            readout("Version", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
            Link("Source on GitHub", destination: URL(string: "https://github.com/RabiatS/lantern")!)
        } header: {
            Text("About")
        } footer: {
            Text("Runs entirely on this \(Platform.device) with MLX. The only network use is downloading public model weights.")
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
                if entry.seesPhotos { Chip(text: "sees photos", systemImage: "eye") }
                if app.selectedEntry == entry, app.store.installedModel(for: entry) != nil {
                    Chip(text: "in use")
                }
                if app.customModels.contains(entry) { Chip(text: "custom", systemImage: "wrench.and.screwdriver") }
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
                    if app.customModels.contains(entry) {
                        Button("Remove from list", role: .destructive) { app.removeCustomModel(entry) }
                    }
                }
                .buttonStyle(.bordered)
                .font(.subheadline)
            case .notInstalled:
                HStack {
                    Button("Download") { app.store.install(entry) }
                        .disabled(!verdict.allowsDownload)
                    if app.customModels.contains(entry) {
                        Button("Remove from list", role: .destructive) { app.removeCustomModel(entry) }
                    }
                }
                .buttonStyle(.bordered)
                .font(.subheadline)
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
