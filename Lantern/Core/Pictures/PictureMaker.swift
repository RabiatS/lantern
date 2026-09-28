import CoreGraphics
import Foundation
import Hub
import MLX
import Observation
import StableDiffusion

/// The picture maker: Stability's SD-Turbo, a distilled Stable Diffusion 2.1
/// that draws a 512 by 512 picture in a few steps instead of fifty. Same
/// architecture as SD 2.1 base, which is what the MLX library implements, and
/// unlike 2.1 base its repository is open, so Lantern can download it for
/// anyone. Half-precision files, 2.6 GB.
nonisolated enum PictureModel {
    static let repo = "stabilityai/sd-turbo"
    static let revision = "b261bac6fd2cf515557d5d0707481eafa0485ec2"
    static let displayName = "SD-Turbo"

    /// The MLX library resolves files by the SD 2.1 base preset's id and file
    /// names, so the turbo files are stored under those names.
    static let presetId = "stabilityai/stable-diffusion-2-1-base"

    struct File: Hashable, Sendable {
        let source: String
        let target: String
        let size: Int64
        let sha256: String?
    }

    static let files: [File] = [
        File(source: "unet/config.json", target: "unet/config.json", size: 1867, sha256: nil),
        File(source: "unet/diffusion_pytorch_model.fp16.safetensors", target: "unet/diffusion_pytorch_model.safetensors",
             size: 1_731_904_736, sha256: "40ec400881e27d1376c7c95c5bd495f407b33756e80eb6365e301c33a07af6e5"),
        File(source: "text_encoder/config.json", target: "text_encoder/config.json", size: 618, sha256: nil),
        File(source: "text_encoder/model.fp16.safetensors", target: "text_encoder/model.safetensors",
             size: 680_820_392, sha256: "bc1827c465450322616f06dea41596eac7d493f4e95904dcb51f0fc745c4e13f"),
        File(source: "vae/config.json", target: "vae/config.json", size: 655, sha256: nil),
        File(source: "vae/diffusion_pytorch_model.fp16.safetensors", target: "vae/diffusion_pytorch_model.safetensors",
             size: 167_335_342, sha256: "3e4c08995484ee61270175e9e7a072b66a6e4eeb5f0c266667fe1f45b90daf9a"),
        File(source: "scheduler/scheduler_config.json", target: "scheduler/scheduler_config.json", size: 553, sha256: nil),
        File(source: "tokenizer/vocab.json", target: "tokenizer/vocab.json", size: 1_059_962, sha256: nil),
        File(source: "tokenizer/merges.txt", target: "tokenizer/merges.txt", size: 524_619, sha256: nil),
    ]

    static var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    /// Working set while drawing: the three networks in half precision plus the
    /// activations of a 512 pixel image. Quantising the UNet on 6 GB phones
    /// brings it under their ceiling with little to spare.
    static func estimatedPeakBytes(tier: DeviceTier) -> Int64 {
        let unet: Int64 = tier >= .pro ? 1_732_000_000 : 520_000_000
        return unet + 681_000_000 + 335_000_000 + 1_100_000_000
    }

    static func verdict(report: DeviceReport) -> Verdict {
        guard report.hasMetal else { return .no("This device has no Metal GPU.") }
        if report.isSimulator { return .no("MLX does not run in the iOS Simulator. Use a real iPhone.") }
        if report.tier < .standard { return .no("Drawing pictures needs a 6 GB iPhone or better.") }
        let need = estimatedPeakBytes(tier: report.tier)
        if report.freeDisk < DeviceCapability.requiredDiskBytes(for: totalBytes) {
            return .caution(String(format: "Needs about %.1f GB free on disk.", Double(DeviceCapability.requiredDiskBytes(for: totalBytes)) / Double(1 << 30)))
        }
        if report.availableMemory > 0, report.availableMemory < need {
            return .caution(String(format: "About %.1f GB short right now. Close other apps and try again.", Double(need - report.availableMemory) / Double(1 << 30)))
        }
        if report.tier < .pro {
            return .caution("Runs with a compressed model and unloads after each picture. Expect about a minute per picture.")
        }
        return .go
    }
}

