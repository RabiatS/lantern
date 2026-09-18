import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// One prompt's numbers.
nonisolated struct BenchmarkSample: Codable, Sendable {
    let index: Int
    let prompt: String
    let promptTokens: Int
    let generatedTokens: Int
    let timeToFirstToken: Double
    let promptSeconds: Double
    let tokensPerSecond: Double
    let mlxPeakBytes: Int64
    let availableAfterBytes: Int64
    let thermalState: String
}

/// One ten-second window of the sustained run. The shape of this series over two
/// minutes is the thermal throttling curve.
nonisolated struct SustainedWindow: Codable, Sendable {
    let secondsFromStart: Double
    let tokensInWindow: Int
    let tokensPerSecond: Double
    let thermalState: String
    let mlxActiveBytes: Int64
    let availableBytes: Int64
}

nonisolated struct BenchmarkReport: Codable, Sendable {
    /// "lantern" or "apple". Old files without it are the Lantern model.
    var backend: String?
    let modelId: String
    let deviceModel: String
    let systemVersion: String
    let tier: String
    let physicalMemory: Int64
    let availableAtStart: Int64
    let startedAt: Date
    var loadSeconds: Double
    var samples: [BenchmarkSample]
    var sustained: [SustainedWindow]
    var note: String
}

nonisolated enum BenchmarkMode: Sendable, Equatable {
    /// Five short prompts from a cold cache each: time to first token and decode rate.
    case quick
    /// Keep generating for the given time, sampling every ten seconds.
    case sustained(minutes: Int)
}

