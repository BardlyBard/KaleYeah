import Foundation

struct IMAPFolderInfo: Hashable {
    var name: String
    var flags: [String]
    var kind: FolderKind {
        let upper = name.uppercased()
        let joined = flags.joined(separator: " ").uppercased()
        if upper == "INBOX" || joined.contains("\\INBOX") { return .inbox }
        if joined.contains("\\SENT") || upper.contains("SENT") { return .sent }
        if joined.contains("\\DRAFTS") || upper.contains("DRAFT") { return .drafts }
        if joined.contains("\\TRASH") || upper.contains("TRASH") { return .trash }
        if joined.contains("\\JUNK") || joined.contains("\\SPAM") || upper.contains("SPAM") || upper.contains("JUNK") { return .junk }
        if joined.contains("\\ARCHIVE") || upper.contains("ARCHIVE") { return .archive }
        return .custom
    }
}

struct IMAPFetchedMessage {
    var uid: UInt32
    var flags: [String]
    var fromName: String
    var fromAddress: String
    var toAddresses: [String]
    var ccAddresses: [String]
    var subject: String
    var date: Date
    var body: String
    var isHTML: Bool
    var snippet: String
    var isRead: Bool { flags.contains { $0.uppercased() == "\\SEEN" } }
    var isFlagged: Bool { flags.contains { $0.uppercased() == "\\FLAGGED" } }
}

