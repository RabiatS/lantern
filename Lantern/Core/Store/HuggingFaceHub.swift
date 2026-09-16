import Foundation

/// One file in a model repository as the hub describes it.
nonisolated struct RemoteFile: Codable, Hashable, Sendable {
    let path: String
    let size: Int64
    /// Present for LFS files (the weights). Small JSON files carry a git sha1
    /// instead, which is not useful, so they are verified by size alone.
    let sha256: String?
}

/// Everything needed to download one revision of a model and prove it arrived intact.
nonisolated struct RemoteManifest: Codable, Sendable {
    let repo: String
    /// Commit sha of the revision the file list was read from.
    let revision: String
    let gated: Bool
    let files: [RemoteFile]

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
}

nonisolated enum HubError: LocalizedError {
    case badResponse
    case httpStatus(Int, String)
    case gated(String)
    case noWeights(String)

    var errorDescription: String? {
        switch self {
        case .badResponse: "The Hugging Face reply could not be read."
        case .httpStatus(let code, let what): "Hugging Face answered \(code) for \(what)."
        case .gated(let repo): "\(repo) requires accepting a licence on huggingface.co, which this app cannot do for you."
        case .noWeights(let repo): "\(repo) has no safetensors weights."
        }
    }
}

/// Read-only client for the parts of the Hugging Face hub the store needs: the
/// repository's commit, its file tree, and the URL a file downloads from.
/// No token, no account. Every model in the catalog is public.
nonisolated struct HuggingFaceHub: Sendable {
    var session: URLSession = .shared
    var baseURL = URL(string: "https://huggingface.co")!

    /// The file types the loader reads. Everything else in a repo (README, images) is skipped.
    static let wantedExtensions: Set<String> = ["safetensors", "json", "jinja", "txt", "model"]

    func manifest(for repo: String, revision: String = "main") async throws -> RemoteManifest {
        let info = try await fetch(baseURL.appending(path: "api/models/\(repo)"), what: "model info")
        let (sha, gated) = try Self.parseInfo(info)
        let tree = try await fetch(
            baseURL.appending(path: "api/models/\(repo)/tree/\(revision)"),
            what: "file list")
        let files = try Self.parseTree(tree)
        guard files.contains(where: { $0.path.hasSuffix(".safetensors") }) else {
            throw HubError.noWeights(repo)
        }
        return RemoteManifest(repo: repo, revision: sha, gated: gated, files: files)
    }

    func downloadURL(repo: String, revision: String, path: String) -> URL {
        baseURL.appending(path: "\(repo)/resolve/\(revision)/\(path)")
    }

    private func fetch(_ url: URL, what: String) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw HubError.badResponse }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw HubError.httpStatus(http.statusCode, what)
        }
        return data
    }

    // MARK: Parsing, kept pure so it is testable without a network

    private struct TreeEntry: Decodable {
        struct LFS: Decodable {
            let oid: String
            let size: Int64
        }
        let type: String
        let path: String
        let size: Int64?
        let lfs: LFS?
    }

    static func parseTree(_ data: Data) throws -> [RemoteFile] {
        let entries = try JSONDecoder().decode([TreeEntry].self, from: data)
        return entries.compactMap { entry in
            guard entry.type == "file" else { return nil }
            let ext = (entry.path as NSString).pathExtension.lowercased()
            guard wantedExtensions.contains(ext) else { return nil }
            let size = entry.lfs?.size ?? entry.size ?? 0
            return RemoteFile(path: entry.path, size: size, sha256: entry.lfs?.oid)
        }
    }

    private struct InfoEntry: Decodable {
        let sha: String
        /// The hub sends `false`, or a string like "auto" or "manual" when gated.
        let gated: GatedValue?

        enum GatedValue: Decodable {
            case flag(Bool)
            case mode(String)

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let flag = try? container.decode(Bool.self) {
                    self = .flag(flag)
                } else {
                    self = .mode(try container.decode(String.self))
                }
            }

            var isGated: Bool {
                switch self {
                case .flag(let flag): flag
                case .mode: true
                }
            }
        }
    }

    static func parseInfo(_ data: Data) throws -> (sha: String, gated: Bool) {
        let info = try JSONDecoder().decode(InfoEntry.self, from: data)
        return (info.sha, info.gated?.isGated ?? false)
    }
}
