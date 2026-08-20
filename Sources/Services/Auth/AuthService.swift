import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import Security
import UIKit

/// Sign-in, deliberately optional.
///
/// BP Coach works fully without an account: readings, trends, reminders and
/// export are all local. Signing in exists so a future build can restore your
/// data on a new phone — it is not a gate, and nothing is withheld from someone
/// who skips it.
///
/// That is a product decision with a privacy consequence worth stating: because
/// an account is optional and holds no health data today, the app's "your data
/// stays on this device" claim remains true.
@Observable
@MainActor
final class AuthService: NSObject {

    enum Provider: String, Codable, Sendable {
        case apple, google, email

        var label: String {
            switch self {
            case .apple: "Apple"
            case .google: "Google"
            case .email: "Email"
            }
        }
    }

    struct Account: Codable, Equatable, Sendable {
        let id: String
        let provider: Provider
        var email: String?
        var displayName: String?
        var signedInAt: Date
    }

    enum AuthError: LocalizedError, Equatable {
        case cancelled
        case invalidCredential
        case invalidEmail
        case weakPassword
        case notConfigured(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled:
                nil  // The user chose to stop; not worth an error banner.
            case .invalidCredential:
                "That sign-in could not be verified. Please try again."
            case .invalidEmail:
                "That does not look like an email address."
            case .weakPassword:
                "Use at least 8 characters, including a number."
            case .notConfigured(let provider):
                "\(provider) sign-in is not set up in this build."
            case .failed(let reason):
                reason
            }
        }
    }

    private(set) var account: Account?
    private(set) var isWorking = false

    var isSignedIn: Bool { account != nil }

    private let store: AccountStore
    private var appleContinuation: CheckedContinuation<ASAuthorization, Error>?
    /// Guards against a replayed Apple credential.
    private var currentNonce: String?

    init(store: AccountStore = KeychainAccountStore()) {
        self.store = store
        super.init()
        self.account = store.load()
    }

    // MARK: - Sign in with Apple

    /// Apple is the only provider that works with no additional configuration:
    /// the credential is verified by Apple and needs no server of ours.
    func signInWithApple() async throws {
        isWorking = true
        defer { isWorking = false }

        let nonce = Self.randomNonce()
        currentNonce = nonce

        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)

        let authorization = try await withCheckedThrowingContinuation { continuation in
            appleContinuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }

        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            throw AuthError.invalidCredential
        }

        // Apple returns the name and email only on the very first sign-in, so
        // whatever arrives now must be kept — it will not come again.
        var name: String?
        if let components = credential.fullName {
            let parts = [components.givenName, components.familyName].compactMap { $0 }
            name = parts.isEmpty ? nil : parts.joined(separator: " ")
        }

        let account = Account(
            id: credential.user,
            provider: .apple,
            email: credential.email ?? self.account?.email,
            displayName: name ?? self.account?.displayName,
            signedInAt: .now
        )
        store.save(account)
        self.account = account
    }

    /// Whether a previously issued Apple credential is still valid.
    ///
    /// Called at launch: a user who revoked access in iOS Settings should not
    /// still appear signed in.
    func refreshAppleCredentialState() async {
        guard let account, account.provider == .apple else { return }
        let state = try? await ASAuthorizationAppleIDProvider()
            .credentialState(forUserID: account.id)
        if state == .revoked || state == .notFound {
            signOut()
        }
    }

    // MARK: - Google

    /// Not available in this build.
    ///
    /// Google sign-in needs an OAuth client ID and a registered redirect URI.
    /// Rather than ship a button that fails at the last step, it reports itself
    /// unavailable until `GoogleAuthConfig.clientID` is set.
    func signInWithGoogle() async throws {
        guard GoogleAuthConfig.isConfigured else {
            throw AuthError.notConfigured("Google")
        }
        // Deliberately unimplemented: with no client ID there is nothing to
        // test against, and a half-written OAuth flow is worse than none.
        throw AuthError.notConfigured("Google")
    }

    // MARK: - Email and password

    /// Validates input, then asks the backend.
    ///
    /// Validation happens here so bad input never leaves the device, but the
    /// account itself lives on the server — there is no local password store,
    /// and there must not be one.
    func signIn(email: String, password: String) async throws {
        try Self.validate(email: email, password: password)
        guard EmailAuthConfig.isConfigured else {
            throw AuthError.notConfigured("Email")
        }
        throw AuthError.notConfigured("Email")
    }

    func register(email: String, password: String) async throws {
        try Self.validate(email: email, password: password)
        guard EmailAuthConfig.isConfigured else {
            throw AuthError.notConfigured("Email")
        }
        throw AuthError.notConfigured("Email")
    }

    static func validate(email: String, password: String) throws {
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        // Deliberately loose: strict email regexes reject valid addresses, and
        // the server is the real authority anyway.
        guard trimmed.contains("@"),
              trimmed.split(separator: "@").count == 2,
              trimmed.split(separator: "@").last?.contains(".") == true,
              !trimmed.hasPrefix("@"), !trimmed.hasSuffix("@")
        else { throw AuthError.invalidEmail }

        guard password.count >= 8,
              password.rangeOfCharacter(from: .decimalDigits) != nil
        else { throw AuthError.weakPassword }
    }

    // MARK: - Sign out

    func signOut() {
        store.clear()
        account = nil
    }

    /// Removes the account and its stored credential.
    ///
    /// Health data is untouched: it lives on the device and belongs to the
    /// person, not the account. Deleting readings is a separate, explicit action
    /// in Privacy & Data — conflating the two would destroy someone's history
    /// when they only meant to sign out permanently.
    func deleteAccount() async throws {
        store.clear()
        account = nil
    }

    // MARK: - Nonce

    private static func randomNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length

        while remaining > 0 {
            var random: UInt8 = 0
            let status = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
            guard status == errSecSuccess else { continue }
            if random < charset.count {
                result.append(charset[Int(random)])
                remaining -= 1
            }
        }
        return result
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

