import Foundation

/// Parsed RFC822 / `.eml` message ready for Graph JSON import.
struct ParsedEML: Sendable {
    var subject: String
    var fromName: String?
    var fromAddress: String?
    var to: [(name: String?, address: String)]
    var cc: [(name: String?, address: String)]
    var internetMessageId: String?
    var receivedDate: Date?
    var sentDate: Date?
    var isRead: Bool
    var body: String
    var isHTML: Bool
    var attachments: [ParsedMailAttachment]
    /// Raw bytes of the original `.eml` (for MIME upload attempts). Never logged.
    var rawMIME: Data
}

enum EMLFileParser {
    static func parse(data: Data) throws -> ParsedEML {
        // Prefer UTF-8; fall back to Latin-1 so binary-ish EMLs still yield headers.
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ParseError.empty
        }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let headerEnd: String.Index
        let bodyText: String
        if let r = normalized.range(of: "\n\n") {
            headerEnd = r.lowerBound
            bodyText = String(normalized[normalized.index(headerEnd, offsetBy: 2)...])
        } else {
            headerEnd = normalized.endIndex
            bodyText = ""
        }
        let headers = parseHeaderBlock(String(normalized[..<headerEnd]))

        let contentType = headers["content-type"]
        let cte = headers["content-transfer-encoding"]
        let parsedBody = MimeBodyParser.parse(
            textBody: bodyText,
            contentTypeHeader: contentType,
            contentTransferEncoding: cte
        )

        let from = parseAddressList(headers["from"] ?? "").first
        let to = parseAddressList(headers["to"] ?? "")
        let cc = parseAddressList(headers["cc"] ?? "")
        let subject = decodeMIMEHeader(headers["subject"] ?? "(no subject)")
        let messageID = normalizeMessageID(headers["message-id"])
        let dateHeader = headers["date"].flatMap(parseRFC822Date)
        let received = headers["received"].flatMap(parseReceivedDate) ?? dateHeader

        return ParsedEML(
            subject: subject.isEmpty ? "(no subject)" : subject,
            fromName: from?.name,
            fromAddress: from?.address,
            to: to,
            cc: cc,
            internetMessageId: messageID,
            receivedDate: received ?? dateHeader,
            sentDate: dateHeader,
            isRead: true,
            body: parsedBody.body.isEmpty ? (parsedBody.snippet.isEmpty ? "(empty body)" : parsedBody.snippet) : parsedBody.body,
            isHTML: parsedBody.isHTML,
            attachments: parsedBody.attachments,
            rawMIME: data
        )
    }

    enum ParseError: LocalizedError {
        case empty
        var errorDescription: String? {
            switch self {
            case .empty: return "EML file is empty or unreadable"
            }
        }
    }

    // MARK: - Headers / addresses

    private static func parseHeaderBlock(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        var currentKey: String?
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            if s.isEmpty { continue }
            if s.first?.isWhitespace == true, let key = currentKey {
                result[key, default: ""] += " " + s.trimmingCharacters(in: .whitespaces)
            } else if let colon = s.firstIndex(of: ":") {
                let key = String(s[..<colon]).lowercased()
                let value = s[s.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                // Keep first Message-ID / Date; Received can be multi — keep last (closest to mailbox).
                if key == "received" {
                    result[key] = value
                } else if result[key] == nil {
                    result[key] = value
                }
                currentKey = key
            }
        }
        return result
    }

    private static func parseAddressList(_ raw: String) -> [(name: String?, address: String)] {
        // Split on commas that are not inside quotes / angle brackets.
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var angleDepth = 0
        for ch in raw {
            if ch == "\"" { inQuotes.toggle() }
            if !inQuotes {
                if ch == "<" { angleDepth += 1 }
                if ch == ">" { angleDepth = max(0, angleDepth - 1) }
            }
            if ch == "," && !inQuotes && angleDepth == 0 {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { parts.append(trimmed) }
                current = ""
                continue
            }
            current.append(ch)
        }
        let last = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty { parts.append(last) }

        return parts.compactMap { parseOneAddress($0) }
    }

    private static func parseOneAddress(_ raw: String) -> (name: String?, address: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let open = trimmed.firstIndex(of: "<"), let close = trimmed.firstIndex(of: ">"), open < close {
            let addr = String(trimmed[trimmed.index(after: open)..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
            var name = String(trimmed[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            name = decodeMIMEHeader(name)
            guard addr.contains("@") else { return nil }
            return (name.isEmpty ? nil : name, addr)
        }
        // Bare address
        let bare = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        guard bare.contains("@") else { return nil }
        return (nil, bare)
    }

    private static func normalizeMessageID(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if !s.hasPrefix("<") { s = "<" + s }
        if !s.hasSuffix(">") { s = s + ">" }
        return s
    }

    private static func decodeMIMEHeader(_ value: String) -> String {
        let pattern = #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..., in: value)
        var result = value
        for match in regex.matches(in: value, options: [], range: range).reversed() {
            guard match.numberOfRanges >= 4,
                  let encR = Range(match.range(at: 2), in: value),
                  let payR = Range(match.range(at: 3), in: value),
                  let full = Range(match.range(at: 0), in: result) else { continue }
            let encoding = String(value[encR]).uppercased()
            let payload = String(value[payR])
            let data: Data?
            if encoding == "B" {
                data = Data(base64Encoded: payload)
            } else {
                let qp = MimeBodyParser.decodeQuotedPrintable(payload.replacingOccurrences(of: "_", with: " "))
                data = qp.data(using: .utf8)
            }
            if let data, let decoded = String(data: data, encoding: .utf8) {
                result.replaceSubrange(full, with: decoded)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseRFC822Date(_ raw: String) -> Date? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm:ss Z",
            "dd MMM yyyy HH:mm:ss Z",
            "d MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEE, d MMM yyyy HH:mm:ss zzz",
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for f in formats {
            formatter.dateFormat = f
            // Strip optional day-name trailing comments / excess.
            let candidate = cleaned.components(separatedBy: " (").first ?? cleaned
            if let d = formatter.date(from: candidate) { return d }
            // Some dates include timezone names after offset; take first 31 chars-ish.
            let truncated = String(candidate.prefix(32)).trimmingCharacters(in: .whitespaces)
            if let d = formatter.date(from: truncated) { return d }
        }
        // Fallback: ISO-ish
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: cleaned) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: cleaned)
    }

    private static func parseReceivedDate(_ raw: String) -> Date? {
        // Received: ...; Tue, 1 Apr 2025 12:34:56 -0700
        guard let semi = raw.lastIndex(of: ";") else { return nil }
        let datePart = String(raw[raw.index(after: semi)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return parseRFC822Date(datePart)
    }
}
