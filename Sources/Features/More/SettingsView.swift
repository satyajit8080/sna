import SwiftData
import SwiftUI
import UIKit

struct GuidelineSettingsView: View {
    @Environment(GuidelineEngine.self) private var guidelines
    @State private var selected: BPGuidelineID = .accAha2017

    var body: some View {
        List {
            Section {
                ForEach(BPGuidelineID.allCases, id: \.self) { id in
                    Button {
                        selected = id
                        guidelines.select(id)
                        Haptics.selection()
                    } label: {
                        HStack(alignment: .top, spacing: Theme.Spacing.md) {
                            Image(systemName: selected == id ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(id.displayName)
                                    .font(.headline)
                                    .foregroundStyle(Theme.textPrimary)
                                Text(id.summary)
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                }
            } footer: {
                Text("Changing this relabels your readings. It never alters the readings themselves.")
            }

            Section("Categories in \(guidelines.active.displayName)") {
                ForEach(guidelines.active.categories, id: \.identifier) { category in
                    HStack {
                        CategoryBadge(category: category, compact: true)
                        Spacer()
                    }
                }
            }

            Section {
                Text(guidelines.active.citation)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .navigationTitle("BP guideline")
        .scrollContentBackground(.hidden)
        .background(Brand.background)
        .onAppear { selected = guidelines.active.id }
    }
}

struct NotificationSettingsView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @State private var authorizationDenied = false
    @State private var quiet = NotificationEngine.QuietHours.current()
    @State private var pendingCount = 0
    @State private var enabled: [NotificationEngine.Category: Bool] = [:]
    @State private var testResult: String?
    @State private var checkInHour = NotificationEngine.checkInHour
    @State private var nextCheckIn: (date: Date, title: String)?

    /// Describes the pending check-in, or why there is none.
    ///
    /// Each branch is a different cause with a different fix, and they used to
    /// be indistinguishable: no notification at all looked the same whether
    /// permission was denied, the category was off, or the rules simply had
    /// nothing to say.
    private var nextCheckInLabel: String {
        if authorizationDenied { return "Blocked in iOS Settings" }
        guard enabled[.dailyCheckIn] ?? true else { return "Turned off" }
        guard let nextCheckIn else { return "Nothing to ask today" }
        return nextCheckIn.date.formatted(date: .abbreviated, time: .shortened)
    }

    @Environment(AppModel.self) private var app
    @Query(sort: \BPReading.recordedAt, order: .reverse) private var allReadings: [BPReading]
    @Query private var allMedications: [Medication]
    @Query private var allAppointments: [Appointment]
    @Query private var allDoses: [MedicationDose]
    @Query private var allLifestyle: [LifestyleEntry]
    @Query private var allSymptoms: [SymptomEntry]

    var body: some View {
        BrandScreen {
            BrandHeader(
                title: "Notifications",
                subtitle: "Choose what BP Coach reminds you about",
                showsBack: true,
                onBack: { dismiss() }
            )

            if authorizationDenied {
                BrandCard(padding: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Notifications are off", systemImage: "bell.slash.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Brand.restingHeartRate)
                        Text("BP Coach cannot send reminders until you allow notifications in iOS Settings.")
                            .font(.system(size: 12))
                            .foregroundStyle(Brand.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open iOS Settings") { openSettings() }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Brand.accent)
                    }
                }
            }

            BrandFormSection(
                "Categories",
                footer: "Everything is scheduled on this device. BP Coach sends no push notifications."
            ) {
                ForEach(Array(NotificationEngine.Category.allCases.enumerated()), id: \.offset) { index, category in
                    if index > 0 { BrandRowDivider() }
                    BrandToggleRow(
                        title: category.label,
                        detail: category.explanation,
                        symbol: symbol(for: category),
                        tint: tint(for: category),
                        isOn: Binding(
                            get: { enabled[category] ?? true },
                            set: { newValue in
                                enabled[category] = newValue
                                NotificationEngine.shared.setEnabled(newValue, for: category)
                            }
                        )
                    )
                }
            }

            BrandFormSection(
                "Quiet hours",
                footer: """
                Reminders due during quiet hours move to \(hourLabel(quiet.endHour)) rather than \
                being dropped — a medication reminder that never arrives is worse than a late one.
                """
            ) {
                BrandToggleRow(
                    title: "Quiet hours",
                    symbol: "moon.fill",
                    tint: Brand.sleep,
                    isOn: $quiet.isEnabled
                )

                if quiet.isEnabled {
                    BrandRowDivider()
                    hourPicker("From", selection: $quiet.startHour)
                    BrandRowDivider()
                    hourPicker("Until", selection: $quiet.endHour)
                }
            }

            BrandFormSection(
                "Daily check-in",
                footer: """
                One question a day, chosen from your own data. It is skipped entirely \
                on days when there is nothing useful to ask — silence is intended, not \
                a fault.
                """
            ) {
                // The pending state, in plain words. Without this, "scheduled
                // for tonight" and "silently failed" look identical.
                BrandValueRow(
                    title: "Next check-in",
                    value: nextCheckInLabel,
                    symbol: "clock.badge.checkmark"
                )

                BrandRowDivider()

                HStack {
                    Text("Time")
                        .font(.system(size: 15))
                        .foregroundStyle(Brand.textPrimary)
                    Spacer()
                    Picker("Time", selection: $checkInHour) {
                        ForEach(6..<23, id: \.self) { Text(hourLabel($0)).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .tint(Brand.accent)
                }
                .padding(16)

                BrandRowDivider()

                BrandActionRow(
                    title: "Send a test now",
                    detail: testResult ?? "Arrives in about five seconds",
                    symbol: "bell.badge.fill",
                    tint: Brand.accent,
                    showsChevron: false
                ) { sendTest() }
            }

            BrandFormSection("System") {
                BrandValueRow(
                    title: "Scheduled reminders",
                    value: "\(pendingCount)",
                    symbol: "calendar.badge.clock"
                )
                BrandRowDivider()
                BrandActionRow(
                    title: "Open iOS notification settings",
                    detail: "Sounds, banners and the lock screen are controlled by iOS",
                    symbol: "gearshape.fill",
                    tint: Brand.textSecondary
                ) { openSettings() }
            }
        }
        .onChange(of: checkInHour) { _, newValue in
            NotificationEngine.checkInHour = newValue
            Task { await rescheduleCheckIn() }
        }
        .onChange(of: quiet.isEnabled) { _, _ in quiet.save() }
        .onChange(of: quiet.startHour) { _, _ in quiet.save() }
        .onChange(of: quiet.endHour) { _, _ in quiet.save() }
        .task {
            authorizationDenied = await !NotificationEngine.shared.isAuthorized()
            pendingCount = await NotificationEngine.shared.pendingCount()
            for category in NotificationEngine.Category.allCases {
                enabled[category] = NotificationEngine.shared.isEnabled(category)
            }
            await rescheduleCheckIn()
        }
    }

    /// Reschedules and reads back when it will fire.
    private func rescheduleCheckIn() async {
        await NotificationEngine.shared.scheduleDailyCheckIn(currentContext)
        nextCheckIn = await NotificationEngine.shared.nextCheckIn()
    }

    private var currentContext: CheckInPrompts.Context {
        CheckInPrompts.context(
            profileID: app.activeProfile.id,
            readings: allReadings,
            medications: allMedications,
            doses: allDoses,
            lifestyle: allLifestyle,
            symptoms: allSymptoms,
            appointments: allAppointments
        )
    }

    /// Fires the real check-in, chosen by the real rules, so the test proves the
    /// whole path rather than sending a canned message that would pass even if
    /// the rules were broken.
    private func sendTest() {
        testResult = nil
        Task {
            let granted = await NotificationEngine.shared.requestAuthorization()
            guard granted else {
                testResult = "Notifications are turned off for BP Coach in iOS Settings."
                return
            }

            let sent = await NotificationEngine.shared.sendTestCheckIn(currentContext)
            testResult = sent
                ? "Sent — it should arrive in a few seconds."
                : "Nothing to ask right now, so no notification was sent."
            if sent { Haptics.success() }
        }
    }

    private func hourPicker(_ title: String, selection: Binding<Int>) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 15))
                .foregroundStyle(Brand.textPrimary)
            Spacer()
            Picker(title, selection: selection) {
                ForEach(0..<24, id: \.self) { Text(hourLabel($0)).tag($0) }
            }
            .pickerStyle(.menu)
            .tint(Brand.accent)
        }
        .padding(16)
    }

    private func symbol(for category: NotificationEngine.Category) -> String {
        switch category {
        case .medication: "pills.fill"
        case .measurement: "heart.text.square.fill"
        case .appointment: "calendar"
        case .drift: "chart.line.uptrend.xyaxis"
        case .reportPrep: "doc.text.fill"
        case .dailyCheckIn: "bubble.left.and.text.bubble.right.fill"
        }
    }

    private func tint(for category: NotificationEngine.Category) -> Color {
        switch category {
        case .medication: Brand.medication
        case .measurement: Brand.accent
        case .appointment: Brand.sleep
        case .drift: Brand.restingHeartRate
        case .reportPrep: Brand.steps
        case .dailyCheckIn: Brand.accent
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }

    private func hourLabel(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        let date = Calendar.current.date(from: components) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }
}

struct SodiumTargetView: View {
    @State private var target = SodiumSettings.dailyTarget

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Daily target")
                    Spacer()
                    Text("\(target) mg")
                        .font(Theme.number(20, weight: .semibold))
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(get: { Double(target) }, set: { target = Int($0) }),
                    in: 1000...4000,
                    step: 100
                )
                .accessibilityValue("\(target) milligrams")
            } footer: {
                Text("""
                The American Heart Association suggests an ideal limit of \
                \(ManualSodiumEntry.ahaIdealDailyMilligrams) mg a day, and no more than \
                \(ManualSodiumEntry.ahaUpperDailyMilligrams) mg. If your doctor has given \
                you a different target, use theirs.
                """)
            }

