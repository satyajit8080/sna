import SwiftUI

/// Home. Layout follows the Figma design; every value is live data.
///
/// The one deliberate departure: the calorie ring renders against
/// `budget.total_calories` (target + credited activity), not the base target.
/// The design showed "580 left" of 1,900 while also showing 320 active
/// calories — those two numbers contradict each other. Server-side, remaining
/// already includes the activity credit, so the ring follows the server.
struct DashboardView: View {
    @Environment(AppState.self) private var app
    @Environment(SubscriptionManager.self) private var store
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(HealthService.self) private var health

    @State private var route: LogRoute?
    @State private var showPaywall = false
    @State private var showMoreOptions = false
    @State private var showDiary = false
    @State private var showProgress = false
    @State private var showSettings = false
    @State private var briefing: DailyBriefing = .empty
    @State private var briefingLoaded = false

    private var dash: Dashboard { app.dashboard }

    var body: some View {
        NavigationStack {
            ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.l) {
                        greeting
                        if dash.streakDays > 0 { streakCard }
                        prioritySection

                        sectionHeader("Today Overview", action: nil)
                        overviewCard
                        metricGrid

                        sectionHeader("Today's Meals",
                                      action: dash.meals.isEmpty ? nil : ("View All", {
                                          Haptics.tap()
                                          showDiary = true
                                      }))
                        mealList

                        coachInsight

                        if !entitlements.isPro {
                            let scan = entitlements.entitlements.foodScan
                            Button {
                                entitlements.present(.foodScan, source: "dashboard_badge")
                            } label: {
                                Text(scan.isExhausted ? "Free scans used — go unlimited"
                                                      : scan.badge(noun: "AI scan"))
                                    .font(.jakarta(11, .semibold))
                                    .foregroundStyle(scan.isExhausted ? Theme.accent : Theme.secondary)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)

                            PremiumCard()
                        }

                        Text("Calorie and macro figures are AI estimates, not clinical measurements.")
                            .font(.jakarta(11))
                            .foregroundStyle(Theme.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)

                    Color.clear.frame(height: 86)   // clears the tab bar
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.top, Theme.Space.s)
            }
            .refreshable {
                await app.refresh()
                await loadBriefing()
            }
            .task { await loadBriefing() }
            .background(Theme.bg)
            .navigationBarHidden(true)
            .fullScreenCover(item: $route) { LogFlowView(route: $0) }
            .sheet(isPresented: $showPaywall) {
                PaywallView(context: .general, source: "dashboard")
            }
            .sheet(isPresented: $showDiary) { DiaryView() }
            .sheet(isPresented: $showProgress) { ProgressHubView() }
            .sheet(isPresented: $showSettings) { SettingsView() }
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

    // MARK: - Header

