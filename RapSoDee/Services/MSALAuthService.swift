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
    static let keychainGroup = "com.microsoft.identity.universalstorage"
    /// Keychain account for device-code refresh token (service = local.rapsodee.mail).
    static let deviceCodeRefreshAccount = "msal.device-code.refresh"

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
    /// In-memory access token from the latest device-code / refresh exchange.
    private var deviceCodeAccessToken: String?
    private(set) var signedInUsername: String?
    private(set) var signedInDisplayName: String?

    var isSignedIn: Bool {
        signedInUsername != nil || hasCachedAccount || hasDeviceCodeRefreshToken
    }

    private var hasCachedAccount: Bool {
        guard let application else { return false }
        return (try? application.allAccounts().isEmpty) == false
    }

    private var hasDeviceCodeRefreshToken: Bool {
        KeychainCredentialStore.password(forEmail: MSALAppConfig.deviceCodeRefreshAccount) != nil
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
        guard let application else {
            signedInUsername = MSALAppConfig.rememberedSignedInEmail
            return
        }
        if let account = try? application.allAccounts().first {
            signedInUsername = account.username
            signedInDisplayName = account.accountClaims?["name"] as? String
            if let username = account.username {
                MSALAppConfig.rememberedSignedInEmail = username
            }
        } else if let remembered = MSALAppConfig.rememberedSignedInEmail {
            signedInUsername = remembered
        }
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

        // Prefer MSAL cache over any prior device-code session.
        clearDeviceCodeTokens()
        signedInUsername = result.account.username ?? loginHint
        signedInDisplayName = result.account.accountClaims?["name"] as? String
        if let username = signedInUsername {
            MSALAppConfig.rememberedSignedInEmail = username
        }
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
                if let refresh = tokenJSON["refresh_token"] as? String {
                    try? KeychainCredentialStore.savePassword(refresh, forEmail: MSALAppConfig.deviceCodeRefreshAccount)
                }
                deviceCodeAccessToken = accessToken
                // Best-effort username from id_token claims.
                if let idToken = tokenJSON["id_token"] as? String,
                   let email = Self.emailFromIDToken(idToken) {
                    signedInUsername = email
                    MSALAppConfig.rememberedSignedInEmail = email
                } else if let hint = loginHint {
                    signedInUsername = hint
                    MSALAppConfig.rememberedSignedInEmail = hint
                }
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
    func acquireAccessToken(interactiveIfNeeded: Bool = false, loginHint: String? = nil) async throws -> String {
        rebuildApplicationIfPossible()
        // Prior Sync/Send timeout may have set this; clear so device-code refresh can run.
        deviceCodeCancelled = false
        guard MSALAppConfig.clientID.isEmpty == false else { throw MSALAuthError.missingClientID }

        if let application, let account = try? application.allAccounts().first {
            do {
                let silent = MSALSilentTokenParameters(scopes: MSALAppConfig.scopes, account: account)
                let result = try await acquireTokenSilent(application: application, parameters: silent)
                signedInUsername = result.account.username ?? signedInUsername
                return result.accessToken
            } catch {
                if interactiveIfNeeded {
                    return try await signIn(loginHint: loginHint ?? account.username)
                }
                // Fall through to device-code refresh if present.
            }
        }

        if let token = try await refreshDeviceCodeAccessTokenIfPossible() {
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

        if let application, let account = try? application.allAccounts().first {
            do {
                let silent = MSALSilentTokenParameters(scopes: MSALAppConfig.smtpScopes, account: account)
                let result = try await acquireTokenSilent(application: application, parameters: silent)
                signedInUsername = result.account.username ?? signedInUsername
                return result.accessToken
            } catch {
                if interactiveIfNeeded {
                    return try await acquireSMTPTokenInteractive(loginHint: loginHint ?? account.username)
                }
                // Fall through to device-code refresh with SMTP scope.
            }
        }

        if let token = try await refreshDeviceCodeAccessTokenIfPossible(scopes: MSALAppConfig.smtpScopes + ["offline_access"]) {
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
        signedInUsername = result.account.username ?? signedInUsername
        if let username = signedInUsername {
            MSALAppConfig.rememberedSignedInEmail = username
        }
        return result.accessToken
    }

    func signOut() async {
        Self.cancelInteractiveSession()
        deviceCodeCancelled = true
        clearDeviceCodeTokens()
        guard let application else {
            signedInUsername = nil
            signedInDisplayName = nil
            MSALAppConfig.rememberedSignedInEmail = nil
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
        MSALAppConfig.rememberedSignedInEmail = nil
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

    private func clearDeviceCodeTokens() {
        deviceCodeAccessToken = nil
        KeychainCredentialStore.deletePassword(forEmail: MSALAppConfig.deviceCodeRefreshAccount)
    }

    private func refreshDeviceCodeAccessTokenIfPossible(scopes: [String]? = nil) async throws -> String? {
        guard let refresh = KeychainCredentialStore.password(forEmail: MSALAppConfig.deviceCodeRefreshAccount) else {
            return scopes == nil ? deviceCodeAccessToken : nil
        }
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
                clearDeviceCodeTokens()
            }
            return nil
        }
        if let newRefresh = json["refresh_token"] as? String {
            try? KeychainCredentialStore.savePassword(newRefresh, forEmail: MSALAppConfig.deviceCodeRefreshAccount)
        }
        if scopes == nil {
            deviceCodeAccessToken = accessToken
        }
        if let idToken = json["id_token"] as? String, let email = Self.emailFromIDToken(idToken) {
            signedInUsername = email
            MSALAppConfig.rememberedSignedInEmail = email
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