            Section {
                Button("Use AHA ideal (\(ManualSodiumEntry.ahaIdealDailyMilligrams) mg)") {
                    target = ManualSodiumEntry.ahaIdealDailyMilligrams
                }
                Button("Use AHA upper limit (\(ManualSodiumEntry.ahaUpperDailyMilligrams) mg)") {
                    target = ManualSodiumEntry.ahaUpperDailyMilligrams
                }
            }
        }
        .navigationTitle("Sodium target")
        .scrollContentBackground(.hidden)
        .background(Brand.background)
        .onChange(of: target) { _, new in SodiumSettings.dailyTarget = new }
    }
}

struct AboutView: View {
    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    private var coachStatus: String {
        BackendConfig.baseURL == nil ? "Not configured" : "Configured"
    }

    private var coachTint: Color {
        BackendConfig.baseURL == nil ? Theme.statusElevated : Theme.statusNormal
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "heart.text.square.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(Theme.accent)
                    Text("BP Coach").font(.title2.weight(.bold))
                    Text("Measure. Understand. Improve.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Spacing.lg)
                .listRowBackground(Color.clear)
            }

            Section {
                LabeledContent("Version", value: version)
            }

            // Diagnostics, in About because it is the one screen that is always
            // reachable and never redesigned away. Without this the only way to
            // tell whether a build has a backend URL is to read a CI log.
            Section {
                LabeledContent("AI coach") {
                    Text(coachStatus).foregroundStyle(coachTint)
                }
                LabeledContent("Endpoint") {
                    Text(BackendConfig.baseURL?.host() ?? "none")
                        .font(.caption.monospaced())
                        .foregroundStyle(
                            BackendConfig.baseURL == nil ? Theme.statusElevated : Theme.textSecondary
                        )
                }
            } header: {
                Text("Connection")
            } footer: {
                Text(BackendConfig.baseURL == nil
                     ? """
                       This build has no backend address, so the coach cannot answer. \
                       Everything else works.
                       """
                     : "The coach and barcode lookup both use this address.")
            }

            Section {
                Text("""
                BP Coach is not a medical device and does not diagnose, treat or prevent any \
                condition. It records what you measure and helps you describe it to your \
                doctor. Categories come from published guidelines; urgency guidance follows \
                fixed clinical rules.

                Always follow your doctor's advice over anything shown here.
                """)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
            } header: {
                Text("Important")
            }
        }
        .navigationTitle("About")
        .scrollContentBackground(.hidden)
        .background(Brand.background)
    }
}
