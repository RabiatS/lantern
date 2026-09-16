import Foundation
import Observation

/// What is on disk for one model, written as `install.json` inside its folder
/// once every file has been verified.
nonisolated struct InstalledModel: Codable, Equatable, Sendable {
    let entryId: String
    let revision: String
    let files: [RemoteFile]
    let totalBytes: Int64
    let installedAt: Date
}

nonisolated enum ModelStoreError: LocalizedError {
    case notEnoughDisk(needed: Int64, free: Int64)
    case sizeMismatch(String)
    case checksumMismatch(String)
    case notInstalled(String)

    var errorDescription: String? {
        switch self {
        case .notEnoughDisk(let needed, let free):
            let gib = Double(1 << 30)
            return String(format: "Needs %.1f GB free, %.1f GB available.", Double(needed) / gib, Double(free) / gib)
        case .sizeMismatch(let file): return "\(file) arrived with the wrong size."
        case .checksumMismatch(let file): return "\(file) failed its checksum."
        case .notInstalled(let id): return "\(id) is not downloaded."
        }
    }
}

/// Downloads weights after install, keeps them on disk outside of backups, verifies
/// every byte against the hub's checksums, and lets a model be removed or swapped.
/// Nothing is bundled in the binary.
@Observable
final class ModelStore {
    enum Status: Equatable {
        case notInstalled
        case fetchingManifest
        case downloading(written: Int64, total: Int64, file: String)
        case verifying(file: String)
        case installed(InstalledModel)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .fetchingManifest, .downloading, .verifying: true
            default: false
            }
        }
    }

    private(set) var status: [String: Status] = [:]

    let root: URL
    private let hub: HuggingFaceHub
    private var tasks: [String: Task<Void, Never>] = [:]

    init(root: URL = ModelStore.defaultRoot, hub: HuggingFaceHub = HuggingFaceHub()) {
        self.root = root
        self.hub = hub
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        refresh()
    }

    /// Application Support, so the weights survive an app update and never sync
    /// to iCloud. Backup exclusion is set per model folder below.
    static var defaultRoot: URL {
        URL.applicationSupportDirectory.appending(path: "Models", directoryHint: .isDirectory)
    }

    func directory(for entry: ModelEntry) -> URL {
        root.appending(path: entry.folderName, directoryHint: .isDirectory)
    }

    func status(for entry: ModelEntry) -> Status {
        status[entry.id] ?? .notInstalled
    }

    func installedModel(for entry: ModelEntry) -> InstalledModel? {
        if case .installed(let model) = status(for: entry) { return model }
        return nil
    }

    var installedEntries: [ModelEntry] {
        ModelCatalog.all.filter { installedModel(for: $0) != nil }
    }

    /// Re-read `install.json` for every catalog entry. Cheap; called at launch
    /// and after any change.
    func refresh() {
        for entry in ModelCatalog.all where !(status[entry.id]?.isBusy ?? false) {
            let url = directory(for: entry).appending(path: "install.json")
            if let data = try? Data(contentsOf: url),
               let model = try? JSONDecoder().decode(InstalledModel.self, from: data),
               Self.filesPresent(model, in: directory(for: entry)) {
                status[entry.id] = .installed(model)
            } else {
                status[entry.id] = .notInstalled
            }
        }
    }

    private static func filesPresent(_ model: InstalledModel, in directory: URL) -> Bool {
        model.files.allSatisfy { file in
            Integrity.fileSize(at: directory.appending(path: file.path)) == file.size
        }
    }

    // MARK: Install

    func install(_ entry: ModelEntry) {
        guard !(status(for: entry).isBusy) else { return }
        status[entry.id] = .fetchingManifest
        let directory = directory(for: entry)
        let hub = hub
        let id = entry.id
        let report: @Sendable (Status) -> Void = { [weak self] update in
            Task { @MainActor [weak self] in self?.status[id] = update }
        }
        tasks[id] = Task { [weak self] in
            do {
                let installed = try await Self.performInstall(
                    entry: entry, directory: directory, hub: hub, report: report)
                self?.status[id] = .installed(installed)
            } catch is CancellationError {
                self?.status[id] = .notInstalled
            } catch {
                self?.status[id] = .failed(error.localizedDescription)
            }
            self?.tasks[id] = nil
        }
    }

    func cancel(_ entry: ModelEntry) {
        tasks[entry.id]?.cancel()
    }

    /// Delete the weights. Partial downloads and resume data go too.
    func remove(_ entry: ModelEntry) throws {
        cancel(entry)
        let directory = directory(for: entry)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        status[entry.id] = .notInstalled
    }

    var bytesOnDisk: Int64 {
        ModelCatalog.all.compactMap { installedModel(for: $0)?.totalBytes }.reduce(0, +)
    }

    /// Runs off the main actor. Downloads each file in turn, verifies it, and only
    /// then writes `install.json`, so a half-finished folder is never mistaken for
    /// an installed model.
    @concurrent
    nonisolated private static func performInstall(
        entry: ModelEntry,
        directory: URL,
        hub: HuggingFaceHub,
        report: @Sendable @escaping (Status) -> Void
    ) async throws -> InstalledModel {
        let manifest = try await hub.manifest(for: entry.id)
        if manifest.gated { throw HubError.gated(entry.id) }

        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.excludeFromBackup(directory)

        let already = manifest.files.filter { Self.isVerified($0, in: directory) }
        let remaining = manifest.files.filter { !already.contains($0) }
        let remainingBytes = remaining.reduce(0) { $0 + $1.size }
        let free = (try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage) ?? 0
        let needed = DeviceCapability.requiredDiskBytes(for: remainingBytes)
        if remainingBytes > 0, free < needed {
            throw ModelStoreError.notEnoughDisk(needed: needed, free: free)
        }

        var doneBytes = already.reduce(0) { $0 + $1.size }
        let total = manifest.totalBytes

        for file in remaining {
            try Task.checkCancellation()
            let destination = directory.appending(path: file.path)
            try fm.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let resume = directory.appending(path: file.path + ".resume")
            let url = hub.downloadURL(repo: entry.id, revision: manifest.revision, path: file.path)
            let base = doneBytes
            report(.downloading(written: base, total: total, file: file.path))

            let downloaded = try await FileDownloader().download(url, resumeDataURL: resume) { written, _ in
                report(.downloading(written: base + written, total: total, file: file.path))
            }

            report(.verifying(file: file.path))
            guard Integrity.fileSize(at: downloaded) == file.size else {
                try? fm.removeItem(at: downloaded)
                throw ModelStoreError.sizeMismatch(file.path)
            }
            if let expected = file.sha256 {
                let actual = try Integrity.sha256(of: downloaded)
                guard actual == expected else {
                    try? fm.removeItem(at: downloaded)
                    throw ModelStoreError.checksumMismatch(file.path)
                }
            }
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: downloaded, to: destination)
            try Self.markVerified(file, in: directory)
            doneBytes += file.size
        }

        let installed = InstalledModel(
            entryId: entry.id, revision: manifest.revision, files: manifest.files,
            totalBytes: total, installedAt: Date())
        let data = try JSONEncoder().encode(installed)
        try data.write(to: directory.appending(path: "install.json"), options: .atomic)
        return installed
    }

    // MARK: Per-file verification records

    /// A file counts as verified when it is the right size and its sidecar
    /// `.verified` note carries the checksum that was confirmed. Re-hashing a
    /// 4 GB file on every launch would be the alternative.
    nonisolated private static func isVerified(_ file: RemoteFile, in directory: URL) -> Bool {
        let destination = directory.appending(path: file.path)
        guard Integrity.fileSize(at: destination) == file.size else { return false }
        let note = try? String(contentsOf: directory.appending(path: file.path + ".verified"), encoding: .utf8)
        return note == (file.sha256 ?? "size-only")
    }

    nonisolated private static func markVerified(_ file: RemoteFile, in directory: URL) throws {
        let note = file.sha256 ?? "size-only"
        try note.write(
            to: directory.appending(path: file.path + ".verified"), atomically: true, encoding: .utf8)
    }

    nonisolated private static func excludeFromBackup(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}
