import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

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

    @State private var office365Busy = false
    @State private var msalClientID = MSALAppConfig.clientID
    @State private var msalTenantID = MSALAppConfig.tenantID
    @State private var deviceCodePrompt: MSALDeviceCodePrompt?
    @State private var preferSMTPSend = MSALAppConfig.preferSMTPSend
    @State private var emlDestinationFolderID: String = "inbox"
    @State private var emlCustomFolderID = ""
    @State private var newFolderName = ""
    @State private var showAddMicrosoft365 = false
    @State private var addMicrosoft365Hint = MSALAppConfig.calliopeEmail
    @State private var showAdvancedMicrosoft = false
    @State private var emlImportAccountID: UUID?
    @State private var settingsTab: SettingsTab = .accounts
    @State private var signatureLogoError: String?

    private enum SettingsTab: String, CaseIterable, Identifiable {
        case accounts = "Accounts / setup"
        case creature = "Creature features"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Settings section", selection: $settingsTab) {
                    ForEach(SettingsTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

                Form {
                    switch settingsTab {
                    case .accounts:
                        accountsGmailSection
                        accountsMicrosoft365Section
                        syncSection
                        contactsSection
                        importEMLSection
                        aboutSection
                    case .creature:
                        oneInboxSection
                        appearanceSection
                        openSequenceSection
                        flagsSection
                        notificationsSection
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .background(MuseTheme.paper.opacity(0.55))
            }
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
                msalClientID = MSALAppConfig.clientID
                msalTenantID = MSALAppConfig.tenantID
                preferSMTPSend = MSALAppConfig.preferSMTPSend
                store.noteOffice365AuthStateChanged()
                store.restoreOffice365AccountShellIfNeeded()
                if store.office365Accounts().contains(where: {
                    $0.email.lowercased() == Office365Defaults.defaultEmail.lowercased()
                }) {
                    addMicrosoft365Hint = MSALAppConfig.calliopeEmail
                } else {
                    addMicrosoft365Hint = Office365Defaults.defaultEmail
                }
                if emlImportAccountID == nil {
                    emlImportAccountID = store.office365Account()?.id
                }
            }
        }
        // Sheet/Form on macOS often proposes a skinny ideal width; pin a usable size and allow resize.
        .frame(minWidth: 640, idealWidth: 720, maxWidth: 960,
               minHeight: 520, idealHeight: 700, maxHeight: 900)
        .background(SettingsSheetWindowConfigurator())
        .preferredColorScheme(.light)
    }

    // MARK: - Accounts — Gmail

    private var accountsGmailSection: some View {
        Section {
            TextField("Email", text: $gmailEmail)
            MacSecureField(text: $gmailAppPassword, placeholder: "Gmail App Password")
                .frame(maxWidth: .infinity, minHeight: 22)
                .id(gmailSecureFieldID)
            HStack(spacing: 8) {
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
            Text("Create an App Password at Google Account → Security (2FA required). Stored only in macOS Keychain.")
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
        } header: {
            Text("Accounts — Gmail")
        }
    }

    // MARK: - Accounts — Microsoft 365

    private var accountsMicrosoft365Section: some View {
        Section {
            Text("Derek and Callie can both stay signed in. Use Add Microsoft 365… for Calliope — Derek stays connected.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if store.office365Accounts().isEmpty {
                Text("No Microsoft 365 accounts yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(store.office365Accounts()) { account in
                microsoftAccountRow(account)
            }

            if showAddMicrosoft365 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Add Microsoft 365")
                        .font(.headline)
                    TextField("Email hint (Callie or Derek)", text: $addMicrosoft365Hint)
                    Text("Preferred: device code. Enter the code at microsoft.com/devicelogin while signed into that mailbox.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Button("Sign in with device code") {
                            Task { await addMicrosoft365(deviceCode: true) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(office365Busy || store.office365IsSyncing || msalClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button("Sign in with Microsoft") {
                            Task { await addMicrosoft365(deviceCode: false) }
                        }
                        .buttonStyle(.bordered)
                        .disabled(office365Busy || store.office365IsSyncing || msalClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button("Cancel") {
                            showAddMicrosoft365 = false
                            deviceCodePrompt = nil
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.vertical, 4)
            } else {
                Button("Add Microsoft 365…") {
                    if store.office365Accounts().contains(where: {
                        $0.email.lowercased() == Office365Defaults.defaultEmail.lowercased()
                    }) {
                        addMicrosoft365Hint = MSALAppConfig.calliopeEmail
                    }
                    showAddMicrosoft365 = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(office365Busy || store.office365IsSyncing)
            }

            if let prompt = deviceCodePrompt {
                deviceCodePromptView(prompt)
            }

            if !store.office365SyncStatus.isEmpty {
                Text(store.office365SyncStatus)
                    .font(.caption)
                    .foregroundStyle(store.office365LastError == nil ? Color.secondary : Color.orange)
                    .textSelection(.enabled)
            }
            if let err = store.office365LastError, !err.isEmpty {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if store.pendingServerOpCount > 0 {
                Text("\(store.pendingServerOpCount) queued file/read/flag action(s) will retry after a successful Sign in / Sync.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if store.office365IsSyncing || office365Busy {
                HStack(spacing: 10) {
                    if let started = store.office365SyncStartedAt {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let elapsed = Int(context.date.timeIntervalSince(started))
                            Text(elapsed >= 15
                                 ? "Still working (\(elapsed)s) — you can cancel"
                                 : "Working… \(elapsed)s")
                                .font(.caption)
                                .foregroundStyle(elapsed >= 15 ? .orange : .secondary)
                        }
                    } else {
                        Text("Working…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Cancel sign-in / sync") {
                        store.cancelOffice365Sync()
                        office365Busy = false
                        deviceCodePrompt = nil
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                }
            } else if let err = store.office365LastError,
                      err.localizedCaseInsensitiveContains("interactive session") {
                Button("Clear stuck sign-in") {
                    MSALAuthService.cancelPendingAuth()
                    store.cancelOffice365Sync()
                    office365Busy = false
                    deviceCodePrompt = nil
                    store.office365LastError = nil
                    store.office365SyncStatus = "Cleared stuck Microsoft sign-in. Try Add Microsoft 365… again."
                }
                .buttonStyle(.bordered)
                .tint(.orange)
            }

            DisclosureGroup("Advanced (Entra / SMTP)", isExpanded: $showAdvancedMicrosoft) {
                TextField("Application (client) ID", text: $msalClientID)
                    .onChange(of: msalClientID) { _, value in
                        MSALAppConfig.setClientIDOverride(value)
                        MSALAuthService.shared.rebuildApplicationIfPossible()
                    }
                Text("Paste the Entra Application (client) ID — stored in UserDefaults. Public client only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Directory (tenant) ID", text: $msalTenantID)
                    .onChange(of: msalTenantID) { _, value in
                        MSALAppConfig.setTenantIDOverride(value)
                        MSALAuthService.shared.rebuildApplicationIfPossible()
                    }
                Text("Authority: \(MSALAppConfig.authorityURL.absoluteString)")
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                Text(MSALAppConfig.redirectURI)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)

                Toggle("Prefer SMTP (XOAUTH2) for send", isOn: $preferSMTPSend)
                    .onChange(of: preferSMTPSend) { _, value in
                        MSALAppConfig.preferSMTPSend = value
                    }
                Text("Default uses Graph draft→send. Prefer SMTP tries XOAUTH2 first with Graph fallback.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Accounts — Microsoft 365")
        } footer: {
            Text("Callie setup: Add Microsoft 365… → enter calliope.voss@kaleyeahinspections.com → Sign in with device code. Derek stays signed in.")
                .font(.caption)
        }
    }

    @ViewBuilder
    private func microsoftAccountRow(_ account: MailAccount) -> some View {
        // Depend on auth revision so Sign in vs Sync updates per mailbox independently.
        let signedIn = store.isOffice365SignedIn(email: account.email)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(Color(hex: account.tintHex)).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(account.name).font(.headline)
                        if account.isCalliope || account.email.lowercased().contains("calliope") {
                            Text("Callie")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(MuseTheme.approveSoft)
                                .clipShape(Capsule())
                        }
                        if !signedIn {
                            Text("Needs sign-in")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.25))
                                .clipShape(Capsule())
                        }
                    }
                    Text(account.email).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if store.office365IsSyncing || office365Busy {
                    ProgressView().controlSize(.small)
                }
            }
            // Per-account controls stay visible for every shell. Auth state is independent:
            // Sign in… when THIS email has no valid token; Sync / Sign out only when it does.
            HStack(spacing: 10) {
                if signedIn {
                    Button("Sync") {
                        Task {
                            office365Busy = true
                            defer { office365Busy = false }
                            await store.syncOffice365Now()
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(office365Busy || store.office365IsSyncing)

                    Button("Sign out", role: .destructive) {
                        Task {
                            office365Busy = true
                            deviceCodePrompt = nil
                            defer { office365Busy = false }
                            await store.signOutMicrosoft365(accountID: account.id)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(office365Busy || store.office365IsSyncing)
                } else {
                    Button("Sign in…") {
                        addMicrosoft365Hint = account.email
                        showAddMicrosoft365 = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(office365Busy || store.office365IsSyncing)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func deviceCodePromptView(_ prompt: MSALDeviceCodePrompt) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Device code sign-in")
                .font(.headline)
            Text(prompt.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Text("Code:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(prompt.userCode)
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
                Button("Copy code") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(prompt.userCode, forType: .string)
                }
                .buttonStyle(.bordered)
            }
            HStack(spacing: 8) {
                Text(prompt.verificationURL.absoluteString)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Button("Copy URL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(prompt.verificationURL.absoluteString, forType: .string)
                }
                .buttonStyle(.bordered)
                Button("Open") {
                    NSWorkspace.shared.open(prompt.verificationURL)
                }
                .buttonStyle(.bordered)
            }
            Text("Stay on this page until RapSoDee finishes. Other Microsoft accounts remain signed in.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(MuseTheme.paper.opacity(0.8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func addMicrosoft365(deviceCode: Bool) async {
        office365Busy = true
        deviceCodePrompt = nil
        defer { office365Busy = false }
        let hint = addMicrosoft365Hint.trimmingCharacters(in: .whitespacesAndNewlines)
        if deviceCode {
            await store.signInMicrosoft365WithDeviceCode(
                clientIDOverride: msalClientID,
                tenantIDOverride: msalTenantID,
                loginHint: hint
            ) { prompt in
                deviceCodePrompt = prompt
                store.office365SyncStatus = "Enter code \(prompt.userCode) at \(prompt.verificationURL.host ?? "microsoft.com/devicelogin") for \(hint)"
            }
        } else {
            await store.signInMicrosoft365(
                clientIDOverride: msalClientID,
                tenantIDOverride: msalTenantID,
                loginHint: hint
            )
        }
        deviceCodePrompt = nil
        if store.office365Account(email: hint) != nil || store.office365LastError == nil {
            showAddMicrosoft365 = false
        }
    }

    // MARK: - Sync

    private var syncSection: some View {
        Section {
            Text("Sync all refreshes Gmail and every signed-in Microsoft 365 mailbox (Derek + Callie).")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Sync all connected accounts") {
                Task {
                    office365Busy = true
                    gmailBusy = true
                    defer {
                        office365Busy = false
                        gmailBusy = false
                    }
                    await store.syncAllConnectedAccounts()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(office365Busy || gmailBusy || store.isUniversalSyncing || store.gmailIsSyncing || store.office365IsSyncing)
        } header: {
            Text("Sync")
        }
    }


    // MARK: - Contacts (shared book)

    private var contactsSection: some View {
        Section {
            Text("One shared RapSoDee contact list across Gmail + Kale Yeah + Callie. Autofill works for any From account. Not synced into Outlook or Gmail contacts.")
                .font(.caption)
                .foregroundStyle(.secondary)
            LabeledContent("Contacts") {
                Text("\(store.contactCount)")
                    .font(.body.monospacedDigit())
            }
            if !store.contactsStatus.isEmpty {
                Text(store.contactsStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Button("Rebuild from mail") {
                let n = store.rebuildContactsFromMail(reason: "manual rebuild")
                store.contactsStatus = "\(n) contacts (manual rebuild)"
            }
            .buttonStyle(.bordered)
            Text("Stored under Application Support/RapSoDeeContacts/contacts.json. Optional export: exports/RapSoDeeContacts/ (see Scripts/backup-contacts.sh).")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } header: {
            Text("Contacts")
        }
    }

    // MARK: - Import EML

    private var importEMLSection: some View {
        Section {
            Text("Import Zoho / backup .eml into a Microsoft 365 mailbox (Graph). Sync first so folders appear. Not for PST.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if store.office365Accounts().count > 1 {
                Picker("Mailbox", selection: Binding(
                    get: { emlImportAccountID ?? store.office365Account()?.id ?? UUID() },
                    set: { emlImportAccountID = $0 }
                )) {
                    ForEach(store.office365Accounts()) { account in
                        Text("\(account.name) — \(account.email)").tag(account.id)
                    }
                }
            }

            let importOptions = store.office365EMLImportOptions()
            Picker("Destination folder", selection: $emlDestinationFolderID) {
                ForEach(importOptions) { opt in
                    Text(opt.title).tag(opt.graphFolderID)
                }
                Text("Custom folder ID…").tag("__custom__")
            }
            if emlDestinationFolderID == "__custom__" {
                TextField("Graph mailFolder id", text: $emlCustomFolderID)
                    .font(.system(.body, design: .monospaced))
            }
            HStack(spacing: 8) {
                TextField("New folder name", text: $newFolderName)
                Button("New Folder") {
                    Task {
                        office365Busy = true
                        defer { office365Busy = false }
                        if let created = await store.createOffice365Folder(displayName: newFolderName) {
                            emlDestinationFolderID = created.remoteID ?? emlDestinationFolderID
                            newFolderName = ""
                        }
                    }
                }
                .disabled(
                    office365Busy
                        || store.office365IsSyncing
                        || newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || store.office365Accounts().isEmpty
                )
            }
            HStack(spacing: 10) {
                Button("Import EML…") {
                    Task {
                        office365Busy = true
                        defer { office365Busy = false }
                        let options = store.office365EMLImportOptions()
                        let selectedID: String
                        let selectedTitle: String
                        if emlDestinationFolderID == "__custom__" {
                            selectedID = emlCustomFolderID
                            selectedTitle = "Custom"
                        } else if let opt = options.first(where: { $0.graphFolderID == emlDestinationFolderID }) {
                            selectedID = opt.graphFolderID
                            selectedTitle = opt.title
                        } else {
                            selectedID = emlDestinationFolderID
                            selectedTitle = emlDestinationFolderID
                        }
                        await store.importEMLIntoMicrosoft365(
                            destination: .custom,
                            customFolderID: selectedID,
                            graphFolderID: selectedID,
                            destinationTitle: selectedTitle
                        ) { prompt in
                            deviceCodePrompt = prompt
                            store.office365SyncStatus = "Enter code \(prompt.userCode) at \(prompt.verificationURL.host ?? "microsoft.com/devicelogin")"
                        }
                        deviceCodePrompt = nil
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    office365Busy
                        || store.office365IsSyncing
                        || store.emlImportIsRunning
                        || store.office365Accounts().isEmpty
                )
                if store.emlImportIsRunning {
                    Button("Cancel import") {
                        store.cancelEMLImport()
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                }
            }
            if let prog = store.emlImportProgress {
                VStack(alignment: .leading, spacing: 4) {
                    Text(prog.statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if prog.total > 0 {
                        ProgressView(value: Double(prog.completed), total: Double(max(prog.total, 1)))
                    }
                    if !prog.failures.isEmpty {
                        Text("Failures:")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                        ForEach(Array(prog.failures.prefix(8).enumerated()), id: \.offset) { _, fail in
                            Text("• \(fail.file): \(fail.reason)")
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                        if prog.failures.count > 8 {
                            Text("…and \(prog.failures.count - 8) more")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(8)
                .background(MuseTheme.paper.opacity(0.8))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        } header: {
            Text("Import EML")
        }
    }

    // MARK: - One Inbox / Display

    private var oneInboxSection: some View {
        Section {
            Text("Unified Inbox — one row per mailbox. Include / pin / reorder without duplicates.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(uniqueAccountsForDisplay) { account in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Circle().fill(Color(hex: account.tintHex)).frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(accountDisplayTitle(account))
                                .font(.headline)
                            Text(account.email)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer(minLength: 0)
                        Button("Up") { moveAccount(account.id, -1) }
                            .disabled(account.sortOrder == 0)
                        Button("Down") { moveAccount(account.id, 1) }
                            .disabled(account.sortOrder >= store.accounts.count - 1)
                    }
                    HStack(spacing: 16) {
                        Toggle("Include in One Inbox", isOn: Binding(
                            get: { account.isCalliopeMailbox ? false : account.includeInUnifiedInbox },
                            set: { store.setIncludeInUnifiedInbox(accountID: account.id, include: $0) }
                        ))
                        .disabled(account.isCalliopeMailbox)
                        Toggle("Pin", isOn: Binding(
                            get: { account.inboxPinned },
                            set: { store.setInboxPinned(accountID: account.id, pinned: $0) }
                        ))
                    }
                    if account.isCalliopeMailbox {
                        Text("Callie stays in her own mailbox — open her ladder to see her mail.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("One Inbox")
        }
    }

    /// Deduped by live provider + email so Settings never lists the same mailbox twice.
    private var uniqueAccountsForDisplay: [MailAccount] {
        var seen = Set<String>()
        var out: [MailAccount] = []
        for account in store.accounts.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            let provider = account.isLiveGmail ? "gmail" : (account.isLiveOffice365 ? "m365" : "other")
            let key = provider + "|" + account.email.lowercased() + "|" + account.id.uuidString
            // Prefer first occurrence of provider+email; skip later duplicates.
            let dedupeKey = provider + "|" + account.email.lowercased()
            if account.isLiveGmail || account.isLiveOffice365 {
                if seen.contains(dedupeKey) { continue }
                seen.insert(dedupeKey)
            } else {
                if seen.contains(key) { continue }
                seen.insert(key)
            }
            out.append(account)
        }
        return out
    }

    private func accountDisplayTitle(_ account: MailAccount) -> String {
        if account.isCalliope || account.email.lowercased().contains("calliope") {
            return account.name.lowercased().contains("call") ? account.name : "Calliope (\(account.name))"
        }
        if account.isLiveGmail {
            return account.name == "Gmail" ? "Gmail" : "\(account.name) (Gmail)"
        }
        if account.isLiveOffice365 {
            return account.name
        }
        return account.name
    }

    private var appearanceSection: some View {
        Section {
            Text("Permanent light mode is always on. Names, signatures, and tints are one row per mailbox (deduped).")
                .font(.caption)
                .foregroundStyle(.secondary)

            if uniqueAccountsForDisplay.isEmpty {
                Text("Connect Gmail or Microsoft 365 to rename accounts and mailboxes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(uniqueAccountsForDisplay) { account in
                TextField("Account name", text: Binding(
                    get: { account.name },
                    set: { store.renameAccount(accountID: account.id, name: $0) }
                ))
                Text(account.email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(store.folders.filter { $0.accountID == account.id }.sorted(by: { $0.sortOrder < $1.sortOrder })) { folder in
                    TextField(folder.kind == .custom ? "Custom folder" : "Mailbox label", text: Binding(
                        get: { store.displayName(for: folder) },
                        set: { store.renameFolder(folderID: folder.id, name: $0) }
                    ))
                    .padding(.leading, 12)
                }
            }

            ForEach(uniqueAccountsForDisplay) { account in
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(accountDisplayTitle(account)) signature").font(.headline)
                    TextEditor(text: Binding(
                        get: { account.signature },
                        set: { store.updateSignature(accountID: account.id, signature: $0) }
                    ))
                    .font(.body)
                    .frame(minHeight: 64)
                    signatureLogoControls(for: account)
                }
            }

            if let signatureLogoError, !signatureLogoError.isEmpty {
                Text(signatureLogoError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            ForEach(uniqueAccountsForDisplay) { account in
                HStack {
                    Text(accountDisplayTitle(account))
                    Spacer()
                    TextField("Hex", text: Binding(
                        get: { account.tintHex },
                        set: { store.updateAccountTint(accountID: account.id, hex: $0) }
                    ))
                    .frame(width: 90)
                    Circle().fill(Color(hex: account.tintHex)).frame(width: 14, height: 14)
                }
            }
        } header: {
            Text("Appearance & signatures")
        }
    }

    @ViewBuilder
    private func signatureLogoControls(for account: MailAccount) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if let path = account.signatureLogoPath,
               !path.isEmpty,
               let data = AttachmentStore.load(path: path),
               let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 72, height: 48)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Text("No logo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 72, height: 48)
                    .background(Color.secondary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 6) {
                Button("Choose logo…") {
                    pickSignatureLogo(for: account.id)
                }
                .buttonStyle(.bordered)
                if account.signatureLogoPath != nil {
                    Button("Remove logo", role: .destructive) {
                        signatureLogoError = nil
                        store.updateSignatureLogo(accountID: account.id, path: nil)
                    }
                    .buttonStyle(.bordered)
                }
                Text("Small PNG/JPEG/GIF (≤512 KB). With a logo, compose/send use the image + name once (no extra -- text block).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func pickSignatureLogo(for accountID: UUID) {
        signatureLogoError = nil
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP]
        panel.message = "Choose a small signature logo"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let path = try SignatureLogoStore.importLogo(from: url, accountID: accountID)
            store.updateSignatureLogo(accountID: accountID, path: path)
        } catch {
            signatureLogoError = error.localizedDescription
        }
    }

    // MARK: - Flags

    private var flagsSection: some View {
        Section {
            ForEach(store.flags) { flag in
                HStack(spacing: 10) {
                    Circle()
                        .fill(Color(hex: liveFlag(flag.id)?.colorHex ?? flag.colorHex))
                        .frame(width: 14, height: 14)
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
        } header: {
            Text("Flags")
        }
    }


    // MARK: - Open sequence

    private var openSequenceSection: some View {
        Section {
            Toggle(
                "Play open sequence on launch",
                isOn: Binding(
                    get: { OpenSequenceController.playOnLaunch },
                    set: { OpenSequenceController.playOnLaunch = $0 }
                )
            )
            Text("First launch plays once. Turn this on to see the muse envelope every time you open RapSoDee.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if OpenSequenceController.videoURL == nil {
                Text("OpenSequence.mp4 is missing from the app bundle.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Open sequence")
        }
    }

    // MARK: - Notifications

    private var notificationsSection: some View {
        Section {
            Toggle("Play sound for new mail", isOn: Bindable(store).playSoundForNewMail)
            Picker("Policy", selection: $notificationPolicy) {
                Text("Focus-aware").tag("focusAware")
                Text("VIP only").tag("vipOnly")
                Text("Mute").tag("mute")
            }
            .onChange(of: notificationPolicy) { _, value in
                store.notificationPolicyRaw = value
            }
            Button("Preview sound") {
                MuseNewMailSound.play()
            }
            .buttonStyle(MuseCapsuleButtonStyle())
            TextField("VIP addresses (comma-separated, stub)", text: $vipText)
            Text("Junk + Train sender arrive later.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Notifications")
        }
    }

    // MARK: - About / diagnostics

    private var aboutSection: some View {
        Section {
            Text("RapSoDee — Kale Yeah mail")
                .font(.headline)
            Text("Microsoft accounts signed in: \(microsoftAccountsSummary)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let probe = UserDefaults.standard.string(forKey: "rapSoDee.office365.lastSyncStatus"), !probe.isEmpty {
                Text("Last M365 sync probe: \(probe)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text("Appearance is locked to light mode.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("About / diagnostics")
        }
    }


    private var microsoftAccountsSummary: String {
        let rows = store.office365Accounts().map { account in
            let state = store.isOffice365SignedIn(email: account.email) ? "signed in" : "needs sign-in"
            return "\(account.email) (\(state))"
        }
        return rows.isEmpty ? "none" : rows.joined(separator: ", ")
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
        store.enforceCalliopeExcludedFromUnifiedInbox()
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
            // Keep live message IDs; merge settings fields onto accounts by email (incl. live shells).
            for account in accounts {
                let match: ((MailAccount) -> Bool) = { existing in
                    if account.isLiveGmail || account.isLiveOffice365 {
                        return existing.email.lowercased() == account.email.lowercased()
                            && existing.isLiveGmail == account.isLiveGmail
                            && existing.isLiveOffice365 == account.isLiveOffice365
                    }
                    return existing.email == account.email
                }
                if let i = store.accounts.firstIndex(where: match) {
                    if store.accounts[i].isCalliopeMailbox || account.isCalliopeMailbox {
                        store.accounts[i].isCalliope = true
                        store.accounts[i].includeInUnifiedInbox = false
                    } else {
                        store.accounts[i].includeInUnifiedInbox = account.includeInUnifiedInbox
                    }
                    // Prefer persisted signature when non-empty so edits survive relaunch.
                    if !account.signature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        store.accounts[i].signature = account.signature
                    }
                    store.accounts[i].signatureLogoPath = account.signatureLogoPath ?? store.accounts[i].signatureLogoPath
                    store.accounts[i].tintHex = account.tintHex
                    store.accounts[i].inboxPinned = account.inboxPinned
                    store.accounts[i].sortOrder = account.sortOrder
                } else if !(account.isLiveGmail || account.isLiveOffice365) {
                    // Demo / non-live only — never invent duplicate live shells from JSON.
                    continue
                }
            }
            store.accounts.sort { $0.sortOrder < $1.sortOrder }
            store.deduplicateLiveAccountShells()
            store.enforceCalliopeExcludedFromUnifiedInbox()
        }
        if !persistedFlags.isEmpty {
            store.flags = persistedFlags.map { MailFlag(id: $0.id, name: $0.name, colorHex: $0.colorHex) }
        } else if store.flags.isEmpty {
            store.flags = MailFlag.defaults
            syncFlagsToSwiftData()
        }
    }
}


/// Forces the Settings sheet's NSWindow to a usable size and marks it resizable.
private struct SettingsSheetWindowConfigurator: NSViewRepresentable {
    final class Coordinator {
        var didApplyIdealSize = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            Self.configure(window: view.window, coordinator: context.coordinator)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            Self.configure(window: nsView.window, coordinator: context.coordinator)
        }
    }

    private static func configure(window: NSWindow?, coordinator: Coordinator) {
        guard let window else { return }
        window.styleMask.insert(.resizable)
        window.minSize = NSSize(width: 640, height: 520)
        guard !coordinator.didApplyIdealSize else { return }
        let ideal = NSSize(width: 720, height: 700)
        window.setContentSize(ideal)
        coordinator.didApplyIdealSize = true
    }
}
