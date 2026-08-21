import Charts
import SwiftData
import SwiftUI

/// Home, implemented from the Figma design.
///
/// Every number here comes from stored data. Where a value is genuinely absent
/// the card says so rather than showing a placeholder — the design's sample
/// figures are examples, not defaults.
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(GuidelineEngine.self) private var guidelines
    @Environment(\.modelContext) private var context

    @Query(sort: \BPReading.recordedAt, order: .reverse) private var allReadings: [BPReading]
    @Query private var allMedications: [Medication]
    @Query private var allDoses: [MedicationDose]
    @Query private var allLifestyle: [LifestyleEntry]
    @Query private var allAppointments: [Appointment]
    @Query(sort: \ActivityEntry.startedAt, order: .reverse) private var allActivity: [ActivityEntry]
    @Query private var allSymptoms: [SymptomEntry]

    @State private var isPresentingAdd = false

    private var readings: [BPReading] {
        allReadings.filter { $0.profileID == app.activeProfile.id }
    }

    var body: some View {
        ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    greeting
                    latestReadingCard
                    todaysHealth
                    foodAndSodium
                    movementCard
                    medicationCard
                    coachCard
                }
                .padding(.horizontal, Brand.Metric.pagePadding)
                .padding(.bottom, 32)
        }
        .background(Brand.background.ignoresSafeArea())
        .navigationBarHidden(true)
        .sheet(isPresented: $isPresentingAdd) { AddBPView() }
        .refreshable { await app.health.refreshSnapshot(for: app.activeProfile) }
        .task {
            await app.health.refreshSnapshot(for: app.activeProfile)
            await app.refreshDailyCheckIn(context: checkInContext)
        }
        .reviewPrompt(app.reviewPrompt, readings: readings, isCalmMoment: isCalmMoment)
    }

    // MARK: - Greeting

    private var greeting: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(timeOfDayGreeting)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Brand.textTertiary)
                Text(app.activeProfile.name)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Brand.textPrimary)
            }
            Spacer()
            NavigationLink { MoreView() } label: {
                Circle()
                    .strokeBorder(Brand.cardStroke, lineWidth: 1)
                    .frame(width: 35, height: 35)
                    .overlay {
                        Image(systemName: "bell")
                            .font(.system(size: 15))
                            .foregroundStyle(Brand.textPrimary)
                    }
            }
            .accessibilityLabel("Notifications and settings")
        }
        .padding(.top, 8)
    }

    private var timeOfDayGreeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 4..<12: "Good Morning,"
        case 12..<17: "Good Afternoon,"
        default: "Good Evening,"
        }
    }

    // MARK: - Latest reading

    private var latestReadingCard: some View {
        BrandCard {
            if let reading = readings.first {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        Text("Latest Reading")
                            .font(.system(size: 12))
                            .foregroundStyle(Brand.textSecondary)
                        Spacer()
                        BrandPill(
                            text: guidelines.category(for: reading).label,
                            tint: GuidelineEngine.color(for: guidelines.category(for: reading).severity)
                        )
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(reading.systolic)/\(reading.diastolic)")
                            .font(.system(size: 25, weight: .bold))
                            .foregroundStyle(Brand.textPrimary)
                        Text("mmHg")
                            .font(.system(size: 12))
                            .foregroundStyle(Brand.textSecondary)
                        Spacer()
                        sparkline
                    }
                    .padding(.top, 12)

                    HStack(spacing: 8) {
                        Circle()
                            .fill(GuidelineEngine.color(for: guidelines.category(for: reading).severity))
                            .frame(width: 8, height: 8)
                        Text(guidelines.category(for: reading).label)
                            .foregroundStyle(Brand.accent)
                        Circle().fill(Brand.textSecondary).frame(width: 4, height: 4)
                        Text(reading.recordedAt.formatted(date: .omitted, time: .shortened))
                            .foregroundStyle(Brand.textSecondary)
                    }
                    .font(.system(size: 12))
                    .padding(.top, 12)

                    if let delta = deltaVsAverage(reading) {
                        HStack(spacing: 6) {
                            Image(systemName: delta > 0 ? "arrow.up" : "arrow.down")
                                .font(.system(size: 9, weight: .bold))
                            Text("\(abs(delta)) mmHg vs 7-day average")
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.textSecondary)
                        .padding(.top, 6)
                    }

                    Text("Today's readings: \(todayCount)")
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.textSecondary)
                        .padding(.top, 6)

                    // History sits beside Edit, as in the design. It is the main
                    // way in now that History has no tab of its own.
                    HStack(spacing: 9) {
                        NavigationLink { ReadingDetailView(reading: reading) } label: {
                            Text("Details")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Brand.onAccent)
                                .padding(.horizontal, 12)
                                .frame(height: 22)
                                .background(Brand.accent)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        NavigationLink { UnifiedHistoryView() } label: {
                            Text("History")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Brand.textPrimary)
                                .padding(.horizontal, 12)
                                .frame(height: 22)
                                .overlay {
                                    Capsule().strokeBorder(Brand.cardStroke, lineWidth: 1)
                                }
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 14)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("No readings yet")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Brand.textPrimary)
                    Text("Sit quietly for five minutes, rest your arm at heart height, then measure.")
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.textSecondary)
                    Button { isPresentingAdd = true } label: {
                        Text("Add a reading")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Brand.onAccent)
                            .padding(.horizontal, 14)
                            .frame(height: 30)
                            .background(Brand.accent)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
            }
        }
    }

    /// The last week at a glance. Drawn only with real readings.
    private var sparkline: some View {
        let recent = Array(BPStatistics.within(readings, days: 7).reversed())
        return Group {
            if recent.count >= 2 {
                Chart(recent) { reading in
                    LineMark(
                        x: .value("Date", reading.recordedAt),
                        y: .value("Systolic", reading.systolic)
                    )
                    .foregroundStyle(Brand.accent)
                    .interpolationMethod(.monotone)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(width: 126, height: 28)
                .accessibilityLabel("Systolic over the last 7 days")
            }
        }
    }

    private func deltaVsAverage(_ reading: BPReading) -> Int? {
        guard let average = BPStatistics.homeAverage(readings, days: 7), average.count >= 2
        else { return nil }
        let delta = reading.systolic - average.systolic
        return delta == 0 ? nil : delta
    }

    private var todayCount: Int {
        readings.filter { Calendar.current.isDateInToday($0.recordedAt) }.count
    }

    // MARK: - Today's Health

    private var todaysHealth: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Today's Health", action: "See All") {
                UnifiedHistoryView()
            }

            let snapshot = app.health.snapshot
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible())], spacing: 16) {
                metricTile(
                    title: "Steps", symbol: "figure.walk", tint: Brand.steps,
                    value: snapshot.steps.map { "\($0.formatted())" },
                    caption: "/10,000 steps",
                    fraction: snapshot.steps.map { Double($0) / 10_000 }
                )
                metricTile(
                    title: "Resting HR", symbol: "heart.fill", tint: Brand.restingHeartRate,
                    value: snapshot.restingHeartRate.map { "\($0)" },
                    caption: "bpm",
                    // 40–100 is the range most resting rates fall in.
                    fraction: snapshot.restingHeartRate.map { Double($0 - 40) / 60 }
                )
                metricTile(
                    title: "Sleep", symbol: "bed.double.fill", tint: Brand.sleep,
                    value: snapshot.sleepMinutes.map { "\($0 / 60)h \($0 % 60)m" },
                    caption: sleepQuality(snapshot.sleepMinutes),
                    fraction: snapshot.sleepMinutes.map { Double($0) / 480 }
                )
                weightTile
            }
        }
    }

    private func sleepQuality(_ minutes: Int?) -> String {
        guard let minutes else { return "Not recorded" }
        return minutes >= 420 ? "Good" : minutes >= 360 ? "A little short" : "Short"
    }

    private func metricTile(
        title: String, symbol: String, tint: Color,
        value: String?, caption: String, fraction: Double?
    ) -> some View {
        BrandCard(padding: 16, radius: Brand.Metric.tileRadius) {
            VStack(alignment: .leading, spacing: 0) {
                BrandIconTile(symbol: symbol, tint: tint)

                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Brand.textSecondary)
                    .padding(.top, 14)

                Text(value ?? "—")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(value == nil ? Brand.textTertiary : Brand.textPrimary)
                    .padding(.top, 4)

                Text(value == nil ? "No data" : caption)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Brand.textSecondary)
                    .padding(.top, 4)

                Spacer(minLength: 8)

                BrandProgressBar(fraction: fraction ?? 0, tint: tint, height: Brand.Metric.barHeight)
            }
            .frame(height: 128, alignment: .top)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value ?? "no data")")
    }

    /// Weight shows change rather than progress — there is no target to fill.
    private var weightTile: some View {
        let weights = allLifestyle
            .filter { $0.profileID == app.activeProfile.id && $0.kind == .weight }
            .sorted { $0.recordedAt > $1.recordedAt }
        let latest = weights.first ?? app.health.snapshot.weightKilograms.map {
            LifestyleEntry(profileID: app.activeProfile.id, kind: .weight,
                           value: $0, unit: "kg", label: "Weight")
        }
        let delta = weights.count >= 2 ? weights[0].value - weights[1].value : nil

        return BrandCard(padding: 16, radius: Brand.Metric.tileRadius) {
            VStack(alignment: .leading, spacing: 0) {
                BrandIconTile(symbol: "scalemass.fill", tint: Brand.weight)

                Text("Weight")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Brand.textSecondary)
                    .padding(.top, 14)

                Text(latest.map { app.settings.displayWeight($0.value) } ?? "—")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(latest == nil ? Brand.textTertiary : Brand.textPrimary)
                    .padding(.top, 4)

                if let delta {
                    HStack(spacing: 5) {
                        Image(systemName: delta > 0 ? "arrow.up" : "arrow.down")
                            .font(.system(size: 9, weight: .bold))
                        Text(String(format: "%.1f kg", abs(delta)))
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Brand.accent)
                    .padding(.top, 4)
                } else {
                    Text(latest == nil ? "No data" : "First entry")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Brand.textSecondary)
                        .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 128, alignment: .top)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Food & Sodium

    private var foodAndSodium: some View {
        let today = allLifestyle.filter {
            $0.profileID == app.activeProfile.id && $0.kind == .sodium
                && Calendar.current.isDateInToday($0.recordedAt)
        }
        let total = today.reduce(0) { $0 + $1.value }
        let target = Double(SodiumSettings.dailyTarget)
        let percent = target > 0 ? Int((total / target) * 100) : 0

        return VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Food & Sodium", action: "See Details") { SodiumListView() }

            BrandCard {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text("\(Int(total))")
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundStyle(Brand.accent)
                                Text("mg")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Brand.accent)
                            }
                            Text("of \(Int(target)) mg")
                                .font(.system(size: 12))
                                .foregroundStyle(Brand.textSecondary)
                            Text("Daily sodium goal")
                                .font(.system(size: 12))
                                .foregroundStyle(Brand.textPrimary)
                                .padding(.top, 4)
                        }

                        VStack(alignment: .trailing, spacing: 10) {
                            HStack(spacing: 8) {
                                BrandProgressBar(fraction: total / target, tint: Brand.progress)
                                Text("\(percent)%")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Brand.accent)
                            }
                            Text(sodiumMessage(total: total, target: target))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Brand.textSecondary)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(Color.white.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                    }

                    NavigationLink { ScanHubView() } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "viewfinder").font(.system(size: 14))
                            Text("Scan Food").font(.system(size: 12, weight: .medium))
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 10))
                        }
                        .foregroundStyle(Brand.accent)
                        .padding(.horizontal, 12)
                        .frame(height: 38)
                        .background(Brand.accent.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 16)
                }
            }
        }
    }

    /// Wording follows the number rather than being fixed, so it stays true.
    private func sodiumMessage(total: Double, target: Double) -> String {
        if total == 0 { return "Nothing logged yet today." }
        if total > target { return "Over your target for today." }
        if total > target * 0.75 { return "Close to your target — keep dinner light." }
        return "Good start! You have room for a normal dinner."
    }

    // MARK: - Movement

    private var movementCard: some View {
        let snapshot = app.health.snapshot
        let todayActivity = allActivity.filter {
            $0.profileID == app.activeProfile.id
                && Calendar.current.isDateInToday($0.startedAt)
        }
        let steps = snapshot.steps ?? 0

        return BrandCard(padding: 16) {
            HStack(alignment: .top, spacing: 12) {
                BrandIconTile(symbol: "figure.run", tint: Brand.accent)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Movement")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Brand.textPrimary)

                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(steps > 0 ? steps.formatted() : "—")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(Brand.accent)
                        Text("/10,000 steps")
                            .font(.system(size: 12))
                            .foregroundStyle(Brand.textSecondary)
                    }

                    BrandProgressBar(fraction: Double(steps) / 10_000, tint: Brand.progress)
                        .padding(.top, 4)

                    HStack(spacing: 8) {
                        if let energy = snapshot.activeEnergyKilocalories {
                            Text("\(energy) active kcal")
                        }
                        if let first = todayActivity.first {
                            Circle().fill(Brand.textSecondary).frame(width: 4, height: 4)
                            Text("\(first.minutes) min \(first.kind.label)")
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Brand.textSecondary)
                    .padding(.top, 4)
                }
            }
        }
    }

    // MARK: - Medications

    private var medicationCard: some View {
        let mine = allMedications.filter { $0.profileID == app.activeProfile.id && !$0.isArchived }
        let doses = allDoses.filter {
            $0.profileID == app.activeProfile.id
                && Calendar.current.isDateInToday($0.scheduledFor)
        }
        let taken = doses.filter { $0.status == .taken }.count

        return Group {
            if !mine.isEmpty {
                NavigationLink { MedicationListView() } label: {
                    BrandCard(padding: 16) {
                        HStack(alignment: .top, spacing: 12) {
                            BrandIconTile(symbol: "pills.fill", tint: Brand.medication)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Medications")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(Brand.textPrimary)
                                Text("\(taken) of \(doses.count) taken today")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Brand.medication)
                                Text(adherenceMessage(taken: taken, total: doses.count))
                                    .font(.system(size: 12))
                                    .foregroundStyle(Brand.textSecondary)
                            }

                            Spacer(minLength: 0)

                            if let next = MedicationEngine.nextDue(from: doses) {
                                VStack(spacing: 2) {
                                    Text(next.scheduledFor.formatted(.dateTime.hour().minute()))
                                        .font(.system(size: 12))
                                        .foregroundStyle(Brand.textSecondary)
                                    Text("Next")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Brand.textSecondary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Brand.progress.opacity(0.1))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(Brand.accent.opacity(0.3), lineWidth: 1)
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func adherenceMessage(taken: Int, total: Int) -> String {
        if total == 0 { return "Nothing scheduled today." }
        if taken == total { return "Great job! Keep it up." }
        return "\(total - taken) still to take."
    }

    // MARK: - Coach

    private var coachCard: some View {
        let insight = DailyInsight.forToday(
            readings: readings,
            doses: allDoses.filter { $0.profileID == app.activeProfile.id },
            sodiumToday: allLifestyle
                .filter {
                    $0.profileID == app.activeProfile.id && $0.kind == .sodium
                        && Calendar.current.isDateInToday($0.recordedAt)
                }
                .reduce(0) { $0 + $1.value },
            sodiumTarget: SodiumSettings.dailyTarget,
            guideline: guidelines.active
        )

        return NavigationLink { CoachView() } label: {
            BrandCard(padding: 16) {
                HStack(alignment: .top, spacing: 12) {
                    BrandIconTile(symbol: "bubble.left.and.text.bubble.right.fill", tint: Brand.medication)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Coach")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Brand.textPrimary)
                            Spacer()
                            Text("Ask Coach")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Brand.accent)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10))
                                .foregroundStyle(Brand.accent)
                        }

                        Text(insight == nil ? "Getting started" : "Today's Insight")
                            .font(.system(size: 12))
                            .foregroundStyle(Brand.accent)

                        Text(insight?.body
                             ?? "Log a few readings and the coach will start spotting patterns in them.")
                            .font(.system(size: 12))
                            .foregroundStyle(Brand.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Shared

    private func sectionHeader<Destination: View>(
        _ title: String,
        action: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Brand.textPrimary)
            Spacer()
            NavigationLink(destination: destination) {
                Text(action)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Brand.accent)
            }
        }
    }

    /// Facts about today, for choosing the check-in question.
    ///
    /// Built from stored records only. Nothing here is interpreted — the rules
    /// in `CheckInPrompts` decide what, if anything, is worth saying.
    private var checkInContext: CheckInPrompts.Context {
        let calendar = Calendar.current
        let profileID = app.activeProfile.id

        let doses = allDoses.filter {
            $0.profileID == profileID && calendar.isDateInToday($0.scheduledFor)
        }
        let symptoms = allSymptoms
            .filter { $0.profileID == profileID }
            .max { $0.recordedAt < $1.recordedAt }
        let nextAppointment = allAppointments
            .filter { $0.profileID == profileID && $0.isUpcoming }
            .min { $0.scheduledFor < $1.scheduledFor }

        var context = CheckInPrompts.Context()
        context.readingCount = readings.count
        context.readingsToday = todayCount
        context.hasMedications = allMedications.contains {
            $0.profileID == profileID && !$0.isArchived
        }
        context.dosesOutstandingToday = doses.filter { $0.status == .scheduled }.count
        context.sodiumLoggedToday = allLifestyle.contains {
            $0.profileID == profileID && $0.kind == .sodium
                && calendar.isDateInToday($0.recordedAt)
        }

        if let latest = readings.first {
            context.daysSinceLastReading = calendar.dateComponents(
                [.day], from: latest.recordedAt, to: .now
            ).day
            // A plain comparison against the user's own average, not a judgement.
            if let average = BPStatistics.homeAverage(readings, days: 30), average.count >= 3 {
                context.latestAboveOwnAverage = latest.systolic >= average.systolic + 8
            }
        }

        if let symptoms {
            context.lastSymptomDaysAgo = calendar.dateComponents(
                [.day], from: symptoms.recordedAt, to: .now
            ).day
        }

        if let nextAppointment {
            context.hasUpcomingAppointment = true
            context.daysUntilAppointment = calendar.dateComponents(
                [.day], from: .now, to: nextAppointment.scheduledFor
            ).day
        }

        return context
    }

    /// True when nothing on Home is asking for attention.
    private var isCalmMoment: Bool {
        guard let latest = readings.first else { return false }
        if SafetyEngine.assess(latest).urgency > .none { return false }
        if BPStatistics.hasDrifted(readings) { return false }
        return true
    }
}
