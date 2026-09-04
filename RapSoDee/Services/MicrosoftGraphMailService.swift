import Foundation

/// Microsoft Graph mail sync / send for Microsoft 365 (modern auth).
enum MicrosoftGraphMailService {
    private static let graphRoot = "https://graph.microsoft.com/v1.0"
    private static let recentLimit = Office365Defaults.recentLimit

    struct GraphSyncResult {
        var foldersFetched: Int
        var messagesFetched: Int
        var status: String
        var signedInEmail: String
    }

    // MARK: - Profile

    static func fetchSignedInEmail(accessToken: String) async throws -> String {
        struct Me: Decodable {
            var mail: String?
            var userPrincipalName: String?
        }
        let me: Me = try await getJSON(path: "/me", accessToken: accessToken, query: ["$select": "mail,userPrincipalName"])
        let email = (me.mail ?? me.userPrincipalName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else {
            throw GraphError.unexpected("Signed-in profile has no email")
        }
        return email
    }

    // MARK: - Sync

    static func sync(
        accessToken: String,
        accountID: UUID,
        folderIDs: IMAPFolderIDs,
        accountEmail: String
    ) async throws -> (messages: [MailMessage], result: GraphSyncResult) {
        var all: [MailMessage] = []

        let inbox = try await listFolderMessages(
            folderPath: "/me/mailFolders/inbox/messages",
            accessToken: accessToken,
            accountID: accountID,
            folderID: folderIDs.inbox,
            accountEmail: accountEmail,
            mailboxKey: "inbox",
            isDraft: false
        )
        all.append(contentsOf: inbox)

        let sent = try await listFolderMessages(
            folderPath: "/me/mailFolders/sentitems/messages",
            accessToken: accessToken,
            accountID: accountID,
            folderID: folderIDs.sent,
            accountEmail: accountEmail,
            mailboxKey: "sentitems",
            isDraft: false
        )
        all.append(contentsOf: sent)

        let result = GraphSyncResult(
            foldersFetched: 2,
            messagesFetched: all.count,
            status: "Synced \(all.count) messages via Microsoft Graph (Inbox + Sent)",
            signedInEmail: accountEmail
        )
        return (all, result)
    }

    // MARK: - Send

    static func sendMail(
        accessToken: String,
        draft: ComposeDraft,
        fromEmail: String,
        signature: String?
    ) async throws {
        var bodyText = draft.body
        if let signature, !signature.isEmpty, !bodyText.contains(signature) {
            bodyText += "\n\n--\n" + signature
        }
        let to = draft.to.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let cc = draft.cc.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !to.isEmpty else { throw GraphError.unexpected("Add at least one To recipient") }

        let payload: [String: Any] = [
            "message": [
                "subject": draft.subject,
                "body": [
                    "contentType": "Text",
                    "content": bodyText,
                ],
                "toRecipients": to.map { ["emailAddress": ["address": $0]] },
                "ccRecipients": cc.map { ["emailAddress": ["address": $0]] },
                "from": ["emailAddress": ["address": fromEmail]],
            ] as [String: Any],
            "saveToSentItems": true,
        ]

        try await postJSON(path: "/me/sendMail", accessToken: accessToken, body: payload)
    }

    // MARK: - Internals

    private static func listFolderMessages(
        folderPath: String,
        accessToken: String,
        accountID: UUID,
        folderID: UUID,
        accountEmail: String,
        mailboxKey: String,
        isDraft: Bool
    ) async throws -> [MailMessage] {
        struct GraphList: Decodable {
            var value: [GraphMessage]
        }
        let select = "id,subject,bodyPreview,body,from,toRecipients,ccRecipients,receivedDateTime,sentDateTime,isRead,flag,hasAttachments"
        let list: GraphList = try await getJSON(
            path: folderPath,
            accessToken: accessToken,
            query: [
                "$top": "\(recentLimit)",
                "$orderby": "receivedDateTime desc",
                "$select": select,
            ]
        )

        return list.value.map { gm in
            mapMessage(
                gm,
                accountID: accountID,
                folderID: folderID,
                accountEmail: accountEmail,
                mailboxKey: mailboxKey,
                isDraft: isDraft
            )
        }
    }

    private static func mapMessage(
        _ gm: GraphMessage,
        accountID: UUID,
        folderID: UUID,
        accountEmail: String,
        mailboxKey: String,
        isDraft: Bool
    ) -> MailMessage {
        let fromAddr = gm.from?.emailAddress?.address ?? ""
        let fromName = gm.from?.emailAddress?.name ?? fromAddr
        let to = (gm.toRecipients ?? []).compactMap { $0.emailAddress?.address }
        let cc = (gm.ccRecipients ?? []).compactMap { $0.emailAddress?.address }
        let subject = gm.subject ?? "(no subject)"
        let snippet = gm.bodyPreview ?? ""
        let contentType = (gm.body?.contentType ?? "text").lowercased()
        let isHTML = contentType == "html"
        let body = gm.body?.content ?? snippet
        let date = gm.receivedDateTime.flatMap(parseGraphDate)
            ?? gm.sentDateTime.flatMap(parseGraphDate)
            ?? Date()
        let flagged = (gm.flag?.flagStatus ?? "").lowercased() == "flagged"
        let id = stableMessageID(email: accountEmail, mailbox: mailboxKey, graphID: gm.id ?? UUID().uuidString)

        return MailMessage(
            id: id,
            accountID: accountID,
            folderID: folderID,
            fromName: fromName,
            fromAddress: fromAddr,
            toAddresses: to.isEmpty ? [accountEmail] : to,
            ccAddresses: cc,
            subject: subject,
            snippet: snippet,
            body: body,
            isHTML: isHTML,
            receivedAt: date,
            isRead: gm.isRead ?? false,
            isFlagged: flagged,
            deliveredTo: accountEmail,
            disposition: .normal,
            isDraft: isDraft
        )
    }

    private static func stableMessageID(email: String, mailbox: String, graphID: String) -> UUID {
        let raw = "rapsodee.graph.office365|\(email.lowercased())|\(mailbox)|\(graphID)"
        var hash = [UInt8](repeating: 0, count: 16)
        let bytes = Array(raw.utf8)
        for (i, b) in bytes.enumerated() {
            hash[i % 16] ^= b &+ UInt8(i % 251)
        }
        hash[6] = (hash[6] & 0x0F) | 0x40
        hash[8] = (hash[8] & 0x3F) | 0x80
        return UUID(uuid: (
            hash[0], hash[1], hash[2], hash[3],
            hash[4], hash[5], hash[6], hash[7],
            hash[8], hash[9], hash[10], hash[11],
            hash[12], hash[13], hash[14], hash[15]
        ))
    }

    private static func parseGraphDate(_ raw: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: raw) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: raw)
    }

    private static func makeURL(path: String, query: [String: String]) throws -> URL {
        var comps = URLComponents(string: graphRoot + (path.hasPrefix("/") ? path : "/" + path))!
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else { throw GraphError.unexpected("Bad Graph URL") }
        return url
    }

    private static func getJSON<T: Decodable>(path: String, accessToken: String, query: [String: String] = [:]) async throws -> T {
        let url = try makeURL(path: path, query: query)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        try throwIfNeeded(response: response, data: data)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw GraphError.unexpected("Decode failed: \(error.localizedDescription)")
        }
    }

    private static func postJSON(path: String, accessToken: String, body: [String: Any]) async throws {
        let url = try makeURL(path: path, query: [:])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try throwIfNeeded(response: response, data: data)
    }

    private static func throwIfNeeded(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw GraphError.http(http.statusCode, text)
        }
    }

    enum GraphError: LocalizedError {
        case unexpected(String)
        case http(Int, String)
        var errorDescription: String? {
            switch self {
            case .unexpected(let s): return s
            case .http(let code, let body):
                if body.count < 500 { return "Graph HTTP \(code): \(body)" }
                return "Graph HTTP \(code)"
            }
        }
    }
}

// MARK: - Graph DTOs

private struct GraphMessage: Decodable {
    var id: String?
    var subject: String?
    var bodyPreview: String?
    var body: GraphBody?
    var from: GraphRecipient?
    var toRecipients: [GraphRecipient]?
    var ccRecipients: [GraphRecipient]?
    var receivedDateTime: String?
    var sentDateTime: String?
    var isRead: Bool?
    var flag: GraphFlag?
    var hasAttachments: Bool?
}

private struct GraphBody: Decodable {
    var contentType: String?
    var content: String?
}

private struct GraphRecipient: Decodable {
    var emailAddress: GraphEmailAddress?
}

private struct GraphEmailAddress: Decodable {
    var name: String?
    var address: String?
}

private struct GraphFlag: Decodable {
    var flagStatus: String?
}
