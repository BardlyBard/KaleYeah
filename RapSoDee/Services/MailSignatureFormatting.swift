import Foundation
import AppKit

/// Single place for signature blocks so compose + send never double-append.
enum MailSignatureFormatting {
    static func trimmed(_ signature: String?) -> String {
        (signature ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Plain-text signature block including leading separators.
    static func plainBlock(signature: String?) -> String {
        let text = trimmed(signature)
        guard !text.isEmpty else { return "" }
        return "\n\n--\n" + text
    }

    /// True when this signature already appears as the sole trailing `--` block.
    static func bodyAlreadyHasSignature(_ body: String, signature: String?) -> Bool {
        let text = trimmed(signature)
        guard !text.isEmpty else { return true }
        let block = plainBlock(signature: text)
        if body.hasSuffix(block) { return true }
        if let last = lastTrailingDashSignaturePayload(in: body) {
            return trimmed(last) == text
        }
        return false
    }

    /// RFC 3676-style: strip every trailing `\n--\n…` block (stacked / mismatched account sigs).
    static func stripTrailingDashSignatures(from body: String) -> String {
        var result = body
        while let range = result.range(of: "\n--\n", options: .backwards) {
            result = String(result[..<range.lowerBound])
        }
        let t = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("--\n") || t == "--" {
            return ""
        }
        while result.hasSuffix("\n") { result.removeLast() }
        return result
    }

    private static func lastTrailingDashSignaturePayload(in body: String) -> String? {
        guard let range = body.range(of: "\n--\n", options: .backwards) else { return nil }
        return String(body[range.upperBound...])
    }

    /// Ensure exactly one trailing signature (strips prior `--` blocks first, then appends once).
    static func appendPlainIfNeeded(body: String, signature: String?) -> String {
        let text = trimmed(signature)
        let base = stripTrailingDashSignatures(from: body)
        guard !text.isEmpty else { return base }
        return base + plainBlock(signature: text)
    }

    /// Swap From-account signature: drop all trailing `--` blocks, then attach the new one once.
    static func replaceSignature(in body: String, old: String?, new: String?) -> String {
        _ = old // May differ by punctuation/account; stripping all trailing `--` blocks is safer.
        return appendPlainIfNeeded(body: body, signature: new)
    }

    static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Build outbound body. With a logo → HTML (img data URI). Plain otherwise.
    static func outboundBody(
        draftBody: String,
        signature: String?,
        logoPath: String?
    ) -> (content: String, isHTML: Bool) {
        let withSig = appendPlainIfNeeded(body: draftBody, signature: signature)
        guard let logoPath,
              !logoPath.isEmpty,
              let data = AttachmentStore.load(path: logoPath),
              !data.isEmpty else {
            return (withSig, false)
        }
        let mime = AttachmentStore.mimeType(forFilename: logoPath)
        let safeMime = mime.hasPrefix("image/") ? mime : "image/png"
        let b64 = data.base64EncodedString()
        let escaped = escapeHTML(withSig).replacingOccurrences(of: "\n", with: "<br>\n")
        let html = """
        <div style="font-family:-apple-system,BlinkMacSystemFont,sans-serif;font-size:14px;line-height:1.45;color:#222;">
        \(escaped)
        <div style="margin-top:10px;">
        <img src="data:\(safeMime);base64,\(b64)" alt="Signature logo" style="max-height:72px;max-width:220px;height:auto;" />
        </div>
        </div>
        """
        return (html, true)
    }

    /// Plain compose preview note when a logo is configured (TextEditor can't show images).
    static func plainComposeHint(hasLogo: Bool) -> String {
        hasLogo ? "\n\n[Signature logo will be included on send]" : ""
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