    private var greeting: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(salutation)
                    .font(.title)
                Text("You're doing great. Let's crush your goal today.")
                    .font(.jakarta(12, .medium))
                    .foregroundStyle(Theme.secondary)
            }

            Spacer(minLength: Theme.Space.s)

            // With four tabs there is no Settings tab, so this is the only way
            // in — and account deletion lives behind it.
            Button {
                Haptics.tap()
                showSettings = true
            } label: {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Profile and settings")
        }
        .padding(.top, Theme.Space.l)
    }

    private var salutation: String {
        let name = app.profileFirstName
        let part = switch Calendar.current.component(.hour, from: .now) {
        case 4..<12: "Good Morning"
        case 12..<17: "Good Afternoon"
        default: "Good Evening"
        }
        return name.isEmpty ? "\(part)!" : "\(part), \(name)!"
    }

    private var streakCard: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "flame.fill")
                .font(.system(size: 20))
                .foregroundStyle(Theme.streak)
                .frame(width: 47, height: 47)
                .background(Theme.streak.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text("\(dash.streakDays) day streak").font(.jakarta(15, .semibold))
                Text("Keep it up!")
                    .font(.jakarta(12, .medium))
                    .foregroundStyle(Theme.secondary)
            }

            Spacer()

            Text("View Progress")
                .font(.caption_)
                .foregroundStyle(Theme.streak)
        }
        .contentShape(.rect)
        .onTapGesture {
            Haptics.tap()
            showProgress = true
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(Theme.streak.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .stroke(Theme.streak.opacity(0.2), lineWidth: 1)
        )
    }

    /// Today's 1–3 priorities. The hero of this screen.
    @ViewBuilder private var prioritySection: some View {
        if !briefing.headline.isEmpty || !briefing.actions.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if !briefing.headline.isEmpty {
                    Text(briefing.headline)
                        .font(.jakarta(14, .medium))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(briefing.actions) { action in
                    PriorityCard(action: action) {
                        // A completed action changes the picture, so re-ask
                        // rather than leaving a stale list on screen.
                        Task { await loadBriefing() }
                    }
                }

                // Health data missing entirely — offer to connect rather than
                // silently coaching on half the picture.
                if briefing.missing.count >= 3, health.needsPermission {
                    Button {
                        Haptics.tap()
                        connectHealth()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "heart.text.square")
                            Text("Connect Apple Health for sleep and activity coaching")
                                .font(.jakarta(12, .semibold))
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(Theme.accent)
                        .padding(12)
                        .card(radius: Theme.Radius.row, padding: 0)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func loadBriefing() async {
        guard !app.isGuest else { return }
        if let fresh = try? await APIClient.shared.briefing() {
            withAnimation(Theme.snap) { briefing = fresh }
        }
        briefingLoaded = true
    }

    private func sectionHeader(_ title: String,
                               action: (String, () -> Void)?) -> some View {
        HStack(spacing: Theme.Space.m) {
            Text(title).font(.section)
            Spacer()

            // Text, voice, barcode and search live here. The Scan tab covers
            // the camera; without this the other inputs are unreachable.
            if title == "Today's Meals" {
                Button {
                    Haptics.tap()
                    showMoreOptions = true
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add food another way")
            }

            if let action {
                Button(action.0, action: action.1)
                    .font(.caption_)
                    .foregroundStyle(Theme.accent)
            }
        }
    }

    // MARK: - Today Overview

    private var overviewCard: some View {
        HStack(spacing: Theme.Space.m) {
            CalorieRing(consumed: dash.consumed.calories, target: dash.budgetCalories)
                .frame(width: 136, height: 136)

            VStack(spacing: 15) {
                macroRow("Protein", dash.consumed.protein_g, dash.targets.protein_g, Theme.protein)
                macroRow("Carbs", dash.consumed.carbs_g, dash.targets.carbs_g, Theme.carbs)
                macroRow("Fat", dash.consumed.fat_g, dash.targets.fat_g, Theme.fat)
            }
        }
        .card(padding: 17)
    }

    private func macroRow(_ label: String, _ value: Int, _ target: Int, _ tint: Color) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(label)
                    .font(.jakarta(13, .semibold))
                    .foregroundStyle(Theme.secondary)
                Spacer()
                Text("\(value)")
                    .font(.jakarta(13, .semibold))
                + Text("/\(target)g")
                    .font(.jakarta(13, .semibold))
                    .foregroundColor(Theme.secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.10))
                    Capsule().fill(tint)
                        .frame(width: geo.size.width * progress(value, target))
                }
            }
            .frame(height: 5)
        }
        .animation(Theme.snap, value: value)
    }

    private func progress(_ value: Int, _ target: Int) -> CGFloat {
        guard target > 0 else { return 0 }
        return min(1, CGFloat(value) / CGFloat(target))
    }

    // MARK: - Metric tiles

    private var metricGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                            GridItem(.flexible(), spacing: 12)],
                  spacing: 12) {
            MetricTile(icon: "shoeprints.fill", tint: Theme.steps,
                       // Zero with no Health permission is misleading — say so.
                       value: health.needsPermission ? "—" : (dash.activity?.steps.formatted() ?? "0"),
                       detail: health.needsPermission ? "Connect Health" : "/10,000",
                       label: "Steps",
                       onTap: health.needsPermission ? { connectHealth() } : nil)

            MetricTile(icon: "scalemass.fill", tint: Theme.weight,
                       value: dash.currentWeightKg.map { "\($0.formatted(.number.precision(.fractionLength(1)))) kg" } ?? "—",
                       detail: weightDelta, label: "Weight")

            MetricTile(icon: "flame.fill", tint: Theme.activeCal,
                       value: "\(dash.activity?.activeKcal ?? 0)",
                       detail: "kcal today", label: "Active Cal")

            WaterTile(consumedMl: dash.waterMl,
                      targetMl: dash.targets.water_ml,
                      onAdjust: adjustWater)
        }
    }

    private var weightDelta: String {
        guard let current = dash.currentWeightKg, let start = app.startWeightKg else { return "—" }
        let delta = current - start
        guard abs(delta) >= 0.1 else { return "on track" }
        return "\(delta < 0 ? "" : "+")\(delta.formatted(.number.precision(.fractionLength(1)))) kg"
    }

    private func waterLitres(_ ml: Int) -> String {
        "\((Double(ml) / 1000).formatted(.number.precision(.fractionLength(1)))) L"
    }

    private func adjustWater(_ ml: Int) {
        guard app.requireAccount(for: "track your water") else { return }

        // Clamp locally so the optimistic value can never go negative; the
        // server applies the same delta.
        let applied = max(0, app.dashboard.waterMl + ml) - app.dashboard.waterMl
        guard applied != 0 else { return }

        Haptics.tap()
        withAnimation(Theme.snap) { app.dashboard.waterMl += applied }
        Task { _ = try? await APIClient.shared.logWater(ml: applied) }
    }

    // MARK: - Meals

    @ViewBuilder private var mealList: some View {
        if dash.meals.isEmpty {
            Button { start(.camera) } label: {
                VStack(spacing: 6) {
                    Image(systemName: "fork.knife")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.secondary)
                    Text("Nothing logged yet")
                        .font(.jakarta(14, .semibold))
                    Text("Scan your first meal to see it here")
                        .font(.jakarta(12, .medium))
                        .foregroundStyle(Theme.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 26)
                .card(radius: Theme.Radius.row, padding: 0)
            }
            .buttonStyle(.plain)
        } else {
            VStack(spacing: 12) {
                ForEach(dash.meals) { meal in
                    MealRow(meal: meal)
                }
            }
        }
    }

    // MARK: - Coach insight

    @ViewBuilder private var coachInsight: some View {
        if let insight = app.coachInsight {
            HStack(spacing: 11) {
                Image(systemName: "sparkles")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 53, height: 53)
                    .background(Theme.accent, in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("AI Coach Insight")
                        .font(.jakarta(16, .bold))
                        .foregroundStyle(Theme.accent)
                    Text(insight)
                        .font(.jakarta(12, .semibold))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
            }
            .padding(11)
            .background(Theme.card,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .stroke(Theme.accent.opacity(0.4), lineWidth: 1)
            )
        }
    }

    // MARK: - Actions

    private func connectHealth() {
        Task {
            await health.requestAuthorization()
            await app.refresh()
        }
    }
    private func start(_ mode: LogMode, slot: MealSlot? = nil) {
        guard app.requireAccount(for: "save your meals") else { return }

        // Ask before the camera opens: framing a plate and then being refused
        // is a worse experience than being told up front.
        let scan = entitlements.entitlements.foodScan
        if !entitlements.isPro, scan.isExhausted {
            entitlements.present(.foodScan, source: "scan_cta")
            return
        }
        route = LogRoute(mode: mode, slot: slot ?? MealSlot.suggested())
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
            Circle().stroke(Theme.accent.opacity(0.10), lineWidth: 12)

            Circle()
                .trim(from: 0, to: min(progress, 1))
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))

            // Overshoot draws a second arc rather than hiding the excess.
            if progress > 1 {
                Circle()
                    .trim(from: 0, to: min(progress - 1, 1))
                    .stroke(Theme.danger, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }

            VStack(spacing: 0) {
                Text("Calories")
                    .font(.jakarta(12, .semibold))
                    .foregroundStyle(Theme.secondary)
                Text("\(consumed)")
                    .font(.jakarta(20, .bold))
                    .contentTransition(.numericText())
                Text("of \(target.formatted()) kcal")
                    .font(.jakarta(12, .semibold))
                    .foregroundStyle(Theme.secondary)
                Text(isOver ? "\(abs(remaining)) over" : "\(remaining) left")
                    .font(.jakarta(13, .bold))
                    .foregroundStyle(isOver ? Theme.danger : Theme.accent)
            }
        }
        .animation(Theme.snap, value: progress)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(consumed) of \(target) calories, \(abs(remaining)) \(isOver ? "over" : "remaining")")
    }
}

