import Foundation
import Testing
@testable import Lantern

struct DeviceCapabilityTests {
    let gib: Int64 = 1 << 30

    @Test func tiersFollowRealPhoneReadings() {
        #expect(DeviceCapability.tier(forPhysicalMemory: Int64(2.8 * Double(gib))) == .unsupported)
        #expect(DeviceCapability.tier(forPhysicalMemory: Int64(3.7 * Double(gib))) == .compact)
        #expect(DeviceCapability.tier(forPhysicalMemory: Int64(5.6 * Double(gib))) == .standard)
        #expect(DeviceCapability.tier(forPhysicalMemory: Int64(7.5 * Double(gib))) == .pro)
        #expect(DeviceCapability.tier(forPhysicalMemory: 12 * gib) == .pro)
    }

    private func report(physical: Double, available: Double, disk: Double = 64, metal: Bool = true, simulator: Bool = false) -> DeviceReport {
        let physicalBytes = Int64(physical * Double(gib))
        return DeviceReport(
            physicalMemory: physicalBytes,
            availableMemory: Int64(available * Double(gib)),
            freeDisk: Int64(disk * Double(gib)),
            hasMetal: metal,
            isSimulator: simulator,
            tier: DeviceCapability.tier(forPhysicalMemory: physicalBytes),
            thermalState: .nominal,
            gpuName: "test", gpuFamily: "test")
    }

    @Test func fourGigabytePhoneRunsOneBOnly() {
        let phone = report(physical: 3.7, available: 2.2)
        #expect(DeviceCapability.verdict(for: ModelCatalog.llama3_2_1B, report: phone) == .go)
        #expect(DeviceCapability.verdict(for: ModelCatalog.qwen2_5_1_5B, report: phone) == .go)
        guard case .no = DeviceCapability.verdict(for: ModelCatalog.llama3_2_3B, report: phone) else {
            Issue.record("3B must be refused on 4 GB"); return
        }
    }

    @Test func sixGigabytePhoneGetsThreeBWithAWarning() {
        let phone = report(physical: 5.6, available: 4.2)
        #expect(DeviceCapability.verdict(for: ModelCatalog.llama3_2_1B, report: phone) == .go)
        let verdict = DeviceCapability.verdict(for: ModelCatalog.llama3_2_3B, report: phone)
        guard case .caution = verdict else { Issue.record("expected .caution, got \(verdict)"); return }
        #expect(verdict.allowsDownload)
    }

    @Test func sixGigabytePhoneNeverSeesEightBOrPhi() {
        let phone = report(physical: 5.6, available: 5.0)
        for entry in [ModelCatalog.llama3_1_8B, ModelCatalog.phi3_5Mini] {
            guard case .no = DeviceCapability.verdict(for: entry, report: phone) else {
                Issue.record("\(entry.id) must be refused on 6 GB"); return
            }
        }
        #expect(!ModelCatalog.entries(for: .standard).contains(ModelCatalog.llama3_1_8B))
    }

    @Test func eightGigabytePhoneRunsThreeBCleanAndTheHeavyOnesWithAWarning() {
        let phone = report(physical: 7.5, available: 6.0)
        #expect(DeviceCapability.verdict(for: ModelCatalog.llama3_2_3B, report: phone) == .go)
        for entry in [ModelCatalog.llama3_1_8B, ModelCatalog.phi3_5Mini] {
            let verdict = DeviceCapability.verdict(for: entry, report: phone)
            guard case .caution = verdict else { Issue.record("\(entry.id) should always warn, got \(verdict)"); return }
            #expect(verdict.allowsDownload)
        }
    }

    @Test func lowAvailableMemoryIsCautionNotRefusal() {
        let verdict = DeviceCapability.verdict(for: ModelCatalog.llama3_2_3B, report: report(physical: 7.5, available: 1.0))
        guard case .caution(let why) = verdict else { Issue.record("expected .caution, got \(verdict)"); return }
        #expect(why.contains("short right now"))
        #expect(verdict.allowsDownload)
    }

    @Test func fullDiskIsCaution() {
        let verdict = DeviceCapability.verdict(for: ModelCatalog.llama3_2_3B, report: report(physical: 7.5, available: 5.0, disk: 1.0))
        guard case .caution(let why) = verdict else { Issue.record("expected .caution, got \(verdict)"); return }
        #expect(why.contains("disk"))
    }

    @Test func simulatorAndNoMetalAreRefused() {
        guard case .no = DeviceCapability.verdict(for: ModelCatalog.llama3_2_1B, report: report(physical: 7.5, available: 5.0, simulator: true)) else {
            Issue.record("simulator should be refused"); return
        }
        guard case .no = DeviceCapability.verdict(for: ModelCatalog.llama3_2_1B, report: report(physical: 7.5, available: 5.0, metal: false)) else {
            Issue.record("no metal should be refused"); return
        }
    }

    @Test func kvCacheMathMatchesTheArchitectures() {
        // Llama 3.2 3B: 28 layers, 8 KV heads, head dim 128, K and V, fp16.
        #expect(ModelCatalog.llama3_2_3B.kvBytesPerToken == 114_688)
        // Phi 3.5 mini has no GQA, so its cache is 3.4x Llama 3B per token.
        #expect(ModelCatalog.phi3_5Mini.kvBytesPerToken == 393_216)
        let phiContext = DeviceCapability.kvCacheBudgetBytes(for: ModelCatalog.phi3_5Mini, tier: .pro)
        #expect(phiContext == 3 * gib, "8192 tokens of Phi context is exactly 3 GiB; that is why it is pro-only and warned")
    }

    @Test func estimatesStayUnderTheJetsamLineOnEveryAllowedTier() {
        // With the increased memory limit an 8 GB phone lets a foreground app use
        // roughly 6 GB, a 6 GB phone roughly 4.2 GB, a 4 GB phone roughly 2.5 GB.
        let ceilings: [DeviceTier: Double] = [.compact: 2.5, .standard: 4.2, .pro: 6.0]
        for entry in ModelCatalog.all {
            for (tier, ceiling) in ceilings where entry.requiredTier <= tier {
                let peak = Double(DeviceCapability.estimatedPeakBytes(for: entry, tier: tier)) / Double(gib)
                #expect(peak <= ceiling, "\(entry.id) on \(tier): \(peak) GiB estimated, ceiling \(ceiling)")
            }
        }
    }
}