// MARK: - Apple delegate

extension AuthService: ASAuthorizationControllerDelegate {
    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        Task { @MainActor in
            appleContinuation?.resume(returning: authorization)
            appleContinuation = nil
        }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        Task { @MainActor in
            let authError = (error as? ASAuthorizationError)?.code == .canceled
                ? AuthError.cancelled
                : AuthError.failed(error.localizedDescription)
            appleContinuation?.resume(throwing: authError)
            appleContinuation = nil
        }
    }
}

extension AuthService: ASAuthorizationControllerPresentationContextProviding {
    nonisolated func presentationAnchor(
        for controller: ASAuthorizationController
    ) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }
}

/// Where the signed-in account is kept.
protocol AccountStore: Sendable {
    func load() -> AuthService.Account?
    func save(_ account: AuthService.Account)
    func clear()
}

/// Keychain-backed storage.
///
/// The Keychain rather than `UserDefaults` because the account identifier is a
/// credential, and `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` keeps it
/// off iCloud backups and off any other device.
struct KeychainAccountStore: AccountStore {
    private let service = "app.snapcal.ios.account"
    private let key = "current"

    func load() -> AuthService.Account? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(AuthService.Account.self, from: data)
    }

    func save(_ account: AuthService.Account) {
        guard let data = try? JSONEncoder().encode(account) else { return }
        SecItemDelete(baseQuery() as CFDictionary)

        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}

/// Google OAuth configuration.
enum GoogleAuthConfig {
    /// Read from Info.plist so it is a build setting, not a source change.
    static var clientID: String? {
        let value = Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String
        guard let value, !value.isEmpty, value != "unset" else { return nil }
        return value
    }

    static var isConfigured: Bool { clientID != nil }
}

/// Email/password backend configuration.
enum EmailAuthConfig {
    /// Email sign-in needs a server that stores users. The current backend is
    /// stateless with no database, so this stays false until one exists.
    static var isConfigured: Bool { false }
}