// MARK: - Metric tile

struct MetricTile: View {
    let icon: String
    let tint: Color
    let value: String
    let detail: String
    let label: String
    var onTap: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            IconTile(systemName: icon, tint: tint)
            Spacer(minLength: 6)
            Text(value)
                .font(.bigNum)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            Text(detail)
                .font(.jakarta(13, .bold))
                .foregroundStyle(tint)
            Spacer(minLength: 6)
            Text(label)
                .font(.caption_)
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 150)
        .padding(17)
        .card(padding: 0)
        .contentShape(.rect)
        .onTapGesture {
            guard let onTap else { return }
            Haptics.tap()
            onTap()
        }
    }
}

// MARK: - Meal row

struct MealRow: View {
    @Environment(AppState.self) private var app
    let meal: Meal

    /// The design shows a food photo here. Meal images are never persisted —
    /// they are hashed for the scan cache and discarded — so this renders a
    /// tinted slot glyph instead. Storing photos would need object storage and
    /// a privacy-label change.
    private var thumbnail: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Theme.accent.opacity(0.10))
            .frame(width: 65, height: 65)
            .overlay(
                Image(systemName: meal.slot.icon)
                    .font(.system(size: 24))
                    .foregroundStyle(Theme.accent)
            )
    }

    var body: some View {
        HStack(spacing: 12) {
            thumbnail

            VStack(alignment: .leading, spacing: 2) {
                Text(meal.slot.title).font(.rowTitle)
                Text(meal.items.map(\.name).joined(separator: ", ").capitalized)
                    .font(.jakarta(12, .semibold))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                if let time = meal.loggedTime {
                    Text(time)
                        .font(.micro)
                        .foregroundStyle(Theme.secondary)
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 0) {
                Text("\(meal.calories)")
                    .font(.jakarta(16, .bold))
                    .foregroundStyle(Theme.accent)
                Text("kcal")
                    .font(.micro)
                    .foregroundStyle(Theme.secondary)
            }
        }
        .padding(8)
        .card(radius: Theme.Radius.row, padding: 0)
    }
}

