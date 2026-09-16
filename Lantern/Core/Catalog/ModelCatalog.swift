import Foundation

/// How much phone a model needs. Ordered so that a device tier can be compared
/// against a model's required tier with plain `<`.
nonisolated enum DeviceTier: Int, Codable, Comparable, Sendable, CustomStringConvertible {
    /// Under about 3.5 GiB. Nothing in the catalog is offered.
    case unsupported = 0
    /// 4 GB phones: iPhone 12, 13, SE 3. Only the 1B class, with a short context.
    case compact = 1
    /// 6 GB phones: iPhone 14, 15, 16e. The 1B class comfortably, 3B with a warning.
    case standard = 2
    /// 8 GB and up: iPhone 15 Pro, every iPhone 16 and 17. 3B comfortably, 8B with a warning.
    case pro = 3

    static func < (lhs: DeviceTier, rhs: DeviceTier) -> Bool { lhs.rawValue < rhs.rawValue }

    var description: String {
        switch self {
        case .unsupported: "unsupported"
        case .compact: "compact (4 GB)"
        case .standard: "standard (6 GB)"
        case .pro: "pro (8 GB+)"
        }
    }
}

/// One model the app knows how to download and run. The catalog is static on
/// purpose: it is the contract between the device gate, the store and the engine,
/// and nothing about it should depend on a network reply.
nonisolated struct ModelEntry: Identifiable, Hashable, Codable, Sendable {
    /// Hugging Face repository id, also the on-disk identity.
    let id: String
    let displayName: String
    let family: String
    /// Parameter count in billions. Used for the "nothing above 8B" rule.
    let parameterBillions: Double
    /// Size of the weights, for the disk check and the UI before the manifest arrives.
    let approximateBytes: Int64
    /// KV cache cost per token of context in bytes, fp16:
    /// layers x kv_heads x head_dim x 2 (K and V) x 2 bytes.
    let kvBytesPerToken: Int64
    /// The lowest tier the model is offered on at all.
    let requiredTier: DeviceTier
    /// The lowest tier it runs on without a memory warning in the gate. `nil`
    /// means it is tight everywhere it is allowed.
    let comfortableTier: DeviceTier?
    /// Tokens the model emits to end a turn beyond the tokenizer's own EOS.
    let extraEOSTokens: Set<String>
    /// The model's native window. The engine caps the KV cache well below this.
    let contextWindow: Int
    /// Repository requires accepting a licence on Hugging Face before download.
    let gated: Bool

    /// Folder name inside the model store. Slashes are not allowed in a path.
    var folderName: String { id.replacingOccurrences(of: "/", with: "__") }
}

nonisolated enum ModelCatalog {
    /// Default. 16 layers, 8 KV heads of 64: a 4096 token context costs 128 MB.
    /// Weights are 695 MB, so it fits on a 4 GB phone with room to spare.
    static let llama3_2_1B = ModelEntry(
        id: "mlx-community/Llama-3.2-1B-Instruct-4bit",
        displayName: "Llama 3.2 1B",
        family: "Llama",
        parameterBillions: 1.24,
        approximateBytes: 695_283_921,
        kvBytesPerToken: 16 * 8 * 64 * 2 * 2,
        requiredTier: .compact,
        comfortableTier: .compact,
        extraEOSTokens: ["<|eot_id|>"],
        contextWindow: 131_072,
        gated: false
    )

    /// Same class as the 1B, stronger at reasoning and code. 28 layers with only
    /// 2 KV heads of 128, so its cache is the cheapest in the catalog.
    static let qwen2_5_1_5B = ModelEntry(
        id: "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
        displayName: "Qwen 2.5 1.5B",
        family: "Qwen",
        parameterBillions: 1.54,
        approximateBytes: 868_628_559,
        kvBytesPerToken: 28 * 2 * 128 * 2 * 2,
        requiredTier: .compact,
        comfortableTier: .compact,
        extraEOSTokens: ["<|im_end|>"],
        contextWindow: 32_768,
        gated: false
    )

    /// 1.8 GB of weights and 112 KB per token of context. Comfortable on 8 GB,
    /// offered with a warning on 6 GB, never on 4 GB.
    static let llama3_2_3B = ModelEntry(
        id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
        displayName: "Llama 3.2 3B",
        family: "Llama",
        parameterBillions: 3.21,
        approximateBytes: 1_807_496_278,
        kvBytesPerToken: 28 * 8 * 128 * 2 * 2,
        requiredTier: .standard,
        comfortableTier: .pro,
        extraEOSTokens: ["<|eot_id|>"],
        contextWindow: 131_072,
        gated: false
    )

    /// Phi 3.5 mini has no grouped-query attention: 32 layers x 32 heads x 96,
    /// which is 384 KB per token, three and a half times Llama 3B. The pro
    /// tier's 8192 token window is 3 GB of cache on top of 2.1 GB of weights,
    /// the same working set as the 8B. So: pro-only and always warned, despite
    /// the "mini".
    static let phi3_5Mini = ModelEntry(
        id: "mlx-community/Phi-3.5-mini-instruct-4bit",
        displayName: "Phi 3.5 mini",
        family: "Phi",
        parameterBillions: 3.82,
        approximateBytes: 2_149_696_133,
        kvBytesPerToken: 32 * 32 * 96 * 2 * 2,
        requiredTier: .pro,
        comfortableTier: nil,
        extraEOSTokens: ["<|end|>"],
        contextWindow: 131_072,
        gated: false
    )

    /// The ceiling. 4.5 GB of weights leaves about 1.5 GB for everything else on
    /// an 8 GB phone with the increased memory limit. Always offered with a warning.
    static let llama3_1_8B = ModelEntry(
        id: "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit",
        displayName: "Llama 3.1 8B",
        family: "Llama",
        parameterBillions: 8.03,
        approximateBytes: 4_517_488_999,
        kvBytesPerToken: 32 * 8 * 128 * 2 * 2,
        requiredTier: .pro,
        comfortableTier: nil,
        extraEOSTokens: ["<|eot_id|>"],
        contextWindow: 131_072,
        gated: false
    )

    static let all: [ModelEntry] = [llama3_2_1B, qwen2_5_1_5B, llama3_2_3B, phi3_5Mini, llama3_1_8B]

    static let defaultEntry = llama3_2_1B

    /// The hard ceiling. Anything above this is a reliable out-of-memory kill even on Pro.
    static let maximumParameterBillions = 8.1

    static func entry(id: String) -> ModelEntry? {
        all.first { $0.id == id }
    }

    /// Models a device of the given tier may run at all.
    static func entries(for tier: DeviceTier) -> [ModelEntry] {
        all.filter { $0.requiredTier <= tier }
    }
}
