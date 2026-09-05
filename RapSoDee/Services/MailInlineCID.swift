import Foundation

/// Rewrites HTML `cid:` image references to local relative filenames (or data URLs)
/// so WKWebView can render Graph/IMAP inline attachments.
enum MailInlineCID {
    /// Normalize Graph `contentId` / HTML `cid:` tokens for lookup.
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count >= 4, s.prefix(4).lowercased() == "cid:" {
            s = String(s.dropFirst(4))
        }
        if s.hasPrefix("<"), s.hasSuffix(">"), s.count >= 2 {
            s = String(s.dropFirst().dropLast())
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// True when HTML still has unresolved `cid:` references (case-insensitive).
    static func htmlHasUnresolvedCID(_ html: String) -> Bool {
        html.range(of: "cid:", options: .caseInsensitive) != nil
    }

    /// Map contentId / filename → replacement URL string (relative file name preferred).
    static func replacementMap(for attachments: [MailAttachment], preferDataURLs: Bool = false) -> [String: String] {
        var map: [String: String] = [:]
        for att in attachments {
            guard let path = att.localPath, att.hasLocalContent,
                  let data = AttachmentStore.load(path: path), !data.isEmpty else { continue }
            let mime = att.mimeType.isEmpty
                ? AttachmentStore.mimeType(forFilename: att.filename)
                : att.mimeType
            let replacement: String
            if preferDataURLs {
                replacement = "data:\(mime);base64,\(data.base64EncodedString())"
            } else {
                let fileName = URL(fileURLWithPath: path).lastPathComponent
                replacement = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
            }
            if let cid = att.contentId, !cid.isEmpty {
                let key = normalize(cid)
                map[key] = replacement
                if let bare = key.split(separator: "@").first.map(String.init), bare != key {
                    map[bare] = replacement
                }
            }
            let name = att.filename.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                map[normalize(name)] = replacement
            }
        }
        return map
    }

    /// Replace `cid:…` tokens in HTML with local relative filenames or data URLs.
    static func rewriteHTML(_ html: String, attachments: [MailAttachment], preferDataURLs: Bool = false) -> String {
        let map = replacementMap(for: attachments, preferDataURLs: preferDataURLs)
        guard !map.isEmpty, htmlHasUnresolvedCID(html) else { return html }

        guard let regex = try? NSRegularExpression(
            pattern: #"(?i)cid:([^\"'\s>)]+)"#,
            options: []
        ) else { return html }

        let ns = html as NSString
        let full = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: html, range: full)
        guard !matches.isEmpty else { return html }

        var result = html
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2,
                  let fullRange = Range(match.range(at: 0), in: result),
                  let cidRange = Range(match.range(at: 1), in: result) else { continue }
            let cidRaw = String(result[cidRange])
            let key = normalize(cidRaw)
            let bare = key.split(separator: "@").first.map(String.init) ?? key
            guard let replacement = map[key] ?? map[bare] else { continue }
            result.replaceSubrange(fullRange, with: replacement)
        }
        return result
    }
}
