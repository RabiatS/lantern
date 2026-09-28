import Foundation
import Testing
@testable import Lantern

struct PictureModelTests {
    @Test func manifestIsTheHalfPrecisionTurboUnderTheBasePresetNames() {
        let weights = PictureModel.files.filter { $0.sha256 != nil }
        #expect(weights.count == 3)
        for file in weights {
            #expect(file.source.contains(".fp16."))
            #expect(!file.target.contains(".fp16."))
            #expect(file.sha256?.count == 64)
        }
        #expect(PictureModel.totalBytes > 2_500_000_000 && PictureModel.totalBytes < 2_700_000_000)
        #expect(Set(PictureModel.files.map(\.target)).count == PictureModel.files.count)
    }

    @Test func verdictsByTier() {
        func report(_ gib: Double, available: Double) -> DeviceReport {
            let bytes = Int64(gib * Double(1 << 30))
            return DeviceReport(physicalMemory: bytes, availableMemory: Int64(available * Double(1 << 30)), freeDisk: 64 << 30,
                                hasMetal: true, isSimulator: false, tier: DeviceCapability.tier(forPhysicalMemory: bytes),
                                thermalState: .nominal, gpuName: "t", gpuFamily: "t")
        }
        guard case .no = PictureModel.verdict(report: report(3.7, available: 2.5)) else { Issue.record("4 GB must refuse"); return }
        guard case .caution = PictureModel.verdict(report: report(5.6, available: 4.0)) else { Issue.record("6 GB should warn"); return }
        #expect(PictureModel.verdict(report: report(7.5, available: 6.0)) == .go)
    }
}
