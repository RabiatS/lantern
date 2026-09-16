import Foundation

nonisolated struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable {
        case system
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    var text: String
    let createdAt: Date
    /// Filled in for assistant messages once generation ends.
    var stats: GenerationStats?

    init(id: UUID = UUID(), role: Role, text: String, createdAt: Date = Date(), stats: GenerationStats? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.stats = stats
    }
}


nonisolated struct Conversation: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    /// Catalog id of the model the conversation was started with.
    var modelId: String
    var messages: [ChatMessage]
    let createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), title: String = "New chat", modelId: String, messages: [ChatMessage] = [], createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.modelId = modelId
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    /// The first user line, trimmed, becomes the title once there is one.
    mutating func refreshTitle() {
        guard title == "New chat", let first = messages.first(where: { $0.role == .user }) else { return }
        let line = first.text.trimmingCharacters(in: .whitespacesAndNewlines)
        title = String(line.prefix(48))
    }
}
