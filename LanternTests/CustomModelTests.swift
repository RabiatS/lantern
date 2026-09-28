import Foundation
import Testing
@testable import Lantern

struct CustomModelTests {
    private func manifest(weights: Int64) -> RemoteManifest {
        RemoteManifest(repo: "someone/model", revision: "abc", gated: false, files: [
            RemoteFile(path: "config.json", size: 1_000, sha256: nil),
            RemoteFile(path: "model.safetensors", size: weights, sha256: "x"),
        ])
    }

    private func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

    @Test func namesMustLookLikeOwnerSlashName() {
        #expect(CustomModelInspector.isValidName("mlx-community/gemma-3-1b-it-4bit"))
        #expect(!CustomModelInspector.isValidName("gemma"))
        #expect(!CustomModelInspector.isValidName("a/b/c"))
        #expect(!CustomModelInspector.isValidName("not a name"))
    }

    @Test func aGemmaLikeModelIsSizedLikeTheBuiltInOnes() throws {
        let config = try json([
            "model_type": "gemma3_text", "num_hidden_layers": 26, "num_attention_heads": 4,
            "num_key_value_heads": 1, "head_dim": 256, "max_position_embeddings": 32768,
            "eos_token_id": 1, "quantization": ["bits": 4, "group_size": 64],
        ])
        let tokenizer = try json([
            "eos_token": "<eos>",
            "added_tokens_decoder": ["1": ["content": "<eos>"], "106": ["content": "<end_of_turn>"]],
        ])
        let entry = try CustomModelInspector.entry(
            repo: "mlx-community/gemma-3-1b-it-4bit", config: config, tokenizerConfig: tokenizer,
            manifest: manifest(weights: 732_000_000))
        #expect(entry.kvBytesPerToken == 26 * 1 * 256 * 2 * 2)
        #expect(entry.requiredTier == .compact)
        #expect(entry.kind == .text)
        #expect(entry.extraEOSTokens == ["<eos>", "<end_of_turn>"])
        #expect(entry.parameterBillions > 1.2 && entry.parameterBillions < 1.4)
    }

    @Test func visionModelsReadTheTextConfigAndBigOnesAreRefused() throws {
        let vision = try json([
            "model_type": "qwen2_vl", "vision_config": ["depth": 32],
            "text_config": ["num_hidden_layers": 28, "num_attention_heads": 12, "num_key_value_heads": 2, "hidden_size": 1536],
            "quantization": ["bits": 4],
        ])
        let entry = try CustomModelInspector.entry(repo: "a/vl", config: vision, tokenizerConfig: nil, manifest: manifest(weights: 1_250_000_000))
        #expect(entry.kind == .vision)
        #expect(entry.kvBytesPerToken == 28 * 2 * 128 * 2 * 2)
        #expect(entry.requiredTier == .standard)

        let big = try json(["model_type": "llama", "num_hidden_layers": 80, "num_attention_heads": 64, "quantization": ["bits": 4]])
        #expect(throws: CustomModelError.self) {
            try CustomModelInspector.entry(repo: "a/big", config: big, tokenizerConfig: nil, manifest: manifest(weights: 40_000_000_000))
        }
    }
}
