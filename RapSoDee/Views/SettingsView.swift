import SwiftUI
import SwiftData
import AppKit

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
                    TextField("Application (client) ID", text: $msalClientID)
                        .onChange(of: msalClientID) { _, value in
                            MSALAppConfig.setClientIDOverride(value)
                            MSALAuthService.shared.rebuildApplicationIfPossible()
                        }
                    Text("Paste the Entra Application (client) ID here — stored in UserDefaults (overrides empty Info.plist MSALClientID). No client secret; public client only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("Directory (tenant) ID", text: $msalTenantID)
                        .onChange(of: msalTenantID) { _, value in
                            MSALAppConfig.setTenantIDOverride(value)
                            MSALAuthService.shared.rebuildApplicationIfPossible()
                        }
                    Text("Single-tenant apps must use your directory ID (not /common). Stored in UserDefaults like the client ID. Default: Kale Yeah tenant.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Authority: \(MSALAppConfig.authorityURL.absoluteString)")
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)

                    Text("Redirect URI (register in Entra → Authentication → Mobile and desktop):")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(MSALAppConfig.redirectURI)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)

                    Text("Basic IMAP password auth is disabled for Microsoft 365. Use Sign in with Microsoft (MSAL + Graph). Gmail App Password path is unchanged.")
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
                    } else if let user = MSALAuthService.shared.signedInUsername ?? MSALAppConfig.rememberedSignedInEmail {
                        Text("Signed in: \(user)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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

                    Toggle("Prefer SMTP (XOAUTH2) for send", isOn: $preferSMTPSend)
                        .onChange(of: preferSMTPSend) { _, value in
                            MSALAppConfig.preferSMTPSend = value
                        }
                    Text("Default: Graph create-draft → send (closer to Outlook). On Graph failure, RapSoDee auto-falls back to SMTP. Prefer SMTP tries XOAUTH2 first; if silent SMTP.Send token fails, it falls back to Graph so send is never a silent no-op. NDRs like 550 5.7.708 are not visible in-app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Group {
                        Text("Import Zoho / backup .eml into this Microsoft 365 mailbox (Graph). Not for PST. Sync first so Sent Items and custom folders appear in the picker.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        let importOptions = store.office365EMLImportOptions()
                        Picker("Destination folder", selection: $emlDestinationFolderID) {
                            ForEach(importOptions) { opt in
                                Text(opt.isCustom ? opt.title : opt.title)
                                    .tag(opt.graphFolderID)
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
                                    || (store.office365Account() == nil && !MSALAuthService.shared.isSignedIn)
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
                                    || (store.office365Account() == nil && !MSALAuthService.shared.isSignedIn)
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
                    }

                    HStack(spacing: 10) {
                        Button("Sign in with Microsoft") {
                            Task {
                                office365Busy = true
                                deviceCodePrompt = nil
                                defer { office365Busy = false }
                                await store.signInMicrosoft365(
                                    clientIDOverride: msalClientID,
                                    tenantIDOverride: msalTenantID
                                )
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(office365Busy || store.office365IsSyncing || msalClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button("Sign in with device code") {
                            Task {
                                office365Busy = true
                                deviceCodePrompt = nil
                                defer { office365Busy = false }
                                await store.signInMicrosoft365WithDeviceCode(
                                    clientIDOverride: msalClientID,
                                    tenantIDOverride: msalTenantID
                                ) { prompt in
                                    deviceCodePrompt = prompt
                                    store.office365SyncStatus = "Enter code \(prompt.userCode) at \(prompt.verificationURL.host ?? "microsoft.com/devicelogin")"
                                }
                                deviceCodePrompt = nil
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(office365Busy || store.office365IsSyncing || msalClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button("Sync now") {
                            Task {
                                office365Busy = true
                                defer { office365Busy = false }
                                await store.syncOffice365Now()
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(office365Busy || store.office365IsSyncing || (store.office365Account() == nil && !MSALAuthService.shared.isSignedIn))

                        if store.office365Account() != nil || MSALAuthService.shared.isSignedIn || MSALAppConfig.rememberedSignedInEmail != nil {
                            Button("Sign out", role: .destructive) {
                                Task {
                                    office365Busy = true
                                    deviceCodePrompt = nil
                                    defer { office365Busy = false }
                                    await store.signOutMicrosoft365()
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(office365Busy || store.office365IsSyncing)
                        }
                    }

                    if let prompt = deviceCodePrompt {
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
                            Text("No browser redirect needed — enter the code on another device/browser, then wait here until RapSoDee finishes.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(8)
                        .background(MuseTheme.paper.opacity(0.8))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    Text("After Allow, RapSoDee should come forward automatically. If the browser still hangs, use Sign in with device code instead.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    // Escape hatch: unlock grayed-out buttons if Graph/MSAL hangs.
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
                            store.office365SyncStatus = "Cleared stuck Microsoft sign-in. Try Sign in again."
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                    }
                }

                Section("Display names") {
                    if store.accounts.isEmpty {
                        Text("Connect Gmail or Microsoft 365 to rename accounts and mailboxes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.accounts) { account in
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
                    Button("Preview sound") {
                        MuseNewMailSound.play()
                    }
                    .buttonStyle(MuseCapsuleButtonStyle())
                    Text("Soft muse chime (~0.6s). Mute policy skips sound; VIP routing arrives later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Junk + Train (stub)") {
                    Text("Mark as Junk and Train sender are wired as mailbox actions later.")
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
                msalClientID = MSALAppConfig.clientID
                msalTenantID = MSALAppConfig.tenantID
                preferSMTPSend = MSALAppConfig.preferSMTPSend
                MSALAuthService.shared.refreshSignedInStateFromCache()
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