/// Runs the engine like an instrument instead of a chat and writes what it saw
/// to Documents/Benchmarks as JSON and CSV, where the Files app can reach them.
nonisolated struct BenchmarkRunner: Sendable {
    static let quickPrompts = [
        "Explain in three sentences why the sky is blue.",
        "Write a limerick about a resistor.",
        "List five uses for a 555 timer, one line each.",
        "What is Ohm's law? Give one worked example.",
        "Summarise the plot of Hamlet in one paragraph.",
    ]

    static let sustainedPrompt =
        "Write a very long, detailed story about an engineer who builds a radio from scratch. Keep going for as long as you can."

    static var directory: URL {
        URL.documentsDirectory.appending(path: "Benchmarks", directoryHint: .isDirectory)
    }

    let engine: any GenerationBackend
    let backend: BackendKind

    func run(
        mode: BenchmarkMode,
        modelId: String,
        tier: DeviceTier,
        loadSeconds: Double,
        progress: @Sendable @escaping (String) -> Void
    ) async throws -> BenchmarkReport {
        let device = DeviceCapability.current()
        var report = BenchmarkReport(
            backend: backend.rawValue,
            modelId: modelId,
            deviceModel: await Self.deviceModel(),
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            tier: tier.description,
            physicalMemory: device.physicalMemory,
            availableAtStart: device.availableMemory,
            startedAt: Date(),
            loadSeconds: loadSeconds,
            samples: [],
            sustained: [],
            note: "")

        switch mode {
        case .quick:
            for (index, prompt) in Self.quickPrompts.enumerated() {
                try Task.checkCancellation()
                progress("Prompt \(index + 1) of \(Self.quickPrompts.count)")
                InferenceEngine.resetPeakMemory()
                var stats: GenerationStats?
                for try await event in await engine.generateOnce(prompt, maxTokens: 200) {
                    if case .finished(let done) = event { stats = done }
                }
                let after = InferenceEngine.memorySnapshot()
                guard let stats else { continue }
                report.samples.append(BenchmarkSample(
                    index: index,
                    prompt: prompt,
                    promptTokens: stats.promptTokens,
                    generatedTokens: stats.generatedTokens,
                    timeToFirstToken: stats.timeToFirstToken,
                    promptSeconds: stats.promptSeconds,
                    tokensPerSecond: stats.tokensPerSecond,
                    mlxPeakBytes: after.mlxPeak,
                    availableAfterBytes: after.available,
                    thermalState: Self.name(after.thermalState)))
            }
            report.note = "quick: 5 prompts, 200 tokens max, fresh cache each"

        case .sustained(let minutes):
            let deadline = ContinuousClock.now + .seconds(minutes * 60)
            let started = ContinuousClock.now
            var windowStart = started
            var windowTokens = 0
            var totalTokens = 0
            var runs = 0
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                runs += 1
                progress("Sustained run \(runs), \(Int(Self.seconds(ContinuousClock.now - started)))s")
                for try await event in await engine.generateOnce(Self.sustainedPrompt, maxTokens: 2048) {
                    if case .token = event {
                        windowTokens += 1
                        totalTokens += 1
                    }
                    let now = ContinuousClock.now
                    if now - windowStart >= .seconds(10) {
                        let snapshot = InferenceEngine.memorySnapshot()
                        let length = Self.seconds(now - windowStart)
                        report.sustained.append(SustainedWindow(
                            secondsFromStart: Self.seconds(now - started),
                            tokensInWindow: windowTokens,
                            tokensPerSecond: Double(windowTokens) / length,
                            thermalState: Self.name(snapshot.thermalState),
                            mlxActiveBytes: snapshot.mlxActive,
                            availableBytes: snapshot.available))
                        windowStart = now
                        windowTokens = 0
                    }
                    if now >= deadline { break }
                }
            }
            report.note = "sustained: \(minutes) min, \(runs) runs, \(totalTokens) tokens"
        }

        try Self.write(report)
        return report
    }

    // MARK: Output

    static func write(_ report: BenchmarkReport) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: report.startedAt)
            .replacingOccurrences(of: ":", with: "-")
        let slug = (report.backend ?? "lantern") + "-" + (report.modelId.split(separator: "/").last.map(String.init) ?? report.modelId)
        let base = directory.appending(path: "\(stamp)-\(slug)")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: base.appendingPathExtension("json"), options: .atomic)
        try csv(report).write(to: base.appendingPathExtension("csv"), atomically: true, encoding: .utf8)
    }

    static func csv(_ report: BenchmarkReport) -> String {
        var lines: [String] = []
        lines.append("# \(report.backend ?? "lantern") \(report.modelId) on \(report.deviceModel) \(report.systemVersion), \(report.tier), load \(String(format: "%.2f", report.loadSeconds))s, \(report.note)")
        if !report.samples.isEmpty {
            lines.append("index,prompt_tokens,generated_tokens,ttft_s,prefill_s,tok_per_s,mlx_peak_mb,available_after_mb,thermal")
            for s in report.samples {
                lines.append("\(s.index),\(s.promptTokens),\(s.generatedTokens),\(f(s.timeToFirstToken)),\(f(s.promptSeconds)),\(f(s.tokensPerSecond)),\(mb(s.mlxPeakBytes)),\(mb(s.availableAfterBytes)),\(s.thermalState)")
            }
        }
        if !report.sustained.isEmpty {
            lines.append("seconds,tokens_in_window,tok_per_s,thermal,mlx_active_mb,available_mb")
            for w in report.sustained {
                lines.append("\(f(w.secondsFromStart)),\(w.tokensInWindow),\(f(w.tokensPerSecond)),\(w.thermalState),\(mb(w.mlxActiveBytes)),\(mb(w.availableBytes))")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func f(_ value: Double) -> String { String(format: "%.3f", value) }
    private static func mb(_ bytes: Int64) -> String { String(bytes / (1024 * 1024)) }

    static func name(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    /// The hardware identifier, like "iPhone17,1", which maps to a marketing name.
    @MainActor
    private static func deviceModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(String(UnicodeScalar(UInt8(value))))
        }
        return identifier.isEmpty ? "unknown" : identifier
    }
}
