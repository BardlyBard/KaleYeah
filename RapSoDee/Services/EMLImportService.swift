import Foundation
import AppKit
import UniformTypeIdentifiers

/// Built-in destinations plus a way to pick any synced Graph folder by id.
enum EMLImportDestination: String, CaseIterable, Identifiable, Sendable {
    case inbox
    case sent
    case archive
    case drafts
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inbox: return "Inbox"
        case .sent: return "Sent Items"
        case .archive: return "Archive"
        case .drafts: return "Drafts"
        case .custom: return "Custom folder ID"
        }
    }

    /// Graph well-known folder name, or nil when custom ID is required.
    var wellKnownName: String? {
        switch self {
        case .inbox: return "inbox"
        case .sent: return "sentitems"
        case .archive: return "archive"
        case .drafts: return "drafts"
        case .custom: return nil
        }
    }
}

/// Named row for the Settings / import destination picker (well-known + synced customs).
struct EMLImportFolderOption: Identifiable, Hashable, Sendable {
    /// Stable picker id (well-known name or Graph folder id).
    var id: String
    var title: String
    /// Value passed to Graph `mailFolders/{id}` (well-known name or real id).
    var graphFolderID: String
    var isCustom: Bool
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

    /// Inter-file pacing (serial import). Keeps under Graph IncomingBytes limits.
    private static let interFileDelayNs: UInt64 = 400_000_000
    /// Initial attempt + retries for the same file on 429.
    private static let maxAttemptsPerFile = 5
    private static let consecutiveThrottleSoftLimit = 3
    private static let consecutiveThrottleHardLimit = 6

    /// Import each EML into the signed-in mailbox via Graph. Continues on per-file errors.
    /// Serial (concurrency 1): honors Retry-After / exponential backoff on 429; only counts a
    /// file failed after retries are exhausted. Message-ID duplicate skip still applies.
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
        var consecutiveThrottles = 0

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
                    let exists = try await withGraphThrottleRetry(
                        fileName: name,
                        progress: &progress,
                        consecutiveThrottles: &consecutiveThrottles,
                        onProgress: onProgress
                    ) {
                        try await MicrosoftGraphMailService.messageExists(
                            accessToken: accessToken,
                            internetMessageId: mid
                        )
                    }
                    if exists {
                        seenMessageIDs.insert(key)
                        progress.skippedDuplicates += 1
                        progress.completed += 1
                        progress.statusLine = "Skipped existing \(name)"
                        await onProgress(progress)
                        try? await Task.sleep(nanoseconds: interFileDelayNs)
                        continue
                    }
                    seenMessageIDs.insert(key)
                }

                _ = try await withGraphThrottleRetry(
                    fileName: name,
                    progress: &progress,
                    consecutiveThrottles: &consecutiveThrottles,
                    onProgress: onProgress
                ) {
                    try await MicrosoftGraphMailService.importEML(
                        accessToken: accessToken,
                        folderID: destinationFolderID,
                        parsed: parsed
                    )
                }
                consecutiveThrottles = 0
                progress.imported += 1
                progress.completed += 1
                progress.statusLine = "Imported \(progress.imported)/\(progress.total)"
                await onProgress(progress)
            } catch is CancellationError {
                progress.statusLine = "Cancelled — \(progress.imported)/\(progress.total) imported"
                await onProgress(progress)
                break
            } catch {
                let reason = String(error.localizedDescription.prefix(200))
                progress.failures.append((file: name, reason: reason))
                progress.completed += 1
                progress.statusLine = "Failed \(name): \(reason)"
                await onProgress(progress)
                if MicrosoftGraphMailService.isThrottlingError(error) {
                    consecutiveThrottles += 1
                } else {
                    consecutiveThrottles = 0
                }
            }

            try? await Task.sleep(nanoseconds: interFileDelayNs)
        }

        let failNote = progress.failures.isEmpty ? "" : ", \(progress.failures.count) failed"
        let skipNote = progress.skippedDuplicates == 0 ? "" : ", \(progress.skippedDuplicates) skipped"
        progress.currentFile = nil
        progress.statusLine = "Done — \(progress.imported)/\(progress.total) imported\(skipNote)\(failNote)"
        await onProgress(progress)
        return progress
    }

    /// Retry the same Graph call a few times on 429 before the caller counts a failure.
    private static func withGraphThrottleRetry<T>(
        fileName: String,
        progress: inout EMLImportProgress,
        consecutiveThrottles: inout Int,
        onProgress: @MainActor @escaping (EMLImportProgress) -> Void,
        operation: () async throws -> T
    ) async throws -> T {
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await operation()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard MicrosoftGraphMailService.isThrottlingError(error),
                      attempt < maxAttemptsPerFile else {
                    throw error
                }
                consecutiveThrottles += 1
                let retryAfter = MicrosoftGraphMailService.retryAfterSeconds(from: error)
                // Exponential backoff: 2s, 4s, 8s, 16s… capped; honor Retry-After when larger.
                var wait = retryAfter ?? min(60, pow(2.0, Double(attempt)))
                if let retryAfter {
                    wait = max(wait, retryAfter)
                }
                if consecutiveThrottles >= consecutiveThrottleSoftLimit {
                    wait = max(wait, 15)
                }
                if consecutiveThrottles >= consecutiveThrottleHardLimit {
                    wait = max(wait, 30)
                }
                wait = min(max(wait, 1), 120)
                let secs = Int(ceil(wait))
                progress.statusLine = "Microsoft throttled — waiting \(secs)s… (\(fileName))"
                await onProgress(progress)
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000.0))
                progress.statusLine = "Retrying \(fileName) (attempt \(attempt + 1)/\(maxAttemptsPerFile))…"
                await onProgress(progress)
            }
        }
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
