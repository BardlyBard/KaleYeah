import Foundation

/// Microsoft Graph mail sync / send for Microsoft 365 (modern auth).
enum MicrosoftGraphMailService {
    private static let graphRoot = "https://graph.microsoft.com/v1.0"
    /// Keep list sync small — full HTML bodies were hanging Kale Yeah sync past 60s.
    private static let listLimit = 25

    /// Bounded Graph HTTP — short timeouts so Cancel / Settings never sit forever.
    /// Do NOT call invalidateAndCancel from UI cancel (can race and crash); rely on Task cancellation.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()

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
    ) async throws -> (messages: [MailMessage], result: GraphSyncResult, prunableFolderIDs: Set<UUID>) {
        var all: [MailMessage] = []
        var prunable: Set<UUID> = []
        var folderErrors: [String] = []

        // Fetch folders independently so one failure does not wipe the other via prune.
        do {
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
            prunable.insert(folderIDs.inbox)
        } catch {
            folderErrors.append("Inbox: \(error.localizedDescription)")
        }

        do {
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
            prunable.insert(folderIDs.sent)
        } catch {
            folderErrors.append("Sent: \(error.localizedDescription)")
        }

        // If every folder fetch failed, surface the error and do NOT return an empty
        // "success" — callers must keep existing mail.
        if prunable.isEmpty {
            let detail = folderErrors.isEmpty ? "No folders synced" : folderErrors.joined(separator: " | ")
            throw GraphError.unexpected("Graph sync failed — \(detail)")
        }

        var status = "Synced \(all.count) messages via Microsoft Graph"
        if prunable.contains(folderIDs.inbox) && prunable.contains(folderIDs.sent) {
            status += " (Inbox + Sent)"
        } else if prunable.contains(folderIDs.inbox) {
            status += " (Inbox only)"
        } else {
            status += " (Sent only)"
        }
        if !folderErrors.isEmpty {
            status += " — partial: \(folderErrors.joined(separator: " | "))"
        }
        let result = GraphSyncResult(
            foldersFetched: prunable.count,
            messagesFetched: all.count,
            status: status,
            signedInEmail: accountEmail
        )
        return (all, result, prunable)
    }


    /// Fetch full body for one message (reading pane). Safe to call after lightweight list sync.
    static func fetchMessageBody(accessToken: String, graphMessageID: String) async throws -> (body: String, isHTML: Bool) {
        struct GraphBodyOnly: Decodable {
            var body: GraphBody?
        }
        let encoded = graphMessageID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? graphMessageID
        let detail: GraphBodyOnly = try await getJSON(
            path: "/me/messages/\(encoded)",
            accessToken: accessToken,
            query: ["$select": "id,body"]
        )
        let contentType = (detail.body?.contentType ?? "text").lowercased()
        let content = detail.body?.content ?? ""
        guard !content.isEmpty else {
            throw GraphError.unexpected("Graph returned an empty message body")
        }
        return (content, contentType == "html")
    }

    // MARK: - Send

    /// Sends via Graph. Uses mailbox identity of the signed-in `/me` user — never sets `from`
    /// (spoofed From triggers outbound filters / NDR 550 5.7.708). Replies with a Graph
    /// `remoteID` use createReply/createReplyAll → PATCH → send. New mail uses
    /// POST `/me/messages` (draft) → POST `/me/messages/{id}/send` (closer to Outlook compose
    /// than one-shot `/me/sendMail`, which can be treated more harshly for consumer destinations).
    /// Returns a short status line for the UI (no message body).
    @discardableResult
    static func sendMail(
        accessToken: String,
        draft: ComposeDraft,
        fromEmail: String,
        mailboxEmail: String,
        signature: String?
    ) async throws -> String {
        var bodyText = draft.body
        if let signature, !signature.isEmpty, !bodyText.contains(signature) {
            bodyText += "\n\n--\n" + signature
        }
        let to = parseAddressList(draft.to)
        let cc = parseAddressList(draft.cc)
        guard !to.isEmpty else { throw GraphError.unexpected("Add at least one To recipient") }

        let mailbox = mailboxEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        // fromEmail retained for API compatibility / status; never written into Graph payload.
        _ = fromEmail

        if case .reply(let original) = draft.mode,
           let remoteID = original.remoteID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !remoteID.isEmpty {
            try await sendReplyViaCreateReply(
                accessToken: accessToken,
                originalGraphID: remoteID,
                replyAll: false,
                subject: draft.subject,
                bodyText: bodyText,
                to: to,
                cc: cc,
                attachments: draft.attachments
            )
            return sendStatusSummary(
                path: "createReply→send",
                mailbox: mailbox,
                to: to,
                attachmentCount: draft.attachments.count
            )
        }
        if case .replyAll(let original) = draft.mode,
           let remoteID = original.remoteID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !remoteID.isEmpty {
            try await sendReplyViaCreateReply(
                accessToken: accessToken,
                originalGraphID: remoteID,
                replyAll: true,
                subject: draft.subject,
                bodyText: bodyText,
                to: to,
                cc: cc,
                attachments: draft.attachments
            )
            return sendStatusSummary(
                path: "createReplyAll→send",
                mailbox: mailbox,
                to: to,
                attachmentCount: draft.attachments.count
            )
        }

        try await sendNewMailViaDraftThenSend(
            accessToken: accessToken,
            subject: draft.subject,
            bodyText: bodyText,
            to: to,
            cc: cc,
            attachments: draft.attachments,
            draft: draft
        )
        return sendStatusSummary(
            path: "draft→send",
            mailbox: mailbox,
            to: to,
            attachmentCount: draft.attachments.count
        )
    }

    /// Create draft via POST /me/messages, then POST /me/messages/{id}/send.
    private static func sendNewMailViaDraftThenSend(
        accessToken: String,
        subject: String,
        bodyText: String,
        to: [String],
        cc: [String],
        attachments: [ComposeAttachment],
        draft: ComposeDraft
    ) async throws {
        var messageObj: [String: Any] = [
            "subject": subject,
            "body": [
                "contentType": "Text",
                "content": bodyText,
            ],
            "toRecipients": recipientObjects(to),
            "ccRecipients": recipientObjects(cc),
        ]
        // Do not set `from` — Graph sends as the signed-in `/me` mailbox.
        if let headers = replyInternetMessageHeaders(for: draft) {
            messageObj["internetMessageHeaders"] = headers
        }
        let createdData = try await postJSON(path: "/me/messages", accessToken: accessToken, body: messageObj)
        struct CreatedDraft: Decodable { var id: String? }
        let created = try JSONDecoder().decode(CreatedDraft.self, from: createdData)
        guard let draftID = created.id?.trimmingCharacters(in: .whitespacesAndNewlines), !draftID.isEmpty else {
            throw GraphError.unexpected("Graph create draft returned no message id")
        }
        let encodedDraft = draftID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? draftID
        if let graphAttachments = fileAttachmentObjects(attachments) {
            for att in graphAttachments {
                _ = try await postJSON(
                    path: "/me/messages/\(encodedDraft)/attachments",
                    accessToken: accessToken,
                    body: att
                )
            }
        }
        _ = try await postJSON(path: "/me/messages/\(encodedDraft)/send", accessToken: accessToken, body: [:])
    }

    /// SMTP AUTH via XOAUTH2 to smtp.office365.com:587 (STARTTLS). Uses a token with
    /// audience/scope `https://outlook.office.com/SMTP.Send` (not the Graph token).
    @discardableResult
    static func sendViaSMTPOAuth(
        accessToken: String,
        mailboxEmail: String,
        draft: ComposeDraft,
        signature: String?
    ) async throws -> String {
        var bodyText = draft.body
        if let signature, !signature.isEmpty, !bodyText.contains(signature) {
            bodyText += "\n\n--\n" + signature
        }
        let to = parseAddressList(draft.to)
        let cc = parseAddressList(draft.cc)
        guard !to.isEmpty else { throw GraphError.unexpected("Add at least one To recipient") }
        let mailbox = mailboxEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mailbox.isEmpty else { throw GraphError.unexpected("No mailbox email for SMTP send") }

        var outbound: [SimpleSMTPClient.OutboundAttachment] = []
        for att in draft.attachments {
            guard let data = AttachmentStore.load(path: att.localPath) else { continue }
            outbound.append(
                .init(
                    filename: att.filename,
                    mimeType: att.mimeType.isEmpty ? "application/octet-stream" : att.mimeType,
                    data: data
                )
            )
        }

        let smtp = SimpleSMTPClient()
        do {
            try await smtp.connect(
                host: MailIMAPProvider.office365.smtpHost,
                port: MailIMAPProvider.office365.smtpPort,
                startTLS: true
            )
            try await smtp.loginXOAuth2(email: mailbox, accessToken: accessToken)
            try await smtp.send(
                from: mailbox,
                to: to,
                cc: cc,
                subject: draft.subject,
                body: bodyText,
                attachments: outbound
            )
            await smtp.quit()
        } catch {
            await smtp.quit()
            throw error
        }
        return sendStatusSummary(
            path: "SMTP XOAUTH2",
            mailbox: mailbox,
            to: to,
            attachmentCount: draft.attachments.count
        )
    }

    private static func sendReplyViaCreateReply(
        accessToken: String,
        originalGraphID: String,
        replyAll: Bool,
        subject: String,
        bodyText: String,
        to: [String],
        cc: [String],
        attachments: [ComposeAttachment]
    ) async throws {
        let encodedID = originalGraphID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? originalGraphID
        let createPath = replyAll
            ? "/me/messages/\(encodedID)/createReplyAll"
            : "/me/messages/\(encodedID)/createReply"
        let createdData = try await postJSON(path: createPath, accessToken: accessToken, body: [:])
        struct CreatedDraft: Decodable { var id: String? }
        let created = try JSONDecoder().decode(CreatedDraft.self, from: createdData)
        guard let draftID = created.id?.trimmingCharacters(in: .whitespacesAndNewlines), !draftID.isEmpty else {
            throw GraphError.unexpected("Graph createReply returned no draft id")
        }
        let encodedDraft = draftID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? draftID
        let patch: [String: Any] = [
            "subject": subject,
            "body": [
                "contentType": "Text",
                "content": bodyText,
            ],
            "toRecipients": recipientObjects(to),
            "ccRecipients": recipientObjects(cc),
        ]
        try await patchJSON(path: "/me/messages/\(encodedDraft)", accessToken: accessToken, body: patch)
        if let graphAttachments = fileAttachmentObjects(attachments) {
            for att in graphAttachments {
                _ = try await postJSON(
                    path: "/me/messages/\(encodedDraft)/attachments",
                    accessToken: accessToken,
                    body: att
                )
            }
        }
        _ = try await postJSON(path: "/me/messages/\(encodedDraft)/send", accessToken: accessToken, body: [:])
    }

    private static func replyInternetMessageHeaders(for draft: ComposeDraft) -> [[String: String]]? {
        let messageIDRaw: String?
        if case .reply(let m) = draft.mode {
            messageIDRaw = m.internetMessageId
        } else if case .replyAll(let m) = draft.mode {
            messageIDRaw = m.internetMessageId
        } else {
            return nil
        }
        guard let messageID = messageIDRaw?.trimmingCharacters(in: .whitespacesAndNewlines), !messageID.isEmpty else {
            return nil
        }
        // Best-effort threading when createReply is unavailable (no Graph remoteID).
        return [
            ["name": "In-Reply-To", "value": messageID],
            ["name": "References", "value": messageID],
        ]
    }

    private static func parseAddressList(_ raw: String) -> [String] {
        raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func recipientObjects(_ addresses: [String]) -> [[String: Any]] {
        addresses.map { ["emailAddress": ["address": $0]] }
    }

    private static func fileAttachmentObjects(_ attachments: [ComposeAttachment]) -> [[String: Any]]? {
        guard !attachments.isEmpty else { return nil }
        var graphAttachments: [[String: Any]] = []
        for att in attachments {
            guard let data = AttachmentStore.load(path: att.localPath) else { continue }
            graphAttachments.append([
                "@odata.type": "#microsoft.graph.fileAttachment",
                "name": att.filename,
                "contentType": att.mimeType.isEmpty ? "application/octet-stream" : att.mimeType,
                "contentBytes": data.base64EncodedString(),
            ])
        }
        return graphAttachments.isEmpty ? nil : graphAttachments
    }

    private static func sendStatusSummary(path: String, mailbox: String, to: [String], attachmentCount: Int) -> String {
        let toPreview = to.prefix(3).joined(separator: ", ")
        let more = to.count > 3 ? " +\(to.count - 3)" : ""
        let att = attachmentCount > 0 ? ", \(attachmentCount) attachment(s)" : ""
        return "Sent via Graph (\(path)) as \(mailbox) → \(toPreview)\(more)\(att)"
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
            var value: [GraphMessage]?
        }
        // Lightweight list only — no `body` (HTML payloads hung sync). Bodies load on open.
        let select = "id,internetMessageId,subject,bodyPreview,from,toRecipients,ccRecipients,receivedDateTime,sentDateTime,isRead,flag,hasAttachments"
        let list: GraphList = try await getJSON(
            path: folderPath,
            accessToken: accessToken,
            query: [
                "$top": "\(listLimit)",
                "$orderby": "receivedDateTime desc",
                "$select": select,
            ]
        )

        var out: [MailMessage] = []
        for gm in list.value ?? [] {
            guard let graphID = gm.id, !graphID.isEmpty else { continue }
            let id = stableMessageID(graphID: graphID)
            var attachments: [MailAttachment] = []
            if gm.hasAttachments == true {
                // Do not call Graph /attachments during list sync — N extra round-trips
                // (and contentBytes) blew the Office365 timeout and left Kale Yeah empty.
                // Stub keeps the "Has attachments" filter working; full bodies load on open.
                attachments = [
                    MailAttachment(
                        id: UUID(),
                        filename: "Attachment",
                        mimeType: "application/octet-stream",
                        byteSize: 0,
                        localPath: nil,
                        remoteID: nil
                    )
                ]
            }
            out.append(
                mapMessage(
                    gm,
                    accountID: accountID,
                    folderID: folderID,
                    accountEmail: accountEmail,
                    isDraft: isDraft,
                    messageID: id,
                    remoteID: graphID,
                    attachments: attachments
                )
            )
        }
        return out
    }

    private static func fetchFileAttachments(
        messageGraphID: String,
        accessToken: String,
        mailMessageID: UUID,
        includeBytes: Bool = true
    ) async throws -> [MailAttachment] {
        struct GraphAttachmentList: Decodable {
            var value: [GraphAttachment]?
        }
        let encodedID = messageGraphID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? messageGraphID
        // Metadata-only during inbox sync — contentBytes payloads are huge and slow.
        let query: [String: String] = includeBytes
            ? [:]
            : ["$select": "id,name,contentType,size,@odata.type"]
        let list: GraphAttachmentList = try await getJSON(
            path: "/me/messages/\(encodedID)/attachments",
            accessToken: accessToken,
            query: query
        )
        var result: [MailAttachment] = []
        for item in list.value ?? [] {
            let typeName = (item.odataType ?? "").lowercased()
            guard typeName.contains("fileattachment") else { continue }
            let filename = (item.name ?? "attachment").trimmingCharacters(in: .whitespacesAndNewlines)
            let mime = item.contentType ?? AttachmentStore.mimeType(forFilename: filename)
            var localPath: String? = nil
            var byteSize = item.size ?? 0
            if includeBytes,
               let b64 = item.contentBytes, !b64.isEmpty,
               let data = Data(base64Encoded: b64, options: [.ignoreUnknownCharacters]) {
                byteSize = data.count
                localPath = try? AttachmentStore.save(data: data, filename: filename, messageID: mailMessageID)
            }
            result.append(
                MailAttachment(
                    id: UUID(),
                    filename: filename.isEmpty ? "attachment" : filename,
                    mimeType: mime,
                    byteSize: byteSize,
                    localPath: localPath,
                    remoteID: item.id
                )
            )
        }
        return result
    }

    private static func mapMessage(
        _ gm: GraphMessage,
        accountID: UUID,
        folderID: UUID,
        accountEmail: String,
        isDraft: Bool,
        messageID: UUID,
        remoteID: String,
        attachments: [MailAttachment]
    ) -> MailMessage {
        let fromAddr = gm.from?.emailAddress?.address ?? ""
        let fromName = gm.from?.emailAddress?.name ?? fromAddr
        let to = (gm.toRecipients ?? []).compactMap { $0.emailAddress?.address }
        let cc = (gm.ccRecipients ?? []).compactMap { $0.emailAddress?.address }
        let subject = gm.subject ?? "(no subject)"
        let snippet = gm.bodyPreview ?? ""
        // List sync omits `body`; preview is enough for the message list. Full body fetched on open.
        let contentType = (gm.body?.contentType ?? "text").lowercased()
        let hasFullBody = !(gm.body?.content ?? "").isEmpty
        let isHTML = hasFullBody && contentType == "html"
        let body = hasFullBody ? (gm.body?.content ?? snippet) : snippet
        let date = gm.receivedDateTime.flatMap(parseGraphDate)
            ?? gm.sentDateTime.flatMap(parseGraphDate)
            ?? Date()
        let flagged = (gm.flag?.flagStatus ?? "").lowercased() == "flagged"
        let internetId = gm.internetMessageId?.trimmingCharacters(in: .whitespacesAndNewlines)

        return MailMessage(
            id: messageID,
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
            attachments: attachments,
            deliveredTo: accountEmail,
            disposition: .normal,
            isDraft: isDraft,
            remoteID: remoteID,
            internetMessageId: (internetId?.isEmpty == false) ? internetId : nil
        )
    }

    /// Stable local UUID derived only from Graph id (immutable when Prefer IdType=ImmutableId).
    private static func stableMessageID(graphID: String) -> UUID {
        let raw = "rapsodee.graph.office365|\(graphID)"
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
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("IdType=\"ImmutableId\"", forHTTPHeaderField: "Prefer")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw mapSessionError(error)
        }
        try throwIfNeeded(response: response, data: data)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw GraphError.unexpected("Decode failed: \(error.localizedDescription)")
        }
    }

    @discardableResult
    private static func postJSON(path: String, accessToken: String, body: [String: Any]) async throws -> Data {
        try await sendJSON(method: "POST", path: path, accessToken: accessToken, body: body)
    }

    @discardableResult
    private static func patchJSON(path: String, accessToken: String, body: [String: Any]) async throws -> Data {
        try await sendJSON(method: "PATCH", path: path, accessToken: accessToken, body: body)
    }

    private static func sendJSON(method: String, path: String, accessToken: String, body: [String: Any]) async throws -> Data {
        let url = try makeURL(path: path, query: [:])
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("IdType=\"ImmutableId\"", forHTTPHeaderField: "Prefer")
        // Empty body (e.g. createReply / send) still needs a JSON object for Graph.
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw mapSessionError(error)
        }
        try throwIfNeeded(response: response, data: data)
        return data
    }

    private static func throwIfNeeded(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw GraphError.http(http.statusCode, text)
        }
    }

    /// Pull Graph `error.message` / `code` for UI; never include mail body.
    static func summarizeGraphErrorBody(_ body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "(no error body)" }
        if let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let err = obj["error"] as? [String: Any]
            let code = (err?["code"] as? String) ?? (obj["code"] as? String)
            let message = (err?["message"] as? String) ?? (obj["message"] as? String)
            var parts: [String] = []
            if let code, !code.isEmpty { parts.append(code) }
            if let message, !message.isEmpty { parts.append(message) }
            if !parts.isEmpty {
                let joined = parts.joined(separator: " — ")
                return String(joined.prefix(400))
            }
        }
        return String(trimmed.prefix(400))
    }

    enum GraphError: LocalizedError {
        case unexpected(String)
        case http(Int, String)
        case timedOut(String)
        var errorDescription: String? {
            switch self {
            case .unexpected(let s): return s
            case .http(let code, let body):
                return "Graph HTTP \(code): \(MicrosoftGraphMailService.summarizeGraphErrorBody(body))"
            case .timedOut(let s): return s
            }
        }
    }

    private static func mapSessionError(_ error: Error) -> Error {
        if error is CancellationError { return error }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
            return CancellationError()
        }
        if ns.domain == NSURLErrorDomain,
           ns.code == NSURLErrorTimedOut
            || ns.code == NSURLErrorNetworkConnectionLost
            || ns.code == NSURLErrorNotConnectedToInternet {
            return GraphError.timedOut("Microsoft Graph request timed out. Try Sync now again.")
        }
        return error
    }
}

// MARK: - Graph DTOs

private struct GraphMessage: Decodable {
    var id: String?
    var internetMessageId: String?
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

private struct GraphAttachment: Decodable {
    var id: String?
    var name: String?
    var contentType: String?
    var size: Int?
    var contentBytes: String?
    var odataType: String?

    enum CodingKeys: String, CodingKey {
        case id, name, contentType, size, contentBytes
        case odataType = "@odata.type"
    }
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
