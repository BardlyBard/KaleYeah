import Foundation
import MSAL
import AppKit

/// Microsoft Entra / MSAL public-client configuration for RapSoDee.
enum MSALAppConfig {
    static let bundleID = "local.rapsodee.mail"
    /// Exact redirect URI to register in Entra (Authentication → Public client/native).
    static let redirectURI = "msauth.\(bundleID)://auth"
    static let urlScheme = "msauth.\(bundleID)"
    static let scopes = ["Mail.Read", "Mail.ReadWrite", "Mail.Send", "User.Read"]
    /// Device-code / refresh token requests need offline_access for a refresh token.
    static let deviceCodeScopes = scopes + ["offline_access", "openid", "profile"]
    /// Separate resource audience from Graph — request independently for SMTP AUTH XOAUTH2.
    /// Entra: APIs my org uses → Office 365 Exchange Online → Delegated → SMTP.Send
    /// (scope string `https://outlook.office.com/SMTP.Send`).
    static let smtpScopes = ["https://outlook.office.com/SMTP.Send"]
    static let preferSMTPSendKey = "rapSoDee.office365.preferSMTPSend"

    /// When true, Office 365 compose uses SMTP XOAUTH2 first; otherwise Graph draft→send,
    /// with automatic SMTP fallback if Graph send fails.
    static var preferSMTPSend: Bool {
        get { UserDefaults.standard.bool(forKey: preferSMTPSendKey) }
        set { UserDefaults.standard.set(newValue, forKey: preferSMTPSendKey) }
    }
    static let defaultClientID = "3f7dfcbe-daee-4902-a5db-cc779ad45c4b"
    /// Kale Yeah / GoDaddy M365 directory (single-tenant app).
    static let defaultTenantID = "d0b3fdba-6d90-4e3a-9938-c7a29e2359ee"
    static let clientIDDefaultsKey = "rapSoDee.msal.clientID"
    static let tenantIDDefaultsKey = "rapSoDee.msal.tenantID"
    static let signedInEmailKey = "rapSoDee.msal.signedInEmail"
    /// Ordered list of signed-in Microsoft usernames (Derek + Calliope, etc.).
    static let signedInEmailsKey = "rapSoDee.msal.signedInEmails"
    static let keychainGroup = "com.microsoft.identity.universalstorage"
    /// Legacy single-slot device-code refresh (pre multi-account). Migrated on read.
    static let deviceCodeRefreshAccount = "msal.device-code.refresh"
    static let deviceCodeRefreshPrefix = "msal.device-code.refresh."
    /// Suggested second mailbox for Add Microsoft 365… (Callie).
    static let calliopeEmail = "calliope.voss@kaleyeahinspections.com"

    /// Per-email Keychain account for device-code refresh tokens.
    static func deviceCodeRefreshAccount(forEmail email: String) -> String {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return deviceCodeRefreshPrefix + normalized
    }

    /// Priority: UserDefaults override → Info.plist MSALClientID → baked-in defaultClientID.
    static var clientID: String {
        if let override = UserDefaults.standard.string(forKey: clientIDDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return override
        }
        if let plist = Bundle.main.object(forInfoDictionaryKey: "MSALClientID") as? String {
            let trimmed = plist.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed != "YOUR_CLIENT_ID_HERE" {
                return trimmed
            }
        }
        return defaultClientID
    }

    /// Priority: UserDefaults override → baked-in defaultTenantID (single-tenant).
    static var tenantID: String {
        if let override = UserDefaults.standard.string(forKey: tenantIDDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return override
        }
        return defaultTenantID
    }

    /// Single-tenant authority — do not use `/common` for this Entra app registration.
    static var authorityURL: URL {
        URL(string: "https://login.microsoftonline.com/\(tenantID)")!
    }

