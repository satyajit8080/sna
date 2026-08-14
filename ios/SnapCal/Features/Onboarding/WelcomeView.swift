import SwiftUI
import AuthenticationServices

struct WelcomeView: View {
    @Environment(AppState.self) private var app
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: Theme.Space.m)

            // Shows the product in four seconds: plate → scan → macros.
            ScanDemoView()
                .frame(height: 320)
                .padding(.horizontal, Theme.Space.l)

            Spacer(minLength: Theme.Space.m)

            VStack(spacing: Theme.Space.s) {
                Text("Snap it.\nCount it.\nDone.")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .lineSpacing(-4)

                Text("The fastest way to track what you eat — including the food you actually eat at home.")
                    .font(.body_)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Space.l)
            }

            Spacer(minLength: Theme.Space.l)

            VStack(spacing: Theme.Space.s) {
                SignInWithAppleButton(.continue) { request in
                    request.requestedScopes = [.fullName]
                } onCompletion: { result in
                    handle(result)
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 52)
                .clipShape(Capsule())

                Text("Nutrition figures are estimates, not medical advice.")
                    .font(.caption_)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.bottom, Theme.Space.l)
        }
        .alert("Sign-in failed", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func handle(_ result: Result<ASAuthorization, Error>) {
        guard case .success(let auth) = result,
              let cred = auth.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = cred.identityToken,
              let token = String(data: tokenData, encoding: .utf8)
        else {
            if case .failure(let e) = result { error = e.localizedDescription }
            return
        }

        Task {
            do {
                let res = try await APIClient.shared.signInWithApple(
                    identityToken: token,
                    name: cred.fullName?.givenName
                )
                app.phase = res.onboarded ? .ready : .onboarding
                if res.onboarded { await app.refresh() }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Animated demo

/// A looping four-beat dramatisation of the core loop: a plate appears, the
/// scanner sweeps it, items resolve one by one, and the calorie total lands.
/// Everything is drawn with shapes — no bundled artwork to ship or localise.
private struct ScanDemoView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Beat: Int { case idle, scanning, resolving, total }

    @State private var beat: Beat = .idle
    @State private var sweep: CGFloat = 0
    @State private var revealed = 0
    @State private var calories = 0

    private let items: [(name: String, kcal: Int, color: Color)] = [
        ("Roti ×2", 238, Theme.carbs),
        ("Dal tadka", 177, Theme.protein),
        ("Bhindi masala", 138, Theme.accent),
    ]
    private var totalCalories: Int { items.reduce(0) { $0 + $1.kcal } }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Theme.card)
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Theme.hairline, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.05), radius: 18, y: 8)

            VStack(spacing: Theme.Space.m) {
                plate
                    .frame(height: 150)
                    .overlay(scannerOverlay)

                resultStrip
                    .frame(height: 92)
            }
            .padding(Theme.Space.m)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Demonstration: photographing a meal of roti, dal and sabzi estimates \(totalCalories) calories")
        .task { await run() }
    }

    // MARK: Plate

    private var plate: some View {
        ZStack {
            Circle()
                .fill(Color.primary.opacity(0.04))
                .overlay(Circle().stroke(Theme.hairline, lineWidth: 1))

            // Two rotis, a katori of dal, a katori of sabzi — the thali shape.
            Circle()
                .fill(Color(hex: 0xE8C98A))
                .frame(width: 62, height: 62)
                .offset(x: -30, y: -18)
                .overlay(
                    Circle().stroke(Color(hex: 0xD4AF6A), lineWidth: 1.5)
                        .frame(width: 62, height: 62)
                        .offset(x: -30, y: -18)
                )

            Circle()
                .fill(Color(hex: 0xE6B85C))
                .frame(width: 46, height: 46)
                .offset(x: 32, y: -22)

            Circle()
                .fill(Color(hex: 0x6FA85A))
                .frame(width: 44, height: 44)
                .offset(x: 18, y: 32)

            Circle()
                .fill(Color(hex: 0xF3EDE0))
                .frame(width: 34, height: 34)
                .offset(x: -34, y: 34)
        }
        .frame(width: 150, height: 150)
        .scaleEffect(beat == .idle ? 0.94 : 1)
        .animation(Theme.snap, value: beat)
    }

    private var scannerOverlay: some View {
        GeometryReader { geo in
            ZStack {
                // Viewfinder corners, drawn only while framing and scanning.
                ForEach(0..<4, id: \.self) { corner in
                    CornerBracket()
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 26, height: 26)
                        .rotationEffect(.degrees(Double(corner) * 90))
                        .position(cornerPosition(corner, in: geo.size))
                }
                .opacity(beat == .total ? 0 : 1)

                if beat == .scanning {
                    // The sweep line, with a soft trail behind it.
                    ZStack(alignment: .top) {
                        LinearGradient(
                            colors: [Theme.accent.opacity(0), Theme.accent.opacity(0.22)],
                            startPoint: .top, endPoint: .bottom
                        )
                        .frame(height: 54)

                        Rectangle()
                            .fill(Theme.accent)
                            .frame(height: 2.5)
                            .shadow(color: Theme.accent.opacity(0.6), radius: 6)
                    }
                    .frame(width: geo.size.width * 0.72)
                    .offset(y: sweep * geo.size.height * 0.82 - geo.size.height * 0.06)
                    .mask(RoundedRectangle(cornerRadius: 16).frame(height: geo.size.height * 0.86))
                }
            }
            .animation(Theme.quick, value: beat)
        }
    }

    private func cornerPosition(_ index: Int, in size: CGSize) -> CGPoint {
        let inset: CGFloat = 24
        let xs = [inset, size.width - inset, size.width - inset, inset]
        let ys = [inset, inset, size.height - inset, size.height - inset]
        return CGPoint(x: xs[index], y: ys[index])
    }

    // MARK: Results

    @ViewBuilder private var resultStrip: some View {
        switch beat {
        case .idle, .scanning:
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 12))
                Text(beat == .scanning ? "Reading your plate…" : "Point at your food")
                    .font(.system(size: 14, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)

        case .resolving:
            VStack(spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    if index < revealed {
                        HStack(spacing: 8) {
                            Circle().fill(item.color).frame(width: 7, height: 7)
                            Text(item.name)
                                .font(.system(size: 14, weight: .medium))
                            Spacer()
                            Text("\(item.kcal)")
                                .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .transition(.asymmetric(
                            insertion: .push(from: .bottom).combined(with: .opacity),
                            removal: .opacity
                        ))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

        case .total:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(calories)")
                    .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 0) {
                    Text("calories").font(.system(size: 15, weight: .medium))
                    Text("logged in 4 seconds")
                        .font(.caption_).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.scale(scale: 0.85).combined(with: .opacity))
        }
    }

    // MARK: Timeline

    private func run() async {
        // Reduce Motion: show the payoff, skip the theatre.
        if reduceMotion {
            beat = .total
            calories = totalCalories
            return
        }

        while !Task.isCancelled {
            withAnimation(Theme.snap) { beat = .idle; revealed = 0; calories = 0 }
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }

            withAnimation(Theme.quick) { beat = .scanning }
            withAnimation(.easeInOut(duration: 1.1)) { sweep = 1 }
            try? await Task.sleep(for: .milliseconds(1150))
            guard !Task.isCancelled else { return }
            sweep = 0

            withAnimation(Theme.snap) { beat = .resolving }
            for index in items.indices {
                try? await Task.sleep(for: .milliseconds(340))
                guard !Task.isCancelled else { return }
                withAnimation(Theme.snap) { revealed = index + 1 }
            }

            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            withAnimation(Theme.snap) { beat = .total }

            // Count up rather than snapping, so the number reads as a result.
            for step in stride(from: 0, through: totalCalories, by: 61) {
                try? await Task.sleep(for: .milliseconds(28))
                guard !Task.isCancelled else { return }
                withAnimation(.linear(duration: 0.03)) { calories = min(step, totalCalories) }
            }
            withAnimation(Theme.snap) { calories = totalCalories }

            try? await Task.sleep(for: .milliseconds(1900))
        }
    }
}

/// One corner of a viewfinder bracket, drawn from the top-left inward.
private struct CornerBracket: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.28))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + rect.width * 0.28, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}
