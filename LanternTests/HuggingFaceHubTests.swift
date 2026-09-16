import Foundation
import Testing
@testable import Lantern

struct HuggingFaceHubTests {
    let tree = """
    [
      {"type":"file","oid":"abc123","size":812,"path":"config.json"},
      {"type":"file","oid":"def456","size":128,"path":"README.md"},
      {"type":"directory","oid":"0","path":"images"},
      {"type":"file","oid":"pointer","size":134,"path":"model.safetensors",
       "lfs":{"oid":"9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08","size":1934567890,"pointerSize":134}},
      {"type":"file","oid":"ghi","size":9000000,"path":"tokenizer.json"}
    ]
    """.data(using: .utf8)!

    @Test func treeKeepsWeightsAndTokenizerFilesOnly() throws {
        let files = try HuggingFaceHub.parseTree(tree)
        #expect(files.map(\.path) == ["config.json", "model.safetensors", "tokenizer.json"])
    }

    @Test func lfsSizeAndChecksumComeFromTheLfsBlock() throws {
        let files = try HuggingFaceHub.parseTree(tree)
        let weights = try #require(files.first { $0.path == "model.safetensors" })
        #expect(weights.size == 1_934_567_890)
        #expect(weights.sha256 == "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08")
        let config = try #require(files.first { $0.path == "config.json" })
        #expect(config.sha256 == nil)
        #expect(config.size == 812)
    }

    @Test func gatedComesAsBoolOrString() throws {
        let open = #"{"sha":"aaa","gated":false}"#.data(using: .utf8)!
        let auto = #"{"sha":"bbb","gated":"auto"}"#.data(using: .utf8)!
        let missing = #"{"sha":"ccc"}"#.data(using: .utf8)!
        #expect(try HuggingFaceHub.parseInfo(open).gated == false)
        #expect(try HuggingFaceHub.parseInfo(auto).gated == true)
        #expect(try HuggingFaceHub.parseInfo(auto).sha == "bbb")
        #expect(try HuggingFaceHub.parseInfo(missing).gated == false)
    }

    @Test func downloadURLIsTheResolveEndpoint() {
        let hub = HuggingFaceHub()
        let url = hub.downloadURL(repo: "mlx-community/Llama-3.2-3B-Instruct-4bit", revision: "main", path: "model.safetensors")
        #expect(url.absoluteString == "https://huggingface.co/mlx-community/Llama-3.2-3B-Instruct-4bit/resolve/main/model.safetensors")
    }
}
