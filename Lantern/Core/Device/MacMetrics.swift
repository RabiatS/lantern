#if os(macOS)
import Darwin
import Foundation
import IOKit
import IOKit.ps
import Observation

/// One reading of the Mac, taken once a second while the window is open.
/// Every value comes from an interface macOS offers a sandboxed app; anything
/// it will not tell us is nil and shown as unavailable, never guessed.
nonisolated struct MacSample: Sendable, Equatable, Identifiable {
    let id: Int
    let time: Date
    /// How hard macOS is working to stay cool. It does not give apps degrees.
    let thermal: ProcessInfo.ThermalState
    /// Share of the graphics chip in use, 0 to 1, from the GPU driver's own statistics.
    let gpuBusy: Double?
    /// Share of all processor cores in use by everything on the Mac.
    let cpuBusy: Double?
    /// Share of all processor cores Lantern itself is using.
    let appCPU: Double?
    /// What Lantern occupies in memory, the figure Activity Monitor shows.
    let appMemory: Int64
    /// Model weights and working buffers held by MLX, part of appMemory.
    let modelMemory: Int64
    /// Memory in use by the whole Mac, and the total.
    let systemUsed: Int64
    let systemTotal: Int64
    let lowPower: Bool
    let battery: MacBattery?
}

nonisolated struct MacBattery: Sendable, Equatable {
    let level: Double
    let charging: Bool
    let onBattery: Bool
}

/// The readers. Plain functions over Mach, IOKit and ProcessInfo.
nonisolated enum MacProbe {
    /// Utilisation the GPU driver publishes for Activity Monitor.
    static func gpuBusy() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        var busy: Double?
        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }
            guard let property = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0),
                  let stats = property.takeRetainedValue() as? [String: Any],
                  let percent = (stats["Device Utilization %"] as? NSNumber)?.doubleValue else { continue }
            busy = max(busy ?? 0, min(1, percent / 100))
        }
        return busy
    }

    /// Busy and total ticks across every core since boot. Two readings a second
    /// apart give the share in use.
    static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        var busy: UInt64 = 0, total: UInt64 = 0
        for cpu in 0 ..< Int(count) {
            let base = cpu * Int(CPU_STATE_MAX)
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            busy += user + system + nice
            total += user + system + nice + idle
        }
        return (busy, total)
    }

    /// Processor seconds this app has used since it started.
    static func appCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// Physical footprint: the number Activity Monitor calls Memory.
    static func appMemory() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    /// Active, wired and compressed memory across the Mac.
    static func systemUsed() -> Int64 {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let page = Int64(getpagesize())
        return (Int64(stats.active_count) + Int64(stats.wire_count) + Int64(stats.compressor_page_count)) * page
    }

    static func battery() -> MacBattery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            return MacBattery(
                level: Double(current) / Double(maximum),
                charging: description[kIOPSIsChargingKey] as? Bool ?? false,
                onBattery: description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue)
        }
        return nil
    }
}

/// Keeps the last minute of readings for the corner gauge and its panel.
@Observable
final class MacMetrics {
    static let window = 60
    private(set) var samples: [MacSample] = []
    var latest: MacSample? { samples.last }

    private var timer: Timer?
    private var lastTicks: (busy: UInt64, total: UInt64)?
    private var lastAppCPU: (seconds: Double, at: Date)?
    private var counter = 0
    private let cores = Double(ProcessInfo.processInfo.activeProcessorCount)

    func start() {
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        let previousTicks = lastTicks
        let previousApp = lastAppCPU
        let id = counter
        counter += 1
        let cores = cores
        Task.detached(priority: .utility) {
            let now = Date()
            let ticks = MacProbe.cpuTicks()
            var cpu: Double?
            if let ticks, let previousTicks, ticks.total > previousTicks.total {
                cpu = Double(ticks.busy - previousTicks.busy) / Double(ticks.total - previousTicks.total)
            }
            let appSeconds = MacProbe.appCPUSeconds()
            var app: Double?
            if let previousApp {
                let wall = now.timeIntervalSince(previousApp.at)
                if wall > 0 { app = min(1, max(0, (appSeconds - previousApp.seconds) / wall / cores)) }
            }
            let model = InferenceEngine.memorySnapshot()
            let reading = MacSample(
                id: id, time: now,
                thermal: ProcessInfo.processInfo.thermalState,
                gpuBusy: MacProbe.gpuBusy(),
                cpuBusy: cpu, appCPU: app,
                appMemory: MacProbe.appMemory(),
                modelMemory: model.mlxActive + model.mlxCache,
                systemUsed: MacProbe.systemUsed(),
                systemTotal: Int64(ProcessInfo.processInfo.physicalMemory),
                lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                battery: MacProbe.battery())
            await MainActor.run {
                self.lastTicks = ticks
                self.lastAppCPU = (appSeconds, now)
                self.samples.append(reading)
                if self.samples.count > Self.window { self.samples.removeFirst(self.samples.count - Self.window) }
            }
        }
    }
}
#endif
