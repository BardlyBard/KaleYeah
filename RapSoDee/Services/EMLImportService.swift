import Foundation
import AppKit
import UniformTypeIdentifiers

enum EMLImportDestination: String, CaseIterable, Identifiable, Sendable {
    case inbox
    case archive
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inbox: return "Inbox"
        case .archive: return "Archive"
        case .custom: return "Custom folder ID"
        }
    }

    /// Graph well-known folder name, or nil when custom ID is required.
    var wellKnownName: String? {
        switch self {
        case .inbox: return "inbox"
        case .archive: return "archive"
        case .custom: return nil
        }
    }
}

struct EMLImportProgress: Sendable {
    var total: Int
    var completed: Int
    var imported: Int
    var skippedDuplicates: Int
    var failures: [(file: String, reason: String)]
    var currentFile: String?
    var statusLine: String

    static func empty(total: Int = 0) -> EMLImportProgress {
        EMLImportProgress(
            total: total,
            completed: 0,
            imported: 0,
            skippedDuplicates: 0,
            failures: [],
            currentFile: nil,
            statusLine: total == 0 ? "No .eml files found" : "Starting…"
        )
    }
}

enum EMLImportService {
    /// Recursively collect `.eml` / `.EML` files from folders and individual file URLs.
    static func collectEMLFiles(from urls: [URL]) -> [URL] {
        var found: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                guard let enumerator = fm.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for case let fileURL as URL in enumerator {
                    if isEML(fileURL) { found.append(fileURL) }
                }
            } else if isEML(url) {
                found.append(url)
            }
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0.path).inserted }.sorted { $0.path < $1.path }
    }

    private static func isEML(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "eml"
    }

    /// Import each EML into the signed-in mailbox via Graph. Continues on per-file errors.
    static func importFiles(
        _ files: [URL],
        accessToken: String,
        destinationFolderID: String,
        onProgress: @MainActor @escaping (EMLImportProgress) -> Void
    ) async -> EMLImportProgress {
        var progress = EMLImportProgress.empty(total: files.count)
        await onProgress(progress)
        guard !files.isEmpty else { return progress }

        var seenMessageIDs = Set<String>()

        for (index, fileURL) in files.enumerated() {
            if Task.isCancelled {
                progress.statusLine = "Cancelled — \(progress.imported)/\(progress.total) imported"
                await onProgress(progress)
                break
            }
            let name = fileURL.lastPathComponent
            progress.currentFile = name
            progress.statusLine = "Importing \(index + 1)/\(files.count): \(name)"
            await onProgress(progress)

            do {
                let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
                let parsed = try EMLFileParser.parse(data: data)

                if let mid = parsed.internetMessageId {
                    let key = mid.lowercased()
                    if seenMessageIDs.contains(key) {
                        progress.skippedDuplicates += 1
                        progress.completed += 1
                        progress.statusLine = "Skipped duplicate \(name)"
                        await onProgress(progress)
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        continue
                    }
                    if try await MicrosoftGraphMailService.messageExists(
                        accessToken: accessToken,
                        internetMessageId: mid
                    ) {
                        seenMessageIDs.insert(key)
                        progress.skippedDuplicates += 1
                        progress.completed += 1
                        progress.statusLine = "Skipped existing \(name)"
                        await onProgress(progress)
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        continue
                    }
                    seenMessageIDs.insert(key)
                }

                _ = try await MicrosoftGraphMailService.importEML(
                    accessToken: accessToken,
                    folderID: destinationFolderID,
                    parsed: parsed
                )
                progress.imported += 1
                progress.completed += 1
                progress.statusLine = "Imported \(progress.imported)/\(progress.total)"
                await onProgress(progress)
            } catch {
                let reason = String(error.localizedDescription.prefix(200))
                progress.failures.append((file: name, reason: reason))
                progress.completed += 1
                progress.statusLine = "Failed \(name): \(reason)"
                await onProgress(progress)
                if reason.contains("429") || reason.localizedCaseInsensitiveContains("throttl") {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }

            try? await Task.sleep(nanoseconds: 350_000_000)
        }

        let failNote = progress.failures.isEmpty ? "" : ", \(progress.failures.count) failed"
        let skipNote = progress.skippedDuplicates == 0 ? "" : ", \(progress.skippedDuplicates) skipped"
        progress.currentFile = nil
        progress.statusLine = "Done — \(progress.imported)/\(progress.total) imported\(skipNote)\(failNote)"
        await onProgress(progress)
        return progress
    }

    /// Present an NSOpenPanel for a folder and/or multiple `.eml` files.
    @MainActor
    static func pickEMLSources() -> [URL]? {
        let panel = NSOpenPanel()
        panel.title = "Import EML"
        panel.message = "Choose a folder of Zoho/backup .eml files, or select one or more .eml files."
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        if let eml = UTType(filenameExtension: "eml") {
            panel.allowedContentTypes = [eml, .folder]
        }
        let result = panel.runModal()
        guard result == .OK else { return nil }
        return panel.urls
    }
}
