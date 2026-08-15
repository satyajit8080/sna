import SwiftUI

/// Email sign-in / sign-up.
///
/// Deliberately a thin front door onto the *same* backend auth the Apple path
/// uses — same `/auth/*` endpoints, same JWT, same Keychain slot. A second
/// auth system would mean two sets of sessions to reconcile.
struct AuthView: View {
    enum Mode: String, CaseIterable {
        case signIn = "Sign In"
        case signUp = "Sign Up"
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var app

    var startingMode: Mode = .signIn
    /// Called after a successful auth, with whether onboarding is still needed.
    var onAuthenticated: ((Bool) -> Void)?

    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var working = false
    @State private var error: String?
    @FocusState private var focus: Field?

    private enum Field { case email, password }

    private var canSubmit: Bool {
        email.contains("@") && email.count >= 5 && password.count >= 8 && !working
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.top, Theme.Space.s)

                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Text(mode == .signIn ? "Welcome back" : "Create your account")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                        Text(mode == .signIn
                             ? "Sign in to pick up where you left off."
                             : "Your meals, targets and progress sync across devices.")
                            .font(.body_).foregroundStyle(.secondary)
                    }

                    VStack(spacing: Theme.Space.s) {
                        field("Email", text: $email, field: .email)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        secureField("Password", text: $password)
                    }

                    if mode == .signUp {
                        Text("At least 8 characters.")
                            .font(.caption_).foregroundStyle(.tertiary)
                    }

                    Button {
                        Haptics.commit()
                        submit()
                    } label: {
                        if working { ProgressView().tint(.white) }
                        else { Text(mode == .signIn ? "Sign In" : "Create Account") }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!canSubmit)
                    .opacity(canSubmit ? 1 : 0.4)

                    Text("By continuing you agree to our [Terms](https://snapcal.app/terms) and [Privacy Policy](https://snapcal.app/privacy).")
                        .font(.caption_)
                        .foregroundStyle(.tertiary)
                        .tint(Theme.accent)

                    Spacer(minLength: 0)
                }
                .padding(Theme.Space.l)
            }
            .background(Theme.bg)
            .navigationTitle(mode.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Couldn't continue", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
            .onAppear {
                mode = startingMode
                focus = .email
            }
        }
    }

    private func field(_ label: String, text: Binding<String>, field: Field) -> some View {
        TextField(label, text: text)
            .focused($focus, equals: field)
            .padding(Theme.Space.m)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control)
                .stroke(Theme.hairline, lineWidth: 1))
    }

    private func secureField(_ label: String, text: Binding<String>) -> some View {
        SecureField(label, text: text)
            .textContentType(mode == .signUp ? .newPassword : .password)
            .focused($focus, equals: .password)
            .padding(Theme.Space.m)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control)
                .stroke(Theme.hairline, lineWidth: 1))
    }

    private func submit() {
        working = true
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        Task {
            defer { working = false }
            do {
                let res = mode == .signUp
                    ? try await APIClient.shared.signUp(email: trimmed, password: password)
                    : try await APIClient.shared.signIn(email: trimmed, password: password)

                Haptics.success()
                app.leaveGuestMode()
                onAuthenticated?(res.onboarded)
                dismiss()
            } catch let e as APIError {
                // Signing up with an existing email is a near-miss, not a dead
                // end — flip to sign-in rather than making them start over.
                if case .emailTaken = e { mode = .signIn }
                error = e.errorDescription
            } catch {
                self.error = "Something went wrong. Try again."
            }
        }
    }
}

/// Shown when a guest hits something that needs an account.
struct SignInPromptView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var app

    let feature: String
    @State private var showAuth = false

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            Spacer()

            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.accent)

            VStack(spacing: Theme.Space.s) {
                Text("Create an account to \(feature)")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                Text("Your meals and progress need somewhere to live. It takes about ten seconds.")
                    .font(.body_).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, Theme.Space.m)

            Spacer()

            VStack(spacing: Theme.Space.s) {
                Button("Create Account") {
                    Haptics.tap()
                    showAuth = true
                }
                .buttonStyle(PrimaryButtonStyle())

                Button("Keep Looking Around") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(Theme.Space.l)
        .background(Theme.bg)
        .sheet(isPresented: $showAuth) {
            AuthView(startingMode: .signUp) { onboarded in
                app.phase = onboarded ? .ready : .onboarding
                dismiss()
            }
        }
    }
}
