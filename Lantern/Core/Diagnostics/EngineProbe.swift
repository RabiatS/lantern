#if DEBUG
import Foundation
import ImageIO
#if os(macOS)
import AppKit
#endif

/// A headless check of one model turn, for chasing a bad reply without the UI.
///
/// `--ask=<question>` loads `--model=<id>` (or the selected model), optionally
/// with `--image=<path>` and `--system=<instructions|none>`, prints each token
/// and the stats to stderr, and quits. `--follow=<question>` adds a second turn
/// in the same conversation. The path must be readable by the sandboxed app,
/// such as a file in its own container.
enum EngineProbe {
    @MainActor
    private static func quit() {
        #if os(macOS)
        NSApp.terminate(nil)
        #else
        exit(0)
        #endif
    }

    static func runIfRequested(app: AppState) {
        if let repo = LaunchArguments.value(for: "add-and-ask") {
            // Add a custom model, download it, ask one question, then remove it.
            Task { @MainActor in
                func log(_ text: String) { FileHandle.standardError.write((text + "\n").data(using: .utf8)!) }
                do {
                    let entry = try await CustomModelInspector.inspect(repo)
                    try app.addCustomModel(entry)
                    log("probe: added \(entry.id), in catalog: \(ModelCatalog.entry(id: entry.id) != nil)")
                    app.store.install(entry)
                    while app.store.status(for: entry).isBusy || app.store.status(for: entry) == .notInstalled {
                        try await Task.sleep(for: .seconds(1))
                        if case .failed = app.store.status(for: entry) { break }
                    }
                    log("probe: store status \(app.store.status(for: entry))")
                    app.select(entry)
                    app.newConversation()
                    app.send(LaunchArguments.value(for: "ask") ?? "Say hello in one short sentence.")
                    try await Task.sleep(for: .milliseconds(200))
                    while app.isGenerating { try await Task.sleep(for: .milliseconds(100)) }
                    log("probe: < \(app.current.messages.last?.text.debugDescription ?? "nil") error=\(app.lastError ?? "none")")
                    app.delete(app.current)
                    app.removeCustomModel(entry)
                    try await Task.sleep(for: .seconds(2))
                    log("probe: removed, in catalog: \(ModelCatalog.entry(id: entry.id) != nil), files: \(FileManager.default.fileExists(atPath: app.store.directory(for: entry).path))")
                } catch {
                    log("probe: add-and-ask error \(error.localizedDescription)")
                }
                quit()
            }
            return
        }
        if let repos = LaunchArguments.value(for: "inspect") {
            Task { @MainActor in
                func log(_ text: String) { FileHandle.standardError.write((text + "\n").data(using: .utf8)!) }
                for repo in repos.split(separator: ",").map(String.init) {
                    do {
                        let entry = try await CustomModelInspector.inspect(repo)
                        log("probe: inspect \(repo) -> \(entry.kind) \(entry.family) \(entry.parameterBillions)B \(entry.approximateBytes.byteText) kv=\(entry.kvBytesPerToken) tier=\(entry.requiredTier) eos=\(entry.extraEOSTokens) verdict=\(CustomModelInspector.fits(entry, on: app.device))")
                    } catch {
                        log("probe: inspect \(repo) -> refused: \(error.localizedDescription)")
                    }
                }
                quit()
            }
            return
        }
        #if os(macOS)
        if LaunchArguments.has("metrics") {
            Task { @MainActor in
                func log(_ text: String) { FileHandle.standardError.write((text + "\n").data(using: .utf8)!) }
                let metrics = MacMetrics()
                metrics.start()
                try? await Task.sleep(for: .seconds(3.5))
                for sample in metrics.samples { log("probe: metrics \(sample)") }
                quit()
            }
            return
        }
        #endif
        if let backend = LaunchArguments.value(for: "bench") {
            Task { @MainActor in
                await bench(app: app, backend: backend)
                quit()
            }
            return
        }
        guard let question = LaunchArguments.value(for: "ask") else { return }
        Task { @MainActor in
            await run(app: app, question: question)
            #if os(macOS)
            NSApp.terminate(nil)
            #else
            exit(0)
            #endif
        }
    }