/// Downloads, verifies and keeps the picture model. Same bones as ModelStore,
/// for one fixed bundle laid out the way the MLX library wants to find it.
@Observable
final class PictureStore {
    enum Status: Equatable {
        case notInstalled
        case downloading(written: Int64, total: Int64, file: String)
        case waitingForNetwork(file: String)
        case verifying(file: String)
        case installed
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .downloading, .waitingForNetwork, .verifying: true
            default: false
            }
        }
    }

    private(set) var status: Status = .notInstalled
    let root: URL
    private var task: Task<Void, Never>?
    var wifiOnly = true

    /// `HubApi(downloadBase:)` resolves a repo to `<base>/models/<id>`.
    var repoDirectory: URL {
        root.appending(path: "models", directoryHint: .isDirectory).appending(path: PictureModel.presetId, directoryHint: .isDirectory)
    }

    init(root: URL = URL.applicationSupportDirectory.appending(path: "PictureModel", directoryHint: .isDirectory)) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        refresh()
    }

    func refresh() {
        guard !status.isBusy else { return }
        let all = PictureModel.files.allSatisfy { Self.isVerified($0, in: repoDirectory) }
        status = all ? .installed : .notInstalled
    }

    var isInstalled: Bool { status == .installed }

    func install() {
        guard !status.isBusy else { return }
        let directory = repoDirectory
        let allowsCellular = !wifiOnly
        let report: @Sendable (Status) -> Void = { [weak self] update in
            Task { @MainActor in self?.status = update }
        }
        task = Task { [weak self] in
            do {
                try await Self.performInstall(directory: directory, allowsCellular: allowsCellular, report: report)
                self?.status = .installed
            } catch is CancellationError {
                self?.status = .notInstalled
            } catch {
                self?.status = .failed(error.localizedDescription)
            }
            self?.task = nil
        }
    }

    func cancel() { task?.cancel() }

    func remove() throws {
        cancel()
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        status = .notInstalled
    }

    @concurrent
    nonisolated private static func performInstall(
        directory: URL, allowsCellular: Bool, report: @Sendable @escaping (Status) -> Void
    ) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)

        let remaining = PictureModel.files.filter { !isVerified($0, in: directory) }
        let total = PictureModel.totalBytes
        var done = PictureModel.files.filter { isVerified($0, in: directory) }.reduce(0) { $0 + $1.size }
        let hub = HuggingFaceHub()
        for file in remaining {
            try Task.checkCancellation()
            let destination = directory.appending(path: file.target)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let resume = directory.appending(path: file.target + ".resume")
            let source = hub.downloadURL(repo: PictureModel.repo, revision: PictureModel.revision, path: file.source)
            let base = done
            report(.downloading(written: base, total: total, file: file.source))
            let downloaded = try await FileDownloader(allowsCellular: allowsCellular).download(source, resumeDataURL: resume) { written, _ in
                report(.downloading(written: base + written, total: total, file: file.source))
            } waiting: {
                report(.waitingForNetwork(file: file.source))
            }
            report(.verifying(file: file.source))
            guard Integrity.fileSize(at: downloaded) == file.size else {
                try? fm.removeItem(at: downloaded)
                throw ModelStoreError.sizeMismatch(file.source)
            }
            if let expected = file.sha256 {
                guard try Integrity.sha256(of: downloaded) == expected else {
                    try? fm.removeItem(at: downloaded)
                    throw ModelStoreError.checksumMismatch(file.source)
                }
            }
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: downloaded, to: destination)
            try (file.sha256 ?? "size-only").write(to: directory.appending(path: file.target + ".verified"), atomically: true, encoding: .utf8)
            done += file.size
        }
    }

    nonisolated private static func isVerified(_ file: PictureModel.File, in directory: URL) -> Bool {
        guard Integrity.fileSize(at: directory.appending(path: file.target)) == file.size else { return false }
        let note = try? String(contentsOf: directory.appending(path: file.target + ".verified"), encoding: .utf8)
        return note == (file.sha256 ?? "size-only")
    }
}

nonisolated enum PictureEvent: Sendable {
    case step(Int, of: Int)
    case decoding
    case done(CGImage, seconds: Double)
}

/// Draws pictures. Holds the networks while the phone can afford to; on 6 GB
/// phones it lets them go after each picture and reloads next time.
actor PictureMaker {
    private var generator: (any TextToImageGenerator)?
    private var keepLoaded = true

    func unload() {
        generator = nil
        if generatorWasLoaded { Memory.clearCache() }
        generatorWasLoaded = false
    }
    private var generatorWasLoaded = false

    /// Draw one picture. Four steps at 512 by 512, which is what SD-Turbo was
    /// trained for; classifier-free guidance is off, as it must be for turbo.
    func make(prompt: String, root: URL, tier: DeviceTier) -> AsyncThrowingStream<PictureEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let started = ContinuousClock.now
                do {
                    let generator = try self.loadedGenerator(root: root, tier: tier)
                    let steps = 4
                    var parameters = EvaluateParameters(cfgWeight: 0, steps: steps, seed: UInt64.random(in: 0 ... UInt64.max), prompt: prompt)
                    parameters.latentSize = [64, 64]
                    var latents: MLXArray?
                    var index = 0
                    for xt in generator.generateLatents(parameters: parameters) {
                        try Task.checkCancellation()
                        eval(xt)
                        latents = xt
                        index += 1
                        continuation.yield(.step(index, of: steps))
                    }
                    guard let latents else { throw EngineError.noModelLoaded }
                    continuation.yield(.decoding)
                    let decoded = generator.decode(xt: latents)
                    let raster = (decoded[0] * 255).asType(.uint8)
                    eval(raster)
                    let image = Image(raster).asCGImage()
                    if !self.keepLoaded { self.unload() }
                    Memory.clearCache()
                    let parts = (ContinuousClock.now - started).components
                    continuation.yield(.done(image, seconds: Double(parts.seconds) + Double(parts.attoseconds) / 1e18))
                    continuation.finish()
                } catch {
                    if !self.keepLoaded { self.unload() }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func loadedGenerator(root: URL, tier: DeviceTier) throws -> any TextToImageGenerator {
        if let generator { return generator }
        keepLoaded = tier >= .pro
        let hub = HubApi(downloadBase: root)
        let load = LoadConfiguration(float16: true, quantize: tier < .pro)
        guard let generator = try StableDiffusionConfiguration.presetStableDiffusion21Base
            .textToImageGenerator(hub: hub, configuration: load) else {
            throw EngineError.noModelLoaded
        }
        generator.ensureLoaded()
        generatorWasLoaded = true
        self.generator = generator
        return generator
    }
}
