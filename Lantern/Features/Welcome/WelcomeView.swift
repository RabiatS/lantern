import SwiftUI

/// First run, or any time no model is on the phone: the green light, a choice,
/// and a download while there is still Wi-Fi. The chat opens once a model is in.
struct WelcomeView: View {
    @Environment(AppState.self) private var app
    @State private var chosen: ModelEntry?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: Theme.Space.xl) {
                        header
                        phoneCard
                        modelList
                        footer
                        NavigationLink("How Lantern works, in plain words") { TransparencyView() }
                            .font(.subheadline)
                            .tint(Theme.accent)
                    }
                    .padding(Theme.Space.l)
                }
            }
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
        }
        .onAppear { if chosen == nil { chosen = app.offeredEntries.first { app.verdict(for: $0) == .go } ?? app.offeredEntries.first } }
    }

    private var header: some View {
        VStack(spacing: Theme.Space.m) {
            LanternMark(size: 96).padding(.top, Theme.Space.xl)
            Text("Lantern")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(Theme.ink)
            Text("A light you carry. Works with no signal, keeps everything on this phone.")
                .font(.body)
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
        }
    }

    private var phoneCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Label("This iPhone", systemImage: "iphone")
                    .font(Theme.heading(.headline))
                    .foregroundStyle(Theme.ink)
                Text(phoneSummary)
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
            }
        }
    }

    private var phoneSummary: String {
        let memory = app.device.physicalMemory.byteText
        switch app.device.tier {
        case .unsupported: return "\(memory) of memory. Nothing in the catalog fits with room to spare."
        case .compact: return "\(memory) of memory. Runs the 1B class comfortably."
        case .standard: return "\(memory) of memory. Runs the 1B class comfortably, 3B with a warning."
        case .pro: return "\(memory) of memory. Runs every model here; the largest with a warning."
        }
    }

    private var modelList: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Pick a model to carry")
                .font(Theme.heading(.headline))
                .foregroundStyle(Theme.ink)
            ForEach(app.offeredEntries) { entry in
                ModelChoiceRow(entry: entry, verdict: app.verdict(for: entry), selected: chosen == entry) {
                    chosen = entry
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: Theme.Space.m) {
            if let chosen {
                let status = app.store.status(for: chosen)
                switch status {
                case .installed:
                    Button {
                        app.select(chosen)
                        app.finishWelcome()
                    } label: {
                        Text("Start").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .controlSize(.large)
                case .notInstalled, .failed:
                    Button {
                        app.select(chosen)
                        app.store.install(chosen)
                    } label: {
                        Text("Download \(chosen.approximateBytes.byteText)").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .controlSize(.large)
                    .disabled(!app.verdict(for: chosen).allowsDownload)
                    if case .failed(let why) = status {
                        Text(why).font(.caption).foregroundStyle(Theme.danger)
                    }
                default:
                    DownloadProgress(entry: chosen)
                }
            }
            Text(app.store.wifiOnly ? "Downloads on Wi-Fi only. After that, no network is ever needed." : "Downloads on any connection. After that, no network is ever needed.")
                .font(.caption)
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
            if app.appleStatus.isAvailable {
                Button {
                    app.startWithApple()
                } label: {
                    Text("Or start now with Apple Intelligence, no download").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(Theme.accent)
                .controlSize(.large)
                Text("Apple's built-in model is already on this phone. You can download a Lantern model later and compare them.")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

private struct ModelChoiceRow: View {
    let entry: ModelEntry
    let verdict: Verdict
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(spacing: Theme.Space.m) {
                StatusLight(verdict: verdict)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                    Text("\(entry.approximateBytes.byteText) · \(entry.family)")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                    if case .caution(let why) = verdict {
                        Text(why).font(.caption2).foregroundStyle(Theme.warn)
                    }
                    if case .no(let why) = verdict {
                        Text(why).font(.caption2).foregroundStyle(Theme.danger)
                    }
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Theme.accent : Theme.muted)
            }
            .padding(Theme.Space.l)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .disabled(!verdict.allowsDownload)
    }
}

/// Progress for one model's download, shared by welcome and settings.
struct DownloadProgress: View {
    @Environment(AppState.self) private var app
    let entry: ModelEntry

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            switch app.store.status(for: entry) {
            case .fetchingManifest:
                Label("Checking files…", systemImage: "arrow.triangle.2.circlepath")
            case .downloading(let written, let total, _):
                ProgressView(value: Double(written), total: Double(max(total, 1)))
                    .tint(Theme.accent)
                Text("\(written.byteText) of \(total.byteText)")
                    .font(Theme.readout(.caption))
            case .waitingForNetwork:
                Label("Waiting for Wi-Fi…", systemImage: "wifi.slash")
                    .foregroundStyle(Theme.warn)
            case .verifying:
                Label("Verifying…", systemImage: "checkmark.shield")
            default:
                EmptyView()
            }
            Button("Cancel", role: .cancel) { app.store.cancel(entry) }
                .font(.caption)
        }
        .font(.subheadline)
        .foregroundStyle(Theme.muted)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