// MARK: - Premium card

struct PremiumCard: View {
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(HealthService.self) private var health

    var body: some View {
        Button {
            Haptics.tap()
            Analytics.track(.premiumCTAClicked, ["source": "home_card"])
            entitlements.present(.general, source: "home_card")
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                    Text("Get More From Your AI Coach").font(.jakarta(15, .bold))
                }
                Text("Unlimited scans · Unlimited coaching · Personalized meal plans")
                    .font(.jakarta(12, .medium))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    Text("Unlock Premium").font(.jakarta(13, .bold))
                    Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(Theme.accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .card(radius: Theme.Radius.row, padding: 0)
        }
        .buttonStyle(.plain)
    }
}


/// Water tile with its own +/− controls.
///
/// This was tap-to-add-only, which made an accidental double tap unfixable —
/// hence days showing 4.2 L against a 2.1 L target.
struct WaterTile: View {
    let consumedMl: Int
    let targetMl: Int
    let onAdjust: (Int) -> Void

    private func litres(_ ml: Int) -> String {
        "\((Double(ml) / 1000).formatted(.number.precision(.fractionLength(1)))) L"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                IconTile(systemName: "drop.fill", tint: Theme.water)
                Spacer()
                Button {
                    onAdjust(-250)
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.water)
                        .frame(width: 30, height: 30)
                        .background(Theme.water.opacity(0.10), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(consumedMl <= 0)
                .opacity(consumedMl <= 0 ? 0.35 : 1)

                Button {
                    onAdjust(250)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Theme.water, in: Circle())
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 6)

            Text(litres(consumedMl))
                .font(.bigNum)
                .contentTransition(.numericText())
            Text("/\(litres(targetMl))")
                .font(.jakarta(13, .bold))
                .foregroundStyle(Theme.water)

            Spacer(minLength: 6)

            Text("Water")
                .font(.caption_)
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 150)
        .padding(17)
        .card(padding: 0)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Water, \(litres(consumedMl)) of \(litres(targetMl))")
    }
}
