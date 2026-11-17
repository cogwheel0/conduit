import AppIntents
import Foundation

/// A chat, as Open Chat and the shortcuts built on it name one. Shortcuts
/// keeps the id and the title; the title is asked again by id when a saved
/// shortcut runs, so a renamed chat shows its new name.
struct ChatEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Chat")
    static let defaultQuery = ChatEntityQuery()

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }
}

/// The chats Shortcuts offers: the recent ones (pinned first), the ones a
/// search finds, and the ones a saved shortcut names. All through the app
/// (`intents.chats` in conduitd).
struct ChatEntityQuery: EntityStringQuery {
    func entities(for identifiers: [ChatEntity.ID]) async throws -> [ChatEntity] {
        try await Self.chats(.chats(ids: identifiers))
    }

    func entities(matching string: String) async throws -> [ChatEntity] {
        try await Self.chats(.chats(query: string))
    }

    func suggestedEntities() async throws -> [ChatEntity] {
        try await Self.chats(.chats())
    }

    private static func chats(_ request: IntentRequest) async throws -> [ChatEntity] {
        let reply = try await ConduitApp.send(request)
        return (reply.chats ?? []).map { ChatEntity(id: $0.id, title: $0.title) }
    }
}
