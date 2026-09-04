import Foundation

struct ParsedMailAttachment: Sendable {
    var filename: String
    var mimeType: String
    var data: Data
}

struct ParsedMailBody: Sendable {
    var body: String
    var isHTML: Bool
    var snippet: String
    var attachments: [ParsedMailAttachment]
}

/// Parses IMAP BODY[TEXT] (plus top-level Content-Type / CTE) into a displayable body + attachments.
enum MimeBodyParser {
    static func parse(
        textBody: String,
        contentTypeHeader: String?,
        contentTransferEncoding: String?
    ) -> ParsedMailBody {
        let normalized = textBody.replacingOccurrences(of: "\r\n", with: "\n")
        let typeHeader = contentTypeHeader?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cte = contentTransferEncoding?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let boundary = boundaryParameter(from: typeHeader),
           typeHeader.lowercased().contains("multipart/") {
            let attachments = collectAttachments(in: normalized, boundary: boundary)
            if let part = preferDisplayPart(in: normalized, boundary: boundary) {
                return finalize(part.content, isHTML: part.isHTML, attachments: attachments)
            }
            return finalize("", isHTML: false, attachments: attachments)
        }

        // BODY[TEXT] often includes multipart preamble + parts even when we missed Content-Type.
        if let sniffed = sniffMultipartAndPrefer(normalized) {
            let attachments = sniffMultipartAttachments(normalized)
            return finalize(sniffed.content, isHTML: sniffed.isHTML, attachments: attachments)
        }

        // Single-part: decode transfer encoding, then decide html vs plain from Content-Type.
        let decoded = decodeTransferEncoding(normalized, cte: cte)
        let isHTML = typeHeader.lowercased().contains("text/html") || looksLikeHTMLDocument(decoded)
        if isHTML {
            return finalize(decoded, isHTML: true, attachments: [])
        }
        let plain = stripMIMENoise(from: decoded)
        return finalize(plain.isEmpty ? decoded : plain, isHTML: false, attachments: [])
    }

