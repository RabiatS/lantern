import Foundation
import Testing
@testable import Lantern

struct IntegrityTests {
    @Test func sha256MatchesKnownVector() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "lantern-\(UUID().uuidString).bin")
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try Integrity.sha256(of: url) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(Integrity.sha256(of: Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(Integrity.fileSize(at: url) == 3)
    }

    @Test func largeFileHashesAcrossChunks() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "lantern-\(UUID().uuidString).bin")
        let data = Data(repeating: 0x61, count: 5 << 20)
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try Integrity.sha256(of: url) == Integrity.sha256(of: data))
    }
}
