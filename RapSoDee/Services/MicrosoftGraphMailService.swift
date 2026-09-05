import Foundation

/// Microsoft Graph mail sync / send for Microsoft 365 (modern auth).
enum MicrosoftGraphMailService {
    private static let graphRoot = "https://graph.microsoft.com/v1.0"
    /// Cap for lightweight list sync — matches MailMessageCache.maxCachedMessages.
    /// Full HTML bodies are NOT fetched here (bodies load on open); pagination follows @odata.nextLink.
    private static let listLimit = 200
    /// Per-request page size — keep well under listLimit so a single Graph response stays
    /// inside URLSession timeouts; follow nextLink until listLimit. ($top=listLimit=200
    /// routinely blew the prior 45s hard sync deadline across Inbox+Sent.)
    private static let pageSize = 50

    /// List/sync HTTP — sized for pageSize×pages (Cancel still uses Task cancellation).
    /// Do NOT call invalidateAndCancel from UI cancel (can race and crash); rely on Task cancellation.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 90
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()

    /// Longer timeouts for EML import (MIME / attachments).
    private static let importSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = false
        // Serial EML uploads — IncomingBytes throttle is app-wide.
        config.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: config)
    }()

    struct GraphSyncResult {
        var foldersFetched: Int
        var messagesFetched: Int
        var status: String
        var signedInEmail: String
    }

    /// Lightweight Graph mailFolder row for ladder / import picker upsert.
    struct GraphRemoteFolder: Sendable, Hashable {
        var id: String
        var displayName: String
        var parentFolderId: String?
        var childFolderCount: Int
        var totalItemCount: Int
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
        accountEmail: String,
        extraMessageFolders: [(localFolderID: UUID, graphFolderID: String)] = []
    ) async throws -> (
        messages: [MailMessage],
        result: GraphSyncResult,
        prunableFolderIDs: Set<UUID>,
        remoteFolders: [GraphRemoteFolder]
    ) {
        var all: [MailMessage] = []
        var prunable: Set<UUID> = []
        var folderErrors: [String] = []

        // Folder tree listing is required for the ladder / import picker even when
        // message sync stays limited to well-known + recently used targets.
        var remoteFolders: [GraphRemoteFolder] = []
        do {
            remoteFolders = try await listMailFolderTree(accessToken: accessToken)
        } catch {
            folderErrors.append("Folders: \(error.localizedDescription)")
        }

        // Fetch Inbox + Sent + Archive in parallel (independent failures — one miss must not prune the other).
        await withTaskGroup(of: (name: String, folderID: UUID, result: Result<[MailMessage], Error>).self) { group in
            group.addTask {
                do {
                    let msgs = try await listFolderMessages(
                        folderPath: "/me/mailFolders/inbox/messages",
                        accessToken: accessToken,
                        accountID: accountID,
                        folderID: folderIDs.inbox,
                        accountEmail: accountEmail,
                        mailboxKey: "inbox",
                        isDraft: false
                    )
                    return ("Inbox", folderIDs.inbox, .success(msgs))
                } catch {
                    return ("Inbox", folderIDs.inbox, .failure(error))
                }
            }
            group.addTask {
                do {
                    let msgs = try await listFolderMessages(
                        folderPath: "/me/mailFolders/sentitems/messages",
                        accessToken: accessToken,
                        accountID: accountID,
                        folderID: folderIDs.sent,
                        accountEmail: accountEmail,
                        mailboxKey: "sentitems",
                        isDraft: false
                    )
                    return ("Sent", folderIDs.sent, .success(msgs))
                } catch {
                    return ("Sent", folderIDs.sent, .failure(error))
                }
            }
            group.addTask {
                do {
                    let msgs = try await listFolderMessages(
                        folderPath: "/me/mailFolders/archive/messages",
                        accessToken: accessToken,
                        accountID: accountID,
                        folderID: folderIDs.archive,
                        accountEmail: accountEmail,
                        mailboxKey: "archive",
                        isDraft: false
                    )
                    return ("Archive", folderIDs.archive, .success(msgs))
                } catch {
                    return ("Archive", folderIDs.archive, .failure(error))
                }
            }
            for extra in extraMessageFolders {
                let localID = extra.localFolderID
                let graphID = extra.graphFolderID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !graphID.isEmpty else { continue }
                group.addTask {
                    do {
                        let enc = graphID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? graphID
                        let msgs = try await listFolderMessages(
                            folderPath: "/me/mailFolders/\(enc)/messages",
                            accessToken: accessToken,
                            accountID: accountID,
                            folderID: localID,
                            accountEmail: accountEmail,
                            mailboxKey: graphID,
                            isDraft: false
                        )
                        return ("Custom", localID, .success(msgs))
                    } catch {
                        return ("Custom", localID, .failure(error))
                    }
                }
            }
            for await item in group {
                switch item.result {
                case .success(let msgs):
                    all.append(contentsOf: msgs)
                    prunable.insert(item.folderID)
                case .failure(let error):
                    folderErrors.append("\(item.name): \(error.localizedDescription)")
                }
            }
        }

        // If every folder fetch failed AND we got no folder names either, surface the error.
        // Callers must keep existing mail (do not prune on failed fetch).
        if prunable.isEmpty && remoteFolders.isEmpty {
            let detail = folderErrors.isEmpty ? "No folders synced" : folderErrors.joined(separator: " | ")
            throw GraphError.unexpected("Graph sync failed — \(detail)")
        }

        var status = "Synced \(all.count) messages via Microsoft Graph"
        var parts: [String] = []
        if prunable.contains(folderIDs.inbox) { parts.append("Inbox") }
        if prunable.contains(folderIDs.sent) { parts.append("Sent") }
        if prunable.contains(folderIDs.archive) { parts.append("Archive") }
        let customCount = prunable.subtracting([folderIDs.inbox, folderIDs.sent, folderIDs.archive, folderIDs.drafts, folderIDs.trash]).count
        if customCount > 0 { parts.append("\(customCount) custom") }
        if !parts.isEmpty {
            status += " (" + parts.joined(separator: " + ") + ")"
        }
        if !remoteFolders.isEmpty {
            status += " · \(remoteFolders.count) folders"
        }
        if !folderErrors.isEmpty {
            status += " — partial: \(folderErrors.joined(separator: " | "))"
        }
        let result = GraphSyncResult(
            foldersFetched: max(prunable.count, remoteFolders.isEmpty ? 0 : 1),
            messagesFetched: all.count,
            status: status,
            signedInEmail: accountEmail
        )
        return (all, result, prunable, remoteFolders)
    }

    // MARK: - Mail folders

    /// Recursively list mailbox folders (root + children) for ladder / import picker.
    static func listMailFolderTree(accessToken: String) async throws -> [GraphRemoteFolder] {
        var collected: [GraphRemoteFolder] = []
        var seen = Set<String>()
        var queue: [String?] = [nil] // nil = root /me/mailFolders
        while !queue.isEmpty {
            try Task.checkCancellation()
            let parent = queue.removeFirst()
            let page = try await listMailFoldersPage(accessToken: accessToken, parentFolderID: parent)
            for folder in page {
                let id = folder.id.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty, seen.insert(id).inserted else { continue }
                collected.append(folder)
                if folder.childFolderCount > 0 {
                    queue.append(id)
                }
            }
        }
        return collected
    }

    private static func listMailFoldersPage(accessToken: String, parentFolderID: String?) async throws -> [GraphRemoteFolder] {
        struct GraphFolderList: Decodable {
            var value: [GraphFolderDTO]?
            var nextLink: String?
            enum CodingKeys: String, CodingKey {
                case value
                case nextLink = "@odata.nextLink"
            }
        }
        let path: String
        if let parentFolderID, !parentFolderID.isEmpty {
            let enc = parentFolderID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? parentFolderID
            path = "/me/mailFolders/\(enc)/childFolders"
        } else {
            path = "/me/mailFolders"
        }
        var nextURL: URL? = try makeURL(
            path: path,
            query: [
                "$top": "100",
                "$select": "id,displayName,parentFolderId,childFolderCount,totalItemCount",
            ]
        )
        var out: [GraphRemoteFolder] = []
        while let url = nextURL {
            try Task.checkCancellation()
            let list: GraphFolderList = try await getJSON(url: url, accessToken: accessToken)
            for dto in list.value ?? [] {
                guard let id = dto.id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { continue }
                let name = (dto.displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                out.append(
                    GraphRemoteFolder(
                        id: id,
                        displayName: name.isEmpty ? "(unnamed)" : name,
                        parentFolderId: dto.parentFolderId,
                        childFolderCount: dto.childFolderCount ?? 0,
                        totalItemCount: dto.totalItemCount ?? 0
                    )
                )
            }
            if let link = list.nextLink?.trimmingCharacters(in: .whitespacesAndNewlines),
               !link.isEmpty,
               let parsed = URL(string: link) {
                nextURL = parsed
            } else {
                nextURL = nil
            }
        }
        return out
    }

    /// Create a mail folder at mailbox root, or as a child of `parentFolderID`.
    @discardableResult
    static func createMailFolder(
        accessToken: String,
        displayName: String,
        parentFolderID: String? = nil
    ) async throws -> GraphRemoteFolder {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw GraphError.unexpected("Folder name required") }
        let path: String
        if let parent = parentFolderID?.trimmingCharacters(in: .whitespacesAndNewlines), !parent.isEmpty {
            let enc = parent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? parent
            path = "/me/mailFolders/\(enc)/childFolders"
        } else {
            path = "/me/mailFolders"
        }
        let data = try await postJSON(
            path: path,
            accessToken: accessToken,
            body: ["displayName": name, "isHidden": false]
        )
        struct Created: Decodable {
            var id: String?
            var displayName: String?
            var parentFolderId: String?
            var childFolderCount: Int?
            var totalItemCount: Int?
        }
        let created = try JSONDecoder().decode(Created.self, from: data)
        guard let id = created.id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            throw GraphError.unexpected("Create folder returned no id")
        }
        return GraphRemoteFolder(
            id: id,
            displayName: (created.displayName ?? name).trimmingCharacters(in: .whitespacesAndNewlines),
            parentFolderId: created.parentFolderId,
            childFolderCount: created.childFolderCount ?? 0,
            totalItemCount: created.totalItemCount ?? 0
        )
    }

    /// Rename a Graph mail folder when the remote id is known.
    static func renameMailFolder(
        accessToken: String,
        folderID: String,
        displayName: String
    ) async throws {
        let id = folderID.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw GraphError.unexpected("Missing folder id") }
        guard !name.isEmpty else { throw GraphError.unexpected("Folder name required") }
        let enc = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        _ = try await patchJSON(
            path: "/me/mailFolders/\(enc)",
            accessToken: accessToken,
            body: ["displayName": name]
        )
    }

    /// Map common display names (Zoho / local disk trees) onto Graph well-known folder names.
    static func mapDiskFolderNameToWellKnown(_ name: String) -> String? {
        switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "inbox", "in box":
            return "inbox"
        case "sent", "sent items", "sentitems", "sent mail", "sentmail":
            return "sentitems"
        case "drafts", "draft":
            return "drafts"
        case "archive", "archived":
            return "archive"
        case "trash", "deleted", "deleted items", "deleteditems":
            return "deleteditems"
        case "junk", "junk email", "junkemail", "spam":
            return "junkemail"
        default:
            return nil
        }
    }

    static func wellKnownGraphName(for kind: FolderKind) -> String? {
        switch kind {
        case .inbox: return "inbox"
        case .sent: return "sentitems"
        case .drafts: return "drafts"
        case .archive: return "archive"
        case .trash: return "deleteditems"
        case .junk: return "junkemail"
        default: return nil
        }
    }

    static func folderKind(forDisplayName name: String) -> FolderKind? {
        guard let well = mapDiskFolderNameToWellKnown(name) else { return nil }
        switch well {
        case "inbox": return .inbox
        case "sentitems": return .sent
        case "drafts": return .drafts
        case "archive": return .archive
        case "deleteditems": return .trash
        case "junkemail": return .junk
        default: return nil
        }
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


    // MARK: - Delete

    /// Move a message to Deleted Items (soft delete). Falls back to hard DELETE if move fails.
    static func deleteMessage(accessToken: String, graphMessageID: String, permanent: Bool = false) async throws {
        let trimmed = graphMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GraphError.unexpected("Missing Graph message id for delete")
        }
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed
        if permanent {
            try await deleteHTTP(path: "/me/messages/\(encoded)", accessToken: accessToken)
            return
        }
        do {
            _ = try await postJSON(
                path: "/me/messages/\(encoded)/move",
                accessToken: accessToken,
                body: ["destinationId": "deleteditems"]
            )
        } catch {
            // Already gone or move unsupported — try hard delete once.
            try await deleteHTTP(path: "/me/messages/\(encoded)", accessToken: accessToken)
        }
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


    // MARK: - EML import

    /// True when a message with this `internetMessageId` already exists in the mailbox.
    static func messageExists(accessToken: String, internetMessageId: String) async throws -> Bool {
        let mid = internetMessageId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mid.isEmpty else { return false }
        // OData string literal: escape single quotes by doubling.
        let escaped = mid.replacingOccurrences(of: "'", with: "''")
        struct GraphList: Decodable { var value: [GraphIDOnly]? }
        struct GraphIDOnly: Decodable { var id: String? }
        let list: GraphList = try await getJSON(
            path: "/me/messages",
            accessToken: accessToken,
            query: [
                "$filter": "internetMessageId eq '\(escaped)'",
                "$select": "id",
                "$top": "1",
            ]
        )
        return (list.value?.isEmpty == false)
    }

    /// Import one parsed EML into a mail folder.
    /// Prefers Graph MIME create (base64 RFC822) when the folder endpoint accepts it; otherwise
    /// falls back to JSON message create. Uses `singleValueExtendedProperties` Integer 0x0E07=4
    /// so the item is not left as a draft (Graph create defaults to isDraft=true).
    @discardableResult
    static func importEML(
        accessToken: String,
        folderID: String,
        parsed: ParsedEML
    ) async throws -> String {
        let folder = folderID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folder.isEmpty else { throw GraphError.unexpected("Missing destination folder") }

        // 1) Prefer MIME → draft on /me/messages, then re-create in folder as non-draft JSON.
        // Folder MIME create often returns UnableToDeserializePostBody; /me/messages MIME works.
        do {
            let draftID = try await createMIMEDraft(accessToken: accessToken, mimeData: parsed.rawMIME)
            do {
                let createdID = try await recreateDraftAsNonDraftInFolder(
                    accessToken: accessToken,
                    draftID: draftID,
                    folderID: folder,
                    parsed: parsed
                )
                try? await deleteHTTP(
                    path: "/me/messages/\(draftID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? draftID)",
                    accessToken: accessToken
                )
                return createdID
            } catch {
                // Clean up orphan draft, then fall through to JSON parse path.
                try? await deleteHTTP(
                    path: "/me/messages/\(draftID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? draftID)",
                    accessToken: accessToken
                )
                throw error
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GraphError where error.isThrottled {
            // Do not burn more IncomingBytes with a JSON fallback while throttled.
            throw error
        } catch {
            // MIME path unavailable — parse-based JSON create.
            return try await createParsedMessageInFolder(
                accessToken: accessToken,
                folderID: folder,
                parsed: parsed
            )
        }
    }

    private static func createMIMEDraft(accessToken: String, mimeData: Data) async throws -> String {
        let url = try makeURL(path: "/me/messages", query: [:])
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("IdType=\"ImmutableId\"", forHTTPHeaderField: "Prefer")
        // Graph MIME create expects the entire RFC822 payload base64-encoded as the body.
        request.httpBody = mimeData.base64EncodedString().data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await importSession.data(for: request)
        } catch {
            throw mapSessionError(error)
        }
        try throwIfNeeded(response: response, data: data)
        struct Created: Decodable { var id: String? }
        let created = try JSONDecoder().decode(Created.self, from: data)
        guard let id = created.id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            throw GraphError.unexpected("MIME create returned no message id")
        }
        return id
    }

    private static func recreateDraftAsNonDraftInFolder(
        accessToken: String,
        draftID: String,
        folderID: String,
        parsed: ParsedEML
    ) async throws -> String {
        let encoded = draftID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? draftID
        // Fetch draft fields Graph already parsed from MIME.
        struct DraftDetail: Decodable {
            var subject: String?
            var body: GraphBody?
            var from: GraphRecipient?
            var toRecipients: [GraphRecipient]?
            var ccRecipients: [GraphRecipient]?
            var internetMessageId: String?
            var isRead: Bool?
            var hasAttachments: Bool?
        }
        let detail: DraftDetail = try await getJSON(
            path: "/me/messages/\(encoded)",
            accessToken: accessToken,
            query: [
                "$select": "id,subject,body,from,toRecipients,ccRecipients,internetMessageId,isRead,hasAttachments,receivedDateTime,sentDateTime",
            ]
        )

        var message = graphJSONMessage(
            subject: detail.subject ?? parsed.subject,
            bodyContent: detail.body?.content ?? parsed.body,
            bodyIsHTML: (detail.body?.contentType ?? "").lowercased() == "html" || parsed.isHTML,
            fromName: detail.from?.emailAddress?.name ?? parsed.fromName,
            fromAddress: detail.from?.emailAddress?.address ?? parsed.fromAddress,
            to: mapRecipients(detail.toRecipients) ?? parsed.to,
            cc: mapRecipients(detail.ccRecipients) ?? parsed.cc,
            internetMessageId: detail.internetMessageId ?? parsed.internetMessageId,
            received: parsed.receivedDate,
            sent: parsed.sentDate,
            isRead: detail.isRead ?? parsed.isRead,
            undraft: true
        )

        // Attachments from the draft (with bytes) when present; else from parsed EML.
        var attachments: [[String: Any]] = []
        if detail.hasAttachments == true {
            attachments = try await fetchDraftFileAttachmentPayloads(draftID: draftID, accessToken: accessToken)
        }
        if attachments.isEmpty {
            attachments = fileAttachmentPayloads(from: parsed.attachments)
        }
        if !attachments.isEmpty {
            message["attachments"] = attachments
        }

        let folderEnc = folderID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? folderID
        let createdData = try await postJSONImport(
            path: "/me/mailFolders/\(folderEnc)/messages",
            accessToken: accessToken,
            body: message
        )
        struct Created: Decodable { var id: String? }
        let created = try JSONDecoder().decode(Created.self, from: createdData)
        guard let id = created.id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            throw GraphError.unexpected("Folder create returned no message id")
        }
        return id
    }

    private static func createParsedMessageInFolder(
        accessToken: String,
        folderID: String,
        parsed: ParsedEML
    ) async throws -> String {
        var message = graphJSONMessage(
            subject: parsed.subject,
            bodyContent: parsed.body,
            bodyIsHTML: parsed.isHTML,
            fromName: parsed.fromName,
            fromAddress: parsed.fromAddress,
            to: parsed.to,
            cc: parsed.cc,
            internetMessageId: parsed.internetMessageId,
            received: parsed.receivedDate,
            sent: parsed.sentDate,
            isRead: parsed.isRead,
            undraft: true
        )
        let attachments = fileAttachmentPayloads(from: parsed.attachments)
        if !attachments.isEmpty {
            message["attachments"] = attachments
        }
        let folderEnc = folderID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? folderID
        let createdData = try await postJSONImport(
            path: "/me/mailFolders/\(folderEnc)/messages",
            accessToken: accessToken,
            body: message
        )
        struct Created: Decodable { var id: String? }
        let created = try JSONDecoder().decode(Created.self, from: createdData)
        guard let id = created.id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            throw GraphError.unexpected("JSON import returned no message id")
        }
        return id
    }

    private static func graphJSONMessage(
        subject: String,
        bodyContent: String,
        bodyIsHTML: Bool,
        fromName: String?,
        fromAddress: String?,
        to: [(name: String?, address: String)],
        cc: [(name: String?, address: String)],
        internetMessageId: String?,
        received: Date?,
        sent: Date?,
        isRead: Bool,
        undraft: Bool
    ) -> [String: Any] {
        var message: [String: Any] = [
            "subject": subject,
            "body": [
                "contentType": bodyIsHTML ? "HTML" : "Text",
                "content": bodyContent,
            ],
            "toRecipients": recipientObjectsNamed(to),
            "ccRecipients": recipientObjectsNamed(cc),
            "isRead": isRead,
        ]
        if let fromAddress, !fromAddress.isEmpty {
            var email: [String: String] = ["address": fromAddress]
            if let fromName, !fromName.isEmpty { email["name"] = fromName }
            message["from"] = ["emailAddress": email]
            message["sender"] = ["emailAddress": email]
        }
        if let internetMessageId, !internetMessageId.isEmpty {
            message["internetMessageId"] = internetMessageId
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let received {
            message["receivedDateTime"] = iso.string(from: received)
        }
        if let sent {
            message["sentDateTime"] = iso.string(from: sent)
        }
        if undraft {
            // PidTagMessageFlags — clear draft so OWA/Outlook treat it as received mail.
            message["singleValueExtendedProperties"] = [
                ["id": "Integer 0x0E07", "value": "4"]
            ]
        }
        return message
    }

    private static func recipientObjectsNamed(_ addresses: [(name: String?, address: String)]) -> [[String: Any]] {
        addresses.map { pair in
            var email: [String: String] = ["address": pair.address]
            if let name = pair.name, !name.isEmpty { email["name"] = name }
            return ["emailAddress": email]
        }
    }

    private static func mapRecipients(_ list: [GraphRecipient]?) -> [(name: String?, address: String)]? {
        guard let list, !list.isEmpty else { return nil }
        let mapped: [(name: String?, address: String)] = list.compactMap { r in
            guard let addr = r.emailAddress?.address, !addr.isEmpty else { return nil }
            return (r.emailAddress?.name, addr)
        }
        return mapped.isEmpty ? nil : mapped
    }

    /// Inline fileAttachment payloads; skip anything over ~2.5 MB (Graph inline limit ~3 MB).
    private static func fileAttachmentPayloads(from attachments: [ParsedMailAttachment]) -> [[String: Any]] {
        let limit = 2_500_000
        var out: [[String: Any]] = []
        for att in attachments {
            guard att.data.count <= limit, !att.data.isEmpty else { continue }
            out.append([
                "@odata.type": "#microsoft.graph.fileAttachment",
                "name": att.filename,
                "contentType": att.mimeType.isEmpty ? "application/octet-stream" : att.mimeType,
                "contentBytes": att.data.base64EncodedString(),
            ])
        }
        return out
    }

    private static func fetchDraftFileAttachmentPayloads(draftID: String, accessToken: String) async throws -> [[String: Any]] {
        struct GraphAttachmentList: Decodable { var value: [GraphAttachment]? }
        let encoded = draftID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? draftID
        let list: GraphAttachmentList = try await getJSON(
            path: "/me/messages/\(encoded)/attachments",
            accessToken: accessToken,
            query: [:]
        )
        let limit = 2_500_000
        var out: [[String: Any]] = []
        for item in list.value ?? [] {
            let typeName = (item.odataType ?? "").lowercased()
            guard typeName.contains("fileattachment") else { continue }
            guard let b64 = item.contentBytes, !b64.isEmpty,
                  let data = Data(base64Encoded: b64, options: [.ignoreUnknownCharacters]),
                  data.count <= limit else { continue }
            let filename = (item.name ?? "attachment").trimmingCharacters(in: .whitespacesAndNewlines)
            out.append([
                "@odata.type": "#microsoft.graph.fileAttachment",
                "name": filename.isEmpty ? "attachment" : filename,
                "contentType": item.contentType ?? "application/octet-stream",
                "contentBytes": data.base64EncodedString(),
            ])
        }
        return out
    }

    @discardableResult
    private static func postJSONImport(path: String, accessToken: String, body: [String: Any]) async throws -> Data {
        let url = try makeURL(path: path, query: [:])
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("IdType=\"ImmutableId\"", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await importSession.data(for: request)
        } catch {
            throw mapSessionError(error)
        }
        try throwIfNeeded(response: response, data: data)
        return data
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
            var nextLink: String?

            enum CodingKeys: String, CodingKey {
                case value
                case nextLink = "@odata.nextLink"
            }
        }
        // Lightweight list only — no `body` (HTML payloads hung sync). Bodies load on open.
        let select = "id,internetMessageId,subject,bodyPreview,from,toRecipients,ccRecipients,receivedDateTime,sentDateTime,isRead,flag,hasAttachments"
        // Sent Items sorts more reliably by sentDateTime; Inbox by receivedDateTime.
        let orderby = (folderPath.lowercased().contains("sentitems") || mailboxKey.lowercased().contains("sent"))
            ? "sentDateTime desc"
            : "receivedDateTime desc"
        var nextURL: URL? = try makeURL(
            path: folderPath,
            query: [
                "$top": "\(pageSize)",
                "$orderby": orderby,
                "$select": select,
            ]
        )

        var out: [MailMessage] = []
        while let url = nextURL, out.count < listLimit {
            try Task.checkCancellation()
            let list: GraphList = try await getJSON(url: url, accessToken: accessToken)
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
                if out.count >= listLimit { break }
            }
            if out.count >= listLimit {
                break
            }
            if let link = list.nextLink?.trimmingCharacters(in: .whitespacesAndNewlines),
               !link.isEmpty,
               let parsed = URL(string: link) {
                nextURL = parsed
            } else {
                nextURL = nil
            }
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
        try await getJSON(url: try makeURL(path: path, query: query), accessToken: accessToken)
    }

    /// Absolute-URL GET (path-based queries and Graph `@odata.nextLink` pages).
    private static func getJSON<T: Decodable>(url: URL, accessToken: String) async throws -> T {
        var request = URLRequest(url: url, timeoutInterval: 60)
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

    private static func deleteHTTP(path: String, accessToken: String) async throws {
        let url = try makeURL(path: path, query: [:])
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.httpMethod = "DELETE"
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
        // 204 No Content is success; also treat 404 as already-deleted.
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 { return }
            guard (200..<300).contains(http.statusCode) else {
                let text = String(data: data, encoding: .utf8) ?? ""
                if http.statusCode == 429 {
                    throw GraphError.throttled(retryAfter: parseRetryAfter(http), detail: text)
                }
                throw GraphError.http(http.statusCode, text)
            }
            return
        }
        try throwIfNeeded(response: response, data: data)
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
            if http.statusCode == 429 {
                throw GraphError.throttled(retryAfter: parseRetryAfter(http), detail: text)
            }
            throw GraphError.http(http.statusCode, text)
        }
    }

    /// Parse Retry-After as delay-seconds or HTTP-date.
    private static func parseRetryAfter(_ http: HTTPURLResponse) -> TimeInterval? {
        guard let raw = http.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        if let seconds = Double(raw) {
            return max(0, seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: raw) {
            return max(0, date.timeIntervalSinceNow)
        }
        return nil
    }

    /// True for Graph 429 / ApplicationThrottled / IncomingBytes limit errors.
    static func isThrottlingError(_ error: Error) -> Bool {
        if let ge = error as? GraphError {
            return ge.isThrottled
        }
        let desc = error.localizedDescription
        return desc.contains("429")
            || desc.localizedCaseInsensitiveContains("throttl")
            || desc.localizedCaseInsensitiveContains("IncomingBytes")
            || desc.localizedCaseInsensitiveContains("ApplicationThrottled")
    }

    static func retryAfterSeconds(from error: Error) -> TimeInterval? {
        if let ge = error as? GraphError, case .throttled(let retryAfter, _) = ge {
            return retryAfter
        }
        return nil
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
        /// ApplicationThrottled / IncomingBytes — honor Retry-After when present.
        case throttled(retryAfter: TimeInterval?, detail: String)

        var errorDescription: String? {
            switch self {
            case .unexpected(let s): return s
            case .http(let code, let body):
                return "Graph HTTP \(code): \(MicrosoftGraphMailService.summarizeGraphErrorBody(body))"
            case .timedOut(let s): return s
            case .throttled(let retryAfter, let detail):
                let summary = MicrosoftGraphMailService.summarizeGraphErrorBody(detail)
                if let retryAfter, retryAfter > 0 {
                    return "Graph HTTP 429: \(summary) (Retry-After \(Int(ceil(retryAfter)))s)"
                }
                return "Graph HTTP 429: \(summary)"
            }
        }

        var isThrottled: Bool {
            switch self {
            case .throttled:
                return true
            case .http(let code, let body):
                return code == 429
                    || body.localizedCaseInsensitiveContains("throttl")
                    || body.localizedCaseInsensitiveContains("IncomingBytes")
                    || body.localizedCaseInsensitiveContains("ApplicationThrottled")
            default:
                return false
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

private struct GraphFolderDTO: Decodable {
    var id: String?
    var displayName: String?
    var parentFolderId: String?
    var childFolderCount: Int?
    var totalItemCount: Int?
}

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
