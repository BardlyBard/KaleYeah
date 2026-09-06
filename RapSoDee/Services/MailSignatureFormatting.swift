import Foundation
import AppKit

/// Single place for signature blocks so compose + send never double-append.
///
/// Rules:
/// - Plain compose / send (no logo): exactly one trailing `\n\n--\n{text}` block.
/// - Logo configured: the image *is* the signature in compose UI + HTML send; do **not**
///   also leave a plain `--` text block (that was the live double: text + full brand image).
/// - From-switch / send always strip every trailing dash-signature variant first.
enum MailSignatureFormatting {
    static func trimmed(_ signature: String?) -> String {
        normalizeSignatureText(signature)
    }

    /// Drop accidental delimiter lines users paste into Settings (`--`, `-- `, `—`).
    static func normalizeSignatureText(_ signature: String?) -> String {
        var text = (signature ?? "").replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first {
            let line = first.trimmingCharacters(in: .whitespaces)
            if line == "--" || line == "-- " || line == "—" || line == "–" {
                if first.count < text.count {
                    text = String(text[text.index(text.startIndex, offsetBy: first.count)...])
                    if text.hasPrefix("\n") { text.removeFirst() }
                    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    continue
                }
                return ""
            }
            break
        }
        return text
    }

    private static func normalizeNewlines(_ body: String) -> String {
        body.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Plain-text signature block including leading separators.
    static func plainBlock(signature: String?) -> String {
        let text = trimmed(signature)
        guard !text.isEmpty else { return "" }
        return "\n\n--\n" + text
    }

    /// What to insert into the compose editor for this account.
    /// Logo accounts: empty (image preview below editor is the signature).
    static func composeInsertion(signature: String?, logoPath: String?) -> String {
        if hasUsableLogo(logoPath) { return "" }
        return plainBlock(signature: signature)
    }

    static func hasUsableLogo(_ logoPath: String?) -> Bool {
        guard let logoPath, !logoPath.isEmpty,
              let data = AttachmentStore.load(path: logoPath),
              !data.isEmpty else { return false }
        return true
    }

    /// True when this signature already appears as the sole trailing `--` block.
    static func bodyAlreadyHasSignature(_ body: String, signature: String?) -> Bool {
        let text = trimmed(signature)
        guard !text.isEmpty else { return true }
        let normalized = normalizeNewlines(body)
        let block = plainBlock(signature: text)
        if normalized.hasSuffix(block) { return true }
        if let last = lastTrailingDashSignaturePayload(in: normalized) {
            return trimmed(last) == text
        }
        return false
    }

    /// RFC 3676-style + common variants: strip every trailing signature delimiter block.
    /// Handles `\n--\n`, `\n-- \n` (RFC space), and lone em/en-dash lines.
    static func stripTrailingDashSignatures(from body: String) -> String {
        var result = normalizeNewlines(body)
        while let range = trailingDelimiterRange(in: result) {
            result = String(result[..<range.lowerBound])
        }
        let t = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if t == "--" || t == "-- " || t == "—" || t == "–" || t.hasPrefix("--\n") || t.hasPrefix("—\n") {
            return ""
        }
        while result.hasSuffix("\n") { result.removeLast() }
        return result
    }

    /// Also remove a trailing bare copy of `signature` (no `--` wrapper) so append won't stack names.
    static func stripTrailingSignaturePayload(from body: String, signature: String?) -> String {
        var result = stripTrailingDashSignatures(from: body)
        let text = trimmed(signature)
        guard !text.isEmpty else { return result }
        let normalized = normalizeNewlines(result)
        if normalized.hasSuffix(text) {
            var cut = String(normalized.dropLast(text.count))
            while cut.hasSuffix("\n") { cut.removeLast() }
            // Avoid eating user content that merely ends with the same words mid-sentence:
            // only strip when separated by a blank line or whole-body match.
            if cut.isEmpty || cut.hasSuffix("\n") {
                result = cut
            }
        }
        while result.hasSuffix("\n") { result.removeLast() }
        return result
    }

    private static func trailingDelimiterRange(in body: String) -> Range<String.Index>? {
        // Prefer the last delimiter-only line: \n--\n, \n-- \n, \n—\n, \n–\n
        let patterns = ["\n-- \n", "\n--\n", "\n—\n", "\n–\n"]
        var best: Range<String.Index>?
        for pattern in patterns {
            if let range = body.range(of: pattern, options: .backwards) {
                if best == nil || range.lowerBound > best!.lowerBound {
                    best = range
                }
            }
        }
        return best
    }

    private static func lastTrailingDashSignaturePayload(in body: String) -> String? {
        guard let range = trailingDelimiterRange(in: body) else { return nil }
        return String(body[range.upperBound...])
    }

    /// Ensure exactly one trailing plain signature when no logo; strip all when logo owns the sig.
    static func appendPlainIfNeeded(body: String, signature: String?, logoPath: String? = nil) -> String {
        let text = trimmed(signature)
        let base = stripTrailingSignaturePayload(from: body, signature: text)
        if hasUsableLogo(logoPath) {
            // Logo is the signature — keep body free of trailing `--` text blocks.
            return base
        }
        guard !text.isEmpty else { return base }
        return base + plainBlock(signature: text)
    }

    /// Swap From-account signature: drop trailing sig blocks, then attach the new account's compose form.
    static func replaceSignature(
        in body: String,
        old: String?,
        new: String?,
        newLogoPath: String? = nil
    ) -> String {
        _ = old
        let withoutOld = stripTrailingSignaturePayload(from: body, signature: old)
        let cleaned = stripTrailingDashSignatures(from: withoutOld)
        return appendPlainIfNeeded(body: cleaned, signature: new, logoPath: newLogoPath)
    }

    static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Build outbound body. Logo → HTML image signature only (no plain `--` text). Plain otherwise.
    static func outboundBody(
        draftBody: String,
        signature: String?,
        logoPath: String?
    ) -> (content: String, isHTML: Bool) {
        let text = trimmed(signature)
        let base = stripTrailingSignaturePayload(from: draftBody, signature: text)

        guard hasUsableLogo(logoPath),
              let logoPath,
              let data = AttachmentStore.load(path: logoPath),
              !data.isEmpty else {
            let withSig = text.isEmpty ? base : base + plainBlock(signature: text)
            return (withSig, false)
        }

        let mime = AttachmentStore.mimeType(forFilename: logoPath)
        let safeMime = mime.hasPrefix("image/") ? mime : "image/png"
        let b64 = data.base64EncodedString()
        let escapedBody = escapeHTML(base).replacingOccurrences(of: "\n", with: "<br>\n")
        // One signature unit: image + optional name lines (no `--` delimiter — that was stacking with the logo).
        let captionHTML: String
        if text.isEmpty {
            captionHTML = ""
        } else {
            let escapedSig = escapeHTML(text).replacingOccurrences(of: "\n", with: "<br>\n")
            captionHTML = """
            <div style="margin-top:8px;font-size:13px;line-height:1.35;color:#222;">\(escapedSig)</div>
            """
        }
        let html = """
        <div style="font-family:-apple-system,BlinkMacSystemFont,sans-serif;font-size:14px;line-height:1.45;color:#222;">
        \(escapedBody)
        <div style="margin-top:12px;">
        <img src="data:\(safeMime);base64,\(b64)" alt="Signature" style="max-height:120px;max-width:280px;height:auto;" />
        \(captionHTML)
        </div>
        </div>
        """
        return (html, true)
    }

    /// Plain compose preview note when a logo is configured (TextEditor can't show images).
    static func plainComposeHint(hasLogo: Bool) -> String {
        hasLogo ? "" : ""
    }
}

/// Small images stored beside attachments for per-account signature logos.
enum SignatureLogoStore {
    private static let folderName = "RapSoDeeSignatureLogos"

    static var rootDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func importLogo(from url: URL, accountID: UUID) throws -> String {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard let image = NSImage(data: data), image.isValid else {
            throw MailNetError.unexpected("Choose a PNG, JPEG, or GIF logo image.")
        }
        // Soft cap — keep signatures small.
        guard data.count <= 512_000 else {
            throw MailNetError.unexpected("Logo is too large (max 512 KB).")
        }
        let ext = url.pathExtension.lowercased().isEmpty ? "png" : url.pathExtension.lowercased()
        let filename = "\(accountID.uuidString).\(ext)"
        let dest = rootDirectory.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.removeItem(at: dest)
        }
        try data.write(to: dest, options: .atomic)
        return dest.path
    }

    static func removeLogo(at path: String?) {
        guard let path, !path.isEmpty else { return }
        try? FileManager.default.removeItem(atPath: path)
    }
}
