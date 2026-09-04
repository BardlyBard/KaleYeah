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
    @State private var gmailEmail = GmailDefaults.defaultEmail
    @State private var gmailAppPassword = ""
    @State private var gmailSecureFieldID = UUID()
    @State private var gmailBusy = false

    @State private var office365Email = Office365Defaults.defaultEmail
    @State private var office365Password = ""
    @State private var office365SecureFieldID = UUID()
    @State private var office365Busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Accounts — Gmail") {
                    TextField("Email", text: $gmailEmail)
                        // Avoid .username/.password content types in Form — they break binding updates on macOS.
                    MacSecureField(text: $gmailAppPassword, placeholder: "Gmail App Password")
                        .frame(maxWidth: .infinity, minHeight: 22)
                        .id(gmailSecureFieldID)
                    HStack {
                        if gmailPasswordTrimmed.isEmpty {
                            Text("No password entered")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Password entered (\(gmailPasswordTrimmed.count) characters)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    Text("Create an App Password at Google Account → Security (2FA required). Stored only in macOS Keychain — never committed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let gmail = store.gmailAccount() {
                        HStack(spacing: 8) {
                            Circle().fill(Color(hex: gmail.tintHex)).frame(width: 10, height: 10)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(gmail.name).font(.headline)
                                Text(gmail.email).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if store.gmailIsSyncing || gmailBusy {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }

                    if !store.gmailSyncStatus.isEmpty {
                        Text(store.gmailSyncStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let err = store.gmailLastError, !err.isEmpty {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    // Standard Form buttons — MuseCapsule can swallow clicks inside Form rows.
                    HStack(spacing: 10) {
                        Button(store.gmailAccount() == nil ? "Add Gmail" : "Save Password") {
                            Task { await saveGmail() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSaveGmail)

                        Button("Test connection") {
                            Task { await testGmailFromSettings() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(!canTestGmail)

                        Button("Sync now") {
                            Task {
                                gmailBusy = true
                                await store.syncGmailNow()
                                gmailBusy = false
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(!canSyncGmail)
                    }

                    if store.gmailAccount() != nil {
                        Button("Remove Gmail account", role: .destructive) {
                            store.removeGmailAccount()
                            gmailAppPassword = ""
                            gmailSecureFieldID = UUID()
                            gmailEmail = GmailDefaults.defaultEmail
                        }
                    }
                }

                Section("Accounts — Microsoft 365") {
                    TextField("Email", text: $office365Email)
                    MacSecureField(text: $office365Password, placeholder: "Mailbox password")
                        .frame(maxWidth: .infinity, minHeight: 22)
                        .id(office365SecureFieldID)
                    HStack {
                        if office365PasswordTrimmed.isEmpty {
                            Text("No password entered")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Password entered (\(office365PasswordTrimmed.count) characters)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    Text("GoDaddy Email Essentials / Microsoft 365 mailbox password for \(Office365Defaults.defaultEmail). IMAP outlook.office365.com:993 · SMTP smtp.office365.com:587 STARTTLS. Stored only in macOS Keychain — never committed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let m365 = store.office365Account() {
                        HStack(spacing: 8) {
                            Circle().fill(Color(hex: m365.tintHex)).frame(width: 10, height: 10)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m365.name).font(.headline)
                                Text(m365.email).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if store.office365IsSyncing || office365Busy {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }

                    if !store.office365SyncStatus.isEmpty {
                        Text(store.office365SyncStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let err = store.office365LastError, !err.isEmpty {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    HStack(spacing: 10) {
                        Button(store.office365Account() == nil ? "Add Microsoft 365" : "Save Password") {
                            Task { await saveOffice365() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSaveOffice365)

                        Button("Test connection") {
                            Task { await testOffice365FromSettings() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(!canTestOffice365)

                        Button("Sync now") {
                            Task {
                                office365Busy = true
                                await store.syncOffice365Now()
                                office365Busy = false
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(!canSyncOffice365)
                    }

                    if store.office365Account() != nil {
                        Button("Remove Microsoft 365 account", role: .destructive) {
                            store.removeOffice365Account()
                            office365Password = ""
                            office365SecureFieldID = UUID()
                            office365Email = Office365Defaults.defaultEmail
                        }
                    }
                }

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
                            // Name and color are independent — rename never touches colorHex.
                            TextField("Name", text: Binding(
                                get: { liveFlag(flag.id)?.name ?? flag.name },
                                set: { name in
                                    store.renameFlag(id: flag.id, name: name)
                                    syncFlagsToSwiftData()
                                }
                            ))
                            ColorPicker(
                                "Color",
                                selection: Binding(
                                    get: { Color(hex: liveFlag(flag.id)?.colorHex ?? flag.colorHex) },
                                    set: { color in
                                        // Ignore spurious ColorPicker writes (e.g. after rename
                                        // re-render) and failed hex conversion so colorHex stays put.
                                        guard let hex = color.toHexStringOrNil() else { return }
                                        let current = liveFlag(flag.id)?.colorHex.uppercased()
                                        guard hex != current else { return }
                                        store.updateFlagColor(id: flag.id, colorHex: hex)
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

                Section("Notifications") {
                    Toggle("Play sound for new mail", isOn: Bindable(store).playSoundForNewMail)
                    Picker("Policy", selection: $notificationPolicy) {
                        Text("Focus-aware").tag("focusAware")
                        Text("VIP only").tag("vipOnly")
                        Text("Mute").tag("mute")
                    }
                    .onChange(of: notificationPolicy) { _, value in
                        store.notificationPolicyRaw = value
                    }
                    HStack(spacing: 10) {
                        Button("Preview sound") {
                            MuseNewMailSound.play()
                        }
                        .buttonStyle(MuseCapsuleButtonStyle())
                        Button("Simulate new mail") {
                            _ = store.simulateNewMail()
                        }
                        .buttonStyle(MuseCapsuleButtonStyle(prominent: true))
                    }
                    Text("Soft muse chime (~0.6s). Mute policy skips sound; VIP routing arrives later.")
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
            .scrollContentBackground(.hidden)
            .background(MuseTheme.paper.opacity(0.55))
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        persistSettingsBlob()
                        dismiss()
                    }
                    .buttonStyle(MuseCapsuleButtonStyle(prominent: true))
                }
            }
            .onAppear {
                loadSettingsBlob()
                notificationPolicy = store.notificationPolicyRaw
                if let email = store.gmailAccount()?.email ?? GmailSyncService.storedEmail() {
                    gmailEmail = email
                } else {
                    gmailEmail = GmailDefaults.defaultEmail
                }
                if let email = store.office365Account()?.email ?? Office365SyncService.storedEmail() {
                    office365Email = email
                } else {
                    office365Email = Office365Defaults.defaultEmail
                }
            }
        }
        .frame(minWidth: 560, minHeight: 480)
    }


    private var gmailEmailTrimmed: String {
        gmailEmail.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var gmailPasswordTrimmed: String {
        gmailAppPassword.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSaveGmail: Bool {
        !gmailBusy
            && !gmailEmailTrimmed.isEmpty
            && !gmailPasswordTrimmed.isEmpty
    }

    private var canTestGmail: Bool {
        guard !gmailBusy, !store.gmailIsSyncing, !gmailEmailTrimmed.isEmpty else { return false }
        if !gmailPasswordTrimmed.isEmpty { return true }
        return KeychainCredentialStore.hasCredentials(forEmail: gmailEmailTrimmed)
    }

    private var canSyncGmail: Bool {
        guard let account = store.gmailAccount(), !gmailBusy, !store.gmailIsSyncing else { return false }
        return KeychainCredentialStore.hasCredentials(forEmail: account.email)
    }

    private func saveGmail() async {
        gmailBusy = true
        store.gmailLastError = nil
        do {
            try store.saveGmailCredentials(email: gmailEmailTrimmed, appPassword: gmailPasswordTrimmed)
            gmailAppPassword = ""
            gmailSecureFieldID = UUID()
            store.gmailSyncStatus = "Credentials saved in Keychain."
            await store.testGmailConnection(email: gmailEmailTrimmed)
            if store.gmailLastError == nil {
                await store.syncGmailNow()
            }
        } catch {
            store.gmailLastError = error.localizedDescription
        }
        gmailBusy = false
    }

    private func testGmailFromSettings() async {
        gmailBusy = true
        let fieldPass = gmailPasswordTrimmed.isEmpty ? nil : gmailPasswordTrimmed
        await store.testGmailConnection(email: gmailEmailTrimmed, appPassword: fieldPass)
        gmailBusy = false
    }

    private var office365EmailTrimmed: String {
        office365Email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var office365PasswordTrimmed: String {
        office365Password.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSaveOffice365: Bool {
        !office365Busy
            && !office365EmailTrimmed.isEmpty
            && !office365PasswordTrimmed.isEmpty
    }

    private var canTestOffice365: Bool {
        guard !office365Busy, !store.office365IsSyncing, !office365EmailTrimmed.isEmpty else { return false }
        if !office365PasswordTrimmed.isEmpty { return true }
        return KeychainCredentialStore.hasCredentials(forEmail: office365EmailTrimmed)
    }

    private var canSyncOffice365: Bool {
        guard let account = store.office365Account(), !office365Busy, !store.office365IsSyncing else { return false }
        return KeychainCredentialStore.hasCredentials(forEmail: account.email)
    }

    private func saveOffice365() async {
        office365Busy = true
        store.office365LastError = nil
        do {
            try store.saveOffice365Credentials(email: office365EmailTrimmed, password: office365PasswordTrimmed)
            office365Password = ""
            office365SecureFieldID = UUID()
            store.office365SyncStatus = "Credentials saved in Keychain."
            await store.testOffice365Connection(email: office365EmailTrimmed)
            if store.office365LastError == nil {
                await store.syncOffice365Now()
            }
        } catch {
            store.office365LastError = error.localizedDescription
        }
        office365Busy = false
    }

    private func testOffice365FromSettings() async {
        office365Busy = true
        let fieldPass = office365PasswordTrimmed.isEmpty ? nil : office365PasswordTrimmed
        await store.testOffice365Connection(email: office365EmailTrimmed, password: fieldPass)
        office365Busy = false
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
        row.playSoundForNewMail = store.playSoundForNewMail
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
        store.notificationPolicyRaw = row.notificationPolicyRaw
        store.playSoundForNewMail = row.playSoundForNewMail
        if let data = row.accountsJSON, let accounts = try? JSONDecoder().decode([MailAccount].self, from: data) {
            // Keep live message IDs; merge settings fields onto seeded accounts by email.
            for account in accounts {
                if account.isLiveGmail || account.isLiveOffice365 {
                    continue // live IMAP accounts are restored from Keychain / UserDefaults
                }
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
