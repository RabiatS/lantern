import Foundation
import Testing
@testable import Lantern

struct BenchmarkRunnerTests {
    @Test func csvHasOneHeaderPerSectionAndRoundsSensibly() {
        let report = BenchmarkReport(
            backend: "lantern",
            modelId: "mlx-community/Llama-3.2-1B-Instruct-4bit",
            deviceModel: "iPhone17,1",
            systemVersion: "26.5",
            tier: "pro (8 GB+)",
            physicalMemory: 8_000_000_000,
            availableAtStart: 6_000_000_000,
            startedAt: Date(timeIntervalSince1970: 0),
            loadSeconds: 1.5,
            samples: [BenchmarkSample(index: 0, prompt: "p", promptTokens: 12, generatedTokens: 100, timeToFirstToken: 0.21, promptSeconds: 0.15, tokensPerSecond: 41.2, mlxPeakBytes: 900 * 1024 * 1024, availableAfterBytes: 5 * 1024 * 1024 * 1024, thermalState: "nominal")],
            sustained: [SustainedWindow(secondsFromStart: 10, tokensInWindow: 400, tokensPerSecond: 40, thermalState: "fair", mlxActiveBytes: 800 * 1024 * 1024, availableBytes: 5 * 1024 * 1024 * 1024)],
            note: "test")
        let csv = BenchmarkRunner.csv(report)
        let lines = csv.split(separator: "\n")
        #expect(lines[0].hasPrefix("# lantern mlx-community/Llama-3.2-1B-Instruct-4bit on iPhone17,1"))
        #expect(lines[1] == "index,prompt_tokens,generated_tokens,ttft_s,prefill_s,tok_per_s,mlx_peak_mb,available_after_mb,thermal")
        #expect(lines[2] == "0,12,100,0.210,0.150,41.200,900,5120,nominal")
        #expect(lines[3] == "seconds,tokens_in_window,tok_per_s,thermal,mlx_active_mb,available_mb")
        #expect(lines[4] == "10.000,400,40.000,fair,800,5120")
    }

    @Test func thermalNamesAreStable() {
        #expect(BenchmarkRunner.name(.nominal) == "nominal")
        #expect(BenchmarkRunner.name(.critical) == "critical")
    }
}
