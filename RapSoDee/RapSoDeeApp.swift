import SwiftUI
import SwiftData

@main
struct RapSoDeeApp: App {
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
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .tint(MuseTheme.leaf)
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
