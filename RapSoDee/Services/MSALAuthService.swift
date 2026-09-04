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
    static let defaultClientID = "3f7dfcbe-daee-4902-a5db-cc779ad45c4b"
    static let clientIDDefaultsKey = "rapSoDee.msal.clientID"
    static let signedInEmailKey = "rapSoDee.msal.signedInEmail"
    static let keychainGroup = "com.microsoft.identity.universalstorage"
    static let authorityURL = URL(string: "https://login.microsoftonline.com/common")!

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

    static func setClientIDOverride(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: clientIDDefaultsKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: clientIDDefaultsKey)
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
            return "Not signed in with Microsoft. Use Sign in with Microsoft."
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
@MainActor
final class MSALAuthService {
    static let shared = MSALAuthService()

    private var application: MSALPublicClientApplication?
    private var presentationHost: MSALPresentationHost?
    private(set) var signedInUsername: String?
    private(set) var signedInDisplayName: String?

    var isSignedIn: Bool { signedInUsername != nil || hasCachedAccount }

    private var hasCachedAccount: Bool {
        guard let application else { return false }
        return (try? application.allAccounts().isEmpty) == false
    }

    private init() {
        rebuildApplicationIfPossible()
        refreshSignedInStateFromCache()
    }

    /// Call after Client ID is pasted/saved so the MSAL app is recreated.
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

    /// Interactive sign-in. Prefer login hint for Kale Yeah mailbox.
    func signIn(loginHint: String? = Office365Defaults.defaultEmail) async throws -> String {
        rebuildApplicationIfPossible()
        guard let application else { throw MSALAuthError.missingClientID }

        let presenter = try makePresentingViewController()
        let webParams = MSALWebviewParameters(authPresentationViewController: presenter)
        let parameters = MSALInteractiveTokenParameters(scopes: MSALAppConfig.scopes, webviewParameters: webParams)
        if let hint = loginHint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
            parameters.loginHint = hint
        }
        parameters.promptType = .selectAccount

        let result = try await acquireTokenInteractive(application: application, parameters: parameters)
        signedInUsername = result.account.username ?? loginHint
        signedInDisplayName = result.account.accountClaims?["name"] as? String
        if let username = signedInUsername {
            MSALAppConfig.rememberedSignedInEmail = username
        }
        return result.accessToken
    }

    /// Silent token (Keychain cache). Optionally fall back to interactive.
    func acquireAccessToken(interactiveIfNeeded: Bool = false, loginHint: String? = nil) async throws -> String {
        rebuildApplicationIfPossible()
        guard let application else { throw MSALAuthError.missingClientID }

        if let account = try? application.allAccounts().first {
            do {
                let silent = MSALSilentTokenParameters(scopes: MSALAppConfig.scopes, account: account)
                let result = try await acquireTokenSilent(application: application, parameters: silent)
                signedInUsername = result.account.username ?? signedInUsername
                return result.accessToken
            } catch {
                if interactiveIfNeeded {
                    return try await signIn(loginHint: loginHint ?? account.username)
                }
                throw Self.mapError(error)
            }
        }

        if interactiveIfNeeded {
            return try await signIn(loginHint: loginHint)
        }
        throw MSALAuthError.noAccount
    }

    func signOut() async {
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

    /// iOS uses handleMSALResponse; on macOS ASWebAuthenticationSession / WKWebView owns the redirect.
    /// Kept so App.onOpenURL can call a single entry point without platform #ifs in the UI layer.
    static func handle(url: URL) {
        #if os(iOS)
        _ = MSALPublicClientApplication.handleMSALResponse(url, sourceApplication: nil)
        #else
        _ = url // macOS: custom scheme is registered for Entra; session completes without this hook.
        #endif
    }

    // MARK: - Presentation

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

    private func acquireTokenInteractive(
        application: MSALPublicClientApplication,
        parameters: MSALInteractiveTokenParameters
    ) async throws -> MSALResult {
        try await withCheckedThrowingContinuation { continuation in
            application.acquireToken(with: parameters) { result, error in
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

    private func acquireTokenSilent(
        application: MSALPublicClientApplication,
        parameters: MSALSilentTokenParameters
    ) async throws -> MSALResult {
        try await withCheckedThrowingContinuation { continuation in
            application.acquireTokenSilent(with: parameters) { result, error in
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