    static func setClientIDOverride(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: clientIDDefaultsKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: clientIDDefaultsKey)
        }
    }

    static func setTenantIDOverride(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: tenantIDDefaultsKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: tenantIDDefaultsKey)
        }
    }

    /// Last-active / primary remembered email (kept for older call sites).
    static var rememberedSignedInEmail: String? {
        get { UserDefaults.standard.string(forKey: signedInEmailKey) }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: signedInEmailKey)
            } else {
                UserDefaults.standard.removeObject(forKey: signedInEmailKey)
            }
        }
    }

    /// All remembered Microsoft usernames. Never collapses to a single slot.
    static var rememberedSignedInEmails: [String] {
        get {
            if let arr = UserDefaults.standard.stringArray(forKey: signedInEmailsKey), !arr.isEmpty {
                return Self.uniqueEmails(arr)
            }
            if let one = rememberedSignedInEmail, !one.isEmpty {
                return [one]
            }
            return []
        }
        set {
            let cleaned = Self.uniqueEmails(newValue)
            if cleaned.isEmpty {
                UserDefaults.standard.removeObject(forKey: signedInEmailsKey)
                rememberedSignedInEmail = nil
            } else {
                UserDefaults.standard.set(cleaned, forKey: signedInEmailsKey)
                rememberedSignedInEmail = cleaned.first
            }
        }
    }

    static func rememberSignedInEmail(_ email: String) {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = rememberedSignedInEmails
        let lower = trimmed.lowercased()
        if let idx = list.firstIndex(where: { $0.lowercased() == lower }) {
            list[idx] = trimmed
        } else {
            list.append(trimmed)
        }
        rememberedSignedInEmails = list
        rememberedSignedInEmail = trimmed
    }

    static func forgetSignedInEmail(_ email: String) {
        let lower = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        rememberedSignedInEmails = rememberedSignedInEmails.filter { $0.lowercased() != lower }
    }

    private static func uniqueEmails(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in values {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            if seen.insert(key).inserted {
                out.append(trimmed)
            }
        }
        return out
    }

    /// Public alias for auth-state refresh helpers.
    static func uniqueEmailsPublic(_ values: [String]) -> [String] { uniqueEmails(values) }
}

/// User-facing device-code prompt (copyable code + verification URL).
struct MSALDeviceCodePrompt: Equatable {
    let userCode: String
    let verificationURL: URL
    let message: String
}

enum MSALAuthError: LocalizedError {
    case missingClientID
    case noAccount
    case noPresentingWindow
    case cancelled
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            return "Paste your Entra Application (client) ID in Settings → Microsoft 365 first."
        case .noAccount:
            return "Sign in expired — use Settings → Sign in with device code"
        case .noPresentingWindow:
            return "No window available to present Microsoft sign-in."
        case .cancelled:
            return "Sign-in was cancelled."
        case .underlying(let message):
            return message
        }
    }
}

/// Hosts MSAL’s required presentation view controller when SwiftUI has no NSViewController yet.
private final class MSALPresentationHost: NSViewController {}

/// MSAL public client — tokens cached in macOS Keychain via MSAL.
/// Device-code fallback uses the OAuth 2.0 device authorization grant directly
/// (MSAL ObjC has no acquireTokenWithDeviceCode API).
@MainActor
final class MSALAuthService {
    static let shared = MSALAuthService()

    private var application: MSALPublicClientApplication?
    private var presentationHost: MSALPresentationHost?
    private var interactiveInFlight = false
    /// Cancellation flag for device-code polling (safe to set from cancelPendingAuth off the main actor).
    nonisolated(unsafe) private var deviceCodeCancelled = false
    /// In-memory Graph access tokens from device-code / refresh, keyed by lowercased email.
    private var deviceCodeAccessTokens: [String: String] = [:]
    private(set) var signedInUsername: String?
    private(set) var signedInDisplayName: String?
    /// All known signed-in Microsoft usernames (MSAL cache + device-code + remembered).
    private(set) var signedInUsernames: [String] = []

    var isSignedIn: Bool {
        !signedInUsernames.isEmpty || hasCachedAccount || hasAnyDeviceCodeRefreshToken
    }

