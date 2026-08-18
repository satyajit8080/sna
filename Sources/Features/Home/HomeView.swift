import SwiftData
import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(GuidelineEngine.self) private var guidelines
    @Environment(\.modelContext) private var context

    @Query(sort: \BPReading.recordedAt, order: .reverse) private var allReadings: [BPReading]
    @Query private var allMedications: [Medication]
    @Query private var allDoses: [MedicationDose]
    @Query private var allLifestyle: [LifestyleEntry]
    @Query private var allAppointments: [Appointment]

    @State private var isPresentingAdd = false
    @State private var editing: BPReading?
    @State private var error: AppError?

    private var readings: [BPReading] {
        allReadings.filter { $0.profileID == app.activeProfile.id }
    }

    var body: some View {
        ScrollView {
            ErrorContainer(error: $error) {
                VStack(spacing: Theme.Spacing.lg) {
                    if app.isMultiProfile { ProfileSwitcher() }

                    if let latest = readings.first {
                        latestCard(latest)
                        trendCard
                        averagesCard
                        insightCard
                        medicationCard
                        sodiumCard
                        activityCard
                        appointmentCard
                        coachCard
                    } else {
                        firstRunCard
                    }
                }
            }
            .padding(Theme.Spacing.lg)
        }
        .background(Theme.background)
        .navigationTitle(greeting)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { isPresentingAdd = true } label: {
                    Image(systemName: "plus.circle.fill").font(.title3)
                }
                .accessibilityLabel("Add a reading")
            }
        }
        .sheet(isPresented: $isPresentingAdd) { AddBPView() }
        .sheet(item: $editing) { EditBPView(reading: $0) }
        .refreshable { await app.health.refreshSnapshot(for: app.activeProfile) }
        .task { await app.health.refreshSnapshot(for: app.activeProfile) }
    }

    /// Readings taken today. Surfaced because a second reading in a sitting is
    /// normal practice, and it should be obvious whether one was taken.
    private var todayCount: Int {
        readings.filter { Calendar.current.isDateInToday($0.recordedAt) }.count
    }

    /// Deterministic insight. Present whether or not the coach is configured.
    private var insightCard: some View {
        let doses = allDoses.filter { $0.profileID == app.activeProfile.id }
        let sodium = allLifestyle
            .filter {
                $0.profileID == app.activeProfile.id && $0.kind == .sodium
                    && Calendar.current.isDateInToday($0.recordedAt)
            }
            .reduce(0) { $0 + $1.value }

        let insight = DailyInsight.forToday(
            readings: readings,
            doses: doses,
            sodiumToday: sodium,
            sodiumTarget: SodiumSettings.dailyTarget,
            guideline: guidelines.active
        )

        return Group {
            if let insight {
                CardView {
                    HStack(alignment: .top, spacing: Theme.Spacing.md) {
                        Image(systemName: insight.symbol)
                            .font(.title3)
                            .foregroundStyle(Theme.accent)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(insight.headline).font(.subheadline.weight(.semibold))
                            Text(insight.body)
                                .font(.footnote)
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    /// The next dose still awaiting an answer.
    private var nextDoseText: String? {
        let doses = allDoses.filter { $0.profileID == app.activeProfile.id }
        guard let next = MedicationEngine.nextDue(from: doses) else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Next dose \(formatter.localizedString(for: next.scheduledFor, relativeTo: .now))"
    }

    private var appointmentCard: some View {
        let next = allAppointments
            .filter { $0.profileID == app.activeProfile.id && $0.isUpcoming }
            .min { $0.scheduledFor < $1.scheduledFor }

        return Group {
            if let next {
                NavigationLink { AppointmentListView() } label: {
                    CardView {
                        HStack(spacing: Theme.Spacing.md) {
                            Image(systemName: "calendar")
                                .font(.title3)
                                .foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Next appointment")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                                Text(next.doctorName).font(.subheadline.weight(.medium))
                                Text(next.scheduledFor.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 4..<12: "Good morning"
        case 12..<17: "Good afternoon"
        default: "Good evening"
        }
    }

    // MARK: - Cards

    private var firstRunCard: some View {
        CardView {
            EmptyStateView(
                symbol: "heart.text.square",
                title: "Let's get your first reading",
                message: "Sit quietly for five minutes, rest your arm at heart height, then measure.",
                actionTitle: "Add a reading",
                action: { isPresentingAdd = true }
            )
        }
    }

    private func latestCard(_ reading: BPReading) -> some View {
        CardView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HStack {
                    Text("Latest reading")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    CategoryBadge(category: guidelines.category(for: reading))
                }

                BPValueView(
                    systolic: reading.systolic,
                    diastolic: reading.diastolic,
                    pulse: reading.pulse
                )

                HStack(spacing: Theme.Spacing.xs) {
                    Text(relativeTime(reading.recordedAt))
                    Text("·")
                    Text(reading.source.label)
                    if todayCount > 1 {
                        Text("·")
                        Text("\(todayCount) today")
                    }
                }
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)

                let assessment = SafetyEngine.assess(reading)
                if assessment.urgency > .none {
                    SafetyBanner(assessment: assessment)
                }

                HStack(spacing: Theme.Spacing.sm) {
                    Button("Edit") { editing = reading }
                        .buttonStyle(.bordered)
                    // History has no tab any more, so Home is its main entry point.
                    NavigationLink { UnifiedHistoryView() } label: {
                        Label("History", systemImage: "clock.arrow.circlepath")
                    }
                    .buttonStyle(.bordered)
                }
                .font(.subheadline)
                .controlSize(.small)
            }
        }
    }

    private var trendCard: some View {
        let recent = BPStatistics.within(readings, days: 30)
        return Group {
            if recent.count >= 2 {
                BPTrendChart(readings: recent, days: 30)
            }
        }
    }

    private var averagesCard: some View {
        CardView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                SectionHeader(title: "Averages", subtitle: "Home readings only")
                HStack(spacing: Theme.Spacing.md) {
                    ForEach([7, 30, 90], id: \.self) { days in
                        if let avg = BPStatistics.homeAverage(readings, days: days) {
                            StatTile(
                                title: "\(days) days",
                                value: "\(avg.systolic)/\(avg.diastolic)",
                                caption: "\(avg.count) reading\(avg.count == 1 ? "" : "s")",
                                tint: GuidelineEngine.color(
                                    for: guidelines.category(
                                        systolic: avg.systolic, diastolic: avg.diastolic
                                    ).severity
                                )
                            )
                        } else {
                            StatTile(title: "\(days) days", value: "—", caption: "No data")
                        }
                    }
                }
            }
        }
    }

    private var medicationCard: some View {
        let mine = allMedications.filter { $0.profileID == app.activeProfile.id && !$0.isArchived }
        let myDoses = allDoses.filter { $0.profileID == app.activeProfile.id }
        let adherence = MedicationEngine.adherence(for: myDoses)

        return Group {
            if !mine.isEmpty {
                NavigationLink { MedicationListView() } label: {
                    CardView {
                        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                            SectionHeader(
                                title: "Medication",
                                subtitle: "\(mine.count) active"
                            )
                            if let percent = adherence.percentage {
                                HStack {
                                    StatTile(
                                        title: "Adherence",
                                        value: "\(Int(percent))%",
                                        caption: "\(adherence.taken) of \(adherence.resolved) doses",
                                        tint: percent >= 80 ? Theme.statusNormal : Theme.statusElevated
                                    )
                                    if adherence.scheduled > 0 {
                                        StatTile(
                                            title: "Pending",
                                            value: "\(adherence.scheduled)",
                                            caption: "Not yet due"
                                        )
                                    }
                                }
                            } else {
                                Text("No doses recorded yet.")
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.textSecondary)
                            }

                            if let nextDoseText {
                                Label(nextDoseText, systemImage: "clock")
                                    .font(.caption)
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var sodiumCard: some View {
        let today = allLifestyle.filter {
            $0.profileID == app.activeProfile.id
                && $0.kind == .sodium
                && Calendar.current.isDateInToday($0.recordedAt)
        }
        let total = ManualSodiumEntry.dailyTotal(today)
        let target = SodiumSettings.dailyTarget

        return Group {
            if !today.isEmpty {
                NavigationLink { SodiumListView() } label: {
                    CardView {
                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            SectionHeader(title: "Sodium today")
                            HStack {
                                StatTile(
                                    title: "Total",
                                    value: "\(Int(total.total)) mg",
                                    caption: "Target \(target) mg",
                                    tint: total.total > Double(target)
                                        ? Theme.statusElevated : Theme.statusNormal
                                )
                                if total.containsEstimate { EstimateTag() }
                            }
                            ProgressView(
                                value: min(total.total, Double(target) * 1.5),
                                total: Double(target) * 1.5
                            )
                            .tint(total.total > Double(target) ? Theme.statusElevated : Theme.accent)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var activityCard: some View {
        let snapshot = app.health.snapshot
        return Group {
            if !snapshot.isEmpty {
                CardView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        SectionHeader(title: "Today", subtitle: "From Apple Health")
                        HStack(spacing: Theme.Spacing.md) {
                            if let steps = snapshot.steps {
                                StatTile(title: "Steps", value: "\(steps)")
                            }
                            if let sleep = snapshot.sleepMinutes {
                                StatTile(
                                    title: "Sleep",
                                    value: "\(sleep / 60)h \(sleep % 60)m",
                                    caption: "Last night"
                                )
                            }
                            if let energy = snapshot.activeEnergyKilocalories {
                                StatTile(title: "Active", value: "\(energy) kcal")
                            }
                            if let weight = snapshot.weightKilograms {
                                StatTile(
                                    title: "Weight",
                                    value: String(format: "%.1f kg", weight)
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private var coachCard: some View {
        NavigationLink { CoachView() } label: {
            CardView {
                HStack(spacing: Theme.Spacing.md) {
                    Image(systemName: "sparkles")
                        .font(.title3)
                        .foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Coach").font(.headline)
                        Text(app.coach.isConfigured
                             ? "Ask about your readings"
                             : "Not set up yet")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: .now)
    }
}

// MARK: - Supporting views

struct ProfileSwitcher: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Menu {
            ForEach(app.profiles) { profile in
                Button {
                    app.setActive(profile)
                } label: {
                    Label(
                        profile.name,
                        systemImage: profile.id == app.activeProfile.id ? "checkmark" : "person"
                    )
                }
            }
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "person.crop.circle.fill").foregroundStyle(Theme.accent)
                Text(app.activeProfile.name).fontWeight(.semibold)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
                Spacer()
                if !app.activeProfile.isOwner {
                    Text("Manual entry only")
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(Theme.Spacing.md)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        }
        .accessibilityLabel("Active profile: \(app.activeProfile.name). Double tap to switch.")
    }
}

/// Deterministic safety guidance. Wording comes from `SafetyEngine`, never from a
/// language model.
struct SafetyBanner: View {
    let assessment: SafetyEngine.Assessment

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Label(assessment.title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
            Text(assessment.message)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.md)
        .background(tint.opacity(0.12))
        .foregroundStyle(tint)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch assessment.urgency {
        case .emergency, .urgent: "exclamationmark.triangle.fill"
        case .contactDoctor: "phone.fill"
        default: "info.circle.fill"
        }
    }

    private var tint: Color {
        switch assessment.urgency {
        case .emergency, .urgent: Theme.statusSevere
        case .contactDoctor, .remeasure: Theme.statusElevated
        case .none: Theme.textSecondary
        }
    }
}
