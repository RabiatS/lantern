import Foundation
import Metal

/// The green light. Before anyone downloads a gigabyte, the app measures the
/// phone and says whether a model will run here. Every number is read live: RAM,
/// what this process may still allocate, free disk, and whether Metal is present.
nonisolated struct DeviceReport: Sendable, Equatable {
    let physicalMemory: Int64
    /// What this process can still allocate right now. This is the number jetsam
    /// enforces, and it falls as other apps take memory.
    let availableMemory: Int64
    let freeDisk: Int64
    let hasMetal: Bool
    let isSimulator: Bool
    let tier: DeviceTier
    let thermalState: ProcessInfo.ThermalState
}

/// Whether one model should be offered on this device.
nonisolated enum Verdict: Equatable, Sendable {
    /// Download and run.
    case go
    /// Allowed, with a reason to think twice: tight on memory by design, short of
    /// memory at this moment, or short of disk.
    case caution(String)
    /// Never on this device.
    case no(String)

    var allowsDownload: Bool {
        if case .no = self { return false }
        return true
    }
}

nonisolated enum DeviceCapability {
    static let gib: Int64 = 1 << 30

    /// Phones report a little under their marketing figure, so the cut lines sit
    /// between the tiers rather than on them. A 4 GB phone reads about 3.7 GiB,
    /// a 6 GB phone about 5.6 GiB, an 8 GB phone about 7.5 GiB.
    static func tier(forPhysicalMemory bytes: Int64) -> DeviceTier {
        if bytes >= 7 * gib { return .pro }
        if bytes >= 5 * gib { return .standard }
        if bytes >= Int64(3.5 * Double(gib)) { return .compact }
        return .unsupported
    }

    /// Fixed allowance for MLX scratch buffers, the buffer pool, the tokenizer,
    /// SwiftUI and the app's own heap. Measured, not guessed: see ARCHITECTURE.md.
    static let scratchBytes: Int64 = 600 * 1024 * 1024

    /// Working set the model needs while generating: weights, a KV cache sized by
    /// the tier's token cap, and the scratch allowance.
    static func estimatedPeakBytes(for entry: ModelEntry, tier: DeviceTier) -> Int64 {
        entry.approximateBytes + kvCacheBudgetBytes(for: entry, tier: tier) + scratchBytes
    }

    static func kvCacheBudgetBytes(for entry: ModelEntry, tier: DeviceTier) -> Int64 {
        Int64(InferenceLimits.maxKVTokens(for: tier)) * entry.kvBytesPerToken
    }

    /// Disk the download needs: the files plus a margin for the temp copy and resume data.
    static func requiredDiskBytes(for bytes: Int64) -> Int64 {
        bytes + bytes / 10 + 256 * 1024 * 1024
    }

    static func verdict(for entry: ModelEntry, report: DeviceReport) -> Verdict {
        guard report.hasMetal else {
            return .no("This device has no Metal GPU, which the model runs on.")
        }
        if report.isSimulator {
            return .no("MLX does not run in the iOS Simulator. Use a real iPhone.")
        }
        if report.tier == .unsupported {
            return .no("This device has under 4 GB of memory. Nothing in the catalog fits with room to spare.")
        }
        if entry.requiredTier > report.tier {
            return .no("\(entry.displayName) needs a \(entry.requiredTier.description) device or better.")
        }
        let need = estimatedPeakBytes(for: entry, tier: report.tier)
        if report.freeDisk < requiredDiskBytes(for: entry.approximateBytes) {
            let needGB = Double(requiredDiskBytes(for: entry.approximateBytes)) / Double(gib)
            return .caution(String(format: "Needs about %.1f GB free on disk.", needGB))
        }
        if report.availableMemory > 0, report.availableMemory < need {
            let short = Double(need - report.availableMemory) / Double(gib)
            return .caution(String(format: "About %.1f GB short right now. Close other apps and try again.", short))
        }
        if let comfortable = entry.comfortableTier, comfortable <= report.tier {
            return .go
        }
        let needGB = Double(need) / Double(gib)
        let haveGB = Double(report.availableMemory) / Double(gib)
        return .caution(String(
            format: "Runs, but tight: about %.1f GB needed of %.1f GB this app may use. Expect memory warnings in long chats.",
            needGB, haveGB))
    }

    /// Read the phone. Safe to call often; nothing here is expensive.
    static func current() -> DeviceReport {
        let physical = Int64(ProcessInfo.processInfo.physicalMemory)
        #if os(iOS)
        let available = Int64(os_proc_available_memory())
        #else
        // A Mac has no per-app ceiling of the iOS kind; treat most of RAM as usable.
        let available = physical * 3 / 4
        #endif
        let free: Int64 = {
            let url = URL.applicationSupportDirectory
            let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values?.volumeAvailableCapacityForImportantUsage ?? 0
        }()
        #if targetEnvironment(simulator)
        let simulator = true
        #else
        let simulator = false
        #endif
        return DeviceReport(
            physicalMemory: physical,
            availableMemory: available,
            freeDisk: free,
            hasMetal: MTLCreateSystemDefaultDevice() != nil,
            isSimulator: simulator,
            tier: tier(forPhysicalMemory: physical),
            thermalState: ProcessInfo.processInfo.thermalState
        )
    }
}

/// Runtime limits by tier, shared by the estimate above and the engine so the
/// two never disagree.
nonisolated enum InferenceLimits {
    /// Tokens of context kept in the KV cache before the oldest are rotated out.
    static func maxKVTokens(for tier: DeviceTier) -> Int {
        switch tier {
        case .unsupported: 0
        case .compact: 2048
        case .standard: 4096
        case .pro: 8192
        }
    }

    /// Longest single reply.
    static let maxGeneratedTokens = 1024

    /// MLX keeps freed buffers around for reuse. On a phone that pool has to stay small.
    static let mlxCacheLimitBytes = 64 * 1024 * 1024
}
