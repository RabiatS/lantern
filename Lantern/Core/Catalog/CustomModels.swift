import Foundation
import MLXLLM
import MLXVLM
import Synchronization

/// Models a person added themselves from Hugging Face. Kept in one small JSON
/// file next to the downloaded weights, and joined to the built-in catalog so
/// the store, the gate and the engine treat them like any other entry.
nonisolated enum CustomModels {
    private static let cache = Mutex<[ModelEntry]?>(nil)

    static var file: URL {
        URL.applicationSupportDirectory.appending(path: "Models/custom-models.json")
    }

    static var entries: [ModelEntry] {
        cache.withLock { cached in
            if let cached { return cached }
            let loaded = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([ModelEntry].self, from: $0) } ?? []
            cached = loaded
            return loaded
        }
    }

    static func isCustom(_ entry: ModelEntry) -> Bool {
        entries.contains { $0.id == entry.id }
    }

    static func add(_ entry: ModelEntry) throws {
        try write(entries.filter { $0.id != entry.id } + [entry])
    }

    static func remove(_ entry: ModelEntry) throws {
        try write(entries.filter { $0.id != entry.id })
    }

    private static func write(_ list: [ModelEntry]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(list).write(to: file, options: .atomic)
        cache.withLock { $0 = list }
    }
}

nonisolated enum CustomModelError: LocalizedError {
    case badName
    case builtIn(String)
    case notMLX
    case unsupportedType(String)
    case tooManyParameters(Double)
    case unreadableConfig
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .badName:
            "Write it as owner/name, the way it appears on huggingface.co, for example mlx-community/gemma-3-1b-it-4bit."
        case .builtIn(let name):
            "\(name) is already in Lantern's list."
        case .notMLX:
            "This repository has no MLX weights. Lantern runs models in MLX format; most are published under mlx-community."
        case .unsupportedType(let type):
            "Lantern's MLX library cannot run \"\(type)\" models yet."
        case .tooManyParameters(let billions):
            String(format: "This model has about %.0f billion parameters. Lantern stops at 8 billion, above which a phone closes the app.", billions)
        case .unreadableConfig:
            "The model's config.json could not be read."
        case .notFound(let repo):
            "There is no public model called \(repo) on Hugging Face. Check the spelling; it may also be private."
        }
    }
}