    /// True only when THIS mailbox has a usable MSAL account or device-code refresh/access token.
    /// Remembered shells / UserDefaults alone must never count as signed-in (Derek ≠ Callie).
    func isSignedIn(email: String) -> Bool {
        let lower = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return false }
        if deviceCodeAccessTokens[lower] != nil { return true }
        if let application,
           let accounts = try? application.allAccounts(),
           accounts.contains(where: { ($0.username ?? "").lowercased() == lower }) {
            return true
        }
        return hasDeviceCodeRefreshToken(forEmail: lower)
    }

    private var hasCachedAccount: Bool {
        guard let application else { return false }
        return (try? application.allAccounts().isEmpty) == false
    }

    private var hasAnyDeviceCodeRefreshToken: Bool {
        for email in MSALAppConfig.rememberedSignedInEmails {
            if hasDeviceCodeRefreshToken(forEmail: email) { return true }
        }
        return KeychainCredentialStore.password(forEmail: MSALAppConfig.deviceCodeRefreshAccount) != nil
    }

    private func hasDeviceCodeRefreshToken(forEmail email: String) -> Bool {
        let lower = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let key = MSALAppConfig.deviceCodeRefreshAccount(forEmail: lower)
        if KeychainCredentialStore.password(forEmail: key) != nil { return true }
        // Legacy single-slot refresh is one mailbox only — never broadcast to every remembered email.
        guard let legacy = KeychainCredentialStore.password(forEmail: MSALAppConfig.deviceCodeRefreshAccount),
              !legacy.isEmpty else { return false }
        let remembered = MSALAppConfig.rememberedSignedInEmails.map { $0.lowercased() }
        if remembered.count == 1, remembered[0] == lower { return true }
        // Orphan legacy (no remembered list): only attribute when this is the sole known default.
        if remembered.isEmpty, lower == Office365Defaults.defaultEmail.lowercased() { return true }
        return false
    }

    private init() {
        rebuildApplicationIfPossible()
        refreshSignedInStateFromCache()
    }

    /// Call after Client ID or Tenant ID is pasted/saved so the MSAL app is recreated.
    func rebuildApplicationIfPossible() {
        application = nil
        let clientID = MSALAppConfig.clientID
        guard !clientID.isEmpty else { return }
        do {
            let authority = try MSALAuthority(url: MSALAppConfig.authorityURL)
            let config = MSALPublicClientApplicationConfig(
                clientId: clientID,
                redirectUri: MSALAppConfig.redirectURI,
                authority: authority
            )
            config.cacheConfig.keychainSharingGroup = MSALAppConfig.keychainGroup
            application = try MSALPublicClientApplication(configuration: config)
        } catch {
            application = nil
            NSLog("MSAL init failed: \(error.localizedDescription)")
        }
    }

    func refreshSignedInStateFromCache() {
        var emails: [String] = []
        if let application, let accounts = try? application.allAccounts() {
            for account in accounts {
                if let username = account.username?.trimmingCharacters(in: .whitespacesAndNewlines), !username.isEmpty {
                    emails.append(username)
                    MSALAppConfig.rememberSignedInEmail(username)
                }
            }
            if let first = accounts.first {
                signedInDisplayName = first.accountClaims?["name"] as? String
            }
        }
        // Device-code / remembered: only include emails that still hold a real token.
        // Never mark Derek signed-in because Callie (or a remembered shell) exists.
        var candidates = MSALAppConfig.rememberedSignedInEmails
        candidates.append(contentsOf: deviceCodeAccessTokens.keys)
        for candidate in MSALAppConfig.uniqueEmailsPublic(candidates) {
            let lower = candidate.lowercased()
            if emails.contains(where: { $0.lowercased() == lower }) { continue }
            if deviceCodeAccessTokens[lower] != nil || hasDeviceCodeRefreshToken(forEmail: lower) {
                emails.append(candidate)
            }
        }
        signedInUsernames = MSALAppConfig.uniqueEmailsPublic(emails)
        signedInUsername = signedInUsernames.first ?? MSALAppConfig.rememberedSignedInEmail
    }

    /// MSAL cached account matching login hint / email (case-insensitive).
    /// When a hint is provided and no MSAL account matches, returns nil — never another mailbox
    /// (device-code Callie must not silently use Derek's MSAL cache).
    private func msalAccount(matching loginHint: String?) -> MSALAccount? {
        guard let application, let accounts = try? application.allAccounts(), !accounts.isEmpty else {
            return nil
        }
        if let hint = loginHint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !hint.isEmpty {
            return accounts.first(where: { ($0.username ?? "").lowercased() == hint })
        }
        // No hint: prefer remembered primary, else first cached.
        if let primary = MSALAppConfig.rememberedSignedInEmail?.lowercased(),
           let match = accounts.first(where: { ($0.username ?? "").lowercased() == primary }) {
            return match
        }
        return accounts.first
    }

    /// Dismiss any orphan ASWebAuthenticationSession / embedded auth UI left from a failed handoff.
    @discardableResult
    nonisolated static func cancelInteractiveSession() -> Bool {
        let cancelled = MSALPublicClientApplication.cancelCurrentWebAuthSession()
        Task { @MainActor in
            shared.interactiveInFlight = false
        }
        return cancelled
    }

    /// Cancel stuck interactive *and* in-flight device-code polling.
    @discardableResult
    nonisolated static func cancelPendingAuth() -> Bool {
        let cancelled = cancelInteractiveSession()
        shared.deviceCodeCancelled = true
        return cancelled
    }

    /// Interactive sign-in. Prefer login hint for Kale Yeah mailbox.
    func signIn(loginHint: String? = Office365Defaults.defaultEmail) async throws -> String {
        rebuildApplicationIfPossible()
        guard let application else { throw MSALAuthError.missingClientID }

        // Clear orphan sessions from a previous Safari/ASWebAuthenticationSession that never returned.
        Self.cancelInteractiveSession()
        deviceCodeCancelled = false
        if interactiveInFlight {
            interactiveInFlight = false
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        let result: MSALResult
        do {
            result = try await acquireTokenInteractiveOnce(application: application, loginHint: loginHint)
        } catch {
            if Self.isInteractiveSessionBusy(error) {
                Self.cancelInteractiveSession()
                try? await Task.sleep(nanoseconds: 350_000_000)
                result = try await acquireTokenInteractiveOnce(application: application, loginHint: loginHint)
            } else {
                throw error
            }
        }

        // Drop device-code tokens only for this mailbox — never wipe Derek when Callie signs in.
        let signedEmail = result.account.username ?? loginHint
        if let signedEmail {
            clearDeviceCodeTokens(forEmail: signedEmail)
            MSALAppConfig.rememberSignedInEmail(signedEmail)
        }
        signedInUsername = signedEmail
        signedInDisplayName = result.account.accountClaims?["name"] as? String
        refreshSignedInStateFromCache()
        NSApp.activate(ignoringOtherApps: true)
        return result.accessToken
    }

    /// Device-code fallback — no browser redirect into RapSoDee.
    /// Calls `onPrompt` with the user code + verification URL, then polls until done.
    func signInWithDeviceCode(
        loginHint: String? = Office365Defaults.defaultEmail,
        onPrompt: @MainActor @escaping (MSALDeviceCodePrompt) -> Void
    ) async throws -> String {
        rebuildApplicationIfPossible()
        let clientID = MSALAppConfig.clientID
        guard !clientID.isEmpty else { throw MSALAuthError.missingClientID }

        Self.cancelInteractiveSession()
        deviceCodeCancelled = false
        if interactiveInFlight {
            interactiveInFlight = false
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        let tenant = MSALAppConfig.tenantID
        let deviceCodeURL = URL(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/devicecode")!
        var request = URLRequest(url: deviceCodeURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let scope = MSALAppConfig.deviceCodeScopes.joined(separator: " ")
        var bodyItems: [URLQueryItem] = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "scope", value: scope),
        ]
        if let hint = loginHint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
            // login_hint is not part of the device-code request; kept for API symmetry / future use.
            _ = hint
        }
        request.httpBody = Self.formURLEncoded(bodyItems).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        if deviceCodeCancelled { throw MSALAuthError.cancelled }
        guard let http = response as? HTTPURLResponse else {
            throw MSALAuthError.underlying("Device code request failed (no HTTP response).")
        }
        guard (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceCode = json["device_code"] as? String,
              let userCode = json["user_code"] as? String,
              let verificationURI = (json["verification_uri"] as? String) ?? (json["verification_url"] as? String),
              let verificationURL = URL(string: verificationURI) else {
            let message = Self.oauthErrorMessage(from: data) ?? "Device code request failed (HTTP \(http.statusCode))."
            throw MSALAuthError.underlying(message)
        }

        let interval = max(1, (json["interval"] as? Int) ?? 5)
        let expiresIn = (json["expires_in"] as? Int) ?? 900
        let message = (json["message"] as? String)
            ?? "Go to \(verificationURI) and enter code \(userCode)"

        let prompt = MSALDeviceCodePrompt(
            userCode: userCode,
            verificationURL: verificationURL,
            message: message
        )
        onPrompt(prompt)

        let deadline = Date().addingTimeInterval(TimeInterval(expiresIn))
        var pollInterval = TimeInterval(interval)
        let tokenURL = URL(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/token")!

        while Date() < deadline {
            if deviceCodeCancelled { throw MSALAuthError.cancelled }
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            if deviceCodeCancelled { throw MSALAuthError.cancelled }

            var tokenRequest = URLRequest(url: tokenURL)
            tokenRequest.httpMethod = "POST"
            tokenRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            tokenRequest.httpBody = Self.formURLEncoded([
                URLQueryItem(name: "grant_type", value: "urn:ietf:params:oauth:grant-type:device_code"),
                URLQueryItem(name: "client_id", value: clientID),
                URLQueryItem(name: "device_code", value: deviceCode),
            ]).data(using: .utf8)

            let (tokenData, tokenResponse) = try await URLSession.shared.data(for: tokenRequest)
            if deviceCodeCancelled { throw MSALAuthError.cancelled }

            if let http = tokenResponse as? HTTPURLResponse, (200..<300).contains(http.statusCode),
               let tokenJSON = try? JSONSerialization.jsonObject(with: tokenData) as? [String: Any],
               let accessToken = tokenJSON["access_token"] as? String {
                let resolvedEmail: String? = {
                    if let idToken = tokenJSON["id_token"] as? String,
                       let email = Self.emailFromIDToken(idToken) {
                        return email
                    }
                    return loginHint?.trimmingCharacters(in: .whitespacesAndNewlines)
                }()
                if let refresh = tokenJSON["refresh_token"] as? String {
                    if let resolvedEmail, !resolvedEmail.isEmpty {
                        let key = MSALAppConfig.deviceCodeRefreshAccount(forEmail: resolvedEmail)
                        try? KeychainCredentialStore.savePassword(refresh, forEmail: key)
                        // Do not overwrite a different account's legacy slot.
                        if MSALAppConfig.rememberedSignedInEmails.isEmpty
                            || MSALAppConfig.rememberedSignedInEmails.map({ $0.lowercased() }) == [resolvedEmail.lowercased()] {
                            try? KeychainCredentialStore.savePassword(refresh, forEmail: MSALAppConfig.deviceCodeRefreshAccount)
                        }
                    } else {
                        try? KeychainCredentialStore.savePassword(refresh, forEmail: MSALAppConfig.deviceCodeRefreshAccount)
                    }
                }
                if let resolvedEmail, !resolvedEmail.isEmpty {
                    deviceCodeAccessTokens[resolvedEmail.lowercased()] = accessToken
                    signedInUsername = resolvedEmail
                    MSALAppConfig.rememberSignedInEmail(resolvedEmail)
                }
                refreshSignedInStateFromCache()
                NSApp.activate(ignoringOtherApps: true)
                return accessToken
            }

            let err = Self.oauthErrorCode(from: tokenData)
            if err == "authorization_pending" {
                continue
            }
            if err == "slow_down" {
                pollInterval += 5
                continue
            }
            if err == "expired_token" || err == "code_expired" {
                throw MSALAuthError.underlying("Device code expired. Try Sign in with device code again.")
            }
            if err == "authorization_declined" || err == "access_denied" {
                throw MSALAuthError.cancelled
            }
            let message = Self.oauthErrorMessage(from: tokenData) ?? "Device code sign-in failed."
            throw MSALAuthError.underlying(message)
        }

        throw MSALAuthError.underlying("Device code timed out. Try again.")
    }

    /// Silent token (Keychain cache / device-code refresh). Optionally fall back to interactive.
    /// Always pass `loginHint` when multiple Microsoft accounts are signed in so tokens do not cross.
    func acquireAccessToken(interactiveIfNeeded: Bool = false, loginHint: String? = nil) async throws -> String {
        rebuildApplicationIfPossible()
        // Prior Sync/Send timeout may have set this; clear so device-code refresh can run.
        deviceCodeCancelled = false
        guard MSALAppConfig.clientID.isEmpty == false else { throw MSALAuthError.missingClientID }

        if let application, let account = msalAccount(matching: loginHint) {
            do {
                let silent = MSALSilentTokenParameters(scopes: MSALAppConfig.scopes, account: account)
                let result = try await acquireTokenSilent(application: application, parameters: silent)
                if let username = result.account.username {
                    signedInUsername = username
                    MSALAppConfig.rememberSignedInEmail(username)
                }
                return result.accessToken
            } catch {
                if interactiveIfNeeded {
                    return try await signIn(loginHint: loginHint ?? account.username)
                }
                // Fall through to device-code refresh for this mailbox.
            }
        }

        if let token = try await refreshDeviceCodeAccessTokenIfPossible(forEmail: loginHint) {
            return token
        }

        if interactiveIfNeeded {
            return try await signIn(loginHint: loginHint)
        }
        throw MSALAuthError.noAccount
    }

    /// Access token for SMTP AUTH XOAUTH2. Graph tokens are a different audience and will not work.
    func acquireSMTPAccessToken(interactiveIfNeeded: Bool = false, loginHint: String? = nil) async throws -> String {
        rebuildApplicationIfPossible()
        deviceCodeCancelled = false
        guard MSALAppConfig.clientID.isEmpty == false else { throw MSALAuthError.missingClientID }

        if let application, let account = msalAccount(matching: loginHint) {
            do {
                let silent = MSALSilentTokenParameters(scopes: MSALAppConfig.smtpScopes, account: account)
                let result = try await acquireTokenSilent(application: application, parameters: silent)
                if let username = result.account.username {
                    signedInUsername = username
                    MSALAppConfig.rememberSignedInEmail(username)
                }
                return result.accessToken
            } catch {
                if interactiveIfNeeded {
                    return try await acquireSMTPTokenInteractive(loginHint: loginHint ?? account.username)
                }
                // Fall through to device-code refresh with SMTP scope.
            }
        }

        if let token = try await refreshDeviceCodeAccessTokenIfPossible(
            forEmail: loginHint,
            scopes: MSALAppConfig.smtpScopes + ["offline_access"]
        ) {
            return token
        }

        if interactiveIfNeeded {
            return try await acquireSMTPTokenInteractive(loginHint: loginHint)
        }
        throw MSALAuthError.noAccount
    }

    private func acquireSMTPTokenInteractive(loginHint: String?) async throws -> String {
        rebuildApplicationIfPossible()
        guard let application else { throw MSALAuthError.missingClientID }
        Self.cancelInteractiveSession()
        deviceCodeCancelled = false
        if interactiveInFlight {
            interactiveInFlight = false
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        let presenter = try makePresentingViewController()
        let webParams = MSALWebviewParameters(authPresentationViewController: presenter)
        webParams.webviewType = .authenticationSession
        webParams.prefersEphemeralWebBrowserSession = false

        let parameters = MSALInteractiveTokenParameters(scopes: MSALAppConfig.smtpScopes, webviewParameters: webParams)
        if let hint = loginHint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
            parameters.loginHint = hint
        }
        // Consent for SMTP.Send if not already granted.
        parameters.promptType = .selectAccount

        interactiveInFlight = true
        defer { interactiveInFlight = false }
        let result = try await acquireTokenInteractive(application: application, parameters: parameters)
        if let username = result.account.username ?? loginHint {
            signedInUsername = username
            MSALAppConfig.rememberSignedInEmail(username)
        }
        refreshSignedInStateFromCache()
        return result.accessToken
    }

    /// Remove one Microsoft mailbox without signing the others out.
    func signOut(email: String) async {
        let lower = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return }
        clearDeviceCodeTokens(forEmail: lower)
        if let application, let accounts = try? application.allAccounts() {
            for account in accounts where (account.username ?? "").lowercased() == lower {
                do { try application.remove(account) } catch {
                    NSLog("MSAL signOut(\(lower)): \(error.localizedDescription)")
                }
            }
        }
        MSALAppConfig.forgetSignedInEmail(lower)
        refreshSignedInStateFromCache()
        if signedInUsername?.lowercased() == lower {
            signedInUsername = signedInUsernames.first
            signedInDisplayName = nil
        }
    }

    func signOut() async {
        Self.cancelInteractiveSession()
        deviceCodeCancelled = true
        clearAllDeviceCodeTokens()
        guard let application else {
            signedInUsername = nil
            signedInDisplayName = nil
            signedInUsernames = []
            MSALAppConfig.rememberedSignedInEmails = []
            return
        }
        do {
            let accounts = try application.allAccounts()
            for account in accounts {
                try application.remove(account)
            }
        } catch {
            NSLog("MSAL signOut: \(error.localizedDescription)")
        }
        signedInUsername = nil
        signedInDisplayName = nil
        signedInUsernames = []
        MSALAppConfig.rememberedSignedInEmails = []
    }

    /// Forward custom-scheme redirects into MSAL where supported, and bring RapSoDee forward.
    /// Entra redirect must remain `msauth.local.rapsodee.mail://auth`.
    static func handle(url: URL) {
        guard url.scheme?.lowercased() == MSALAppConfig.urlScheme.lowercased() else { return }

        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where window.isVisible {
                window.makeKeyAndOrderFront(nil)
            }
        }

        #if os(iOS)
        _ = MSALPublicClientApplication.handleMSALResponse(url, sourceApplication: nil)
        #else
        // macOS: ASWebAuthenticationSession normally completes without this hook.
        // If a system browser still delivered the msauth:// URL to the app, activating
        // RapSoDee above is the recovery path; cancel orphans if a second attempt starts.
        NSLog("MSAL redirect received: \(url.absoluteString.prefix(120))…")
        #endif
    }

    // MARK: - Device code helpers

    private func clearDeviceCodeTokens(forEmail email: String) {
        let lower = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        deviceCodeAccessTokens.removeValue(forKey: lower)
        KeychainCredentialStore.deletePassword(forEmail: MSALAppConfig.deviceCodeRefreshAccount(forEmail: lower))
        // Clear legacy slot only when it belongs to this mailbox (or is the sole remembered account).
        let remembered = MSALAppConfig.rememberedSignedInEmails.map { $0.lowercased() }
        if remembered.isEmpty || remembered == [lower] || remembered.contains(lower) && remembered.count == 1 {
            KeychainCredentialStore.deletePassword(forEmail: MSALAppConfig.deviceCodeRefreshAccount)
        }
    }

    private func clearAllDeviceCodeTokens() {
        deviceCodeAccessTokens.removeAll()
        for email in MSALAppConfig.rememberedSignedInEmails {
            KeychainCredentialStore.deletePassword(forEmail: MSALAppConfig.deviceCodeRefreshAccount(forEmail: email))
        }
        KeychainCredentialStore.deletePassword(forEmail: MSALAppConfig.deviceCodeRefreshAccount)
    }

    private func refreshDeviceCodeAccessTokenIfPossible(
        forEmail emailHint: String? = nil,
        scopes: [String]? = nil
    ) async throws -> String? {
        let hint = emailHint?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strict mailbox binding: a non-empty hint must only use that mailbox's refresh
        // (never Derek's token when asking for Callie).
        let candidates: [String] = {
            var keys: [String] = []
            if let hint, !hint.isEmpty {
                keys.append(MSALAppConfig.deviceCodeRefreshAccount(forEmail: hint))
                // Legacy single-slot only when it is known to belong to this mailbox.
                let remembered = MSALAppConfig.rememberedSignedInEmails.map { $0.lowercased() }
                let lower = hint.lowercased()
                if remembered.isEmpty || remembered == [lower] || (remembered.count == 1 && remembered[0] == lower) {
                    keys.append(MSALAppConfig.deviceCodeRefreshAccount)
                }
                return keys
            }
            for email in MSALAppConfig.rememberedSignedInEmails {
                let key = MSALAppConfig.deviceCodeRefreshAccount(forEmail: email)
                if !keys.contains(key) { keys.append(key) }
            }
            keys.append(MSALAppConfig.deviceCodeRefreshAccount)
            return keys
        }()

        var refresh: String?
        var refreshKey: String?
        for key in candidates {
            if let value = KeychainCredentialStore.password(forEmail: key), !value.isEmpty {
                refresh = value
                refreshKey = key
                break
            }
        }

        if refresh == nil {
            if scopes == nil, let hint, let cached = deviceCodeAccessTokens[hint.lowercased()] {
                return cached
            }
            if scopes == nil, hint == nil, let cached = deviceCodeAccessTokens.values.first {
                return cached
            }
            return nil
        }
        guard let refresh, let refreshKey else { return nil }

        let clientID = MSALAppConfig.clientID
        let tenant = MSALAppConfig.tenantID
        let tokenURL = URL(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/token")!
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let scopeList = scopes ?? MSALAppConfig.deviceCodeScopes
        let scope = scopeList.joined(separator: " ")
        request.httpBody = Self.formURLEncoded([
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "refresh_token", value: refresh),
            URLQueryItem(name: "scope", value: scope),
        ]).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            // Stale refresh or scope not consented — clear only when using default Graph scopes.
            if scopes == nil {
                KeychainCredentialStore.deletePassword(forEmail: refreshKey)
                if let hint { deviceCodeAccessTokens.removeValue(forKey: hint.lowercased()) }
                refreshSignedInStateFromCache()
            }
            return nil
        }
        let resolvedEmail = (json["id_token"] as? String).flatMap(Self.emailFromIDToken) ?? hint
        if let newRefresh = json["refresh_token"] as? String {
            if let resolvedEmail, !resolvedEmail.isEmpty {
                let key = MSALAppConfig.deviceCodeRefreshAccount(forEmail: resolvedEmail)
                try? KeychainCredentialStore.savePassword(newRefresh, forEmail: key)
            } else {
                try? KeychainCredentialStore.savePassword(newRefresh, forEmail: refreshKey)
            }
        }
        if let resolvedEmail, !resolvedEmail.isEmpty {
            if scopes == nil {
                deviceCodeAccessTokens[resolvedEmail.lowercased()] = accessToken
            }
            signedInUsername = resolvedEmail
            MSALAppConfig.rememberSignedInEmail(resolvedEmail)
        }
        return accessToken
    }

    nonisolated private static func formURLEncoded(_ items: [URLQueryItem]) -> String {
        items.compactMap { item -> String? in
            guard let value = item.value else { return nil }
            let name = item.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? item.name
            let escaped = value.addingPercentEncoding(withAllowedCharacters: Self.formAllowed) ?? value
            return "\(name)=\(escaped)"
        }.joined(separator: "&")
    }

    nonisolated private static let formAllowed: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()

    nonisolated private static func oauthErrorCode(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["error"] as? String
    }

    nonisolated private static func oauthErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let desc = json["error_description"] as? String, !desc.isEmpty { return desc }
        if let err = json["error"] as? String, !err.isEmpty { return err }
        return nil
    }

    nonisolated private static func emailFromIDToken(_ idToken: String) -> String? {
        let parts = idToken.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let preferred = json["preferred_username"] as? String, !preferred.isEmpty { return preferred }
        if let email = json["email"] as? String, !email.isEmpty { return email }
        if let upn = json["upn"] as? String, !upn.isEmpty { return upn }
        return nil
    }

    // MARK: - Presentation

    private func acquireTokenInteractiveOnce(
        application: MSALPublicClientApplication,
        loginHint: String?
    ) async throws -> MSALResult {
        let presenter = try makePresentingViewController()
        let webParams = MSALWebviewParameters(authPresentationViewController: presenter)
        // Prefer system auth session so Allow dismisses back into RapSoDee instead of leaving Safari hung.
        webParams.webviewType = .authenticationSession
        webParams.prefersEphemeralWebBrowserSession = false

        let parameters = MSALInteractiveTokenParameters(scopes: MSALAppConfig.scopes, webviewParameters: webParams)
        if let hint = loginHint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
            parameters.loginHint = hint
        }
        parameters.promptType = .selectAccount

        interactiveInFlight = true
        defer { interactiveInFlight = false }
        return try await acquireTokenInteractive(application: application, parameters: parameters)
    }

    private func makePresentingViewController() throws -> NSViewController {
        // Prefer an existing controller — never replace SwiftUI’s hosting controller.
        if let vc = NSApp.keyWindow?.contentViewController
            ?? NSApp.mainWindow?.contentViewController
            ?? NSApp.windows.first(where: { $0.isVisible })?.contentViewController {
            return vc
        }
        // Fallback: tiny offscreen host window solely for MSAL presentation.
        let host = presentationHost ?? MSALPresentationHost()
        presentationHost = host
        if host.view.window == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            win.isReleasedWhenClosed = false
            win.contentViewController = host
            win.orderFrontRegardless()
        }
        return host
    }

    // MARK: - Bridging

    /// MSAL (and cancelCurrentWebAuthSession) can invoke the completion more than once.
    /// CheckedContinuation asserts on a second resume — that was the Cancel main-thread crash.
    private final class OnceResume<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        func resume(_ body: () -> Void) {
            lock.lock()
            defer { lock.unlock() }
            guard !resumed else { return }
            resumed = true
            body()
        }
    }

    private func acquireTokenInteractive(
        application: MSALPublicClientApplication,
        parameters: MSALInteractiveTokenParameters
    ) async throws -> MSALResult {
        try await withCheckedThrowingContinuation { continuation in
            let once = OnceResume<MSALResult>()
            application.acquireToken(with: parameters) { result, error in
                once.resume {
                    if let error {
                        continuation.resume(throwing: Self.mapError(error))
                    } else if let result {
                        continuation.resume(returning: result)
                    } else {
                        continuation.resume(throwing: MSALAuthError.underlying("No token result"))
                    }
                }
            }
        }
    }

    private func acquireTokenSilent(
        application: MSALPublicClientApplication,
        parameters: MSALSilentTokenParameters
    ) async throws -> MSALResult {
        try await withCheckedThrowingContinuation { continuation in
            let once = OnceResume<MSALResult>()
            application.acquireTokenSilent(with: parameters) { result, error in
                once.resume {
                    if let error {
                        continuation.resume(throwing: Self.mapError(error))
                    } else if let result {
                        continuation.resume(returning: result)
                    } else {
                        continuation.resume(throwing: MSALAuthError.underlying("No token result"))
                    }
                }
            }
        }
    }

    nonisolated private static func isInteractiveSessionBusy(_ error: Error) -> Bool {
        if let auth = error as? MSALAuthError, case .underlying(let message) = auth {
            if message.localizedCaseInsensitiveContains("Only one interactive session") {
                return true
            }
        }
        let ns = error as NSError
        if ns.domain == MSALErrorDomain {
            let busyCode = MSALInternalError.internalErrorInteractiveSessionAlreadyRunning.rawValue
            if let code = ns.userInfo[MSALInternalErrorCodeKey] as? Int, code == busyCode {
                return true
            }
            if let code = ns.userInfo[MSALInternalErrorCodeKey] as? NSNumber, code.intValue == busyCode {
                return true
            }
            if let desc = ns.userInfo[MSALErrorDescriptionKey] as? String,
               desc.localizedCaseInsensitiveContains("Only one interactive session") {
                return true
            }
        }
        return ns.localizedDescription.localizedCaseInsensitiveContains("Only one interactive session")
    }

    nonisolated private static func mapError(_ error: Error) -> Error {
        let ns = error as NSError
        if ns.domain == MSALErrorDomain {
            if ns.code == MSALError.userCanceled.rawValue {
                return MSALAuthError.cancelled
            }
            if let desc = ns.userInfo[MSALErrorDescriptionKey] as? String, !desc.isEmpty {
                return MSALAuthError.underlying(desc)
            }
        }
        return MSALAuthError.underlying(error.localizedDescription)
    }
}
