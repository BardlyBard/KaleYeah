import Foundation

/// Shared, account-agnostic RapSoDee contacts — local JSON only (no Graph/Gmail Contacts sync).
enum ContactsStore {
    private static let folderName = "RapSoDeeContacts"
    private static let contactsFile = "contacts.json"

    private static var rootDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var contactsURL: URL {
        rootDirectory.appendingPathComponent(contactsFile)
    }

    // MARK: - Load / save

    static func load() -> [RapSoDeeContact] {
        let url = contactsURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return []
        }
        let iso = JSONDecoder()
        iso.dateDecodingStrategy = .iso8601
        if let snapshot = try? iso.decode(RapSoDeeContactsSnapshot.self, from: data) {
            return snapshot.contacts.sorted { $0.email < $1.email }
        }
        if let snapshot = try? JSONDecoder().decode(RapSoDeeContactsSnapshot.self, from: data) {
            return snapshot.contacts.sorted { $0.email < $1.email }
        }
        return []
    }

    static func save(_ contacts: [RapSoDeeContact]) {
        let snapshot = RapSoDeeContactsSnapshot(savedAt: .now, contacts: contacts)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: contactsURL, options: .atomic)
    }

    /// Copy current book to a repo-relative export path for optional private GitHub backup.
    @discardableResult
    static func writeExport(to directory: URL) -> URL? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dest = directory.appendingPathComponent(contactsFile)
        let contacts = load()
        let snapshot = RapSoDeeContactsSnapshot(savedAt: .now, contacts: contacts)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return nil }
        do {
            try data.write(to: dest, options: .atomic)
            return dest
        } catch {
            return nil
        }
    }

    // MARK: - Harvest

    /// Rebuild the shared book from non-junk mail. Account-agnostic.
    /// Inbound → From; Sent → To (+ Cc). Skips noreply / own mailboxes.
    static func harvest(
        messages: [MailMessage],
        folders: [MailFolder],
        ownEmails: [String]
    ) -> [RapSoDeeContact] {
        let folderByID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        let own = Set(ownEmails.map(normalizeEmail).filter { !$0.isEmpty })
        var map: [String: RapSoDeeContact] = [:]

        for message in messages {
            let kind = folderByID[message.folderID]?.kind
            if kind == .junk { continue }

            if kind == .sent {
                for raw in message.toAddresses + message.ccAddresses {
                    ingest(
                        rawAddress: raw,
                        displayName: "",
                        seenAt: message.receivedAt,
                        accountID: message.accountID,
                        own: own,
                        into: &map
                    )
                }
            } else {
                // Inbound (and other non-junk folders): From. Reply-To not stored on MailMessage yet.
                ingest(
                    rawAddress: message.fromAddress,
                    displayName: message.fromName,
                    seenAt: message.receivedAt,
                    accountID: message.accountID,
                    own: own,
                    into: &map
                )
            }
        }

        return Array(map.values).sorted { $0.email < $1.email }
    }

    private static func ingest(
        rawAddress: String,
        displayName: String,
        seenAt: Date,
        accountID: UUID,
        own: Set<String>,
        into map: inout [String: RapSoDeeContact]
    ) {
        let email = normalizeEmail(rawAddress)
        guard isHarvestable(email: email, own: own) else { return }

        let parsedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? extractDisplayName(from: rawAddress)
            : displayName.trimmingCharacters(in: .whitespacesAndNewlines)

        if var existing = map[email] {
            existing.timesSeen += 1
            if seenAt > existing.lastSeen {
                existing.lastSeen = seenAt
                existing.lastAccountID = accountID
            }
            if shouldPreferDisplayName(parsedName, over: existing.displayName, email: email) {
                existing.displayName = parsedName
            }
            map[email] = existing
        } else {
            map[email] = RapSoDeeContact(
                email: email,
                displayName: parsedName,
                lastSeen: seenAt,
                timesSeen: 1,
                lastAccountID: accountID
            )
        }
    }

    // MARK: - Suggest

    /// Rank by frequency + recency; filter by last To/Cc token.
    static func suggestions(
        matching query: String,
        in contacts: [RapSoDeeContact],
        limit: Int = 8
    ) -> [RapSoDeeContact] {
        let token = lastComposeToken(query)
        let q = token.lowercased()
        guard q.count >= 1 else { return [] }

        let now = Date()
        let scored: [(RapSoDeeContact, Double)] = contacts.compactMap { contact in
            let email = contact.email.lowercased()
            let name = contact.displayName.lowercased()
            let matches = email.hasPrefix(q)
                || email.contains(q)
                || name.hasPrefix(q)
                || name.contains(q)
            guard matches else { return nil }
            let days = max(0, now.timeIntervalSince(contact.lastSeen) / 86_400)
            let recency = max(0, 90 - days) // decay over ~3 months
            let score = Double(contact.timesSeen) * 3.0 + recency
            return (contact, score)
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.email < rhs.0.email
            }
            .prefix(limit)
            .map(\.0)
    }

    /// Replace the last comma-separated token with the chosen contact.
    static func applyingSuggestion(_ contact: RapSoDeeContact, toField field: String) -> String {
        let parts = field.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else { return contact.suggestionLabel }
        var mutable = parts
        mutable[mutable.count - 1] = " " + contact.suggestionLabel
        // First token should not start with a leading space if field was empty-ish.
        if mutable.count == 1 {
            return contact.suggestionLabel
        }
        return mutable.joined(separator: ",").trimmingCharacters(in: .whitespaces)
    }

    static func lastComposeToken(_ field: String) -> String {
        let last = field.split(separator: ",").last.map(String.init) ?? field
        return last.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Filters / parse

    static func normalizeEmail(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let start = s.firstIndex(of: "<"), let end = s.firstIndex(of: ">"), start < end {
            s = String(s[s.index(after: start)..<end])
        }
        return s
    }

    static func extractDisplayName(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "<"), start > trimmed.startIndex else { return "" }
        var name = String(trimmed[..<start]).trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 {
            name = String(name.dropFirst().dropLast())
        }
        return name
    }

    static func isHarvestable(email: String, own: Set<String>) -> Bool {
        guard email.contains("@"), email.count >= 5 else { return false }
        if own.contains(email) { return false }
        let local = email.split(separator: "@").first.map(String.init) ?? email
        let blockedLocals: Set<String> = [
            "noreply", "no-reply", "no_reply", "donotreply", "do-not-reply",
            "mailer-daemon", "mailerdaemon", "postmaster", "bounce",
            "notifications", "notification", "alert", "alerts",
        ]
        if blockedLocals.contains(local) { return false }
        if local.hasPrefix("noreply") || local.hasPrefix("no-reply") || local.hasPrefix("donotreply") {
            return false
        }
        if local.contains("mailer-daemon") { return false }
        return true
    }

    private static func shouldPreferDisplayName(_ candidate: String, over existing: String, email: String) -> Bool {
        let c = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty, c.lowercased() != email.lowercased() else { return false }
        let e = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        if e.isEmpty || e.lowercased() == email.lowercased() { return true }
        // Prefer longer human names lightly.
        return c.count > e.count + 2
    }
}
