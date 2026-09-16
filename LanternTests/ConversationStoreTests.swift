import Foundation
import Testing
@testable import Lantern

struct ConversationStoreTests {
    @Test func roundTripsAndOrdersByUpdate() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "lantern-conv-\(UUID().uuidString)")
        let store = ConversationStore(directory: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        var older = Conversation(modelId: ModelCatalog.defaultEntry.id)
        older.messages.append(ChatMessage(role: .user, text: "hello there"))
        older.refreshTitle()
        older.updatedAt = Date(timeIntervalSinceNow: -100)
        var newer = Conversation(modelId: ModelCatalog.defaultEntry.id)
        newer.messages.append(ChatMessage(role: .assistant, text: "hi", stats: GenerationStats(promptTokens: 3, generatedTokens: 1, tokensPerSecond: 20, promptSeconds: 0.1, timeToFirstToken: 0.15)))
        try store.save(older)
        try store.save(newer)

        let loaded = store.loadAll()
        #expect(loaded.map(\.id) == [newer.id, older.id])
        #expect(loaded[1].title == "hello there")
        #expect(loaded[0].messages[0].stats?.tokensPerSecond == 20)

        try store.delete(older.id)
        #expect(store.loadAll().map(\.id) == [newer.id])
    }
}