    static func makeSnippet(from body: String, isHTML: Bool) -> String {
        let plain: String
        if isHTML {
            plain = htmlToVisibleText(body)
        } else {
            plain = stripMIMENoise(from: body)
        }
        let collapsed = plain
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                guard !line.isEmpty else { return false }
                if isMIMENoiseLine(line) { return false }
                // Skip pure URL dumps that dominate marketing plain-text parts.
                if line.hasPrefix("http://") || line.hasPrefix("https://") { return false }
                if line.allSatisfy({ $0.isWhitespace || $0 == "<" || $0 == ">" }) { return false }
                return true
            }
        let joined = collapsed.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if joined.isEmpty {
            let fallback = (isHTML ? htmlToVisibleText(body) : body)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return String(fallback.prefix(140))
        }
        return String(joined.prefix(140))
    }

    // MARK: - Multipart

    private struct MimePart {
        var contentType: String
        var transferEncoding: String?
        var contentDisposition: String?
        var body: String

        var isHTML: Bool { contentType.lowercased().contains("text/html") }
        var isPlain: Bool { contentType.lowercased().contains("text/plain") }
        var isMultipart: Bool { contentType.lowercased().contains("multipart/") }

        var filename: String? {
            filenameParameter(from: contentDisposition)
                ?? filenameParameter(from: contentType)
        }
    }

    private struct DisplayPart {
        var content: String
        var isHTML: Bool
    }

    private static func preferDisplayPart(in text: String, boundary: String) -> DisplayPart? {
        let parts = splitMultipart(text, boundary: boundary)
        guard !parts.isEmpty else { return nil }

        var htmlCandidate: DisplayPart?
        var plainCandidate: DisplayPart?

        for raw in parts {
            guard let part = parseOnePart(raw) else { continue }
            if part.isMultipart, let nestedBoundary = boundaryParameter(from: part.contentType) {
                if let nested = preferDisplayPart(in: part.body, boundary: nestedBoundary) {
                    if nested.isHTML { htmlCandidate = nested }
                    else if plainCandidate == nil { plainCandidate = nested }
                }
                continue
            }
            let decoded = decodeTransferEncoding(part.body, cte: part.transferEncoding)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !decoded.isEmpty else { continue }
            if part.isHTML {
                htmlCandidate = DisplayPart(content: decoded, isHTML: true)
            } else if part.isPlain || part.contentType.isEmpty || part.contentType.lowercased().hasPrefix("text/") {
                if plainCandidate == nil {
                    plainCandidate = DisplayPart(content: decoded, isHTML: false)
                }
            }
        }

        return htmlCandidate ?? plainCandidate
    }

    private static func sniffMultipartAndPrefer(_ text: String) -> DisplayPart? {
        // Find a boundary marker used at least twice (open + close or two parts).
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var counts: [String: Int] = [:]
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.hasPrefix("--"), t.count >= 4, t.count < 80 else { continue }
            if t == "--" { continue }
            let key = t.hasSuffix("--") ? String(t.dropLast(2)) : t
            guard key.hasPrefix("--") else { continue }
            counts[key, default: 0] += 1
        }
        let candidates = counts.filter { $0.value >= 2 }.map(\.key).sorted { $0.count > $1.count }
        for marker in candidates {
            let boundary = String(marker.dropFirst(2)) // strip leading --
            if let part = preferDisplayPart(in: text, boundary: boundary) {
                return part
            }
        }
        return nil
    }

    private static func splitMultipart(_ text: String, boundary: String) -> [String] {
        let delimiter = "--" + boundary
        let close = delimiter + "--"
        var work = text.replacingOccurrences(of: "\r\n", with: "\n")
        if let closeRange = work.range(of: close) {
            work = String(work[..<closeRange.lowerBound])
        }
        let chunks = work.components(separatedBy: delimiter)
        // Drop preamble (before first boundary) and empty segments.
        return chunks.dropFirst().map { chunk -> String in
            var s = chunk
            if s.hasPrefix("\n") { s = String(s.dropFirst()) }
            if s.hasPrefix("\r\n") { s = String(s.dropFirst(2)) }
            return s.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
        }
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static func parseOnePart(_ raw: String) -> MimePart? {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let headerEnd: String.Index
        if let r = normalized.range(of: "\n\n") {
            headerEnd = r.lowerBound
        } else {
            // No header/body split — treat entire chunk as body.
            return MimePart(contentType: "text/plain", transferEncoding: nil, contentDisposition: nil, body: normalized)
        }
        let headerBlob = String(normalized[..<headerEnd])
        var body = String(normalized[normalized.index(headerEnd, offsetBy: 2)...])
        if body.hasPrefix("\n") { body = String(body.dropFirst()) }

        let headers = parseHeaderBlock(headerBlob)
        let ct = headers["content-type"] ?? "text/plain"
        let cte = headers["content-transfer-encoding"]
        let cd = headers["content-disposition"]
        return MimePart(contentType: ct, transferEncoding: cte, contentDisposition: cd, body: body)
    }

    private static func collectAttachments(in text: String, boundary: String) -> [ParsedMailAttachment] {
        var out: [ParsedMailAttachment] = []
        for raw in splitMultipart(text, boundary: boundary) {
            guard let part = parseOnePart(raw) else { continue }
            if part.isMultipart, let nested = boundaryParameter(from: part.contentType) {
                out.append(contentsOf: collectAttachments(in: part.body, boundary: nested))
                continue
            }
            if let att = attachmentFromPart(part) {
                out.append(att)
            }
        }
        return out
    }

    private static func sniffMultipartAttachments(_ text: String) -> [ParsedMailAttachment] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var counts: [String: Int] = [:]
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.hasPrefix("--"), t.count >= 4, t.count < 80 else { continue }
            if t == "--" { continue }
            let key = t.hasSuffix("--") ? String(t.dropLast(2)) : t
            guard key.hasPrefix("--") else { continue }
            counts[key, default: 0] += 1
        }
        let candidates = counts.filter { $0.value >= 2 }.map(\.key).sorted { $0.count > $1.count }
        for marker in candidates {
            let boundary = String(marker.dropFirst(2))
            let found = collectAttachments(in: text, boundary: boundary)
            if !found.isEmpty { return found }
        }
        return []
    }

    private static func attachmentFromPart(_ part: MimePart) -> ParsedMailAttachment? {
        guard !part.isMultipart else { return nil }
        let disp = (part.contentDisposition ?? "").lowercased()
        let ct = part.contentType.lowercased()
        let looksBinary = ct.hasPrefix("application/")
            || ct.hasPrefix("image/")
            || ct.hasPrefix("audio/")
            || ct.hasPrefix("video/")
            || ct.contains("octet-stream")
        let named = part.filename != nil
        let isAttachDisp = disp.contains("attachment")
        let isInlineNamedBinary = disp.contains("inline") && named && !part.isPlain && !part.isHTML
        let isNamedNonText = named && !part.isPlain && !part.isHTML
        guard isAttachDisp || isInlineNamedBinary || isNamedNonText || (looksBinary && !part.isPlain && !part.isHTML) else {
            return nil
        }
        // Prefer body display parts over treating them as attachments.
        if (part.isPlain || part.isHTML) && !isAttachDisp { return nil }

        let data = decodeTransferEncodingData(part.body, cte: part.transferEncoding)
        guard !data.isEmpty else { return nil }
        let trimmedName = part.filename?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let filename = trimmedName.isEmpty ? defaultFilename(for: part.contentType) : trimmedName
        let mime = part.contentType.split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "application/octet-stream"
        return ParsedMailAttachment(filename: filename, mimeType: mime, data: data)
    }

    private static func defaultFilename(for contentType: String) -> String {
        let ct = contentType.lowercased()
        if ct.hasPrefix("image/png") { return "image.png" }
        if ct.hasPrefix("image/jpeg") || ct.hasPrefix("image/jpg") { return "image.jpg" }
        if ct.hasPrefix("image/gif") { return "image.gif" }
        if ct.hasPrefix("image/webp") { return "image.webp" }
        if ct.contains("pdf") { return "document.pdf" }
        return "attachment.bin"
    }

    private static func filenameParameter(from header: String?) -> String? {
        guard let header, !header.isEmpty else { return nil }
        let pattern = #"(?:filename\*|filename)\s*=\s*(?:\"([^\"]+)\"|([^;\s]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(header.startIndex..., in: header)
        guard let match = regex.firstMatch(in: header, options: [], range: range) else { return nil }
        for i in 1..<match.numberOfRanges {
            if let r = Range(match.range(at: i), in: header) {
                var value = String(header[r]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if value.lowercased().hasPrefix("utf-8''") {
                    value = String(value.dropFirst(7))
                    value = value.removingPercentEncoding ?? value
                }
                if !value.isEmpty { return decodeMIMEWord(value) }
            }
        }
        return nil
    }

    private static func decodeMIMEWord(_ value: String) -> String {
        // Lightweight =?UTF-8?B?...?= / Q decode for filenames.
        let pattern = #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..., in: value)
        var result = value
        let matches = regex.matches(in: value, options: [], range: range).reversed()
        for match in matches {
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
                data = decodeQuotedPrintable(payload.replacingOccurrences(of: "_", with: " ")).data(using: .utf8)
            }
            if let data, let decoded = String(data: data, encoding: .utf8) {
                result.replaceSubrange(full, with: decoded)
            }
        }
        return result
    }

    private static func decodeTransferEncodingData(_ body: String, cte: String?) -> Data {
        let encoding = (cte ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if encoding.contains("base64") {
            let cleaned = body.components(separatedBy: .whitespacesAndNewlines).joined()
            if let data = Data(base64Encoded: cleaned, options: [.ignoreUnknownCharacters]) {
                return data
            }
        }
        if encoding.contains("quoted-printable") {
            return Data(decodeQuotedPrintable(body).utf8)
        }
        return Data(body.utf8)
    }

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
                result[key] = value
                currentKey = key
            }
        }
        return result
    }

    private static func boundaryParameter(from contentType: String) -> String? {
        // boundary="foo" or boundary=foo
        let pattern = #"boundary\s*=\s*"([^"]+)"|boundary\s*=\s*([^;\s]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(contentType.startIndex..., in: contentType)
        guard let match = regex.firstMatch(in: contentType, options: [], range: range) else { return nil }
        for i in 1..<match.numberOfRanges {
            if let r = Range(match.range(at: i), in: contentType) {
                let value = String(contentType[r]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    // MARK: - Decode

    private static func decodeTransferEncoding(_ body: String, cte: String?) -> String {
        let encoding = (cte ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if encoding.contains("base64") {
            let cleaned = body
                .components(separatedBy: .whitespacesAndNewlines)
                .joined()
            if let data = Data(base64Encoded: cleaned, options: [.ignoreUnknownCharacters]),
               let s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
                return s.replacingOccurrences(of: "\r\n", with: "\n")
            }
        }
        if encoding.contains("quoted-printable") {
            return decodeQuotedPrintable(body)
        }
        // Heuristic: many servers omit CTE but still send QP in HTML/plain parts.
        if body.contains("=\n") || body.contains("=\r\n") || body.range(of: #"=[0-9A-Fa-f]{2}"#, options: .regularExpression) != nil {
            let decoded = decodeQuotedPrintable(body)
            // Only accept if it clearly improved something (fewer soft breaks / hex escapes).
            if decoded != body { return decoded }
        }
        return body.replacingOccurrences(of: "\r\n", with: "\n")
    }

    static func decodeQuotedPrintable(_ input: String) -> String {
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
        return String(data: out, encoding: .utf8)
            ?? String(data: out, encoding: .isoLatin1)
            ?? input.replacingOccurrences(of: "\r\n", with: "\n")
    }

    private static func hexVal(_ b: UInt8) -> UInt8? {
        switch b {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return b - UInt8(ascii: "0")
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return b - UInt8(ascii: "A") + 10
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return b - UInt8(ascii: "a") + 10
        default: return nil
        }
    }

    // MARK: - Cleanup / snippet helpers

    private static func finalize(_ body: String, isHTML: Bool, attachments: [ParsedMailAttachment] = []) -> ParsedMailBody {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = trimmed.isEmpty ? "" : trimmed
        return ParsedMailBody(
            body: safe,
            isHTML: isHTML && !safe.isEmpty,
            snippet: makeSnippet(from: safe, isHTML: isHTML && !safe.isEmpty),
            attachments: attachments
        )
    }

    private static func looksLikeHTMLDocument(_ text: String) -> Bool {
        let sample = text.prefix(500).lowercased()
        return sample.contains("<html") || sample.contains("<!doctype html") || sample.contains("<body")
            || (sample.contains("<div") && sample.contains("</"))
    }

    private static func isMIMENoiseLine(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        if t.hasPrefix("--") && t.count < 80 { return true }
        let lower = t.lowercased()
        if lower.hasPrefix("content-type:") { return true }
        if lower.hasPrefix("content-transfer-encoding:") { return true }
        if lower.hasPrefix("content-disposition:") { return true }
        if lower.hasPrefix("mime-version:") { return true }
        if lower.contains("this is a multi-part message in mime format") { return true }
        if lower.hasPrefix("charset=") { return true }
        return false
    }

    private static func stripMIMENoise(from text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .filter { !isMIMENoiseLine($0) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func htmlToVisibleText(_ html: String) -> String {
        var s = html
        // Remove script/style blocks.
        s = s.replacingOccurrences(of: #"(?is)<script[^>]*>.*?</script>"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?is)<style[^>]*>.*?</style>"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)</p>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)</div>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)</tr>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        let entities: [String: String] = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&#39;": "'", "&apos;": "'", "&mdash;": "—", "&ndash;": "–", "&rsquo;": "’",
            "&lsquo;": "‘", "&rdquo;": "”", "&ldquo;": "“",
        ]
        for (k, v) in entities {
            s = s.replacingOccurrences(of: k, with: v, options: .caseInsensitive)
        }
        s = s.replacingOccurrences(of: #"&#(\d+);"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"&[a-zA-Z]+;"#, with: " ", options: .regularExpression)
        return s
    }
}


private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