    /// `--bench=lantern|apple`: the app's quick benchmark, five prompts from a
    /// cold cache, printed per prompt.
    @MainActor
    private static func bench(app: AppState, backend: String) async {
        func log(_ text: String) { FileHandle.standardError.write((text + "\n").data(using: .utf8)!) }
        log("probe: apple status \(app.appleStatus)")
        if backend == "apple" {
            app.backend = .apple
        } else {
            app.backend = .lantern
            if let entry = LaunchArguments.value(for: "model").flatMap(ModelCatalog.entry(id:)) { app.select(entry) }
        }
        try? await Task.sleep(for: .milliseconds(300))
        app.runBenchmark(.quick)
        try? await Task.sleep(for: .milliseconds(100))
        while app.benchmarkProgress != nil { try? await Task.sleep(for: .milliseconds(200)) }
        guard let report = app.lastBenchmark else { log("probe: no report, error=\(app.lastError ?? "none")"); return }
        log("probe: bench \(report.backend ?? "?") \(report.modelId) load=\(String(format: "%.2f", report.loadSeconds))s")
        for sample in report.samples {
            log(String(format: "probe: bench #%d first=%.2fs rate=%.1f tok/s tokens=%d prompt=%d peak=%.2f GB",
                       sample.index + 1, sample.timeToFirstToken, sample.tokensPerSecond, sample.generatedTokens,
                       sample.promptTokens, Double(sample.mlxPeakBytes) / 1e9))
        }
    }

    /// The same turn through AppState.send, the path the chat uses, with a
    /// different model loaded first so the switch to this one happens as it
    /// does when a photo is attached. The probe chat is deleted afterwards.
    @MainActor
    private static func throughApp(app: AppState, entry: ModelEntry, question: String, image: URL?, log: (String) -> Void) async {
        if let first = LaunchArguments.value(for: "first").flatMap(ModelCatalog.entry(id:)) {
            app.select(first)
            try? await app.ensureLoaded()
            log("probe: preloaded \(first.id)")
        }
        // A throwaway profile, only when none exists, wiped afterwards.
        let testProfile = app.profile.isEmpty && (LaunchArguments.value(for: "with-name") != nil || LaunchArguments.value(for: "with-memory") != nil)
        if testProfile {
            app.profile.name = LaunchArguments.value(for: "with-name") ?? ""
            if let memory = LaunchArguments.value(for: "with-memory") { app.profile.remember(memory) }
            log("probe: profile block \(app.profile.promptBlock?.debugDescription ?? "none")")
        }
        defer { if testProfile { app.profile.eraseAll() } }
        app.newConversation()
        var turns: [(String, URL?)] = [(question, image)]
        if let follow = LaunchArguments.value(for: "follow") { turns.append((follow, nil)) }
        if let follow = LaunchArguments.value(for: "follow2") { turns.append((follow, nil)) }
        for (prompt, picture) in turns {
            if let picture, let source = CGImageSourceCreateWithURL(picture as CFURL, nil) {
                app.pendingImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
            } else if picture == nil, app.selectedEntry != entry {
                app.select(entry)
            }
            log("probe: > \(prompt)")
            app.send(prompt)
            while app.isGenerating { try? await Task.sleep(for: .milliseconds(100)) }
            let reply = app.current.messages.last
            log("probe: < \(reply?.text.debugDescription ?? "nil") stats=\(reply?.stats.map { "\($0.generatedTokens) tokens" } ?? "none") error=\(app.lastError ?? "none")")
        }
        app.delete(app.current)
    }

    @MainActor
    private static func run(app: AppState, question: String) async {
        func log(_ text: String) { FileHandle.standardError.write((text + "\n").data(using: .utf8)!) }
        let entry = LaunchArguments.value(for: "model").flatMap(ModelCatalog.entry(id:)) ?? app.selectedEntry
        let system: String? = switch LaunchArguments.value(for: "system") {
        case "none": nil
        case let text?: text
        case nil: app.persona.instructions
        }
        let image = LaunchArguments.value(for: "image").map { URL(fileURLWithPath: $0) }
        log("probe: model=\(entry.id) tier=\(app.device.tier) image=\(image?.path ?? "none")")
        if LaunchArguments.has("via-app") {
            await throughApp(app: app, entry: entry, question: question, image: image, log: log)
            return
        }
        log("probe: system=\(system ?? "(none)")")
        do {
            try await app.engine.load(entry, from: app.store.directory(for: entry), tier: app.device.tier)
            try await app.engine.beginConversation(instructions: system, history: [])
            if LaunchArguments.has("fingerprint"), let image {
                for _ in 0 ..< 3 { log("probe: pixels \(try await app.engine.debugImageFingerprint(image))") }
                return
            }
            var turns = [(question, image)]
            if let follow = LaunchArguments.value(for: "follow") { turns.append((follow, nil)) }
        if let follow = LaunchArguments.value(for: "follow2") { turns.append((follow, nil)) }
            for (prompt, picture) in turns {
                log("probe: > \(prompt)")
                var reply = ""
                for try await event in await app.engine.stream(prompt, imageURL: picture) {
                    switch event {
                    case .token(let piece): reply += piece
                    case .finished(let stats):
                        log("probe: stats prompt=\(stats.promptTokens) generated=\(stats.generatedTokens) first=\(String(format: "%.2f", stats.timeToFirstToken))s")
                    }
                }
                log("probe: < \(reply.debugDescription)")
            }
        } catch {
            log("probe: error \(error)")
        }
    }
}
#endif