/// Reads a Hugging Face repository and turns it into a catalog entry, with the
/// same memory arithmetic the built-in models were given by hand.
nonisolated enum CustomModelInspector {
    /// Weights up to this size are offered on 4 GB phones; the built-in 1B
    /// models sit at 0.7 to 0.9 GB.
    static let compactWeightLimit: Int64 = 1_000_000_000
    /// Up to this size on 6 GB phones, like Qwen2-VL 2B and Llama 3.2 3B.
    static let standardWeightLimit: Int64 = 2_200_000_000

    static func isValidName(_ repo: String) -> Bool {
        repo.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
    }

    /// Read the repository and check it can run here. Network: the model's
    /// public description and two small JSON files, the same requests a
    /// download starts with.
    static func inspect(_ repo: String, hub: HuggingFaceHub = HuggingFaceHub()) async throws -> ModelEntry {
        let repo = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidName(repo) else { throw CustomModelError.badName }
        if let existing = ModelCatalog.builtIn.first(where: { $0.id.caseInsensitiveCompare(repo) == .orderedSame }) {
            throw CustomModelError.builtIn(existing.displayName)
        }
        let manifest: RemoteManifest
        do {
            manifest = try await hub.manifest(for: repo)
        } catch HubError.noWeights {
            throw CustomModelError.notMLX
        } catch HubError.httpStatus(let code, _) where code == 401 || code == 404 {
            // The hub answers 401 rather than 404 for a name that does not exist.
            throw CustomModelError.notFound(repo)
        }
        if manifest.gated { throw HubError.gated(repo) }
        let config = try await small(hub, repo, manifest, "config.json")
        guard let config else { throw CustomModelError.unreadableConfig }
        let tokenizerConfig = try? await small(hub, repo, manifest, "tokenizer_config.json")
        var entry = try entry(repo: repo, config: config, tokenizerConfig: tokenizerConfig ?? nil, manifest: manifest)
        let type = modelType(in: config) ?? "unknown"
        if entry.kind == .vision {
            guard await VLMTypeRegistry.shared.contains(type) else { throw CustomModelError.unsupportedType(type) }
        } else if !(await LLMTypeRegistry.shared.contains(type)) {
            // Some vision models only say so through the registry.
            guard await VLMTypeRegistry.shared.contains(type) else { throw CustomModelError.unsupportedType(type) }
            entry.kind = .vision
        }
        return entry
    }

    private static func small(_ hub: HuggingFaceHub, _ repo: String, _ manifest: RemoteManifest, _ path: String) async throws -> Data? {
        guard manifest.files.contains(where: { $0.path == path }) else { return nil }
        let (data, response) = try await hub.session.data(from: hub.downloadURL(repo: repo, revision: manifest.revision, path: path))
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else { return nil }
        return data
    }

    static func modelType(in config: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: config) as? [String: Any])?["model_type"] as? String
    }

    /// The pure part, testable without a network.
    static func entry(repo: String, config: Data, tokenizerConfig: Data?, manifest: RemoteManifest) throws -> ModelEntry {
        guard let root = try JSONSerialization.jsonObject(with: config) as? [String: Any] else {
            throw CustomModelError.unreadableConfig
        }
        // Vision models keep the language model's shape under text_config.
        let text = root["text_config"] as? [String: Any] ?? root
        func int(_ key: String) -> Int? { (text[key] as? NSNumber)?.intValue ?? (root[key] as? NSNumber)?.intValue }

        guard let layers = int("num_hidden_layers"), let heads = int("num_attention_heads") else {
            throw CustomModelError.unreadableConfig
        }
        let kvHeads = int("num_key_value_heads") ?? heads
        let headDim = int("head_dim") ?? (int("hidden_size").map { $0 / max(1, heads) } ?? 128)
        let weights = manifest.files.filter { $0.path.hasSuffix(".safetensors") }.reduce(Int64(0)) { $0 + $1.size }

        let quantization = root["quantization"] as? [String: Any] ?? root["quantization_config"] as? [String: Any]
        let bits = (quantization?["bits"] as? NSNumber)?.doubleValue ?? 16
        // Quantised weights carry a scale and bias per group, about half a bit more.
        let bitsPerWeight = bits < 16 ? bits + 0.5 : bits
        let billions = Double(weights) * 8 / bitsPerWeight / 1e9
        if billions > ModelCatalog.maximumParameterBillions { throw CustomModelError.tooManyParameters(billions) }

        let required: DeviceTier
        let comfortable: DeviceTier?
        switch weights {
        case ...compactWeightLimit: (required, comfortable) = (.compact, .standard)
        case ...standardWeightLimit: (required, comfortable) = (.standard, .pro)
        default: (required, comfortable) = (.pro, nil)
        }

        let eos = endTokens(config: root, tokenizerConfig: tokenizerConfig)

        let name = String(repo.split(separator: "/").last ?? Substring(repo))
        let isVision = root["vision_config"] != nil
        return ModelEntry(
            id: repo,
            displayName: name,
            family: (root["model_type"] as? String) ?? "custom",
            parameterBillions: (billions * 10).rounded() / 10,
            approximateBytes: manifest.totalBytes,
            kvBytesPerToken: Int64(layers * kvHeads * headDim * 2 * 2),
            requiredTier: required,
            comfortableTier: comfortable,
            extraEOSTokens: eos,
            contextWindow: int("max_position_embeddings") ?? 4096,
            gated: false,
            kind: isVision ? .vision : .text)
    }

    /// Markers that end a reply. Models declare one end token, but many end a
    /// chat turn with another that only their chat format uses: Gemma declares
    /// `<eos>` and ends turns with `<end_of_turn>`, and without it a reply runs
    /// to the length limit. So the declared ones are joined by any well-known
    /// end-of-turn marker the model's own token list contains.
    static let knownTurnEnds: Set<String> = [
        "<end_of_turn>", "<|im_end|>", "<|eot_id|>", "<|end|>", "<end_of_utterance>",
        "<|endoftext|>", "<|end_of_text|>", "<|return|>",
    ]

    static func endTokens(config: [String: Any], tokenizerConfig: Data?) -> Set<String> {
        var ends: Set<String> = []
        guard let tokenizerConfig,
              let tokenizer = try? JSONSerialization.jsonObject(with: tokenizerConfig) as? [String: Any] else { return ends }
        if let token = tokenizer["eos_token"] as? String { ends.insert(token) }
        if let token = (tokenizer["eos_token"] as? [String: Any])?["content"] as? String { ends.insert(token) }
        let decoder = tokenizer["added_tokens_decoder"] as? [String: [String: Any]] ?? [:]
        let special = Set(decoder.values.compactMap { $0["content"] as? String })
        ends.formUnion(knownTurnEnds.intersection(special))
        var ids: [Int] = []
        if let id = (config["eos_token_id"] as? NSNumber)?.intValue { ids.append(id) }
        if let list = config["eos_token_id"] as? [NSNumber] { ids += list.map(\.intValue) }
        for id in ids { if let token = decoder[String(id)]?["content"] as? String { ends.insert(token) } }
        return ends
    }

    /// Whether the working set fits what this device lets Lantern use right
    /// now. The catalog's own models were sized by hand; this is the same
    /// sum, applied before anything is added.
    static func fits(_ entry: ModelEntry, on report: DeviceReport) -> Verdict {
        let verdict = DeviceCapability.verdict(for: entry, report: report)
        if case .no = verdict { return verdict }
        let need = DeviceCapability.estimatedPeakBytes(for: entry, tier: report.tier)
        if report.availableMemory > 0, need > report.availableMemory {
            return .no(String(format: "Needs about %.1f GB while it runs; this %@ lets Lantern use about %.1f GB.",
                              Double(need) / 1e9, Platform.device, Double(report.availableMemory) / 1e9))
        }
        return verdict
    }
}
