import SwiftUI

struct DashboardView: View {
    @Environment(AppState.self) private var app
    @Environment(SubscriptionManager.self) private var store
    @Environment(EntitlementStore.self) private var entitlements

    @State private var route: LogRoute?
    @State private var showPaywall = false
    @State private var showMoreOptions = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(spacing: Theme.Space.l) {
                        CalorieRing(
                            consumed: app.dashboard.consumed.calories,
                            target: app.dashboard.targets.calories
                        )
                        .padding(.top, Theme.Space.s)

                        MacroBars(consumed: app.dashboard.consumed, targets: app.dashboard.targets)

                        ForEach(MealSlot.allCases) { slot in
                            MealSection(
                                slot: slot,
                                meals: app.dashboard.meals.filter { $0.slot == slot },
                                onAdd: { start(.camera, slot: slot) }
                            )
                        }

                        if !entitlements.isPro { PremiumCard() }

                        WaterStrip()

                        Text("Calorie and macro figures are AI estimates, not clinical measurements.")
                            .font(.caption_)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, Theme.Space.l)

                        Color.clear.frame(height: 110) // room for the CTA
                    }
                    .padding(.horizontal, Theme.Space.m)
                }
                .refreshable { await app.refresh() }

                scanCTA
            }
            .background(Theme.bg)
            .navigationTitle(greeting)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if app.dashboard.streakDays > 1 {
                        Label("\(app.dashboard.streakDays)", systemImage: "flame.fill")
                            .font(.label)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .fullScreenCover(item: $route) { route in
                LogFlowView(route: route)
            }
            .sheet(isPresented: $showPaywall) { PaywallView(context: .general, source: "dashboard") }
            .confirmationDialog("Add food", isPresented: $showMoreOptions, titleVisibility: .visible) {
                Button("Upload a photo") { start(.library) }
                Button("Describe it") { start(.text) }
                Button("Say it") { start(.voice) }
                Button("Scan a barcode") { start(.barcode) }
                Button("Search foods") { start(.search) }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    // MARK: - The one button that matters

    private var scanCTA: some View {
        VStack(spacing: Theme.Space.s) {
            if !entitlements.isPro {
                let scan = entitlements.entitlements.foodScan
                Button {
                    entitlements.present(.foodScan, source: "dashboard_badge")
                } label: {
                    Text(scan.isExhausted ? "Free scans used — go unlimited"
                                          : scan.badge(noun: "AI scan"))
                        .font(.caption_)
                        .foregroundStyle(scan.isExhausted ? Theme.accent : .secondary)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: Theme.Space.s) {
                Button {
                    Haptics.commit()
                    start(.camera)
                } label: {
                    Label("Scan Food", systemImage: "camera.fill")
                }
                .buttonStyle(PrimaryButtonStyle())

                Button {
                    Haptics.tap()
                    showMoreOptions = true
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 54, height: 54)
                        .background(Theme.card, in: Circle())
                        .overlay(Circle().stroke(Theme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.bottom, Theme.Space.s)
        .background(
            LinearGradient(colors: [Theme.bg.opacity(0), Theme.bg, Theme.bg],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .frame(height: 160)
                .allowsHitTesting(false),
            alignment: .bottom
        )
    }

    private func start(_ mode: LogMode, slot: MealSlot? = nil) {
        // Guests can browse the sample day, but logging needs somewhere to
        // save it. Ask before the camera opens, not after they've framed a plate.
        guard app.requireAccount(for: "save your meals") else { return }

        // Check before opening the camera: making someone frame a plate and
        // then refusing them is a worse experience than asking up front.
        let scan = entitlements.entitlements.foodScan
        if !entitlements.isPro, scan.isExhausted {
            entitlements.present(.foodScan, source: "scan_cta")
            return
        }
        route = LogRoute(mode: mode, slot: slot ?? MealSlot.suggested())
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 4..<12: "Good morning"
        case 12..<17: "Good afternoon"
        default: "Good evening"
        }
    }
}

// MARK: - Calorie ring

struct CalorieRing: View {
    let consumed: Int
    let target: Int

    private var progress: Double { target > 0 ? min(Double(consumed) / Double(target), 1.35) : 0 }
    private var remaining: Int { target - consumed }
    private var isOver: Bool { remaining < 0 }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.hairline, lineWidth: 18)

            Circle()
                .trim(from: 0, to: min(progress, 1))
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 18, lineCap: .round))
                .rotationEffect(.degrees(-90))

            // Overshoot draws a second, warmer arc rather than hiding the excess.
            if progress > 1 {
                Circle()
                    .trim(from: 0, to: min(progress - 1, 1))
                    .stroke(Theme.danger, style: StrokeStyle(lineWidth: 18, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }

            VStack(spacing: 2) {
                Text("\(abs(remaining))")
                    .font(.hero)
                    .contentTransition(.numericText())
                    .foregroundStyle(isOver ? Theme.danger : .primary)

                Text(isOver ? "over" : "left")
                    .font(.label)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Text("\(consumed) of \(target)")
                    .font(.caption_)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
        }
        .frame(width: 210, height: 210)
        .animation(Theme.snap, value: progress)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(consumed) of \(target) calories eaten, \(abs(remaining)) \(isOver ? "over" : "remaining")")
    }
}

// MARK: - Macro bars

struct MacroBars: View {
    let consumed: MacroTotal
    let targets: Targets

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            bar("Protein", consumed.protein_g, targets.protein_g, Theme.protein)
            bar("Carbs", consumed.carbs_g, targets.carbs_g, Theme.carbs)
            bar("Fat", consumed.fat_g, targets.fat_g, Theme.fat)
        }
        .card()
    }

    private func bar(_ label: String, _ value: Int, _ target: Int, _ color: Color) -> some View {
        VStack(spacing: 6) {
            Text(label).font(.caption_).foregroundStyle(.secondary)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.15))
                    Capsule().fill(color)
                        .frame(width: geo.size.width * min(1, target > 0 ? Double(value) / Double(target) : 0))
                }
            }
            .frame(height: 6)

            Text("\(value)/\(target)g")
                .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
        .animation(Theme.snap, value: value)
    }
}

