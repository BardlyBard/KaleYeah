import Foundation
import UniformTypeIdentifiers

/// Disk cache for inbound/outbound attachment bytes. Never logs file contents.
enum AttachmentStore {
    private static let folderName = "RapSoDeeAttachments"

    static var rootDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes bytes to a unique path under Application Support. Returns absolute path.
    @discardableResult
    static func save(data: Data, filename: String, messageID: UUID) throws -> String {
        let safe = sanitizeFilename(filename)
        let dir = rootDirectory.appendingPathComponent(messageID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var url = dir.appendingPathComponent(safe)
        if FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(safe)")
        }
        try data.write(to: url, options: .atomic)
        return url.path
    }

    static func load(path: String) -> Data? {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func fileURL(path: String) -> URL {
        URL(fileURLWithPath: path)
    }

    static func mimeType(forFilename filename: String) -> String {
        let ext = (filename as NSString).pathExtension
        if let ut = UTType(filenameExtension: ext), let mime = ut.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }

    /// Copy a user-selected file into the cache (sandbox-friendly for later send).
    static func importUserFile(from url: URL) throws -> (path: String, filename: String, mimeType: String, byteSize: Int) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        let data = try Data(contentsOf: url)
        let filename = url.lastPathComponent
        let path = try save(data: data, filename: filename, messageID: UUID())
        return (path, filename, mimeType(forFilename: filename), data.count)
    }

    private static func sanitizeFilename(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "attachment" : trimmed
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        return base.components(separatedBy: illegal).joined(separator: "_")
    }
}
