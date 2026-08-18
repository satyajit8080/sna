import Foundation
import SwiftData

@Model
final class AIInsight {
    var id: UUID = UUID()
    var profileID: UUID = UUID()
    var createdAt: Date = Date.now
    var headline: String = ""
    var body: String = ""
    /// Identifiers of the readings and entries this insight was derived from, so
    /// the user can always see what it was actually looking at.
    var sourceIDs: [UUID] = []
    var wasDismissed: Bool = false

    init(profileID: UUID, headline: String, body: String, sourceIDs: [UUID] = []) {
        self.id = UUID()
        self.profileID = profileID
        self.headline = headline
        self.body = body
        self.sourceIDs = sourceIDs
    }
}

@Model
final class AIConversation {
    var id: UUID = UUID()
    var profileID: UUID = UUID()
    var startedAt: Date = Date.now
    var title: String = "Chat"
    @Relationship(deleteRule: .cascade) var messages: [AIMessage] = []

    init(profileID: UUID, title: String = "Chat") {
        self.id = UUID()
        self.profileID = profileID
        self.title = title
    }
}

@Model
final class AIMessage {
    var id: UUID = UUID()
    var createdAt: Date = Date.now
    var isFromUser: Bool = true
    var text: String = ""

    init(isFromUser: Bool, text: String) {
        self.id = UUID()
        self.isFromUser = isFromUser
        self.text = text
    }
}
