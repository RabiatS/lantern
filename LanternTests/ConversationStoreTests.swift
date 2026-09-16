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

    @Test func purgeDeletesOnlyConversationsOlderThanSevenDays() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "lantern-purge-\(UUID().uuidString)")
        let store = ConversationStore(directory: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date()
        var stale = Conversation(modelId: ModelCatalog.defaultEntry.id)
        stale.updatedAt = now.addingTimeInterval(-8 * 86_400)
        var fresh = Conversation(modelId: ModelCatalog.defaultEntry.id)
        fresh.updatedAt = now.addingTimeInterval(-6 * 86_400)
        try store.save(stale)
        try store.save(fresh)

        #expect(ConversationStore.expiry(of: fresh) > now)
        #expect(store.purgeExpired(now: now) == 1)
        #expect(store.loadAll().map(\.id) == [fresh.id])
        #expect(store.purgeExpired(now: now.addingTimeInterval(2 * 86_400)) == 1)
        #expect(store.loadAll().isEmpty)
    }
}