// MARK: - Meal sections

struct MealSection: View {
    @Environment(AppState.self) private var app
    let slot: MealSlot
    let meals: [Meal]
    let onAdd: () -> Void

    private var calories: Int { meals.reduce(0) { $0 + $1.calories } }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Label(slot.title, systemImage: slot.icon)
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                if calories > 0 {
                    Text("\(calories) cal")
                        .font(.system(size: 15, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button(action: onAdd) {
                    Image(systemName: "plus").font(.system(size: 14, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }

            if meals.isEmpty {
                Button(action: onAdd) {
                    Text("Nothing logged yet — tap to scan")
                        .font(.caption_)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, Theme.Space.s)
                }
                .buttonStyle(.plain)
            } else {
                ForEach(meals) { meal in
                    ForEach(meal.items) { item in
                        HStack {
                            Text(item.name.capitalized).font(.body_).lineLimit(1)
                            if item.isEstimate {
                                Image(systemName: "sparkle")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Text("\(item.calories)")
                                .font(.system(size: 15, weight: .medium, design: .rounded).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
        .card()
    }
}

// MARK: - Water

struct WaterStrip: View {
    @Environment(AppState.self) private var app
    private let glass = 250

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "drop.fill").foregroundStyle(.cyan)

            VStack(alignment: .leading, spacing: 4) {
                Text("Water").font(.system(size: 15, weight: .semibold))
                Text("\(app.dashboard.waterMl) / \(app.dashboard.targets.water_ml) ml")
                    .font(.caption_).foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Haptics.tap()
                adjust(-glass)
            } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .disabled(app.dashboard.waterMl <= 0)

            Button {
                Haptics.tap()
                adjust(glass)
            } label: { Image(systemName: "plus.circle.fill").font(.system(size: 26)) }
                .buttonStyle(.plain).foregroundStyle(.cyan)
        }
        .card()
    }

    private func adjust(_ ml: Int) {
        guard app.requireAccount(for: "track your water") else { return }
        withAnimation(Theme.snap) { app.dashboard.waterMl = max(0, app.dashboard.waterMl + ml) }
        Task { _ = try? await APIClient.shared.logWater(ml: ml) }
    }
}


/// Tasteful upgrade card. Deliberately below the fold on a full day: the app
/// should feel like a tracker with an offer, not an ad with a tracker.
struct PremiumCard: View {
    @Environment(EntitlementStore.self) private var entitlements

    var body: some View {
        Button {
            Haptics.tap()
            Analytics.track(.premiumCTAClicked, ["source": "home_card"])
            entitlements.present(.general, source: "home_card")
        } label: {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                    Text("Get More From Your AI Coach")
                        .font(.system(size: 16, weight: .semibold))
                }

                Text("Unlimited scans · Unlimited coaching · Personalized meal plans")
                    .font(.caption_)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 4) {
                    Text("Unlock Premium").font(.system(size: 14, weight: .semibold))
                    Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold))
                }
                .foregroundStyle(Theme.accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
        .buttonStyle(.plain)
    }
}
