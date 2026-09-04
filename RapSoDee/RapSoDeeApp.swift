import SwiftUI
import SwiftData
import AppKit

/// Catches custom-scheme redirects (msauth.local.rapsodee.mail://auth) that arrive via AppKit.
final class RapSoDeeAppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            MSALAuthService.handle(url: url)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // No-op; useful hook if we later drain a pending auth redirect.
    }
}

@main
struct RapSoDeeApp: App {
    @NSApplicationDelegateAdaptor(RapSoDeeAppDelegate.self) private var appDelegate
    @State private var store = DemoMailStore()

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([PersistedFlag.self, PersistedAppSettings.self])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // Stage 1: wipe local store on lightweight-migration mismatches (e.g. new settings fields).
            let url = configuration.url
            let fm = FileManager.default
            for suffix in ["", "-shm", "-wal"] {
                let victim = URL(fileURLWithPath: url.path + suffix)
                try? fm.removeItem(at: victim)
            }
            do {
                return try ModelContainer(for: schema, configurations: [configuration])
            } catch {
                fatalError("Could not create ModelContainer: \(error)")
            }
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .tint(MuseTheme.leaf)
                .onOpenURL { url in
                    MSALAuthService.handle(url: url)
                }
        }
        .modelContainer(sharedModelContainer)
        .defaultSize(width: 1280, height: 800)
        .commands {
            RapKeyboardCommands()
        }

        WindowGroup("Compose", id: "compose", for: UUID.self) { $draftID in
            if let draftID, let draft = ComposeSession.shared.draft(id: draftID) {
                ComposeView(draft: draft, isPopOut: true)
                    .environment(store)
                    .tint(MuseTheme.leaf)
            } else {
                Text("Compose window closed")
                    .padding()
            }
        }
        .defaultSize(width: 720, height: 560)
    }
}

/// Lightweight bridge so pop-out compose windows can resolve drafts.
@Observable
final class ComposeSession {
    static let shared = ComposeSession()
    private var drafts: [UUID: ComposeDraft] = [:]

    func register(_ draft: ComposeDraft) {
        drafts[draft.id] = draft
    }

    func update(_ draft: ComposeDraft) {
        drafts[draft.id] = draft
    }

    func remove(_ id: UUID) {
        drafts[id] = nil
    }

    func draft(id: UUID) -> ComposeDraft? {
        drafts[id]
    }
}
