import Foundation

nonisolated enum DownloadError: LocalizedError {
    case httpStatus(Int)
    case noResponse

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code): "The server answered \(code)."
        case .noResponse: "No response from the server."
        }
    }
}

/// Downloads one file with progress and resume. Cancelling the surrounding task
/// asks the system for resume data, which is written next to the destination so
/// the next attempt continues where this one stopped.
///
/// One instance per file: it owns a URLSession whose delegate is itself, and
/// invalidates that session when the download ends.
nonisolated final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    typealias Progress = @Sendable (_ written: Int64, _ expected: Int64) -> Void

    private let lock = NSLock()
    private var session: URLSession!
    private var continuation: CheckedContinuation<URL, Error>?
    private var progress: Progress?
    private var resumeDataURL: URL?
    private var task: URLSessionDownloadTask?
    private var finishedURL: URL?

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 6 * 60 * 60
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// Returns a temporary file the caller must move or delete.
    func download(_ url: URL, resumeDataURL: URL, progress: @escaping Progress) async throws -> URL {
        defer { session.finishTasksAndInvalidate() }
        do {
            return try await start(url, resumeDataURL: resumeDataURL, progress: progress)
        } catch {
            // URLSession reports our own cancellation as URLError.cancelled. The
            // caller wants the Swift kind so it can tell "stopped" from "failed".
            try Task.checkCancellation()
            throw error
        }
    }

    private func start(_ url: URL, resumeDataURL: URL, progress: @escaping Progress) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task: URLSessionDownloadTask
                if let data = try? Data(contentsOf: resumeDataURL), !data.isEmpty {
                    task = session.downloadTask(withResumeData: data)
                } else {
                    task = session.downloadTask(with: url)
                }
                lock.withLock {
                    self.continuation = continuation
                    self.progress = progress
                    self.resumeDataURL = resumeDataURL
                    self.task = task
                }
                task.resume()
            }
        } onCancel: {
            let task = lock.withLock { self.task }
            task?.cancel { [weak self] data in
                guard let self, let data else { return }
                let url = self.lock.withLock { self.resumeDataURL }
                if let url { try? data.write(to: url, options: .atomic) }
            }
        }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let progress = lock.withLock { self.progress }
        progress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The system deletes `location` when this returns, so the move is synchronous.
        let holding = FileManager.default.temporaryDirectory
            .appending(path: "lantern-download-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: holding)
            lock.withLock { finishedURL = holding }
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
            return
        }
        let status = (task.response as? HTTPURLResponse)?.statusCode
        guard let status else {
            finish(.failure(DownloadError.noResponse))
            return
        }
        guard (200 ..< 300).contains(status) else {
            finish(.failure(DownloadError.httpStatus(status)))
            return
        }
        let url = lock.withLock { finishedURL }
        if let url {
            let resume = lock.withLock { resumeDataURL }
            if let resume { try? FileManager.default.removeItem(at: resume) }
            finish(.success(url))
        } else {
            finish(.failure(DownloadError.noResponse))
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        let continuation = lock.withLock {
            let value = self.continuation
            self.continuation = nil
            return value
        }
        continuation?.resume(with: result)
    }
}