/// Lightweight IMAP client for Gmail (imap.gmail.com:993).
actor SimpleIMAPClient {
    private var conn: MailTLSConnection?
    private var tagCounter = 0
    private var lastExists = 0

    func connect(host: String = "imap.gmail.com", port: UInt16 = 993) async throws {
        let c = MailTLSConnection(host: host, port: port)
        try await c.connect()
        conn = c
        _ = try await c.readLine() // greeting
    }

    func login(email: String, password: String) async throws {
        let pass = password.replacingOccurrences(of: " ", with: "")
        let response = try await tagged("LOGIN \(quote(email)) \(quote(pass))")
        guard response.contains("OK") else { throw MailNetError.authFailed(response) }
    }

    func listFolders() async throws -> [IMAPFolderInfo] {
        let lines = try await taggedLines("LIST \"\" \"*\"")
        var folders: [IMAPFolderInfo] = []
        for line in lines where line.hasPrefix("* LIST") || line.uppercased().hasPrefix("* LIST") {
            let flags = extractParenList(line)
            if let name = extractQuotedTail(line) ?? extractUnquotedMailbox(line) {
                folders.append(IMAPFolderInfo(name: name, flags: flags))
            }
        }
        return folders
    }

    @discardableResult
    func select(_ mailbox: String) async throws -> Int {
        let lines = try await taggedLines("SELECT \(quote(mailbox))")
        var exists = 0
        for line in lines {
            let upper = line.uppercased()
            if line.hasPrefix("* "), upper.contains(" EXISTS") {
                let parts = line.split(separator: " ")
                if parts.count >= 2, let n = Int(parts[1]) { exists = n }
            }
        }
        guard lines.last?.contains("OK") == true else {
            throw MailNetError.unexpected(lines.last ?? "SELECT failed")
        }
        lastExists = exists
        return exists
    }

    /// Fetch the most recent `limit` messages from an already-selected mailbox (by sequence).
    func fetchRecent(limit: Int) async throws -> [IMAPFetchedMessage] {
        let exists = lastExists
        guard exists > 0 else { return [] }
        let start = max(1, exists - limit + 1)
        let set = "\(start):\(exists)"
        let lines = try await taggedLines(
            "FETCH \(set) (UID FLAGS BODY.PEEK[HEADER.FIELDS (FROM TO CC SUBJECT DATE CONTENT-TYPE CONTENT-TRANSFER-ENCODING)] BODY.PEEK[TEXT])",
            allowLiterals: true
        )
        return parseFetch(lines)
    }

    func fetchRecent(mailbox: String, limit: Int) async throws -> [IMAPFetchedMessage] {
        _ = try await select(mailbox)
        return try await fetchRecent(limit: limit)
    }

    func logout() async {
        _ = try? await tagged("LOGOUT")
        conn?.close()
        conn = nil
    }

    // MARK: - Internals

    private func tagged(_ command: String) async throws -> String {
        let lines = try await taggedLines(command, allowLiterals: false)
        return lines.last ?? ""
    }

    private func taggedLines(_ command: String, allowLiterals: Bool = true) async throws -> [String] {
        guard let conn else { throw MailNetError.unexpected("Not connected") }
        tagCounter += 1
        let tag = String(format: "A%04d", tagCounter)
        try await conn.sendLine("\(tag) \(command)")
        var lines: [String] = []
        while true {
            var line = try await conn.readLine()
            if allowLiterals, let lit = literalSize(from: line) {
                let payload = try await conn.readExact(lit)
                let text = String(data: payload, encoding: .utf8) ?? String(decoding: payload, as: UTF8.self)
                // After a literal, IMAP continues; fold payload into this logical line.
                line += "\n" + text
            }
            lines.append(line)
            if line.hasPrefix("\(tag) ") {
                break
            }
        }
        return lines
    }

    private func literalSize(from line: String) -> Int? {
        guard line.hasSuffix("}"), let open = line.lastIndex(of: "{") else { return nil }
        let num = line[line.index(after: open)..<line.index(before: line.endIndex)]
        // Only treat trailing {n} as a literal marker (server waiting to send / client continuing).
        return Int(num)
    }

    private func quote(_ s: String) -> String {
        "\"\(s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private func extractParenList(_ line: String) -> [String] {
        guard let start = line.firstIndex(of: "("), let end = line.firstIndex(of: ")") else { return [] }
        let inner = line[line.index(after: start)..<end]
        return inner.split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }

    private func extractQuotedTail(_ line: String) -> String? {
        var result: String?
        var i = line.startIndex
        while i < line.endIndex {
            if line[i] == "\"" {
                let start = line.index(after: i)
                var j = start
                var escaped = false
                while j < line.endIndex {
                    let c = line[j]
                    if escaped { escaped = false }
                    else if c == "\\" { escaped = true }
                    else if c == "\"" {
                        result = String(line[start..<j])
                        i = line.index(after: j)
                        break
                    }
                    j = line.index(after: j)
                }
                if j >= line.endIndex { break }
                continue
            }
            i = line.index(after: i)
        }
        return result
    }

    private func extractUnquotedMailbox(_ line: String) -> String? {
        line.split(separator: " ").last.map(String.init)
    }

    private func parseFetch(_ lines: [String]) -> [IMAPFetchedMessage] {
        var blocks: [String] = []
        var current = ""
        for line in lines {
            if line.hasPrefix("* "), line.uppercased().contains(" FETCH") {
                if !current.isEmpty { blocks.append(current) }
                current = line
            } else if line.first == "A", line.contains(" OK") || line.contains(" NO") || line.contains(" BAD") {
                break
            } else if !current.isEmpty {
                current += "\n" + line
            }
        }
        if !current.isEmpty { blocks.append(current) }

        return blocks.compactMap { block -> IMAPFetchedMessage? in
            guard let uid = firstMatch(block, pattern: #"UID\s+(\d+)"#).flatMap(UInt32.init) else { return nil }
            let flagBlob = substring(block, after: "FLAGS (", until: ")") ?? ""
            let flags = flagBlob.split(separator: " ").map(String.init)
            let header = extractSection(block, named: "HEADER.FIELDS") ?? extractSection(block, named: "HEADER") ?? ""
            let bodyText = extractSection(block, named: "TEXT") ?? ""
            let headers = parseHeaders(header)
            let fromRaw = headers["from"] ?? ""
            let (fromName, fromAddress) = parseAddress(fromRaw)
            let to = parseAddressList(headers["to"] ?? "")
            let cc = parseAddressList(headers["cc"] ?? "")
            let subject = decodeMIMEHeader(headers["subject"] ?? "(no subject)")
            let date = parseIMAPDate(headers["date"] ?? "") ?? Date()
            let parsed = MimeBodyParser.parse(
                textBody: bodyText,
                contentTypeHeader: headers["content-type"],
                contentTransferEncoding: headers["content-transfer-encoding"]
            )
            let body = parsed.body.isEmpty ? subject : parsed.body
            let snippet = parsed.snippet.isEmpty ? String(subject.prefix(140)) : parsed.snippet
            return IMAPFetchedMessage(
                uid: uid,
                flags: flags,
                fromName: fromName.isEmpty ? fromAddress : fromName,
                fromAddress: fromAddress,
                toAddresses: to,
                ccAddresses: cc,
                subject: subject,
                date: date,
                body: body,
                isHTML: parsed.isHTML && !parsed.body.isEmpty,
                snippet: snippet
            )
        }
        .sorted { $0.date > $1.date }
    }

    private func extractSection(_ block: String, named: String) -> String? {
        let needle = "BODY[\(named)"
        guard let idx = block.uppercased().range(of: needle.uppercased())?.lowerBound else { return nil }
        let from = block[idx...]
        if let litOpen = from.range(of: "{"),
           let litClose = from.range(of: "}"),
           litOpen.upperBound <= litClose.lowerBound,
           let size = Int(from[litOpen.upperBound..<litClose.lowerBound]) {
            var start = litClose.upperBound
            if start < from.endIndex, from[start] == "\n" { start = from.index(after: start) }
            if start < from.endIndex, from[start] == "\r" { start = from.index(after: start) }
            if start < from.endIndex, from[start] == "\n" { start = from.index(after: start) }
            let end = from.index(start, offsetBy: min(size, from.distance(from: start, to: from.endIndex)))
            return String(from[start..<end])
        }
        if let q = extractQuotedTail(String(from)) { return q }
        return nil
    }

    private func parseHeaders(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        var currentKey: String?
        for line in raw.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            if s.isEmpty { continue }
            if s.first?.isWhitespace == true, let key = currentKey {
                result[key, default: ""] += " " + s.trimmingCharacters(in: .whitespaces)
            } else if let colon = s.firstIndex(of: ":") {
                let key = String(s[..<colon]).lowercased()
                let value = s[s.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                result[key] = value
                currentKey = key
            }
        }
        return result
    }

    private func parseAddress(_ raw: String) -> (String, String) {
        if let start = raw.firstIndex(of: "<"), let end = raw.firstIndex(of: ">"), start < end {
            let email = String(raw[raw.index(after: start)..<end]).trimmingCharacters(in: .whitespaces)
            var name = String(raw[..<start]).trimmingCharacters(in: .whitespacesAndNewlines)
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return (decodeMIMEHeader(name), email)
        }
        let email = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return (email, email)
    }

    private func parseAddressList(_ raw: String) -> [String] {
        raw.split(separator: ",").map { parseAddress(String($0)).1 }.filter { !$0.isEmpty }
    }

    private func parseIMAPDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm:ss Z",
            "dd MMM yyyy HH:mm:ss Z",
            "d MMM yyyy HH:mm:ss Z",
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for f in formats {
            formatter.dateFormat = f
            if let d = formatter.date(from: trimmed) { return d }
            if let paren = trimmed.firstIndex(of: "(") {
                let cut = String(trimmed[..<paren]).trimmingCharacters(in: .whitespaces)
                if let d = formatter.date(from: cut) { return d }
            }
        }
        return nil
    }

    private func decodeMIMEHeader(_ value: String) -> String {
        var result = value
        let pattern = #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#
        while let match = result.range(of: pattern, options: .regularExpression) {
            let token = String(result[match])
            guard let decoded = decodeEncodedWord(token) else { break }
            result.replaceSubrange(match, with: decoded)
        }
        return result
    }

    private func decodeEncodedWord(_ token: String) -> String? {
        let parts = token.split(separator: "?")
        guard parts.count >= 4 else { return nil }
        let charset = String(parts[1])
        let encoding = parts[2].uppercased()
        let payload = String(parts[3])
        let data: Data?
        if encoding == "B" {
            data = Data(base64Encoded: payload)
        } else if encoding == "Q" {
            data = decodeQuotedPrintableData(payload.replacingOccurrences(of: "_", with: " "))
        } else {
            data = nil
        }
        guard let data else { return nil }
        if charset.uppercased().contains("UTF-8") {
            return String(data: data, encoding: .utf8)
        }
        return String(data: data, encoding: .isoLatin1)
    }


    private func decodeQuotedPrintableData(_ input: String) -> Data? {
        var out = Data()
        let chars = Array(input.utf8)
        var i = 0
        while i < chars.count {
            if chars[i] == UInt8(ascii: "=") {
                if i + 1 < chars.count, chars[i + 1] == UInt8(ascii: "\r") {
                    i += 2
                    if i < chars.count, chars[i] == UInt8(ascii: "\n") { i += 1 }
                    continue
                }
                if i + 1 < chars.count, chars[i + 1] == UInt8(ascii: "\n") {
                    i += 2
                    continue
                }
                if i + 2 < chars.count,
                   let h1 = hexVal(chars[i + 1]),
                   let h2 = hexVal(chars[i + 2]) {
                    out.append(h1 * 16 + h2)
                    i += 3
                    continue
                }
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    private func hexVal(_ b: UInt8) -> UInt8? {
        switch b {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return b - UInt8(ascii: "0")
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return b - UInt8(ascii: "A") + 10
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return b - UInt8(ascii: "a") + 10
        default: return nil
        }
    }

    private func firstMatch(_ text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range), match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private func substring(_ text: String, after: String, until: String) -> String? {
        guard let start = text.range(of: after, options: .caseInsensitive)?.upperBound else { return nil }
        let rest = text[start...]
        guard let end = rest.range(of: until)?.lowerBound else { return String(rest) }
        return String(rest[..<end])
    }
}
