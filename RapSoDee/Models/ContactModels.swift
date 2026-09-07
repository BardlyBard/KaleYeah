import Foundation

/// Shared RapSoDee address book entry — account-agnostic (Gmail + Kale Yeah + Callie).
/// Email is the durable key; never synced into Outlook/Gmail native contacts.
struct RapSoDeeContact: Identifiable, Hashable, Codable, Sendable {
    /// Lowercased mailbox address (primary key).
    var email: String
    var displayName: String
    var lastSeen: Date
    var timesSeen: Int
    /// Last mailbox that observed this contact (optional hint only).
    var lastAccountID: UUID?

    var id: String { email }

    init(
        email: String,
        displayName: String = "",
        lastSeen: Date = .now,
        timesSeen: Int = 1,
        lastAccountID: UUID? = nil
    ) {
        self.email = email
        self.displayName = displayName
        self.lastSeen = lastSeen
        self.timesSeen = timesSeen
        self.lastAccountID = lastAccountID
    }

    /// Prefer "Name <email>" when a display name is known.
    var suggestionLabel: String {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.lowercased() == email.lowercased() {
            return email
        }
        return "\(name) <\(email)>"
    }
}

/// On-disk snapshot for `contacts.json`.
struct RapSoDeeContactsSnapshot: Codable, Sendable {
    var savedAt: Date
    var contacts: [RapSoDeeContact]

    init(savedAt: Date = .now, contacts: [RapSoDeeContact] = []) {
        self.savedAt = savedAt
        self.contacts = contacts
    }
}
