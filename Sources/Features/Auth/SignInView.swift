import AuthenticationServices
import SwiftUI

/// Sign-in, in the brand palette.
///
/// Presented from Profile & Account, never as a wall in front of the app. The
/// copy says so plainly, because a login screen that appears at launch reads as
/// a gate whatever the buttons underneath it say.
struct SignInView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var error: String?
    @FocusState private var focus: Field?

    enum Mode { case signIn, register }
    enum Field { case email, password }

    var body: some View {
        BrandScreen {
            BrandHeader(
                title: mode == .signIn ? "Sign In" : "Create Account",
                showsBack: true,
                onBack: { dismiss() }
            )

            BrandCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        BrandIconTile(symbol: "icloud.fill", tint: Brand.accent, size: 49)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Optional")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(Brand.textPrimary)
                            Text("BP Coach works fully without an account")
                                .font(.system(size: 12))
                                .foregroundStyle(Brand.accent)
                        }
                        Spacer(minLength: 0)
                    }
                    Text("""
                    Signing in lets a future version restore your data on a new phone. \
                    Your readings stay on this device either way, and nothing is withheld \
                    if you skip this.
                    """)
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Apple first: it is the only provider that works with no extra
            // configuration, and Apple requires it to be offered alongside any
            // other third-party sign-in.
            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.fullName, .email]
            } onCompletion: { _ in
                // Handled by AuthService so the nonce check is not bypassed.
            }
            .signInWithAppleButtonStyle(.white)
            .frame(height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .allowsHitTesting(false)
            .overlay {
                Button { signInWithApple() } label: {
                    Color.clear
                }
                .accessibilityLabel("Sign in with Apple")
            }
            .opacity(app.auth.isWorking ? 0.6 : 1)

            providerButton(
                title: "Continue with Google",
                symbol: "g.circle.fill",
                isAvailable: GoogleAuthConfig.isConfigured
            ) { signInWithGoogle() }

            HStack(spacing: 12) {
                Rectangle().fill(Brand.cardStroke).frame(height: 1)
                Text("or")
                    .font(.system(size: 12))
                    .foregroundStyle(Brand.textSecondary)
                Rectangle().fill(Brand.cardStroke).frame(height: 1)
            }

            BrandFormSection(footer: emailFooter) {
                BrandTextField(
                    title: "Email",
                    placeholder: "you@example.com",
                    text: $email,
                    symbol: "envelope.fill",
                    autocapitalization: .never,
                    keyboard: .emailAddress
                )
                .focused($focus, equals: .email)

                BrandRowDivider()

                HStack(spacing: 12) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Brand.accent)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Password")
                            .font(.system(size: 12))
                            .foregroundStyle(Brand.textSecondary)
                        SecureField(
                            "",
                            text: $password,
                            prompt: Text("At least 8 characters")
                                .foregroundStyle(Brand.textSecondary.opacity(0.6))
                        )
                        .font(.system(size: 15))
                        .foregroundStyle(Brand.textPrimary)
                        .textContentType(mode == .register ? .newPassword : .password)
                        .focused($focus, equals: .password)
                    }
                }
                .padding(16)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Password")
            }

            if let error {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.restingHeartRate)
                    .fixedSize(horizontal: false, vertical: true)
            }

            BrandPrimaryButton(
                title: mode == .signIn ? "Sign In" : "Create Account",
                isEnabled: !app.auth.isWorking
            ) { submitEmail() }

            Button {
                mode = mode == .signIn ? .register : .signIn
                error = nil
            } label: {
                Text(mode == .signIn
                     ? "No account yet? Create one"
                     : "Already have an account? Sign in")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Brand.accent)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)

            Text("""
            Signing in stores only your account identifier, on this device's Keychain. \
            It never carries your readings.
            """)
            .font(.system(size: 11))
            .foregroundStyle(Brand.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
        }
        .onSubmit { focus = focus == .email ? .password : nil }
    }

    private var emailFooter: String? {
        EmailAuthConfig.isConfigured
            ? nil
            : "Email sign-in needs a server that stores accounts. Not available in this build — Apple sign-in works now."
    }

    private func providerButton(
        title: String,
        symbol: String,
        isAvailable: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 18))
                Text(title).font(.system(size: 16, weight: .semibold))
                if !isAvailable {
                    Text("Unavailable")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Brand.cardStroke)
                        .clipShape(Capsule())
                }
            }
            .foregroundStyle(isAvailable ? Brand.textPrimary : Brand.textSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Brand.cardStroke, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
    }

    // MARK: - Actions

    private func signInWithApple() {
        error = nil
        Task {
            do {
                try await app.auth.signInWithApple()
                Haptics.success()
                dismiss()
            } catch let authError as AuthService.AuthError {
                // A cancellation is a choice, not a failure.
                if authError != .cancelled { error = authError.errorDescription }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func signInWithGoogle() {
        error = nil
        Task {
            do { try await app.auth.signInWithGoogle() } catch {
                self.error = (error as? AuthService.AuthError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    private func submitEmail() {
        error = nil
        focus = nil
        Task {
            do {
                if mode == .signIn {
                    try await app.auth.signIn(email: email, password: password)
                } else {
                    try await app.auth.register(email: email, password: password)
                }
                Haptics.success()
                dismiss()
            } catch {
                self.error = (error as? AuthService.AuthError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }
}

/// The signed-in state, shown in Profile & Account.
struct AccountStatusView: View {
    @Environment(AppModel.self) private var app
    @State private var isSigningIn = false
    @State private var isConfirmingSignOut = false

    var body: some View {
        Group {
            if let account = app.auth.account {
                BrandFormSection(
                    "Account",
                    footer: """
                    Signing out removes the account from this device. Your readings, \
                    medications and documents are untouched — deleting those is a separate \
                    action in Privacy & Data.
                    """
                ) {
                    BrandValueRow(
                        title: "Signed in with",
                        value: account.provider.label,
                        symbol: "person.crop.circle.fill",
                        valueTint: Brand.accent
                    )
                    if let email = account.email {
                        BrandRowDivider()
                        BrandValueRow(title: "Email", value: email, symbol: "envelope.fill")
                    }
                    BrandRowDivider()
                    BrandActionRow(
                        title: "Sign out",
                        symbol: "rectangle.portrait.and.arrow.right",
                        tint: Brand.restingHeartRate,
                        isDestructive: true,
                        showsChevron: false
                    ) { isConfirmingSignOut = true }
                }
            } else {
                BrandFormSection(
                    "Account",
                    footer: "Optional. BP Coach works fully without one."
                ) {
                    BrandActionRow(
                        title: "Sign in",
                        detail: "Apple, Google or email",
                        symbol: "person.crop.circle.badge.plus"
                    ) { isSigningIn = true }
                }
            }
        }
        .sheet(isPresented: $isSigningIn) {
            NavigationStack { SignInView() }
        }
        .confirmationDialog(
            "Sign out of BP Coach?",
            isPresented: $isConfirmingSignOut,
            titleVisibility: .visible
        ) {
            Button("Sign out", role: .destructive) { app.auth.signOut() }
            Button("Stay signed in", role: .cancel) {}
        } message: {
            Text("Your health data stays on this device.")
        }
        .task { await app.auth.refreshAppleCredentialState() }
    }
}
