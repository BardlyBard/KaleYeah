import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(DemoMailStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PersistedFlag.sortOrder) private var persistedFlags: [PersistedFlag]

    @State private var newFlagName = ""
    @State private var newFlagColor = Color(hex: "E07A3D")
    @State private var vipText = ""
    @State private var notificationPolicy = "focusAware"

    var body: some View {
        NavigationStack {
            Form {
                Section("Unified Inbox — per-account toggles") {
                    ForEach(store.accounts) { account in
                        Toggle(isOn: Binding(
                            get: { account.includeInUnifiedInbox },
                            set: { store.setIncludeInUnifiedInbox(accountID: account.id, include: $0) }
                        )) {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(account.name)
                                    Text(account.email).font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Circle().fill(Color(hex: account.tintHex)).frame(width: 10, height: 10)
                            }
                        }
                        .disabled(account.isCalliope)
                    }
                }

                Section("Pin inboxes & reorder") {
                    ForEach(store.accounts.sorted(by: { $0.sortOrder < $1.sortOrder })) { account in
                        HStack {
                            Toggle("Pin \(account.name)", isOn: Binding(
                                get: { account.inboxPinned },
                                set: { store.setInboxPinned(accountID: account.id, pinned: $0) }
                            ))
                            Spacer()
                            Button("Up") { moveAccount(account.id, -1) }
                                .disabled(account.sortOrder == 0)
                            Button("Down") { moveAccount(account.id, 1) }
                                .disabled(account.sortOrder >= store.accounts.count - 1)
                        }
                    }
                }

                Section("Signatures (one per account)") {
                    ForEach(store.accounts) { account in
                        VStack(alignment: .leading) {
                            Text(account.name).font(.headline)
                            TextEditor(text: Binding(
                                get: { account.signature },
                                set: { store.updateSignature(accountID: account.id, signature: $0) }
                            ))
                            .font(.body)
                            .frame(minHeight: 64)
                        }
                    }
                }

                Section("Account tints") {
                    ForEach(store.accounts) { account in
                        HStack {
                            Text(account.name)
                            Spacer()
                            TextField("Hex", text: Binding(
                                get: { account.tintHex },
                                set: { store.updateAccountTint(accountID: account.id, hex: $0) }
                            ))
                            .frame(width: 90)
                            Circle().fill(Color(hex: account.tintHex)).frame(width: 14, height: 14)
                        }
                    }
                }

                Section("Named flags") {
                    ForEach(store.flags) { flag in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(Color(hex: liveFlag(flag.id)?.colorHex ?? flag.colorHex))
                                .frame(width: 14, height: 14)
                            TextField("Name", text: Binding(
                                get: { liveFlag(flag.id)?.name ?? flag.name },
                                set: { name in
                                    guard var updated = liveFlag(flag.id) else { return }
                                    updated.name = name
                                    store.upsertFlag(updated)
                                    syncFlagsToSwiftData()
                                }
                            ))
                            ColorPicker(
                                "Color",
                                selection: Binding(
                                    get: { Color(hex: liveFlag(flag.id)?.colorHex ?? flag.colorHex) },
                                    set: { color in
                                        guard var updated = liveFlag(flag.id) else { return }
                                        updated.colorHex = color.toHexString()
                                        store.upsertFlag(updated)
                                        syncFlagsToSwiftData()
                                    }
                                ),
                                supportsOpacity: false
                            )
                            .labelsHidden()
                            .frame(width: 36)
                            Button("Remove", role: .destructive) {
                                store.deleteFlag(flag.id)
                                syncFlagsToSwiftData()
                            }
                        }
                    }
                    HStack(spacing: 10) {
                        Circle()
                            .fill(newFlagColor)
                            .frame(width: 14, height: 14)
                        TextField("Flag name", text: $newFlagName)
                        ColorPicker("Color", selection: $newFlagColor, supportsOpacity: false)
                            .labelsHidden()
                            .frame(width: 36)
                        Button("Add") {
                            guard !newFlagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                            let flag = MailFlag(name: newFlagName.trimmingCharacters(in: .whitespacesAndNewlines), colorHex: newFlagColor.toHexString())
                            store.upsertFlag(flag)
                            newFlagName = ""
                            newFlagColor = Color(hex: "E07A3D")
                            syncFlagsToSwiftData()
                        }
                    }
                    Text("Choose a color with the picker — stored as hex under the hood.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("VIP (stub)") {
                    TextField("Comma-separated addresses", text: $vipText)
                    Text("VIP badges & priority routing arrive in a later stage.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Notifications (stub)") {
                    Picker("Policy", selection: $notificationPolicy) {
                        Text("Focus-aware").tag("focusAware")
                        Text("VIP only").tag("vipOnly")
                        Text("Mute").tag("mute")
                    }
                    Text("Policy is persisted for Stage 1; delivery hooks come later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Junk + Train (stub)") {
                    Text("Mark as Junk and Train sender are wired as mailbox actions later. Demo Junk folder exists.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        persistSettingsBlob()
                        dismiss()
                    }
                }
            }
            .onAppear {
                loadSettingsBlob()
            }
        }
        .frame(minWidth: 560, minHeight: 480)
    }

    private func liveFlag(_ id: UUID) -> MailFlag? {
        store.flags.first { $0.id == id }
    }

    private func moveAccount(_ id: UUID, _ delta: Int) {
        var ids = store.accounts.sorted { $0.sortOrder < $1.sortOrder }.map(\.id)
        guard let idx = ids.firstIndex(of: id) else { return }
        let newIdx = idx + delta
        guard ids.indices.contains(newIdx) else { return }
        ids.swapAt(idx, newIdx)
        store.reorderAccounts(ids)
    }

    private func syncFlagsToSwiftData() {
        let existing = (try? modelContext.fetch(FetchDescriptor<PersistedFlag>())) ?? []
        for row in existing { modelContext.delete(row) }
        for (i, flag) in store.flags.enumerated() {
            modelContext.insert(PersistedFlag(id: flag.id, name: flag.name, colorHex: flag.colorHex, sortOrder: i))
        }
        try? modelContext.save()
    }

    private func persistSettingsBlob() {
        let existing = (try? modelContext.fetch(FetchDescriptor<PersistedAppSettings>())) ?? []
        let row = existing.first ?? PersistedAppSettings()
        if existing.isEmpty { modelContext.insert(row) }
        row.sortRaw = store.sort.rawValue
        row.filterRaw = store.filter.rawValue
        row.vipAddressesCSV = vipText
        row.notificationPolicyRaw = notificationPolicy
        row.accountsJSON = try? JSONEncoder().encode(store.accounts)
        row.foldersJSON = try? JSONEncoder().encode(store.folders)
        try? modelContext.save()
        syncFlagsToSwiftData()
    }

    private func loadSettingsBlob() {
        let existing = (try? modelContext.fetch(FetchDescriptor<PersistedAppSettings>())) ?? []
        guard let row = existing.first else { return }
        if let sort = MessageSort(rawValue: row.sortRaw) { store.sort = sort }
        if let filter = MessageFilter(rawValue: row.filterRaw) { store.filter = filter }
        vipText = row.vipAddressesCSV
        notificationPolicy = row.notificationPolicyRaw
        if let data = row.accountsJSON, let accounts = try? JSONDecoder().decode([MailAccount].self, from: data) {
            // Keep live message IDs; merge settings fields onto seeded accounts by email.
            for account in accounts {
                if let i = store.accounts.firstIndex(where: { $0.email == account.email }) {
                    store.accounts[i].includeInUnifiedInbox = account.includeInUnifiedInbox
                    store.accounts[i].signature = account.signature
                    store.accounts[i].tintHex = account.tintHex
                    store.accounts[i].inboxPinned = account.inboxPinned
                    store.accounts[i].sortOrder = account.sortOrder
                }
            }
            store.accounts.sort { $0.sortOrder < $1.sortOrder }
        }
        if !persistedFlags.isEmpty {
            store.flags = persistedFlags.map { MailFlag(id: $0.id, name: $0.name, colorHex: $0.colorHex) }
        } else if store.flags.isEmpty {
            store.flags = MailFlag.defaults
            syncFlagsToSwiftData()
        }
    }
}
