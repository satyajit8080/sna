import SwiftUI
import UIKit
import AuthenticationServices

struct WelcomeView: View {
    @Environment(AppState.self) private var app
    @State private var showAuth = false
    @State private var authMode: AuthView.Mode = .signIn
    @State private var error: String?
    @State private var signingIn = false

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                Spacer(minLength: 0)

                // The demo IS the pitch: someone should understand the product
                // before reading a word of it.
                ScanDemoView()
                    .frame(maxWidth: 320)
                    .frame(height: min(360, geo.size.height * 0.42))

                Spacer(minLength: Theme.Space.l)

                VStack(spacing: Theme.Space.s) {
                    Text("Snap it. Count it. Done.")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .lineSpacing(-1)

                    Text("Point your camera at any meal and get calories and macros in seconds.")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Theme.Space.l)
                }

                Spacer(minLength: Theme.Space.l)

                VStack(spacing: Theme.Space.m) {
                    SignInWithAppleButton(.continue) { request in
                        request.requestedScopes = [.fullName]
                    } onCompletion: { result in
                        handle(result)
                    }
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 54)
                    .clipShape(Capsule())
                    .disabled(signingIn)
                    .overlay {
                        if signingIn {
                            Capsule().fill(.black.opacity(0.6))
                                .overlay(ProgressView().tint(.white))
                        }
                    }

                    Button {
                        Haptics.tap()
                        authMode = .signUp
                        showAuth = true
                    } label: {
                        Label("Sign up with email", systemImage: "envelope")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(signingIn)

                    HStack(spacing: 4) {
                        Text("Already have an account?")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                        Button("Sign in") {
                            Haptics.tap()
                            authMode = .signIn
                            showAuth = true
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    }

                    // Browsing without an account. No token is issued, so every
                    // protected endpoint refuses a guest exactly as it would any
                    // other unauthenticated caller — nothing is relaxed server-side.
                    Button("Continue as Guest") {
                        Haptics.tap()
                        Analytics.track(.onboardingCompleted, ["mode": "guest"])
                        withAnimation(Theme.snap) { app.enterGuestMode() }
                    }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)

                    Text("Free to start. Nutrition figures are estimates, not medical advice.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, Theme.Space.l)
                .padding(.bottom, Theme.Space.m)
            }
            .frame(maxWidth: .infinity)
        }
        .background(Theme.bg)
        .alert("Sign-in failed", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
        .sheet(isPresented: $showAuth) {
            AuthView(startingMode: authMode) { onboarded in
                app.phase = onboarded ? .ready : .onboarding
                if onboarded { Task { await app.refresh() } }
            }
        }
    }

    private func handle(_ result: Result<ASAuthorization, Error>) {
        guard case .success(let auth) = result,
              let cred = auth.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = cred.identityToken,
              let token = String(data: tokenData, encoding: .utf8)
        else {
            if case .failure(let e) = result {
                // A user-cancelled sheet is not an error worth alerting about.
                if (e as NSError).code != ASAuthorizationError.canceled.rawValue {
                    error = e.localizedDescription
                }
            }
            return
        }

        signingIn = true
        Task {
            defer { signingIn = false }
            do {
                let res = try await APIClient.shared.signInWithApple(
                    identityToken: token,
                    name: cred.fullName?.givenName
                )
                Haptics.success()
                app.phase = res.onboarded ? .ready : .onboarding
                if res.onboarded { await app.refresh() }
            } catch {
                Haptics.warn()
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Looping scan demo

/// Framing → scanning → results, on a loop. Everything is drawn in SwiftUI, so
/// there are no video assets to ship and it adapts to light and dark mode.
struct ScanDemoView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Phase { case framing, scanning, results }

    @State private var phase: Phase = .framing
    @State private var sweep: CGFloat = 0
    @State private var revealed = 0
    @State private var mealIndex = 0

    private struct DemoMeal {
        let market: String
        let plate: [Color]                                   // drawn stand-in
        let items: [(name: String, kcal: Int, tint: Color)]
    }

    /// First-run demo is North America only. The food database handles every
    /// cuisine, but a cold-start user in Ohio should recognise the very first
    /// plate they see — regional examples surface later, from their own logs
    /// and preferences, not from the launch screen.
    private let meals: [DemoMeal] = [
        DemoMeal(market: "USA",
                 plate: [Color(hex: 0xC2703F), Color(hex: 0x7FA35A), Color(hex: 0xE8D9A8)],
                 items: [("Grilled chicken", 248, Theme.protein),
                         ("Sweet potato", 180, Theme.carbs),
                         ("Caesar salad", 145, Theme.fat)]),

        DemoMeal(market: "USA",
                 plate: [Color(hex: 0xD8C9A3), Color(hex: 0xC4703C), Color(hex: 0x8FA663)],
                 items: [("Scrambled eggs × 2", 155, Theme.protein),
                         ("Oatmeal", 190, Theme.carbs),
                         ("Blueberries", 45, Theme.fat)]),

        DemoMeal(market: "USA",
                 plate: [Color(hex: 0xB4553A), Color(hex: 0xE3D2A0), Color(hex: 0x9CAF6B)],
                 items: [("Turkey sandwich", 320, Theme.carbs),
                         ("Cheddar", 110, Theme.fat),
                         ("Side salad", 60, Theme.protein)]),

        DemoMeal(market: "Canada",
                 plate: [Color(hex: 0xB4553A), Color(hex: 0xD9C48A), Color(hex: 0x86A05E)],
                 items: [("Salmon fillet", 280, Theme.protein),
                         ("Wild rice", 165, Theme.carbs),
                         ("Green beans", 55, Theme.fat)]),

    ]

    private var meal: DemoMeal { meals[mealIndex % meals.count] }
    private var items: [(name: String, kcal: Int, tint: Color)] { meal.items }

    private var total: Int {
        items.prefix(revealed).reduce(0) { sum, item in sum + item.kcal }
    }

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Theme.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(Theme.hairline, lineWidth: 1)
                    )

                PlateView(dimmed: phase == .results, tints: meal.plate)
                    .padding(28)

                if phase != .results {
                    ViewfinderCorners()
                        .padding(22)
                        .transition(.opacity)
                }

                if phase == .scanning {
                    ScanSweep(offset: sweep)
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .transition(.opacity)
                }

                if phase == .results {
                    resultOverlay
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .aspectRatio(1, contentMode: .fit)

            caption
        }
        .task { await run() }
    }

    private var resultOverlay: some View {
        VStack(spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(total)")
                    .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                Text("cal")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    if index < revealed {
                        HStack(spacing: 8) {
                            Circle().fill(item.tint).frame(width: 6, height: 6)
                            Text(item.name)
                                .font(.system(size: 13, weight: .medium))
                            Spacer(minLength: 12)
                            Text("\(item.kcal)")
                                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Theme.card, in: Capsule())
                        .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .frame(width: 210)
        }
        .padding(Theme.Space.m)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var caption: some View {
        Text(captionText)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .contentTransition(.opacity)
            .id(captionText)
    }

    private var captionText: String {
        switch phase {
        case .framing:  "Point at your plate"
        case .scanning: "Reading the meal…"
        case .results:  "Logged in 3 seconds"
        }
    }

    private func run() async {
        // Motion-sensitive users get the finished state, not a loop.
        guard !reduceMotion else {
            phase = .results
            revealed = items.count
            return
        }

        while !Task.isCancelled {
            withAnimation(Theme.snap) { phase = .framing; revealed = 0 }
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }

            withAnimation(Theme.snap) { phase = .scanning }
            sweep = 0
            withAnimation(.easeInOut(duration: 1.1)) { sweep = 1 }
            try? await Task.sleep(for: .milliseconds(1250))
            guard !Task.isCancelled else { return }

            withAnimation(Theme.snap) { phase = .results }
            for step in 1...items.count {
                try? await Task.sleep(for: .milliseconds(260))
                guard !Task.isCancelled else { return }
                withAnimation(Theme.snap) { revealed = step }
            }

            try? await Task.sleep(for: .milliseconds(1900))
            guard !Task.isCancelled else { return }
            mealIndex += 1
        }
    }
}

// MARK: - Demo pieces

private struct PlateView: View {
    let dimmed: Bool
    var tints: [Color] = []

    /// A real photo if one has been added to the asset catalog, otherwise the
    /// drawn stand-in. Ships either way — a missing asset degrades, not crashes.
    private var photo: UIImage? { UIImage(named: "DemoPlate") }

    var body: some View {
        Group {
            if let photo {
                Image(uiImage: photo)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Theme.hairline, lineWidth: 1))
            } else {
                drawnPlate
            }
        }
        .opacity(dimmed ? 0.35 : 1)
        .blur(radius: dimmed ? 1.5 : 0)
        .animation(Theme.snap, value: dimmed)
    }

    private var drawnPlate: some View {
        ZStack {
            Circle()
                .fill(Color.primary.opacity(0.05))
                .overlay(Circle().stroke(Theme.hairline, lineWidth: 1))

            // Three abstract portions. Colours come from the current market so
            // the plate reads differently as the demo rotates.
            GeometryReader { geo in
                let s = min(geo.size.width, geo.size.height)
                let c0 = tints.indices.contains(0) ? tints[0] : Theme.carbs
                let c1 = tints.indices.contains(1) ? tints[1] : Theme.protein
                let c2 = tints.indices.contains(2) ? tints[2] : Theme.fat

                Circle()
                    .fill(c0.opacity(0.75))
                    .frame(width: s * 0.34, height: s * 0.34)
                    .position(x: s * 0.33, y: s * 0.32)

                Circle()
                    .fill(c0.opacity(0.55))
                    .frame(width: s * 0.30, height: s * 0.30)
                    .position(x: s * 0.44, y: s * 0.24)

                Circle()
                    .fill(c1.opacity(0.7))
                    .frame(width: s * 0.28, height: s * 0.28)
                    .position(x: s * 0.71, y: s * 0.42)
                    .overlay(
                        Circle()
                            .stroke(c1.opacity(0.45), lineWidth: 3)
                            .frame(width: s * 0.34, height: s * 0.34)
                            .position(x: s * 0.71, y: s * 0.42)
                    )

                Capsule()
                    .fill(c2.opacity(0.7))
                    .frame(width: s * 0.36, height: s * 0.22)
                    .position(x: s * 0.48, y: s * 0.72)
            }
        }
    }
}

private struct ViewfinderCorners: View {
    var body: some View {
        GeometryReader { geo in
            let len = min(geo.size.width, geo.size.height) * 0.16
            ForEach(0..<4, id: \.self) { corner in
                CornerBracket(length: len)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(Double(corner) * 90))
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }
}

private struct CornerBracket: Shape {
    let length: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + length))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + length, y: rect.minY))
        return path
    }
}

private struct ScanSweep: View {
    let offset: CGFloat

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height

            ZStack(alignment: .top) {
                LinearGradient(
                    colors: [Theme.accent.opacity(0), Theme.accent.opacity(0.22)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: h * 0.32)

                Rectangle()
                    .fill(
                        LinearGradient(colors: [.clear, Theme.accent, .clear],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                    .frame(height: 2.5)
                    .offset(y: h * 0.32)
                    .shadow(color: Theme.accent.opacity(0.6), radius: 8)
            }
            .offset(y: -h * 0.32 + offset * h)
        }
    }
}
