import SwiftData
import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(GuidelineEngine.self) private var guidelines
    @State private var selected: BPGuidelineID = .accAha2017

    var body: some View {
        List {
            Section {
                NavigationLink { ProfileSettingsView() } label: {
                    Label("Profiles", systemImage: "person.2.fill")
                }
                NavigationLink { GuidelineSettingsView() } label: {
                    LabeledContent {
                        Text(guidelines.active.displayName)
                    } label: {
                        Label("BP guideline", systemImage: "list.clipboard.fill")
                    }
                }
            }

            Section {
                NavigationLink { NotificationSettingsView() } label: {
                    Label("Notifications", systemImage: "bell.fill")
                }
                NavigationLink { SodiumTargetView() } label: {
                    Label("Sodium target", systemImage: "drop.fill")
                }
                NavigationLink { HealthDataView() } label: {
                    Label("Apple Health", systemImage: "heart.fill")
                }
                NavigationLink { CoachSettingsView() } label: {
                    Label("AI coach", systemImage: "sparkles")
                }
            }

            Section {
                NavigationLink { PrivacyView() } label: {
                    Label("Privacy", systemImage: "lock.fill")
                }
                NavigationLink { DataManagementView() } label: {
                    Label("Export & delete data", systemImage: "square.and.arrow.up")
                }
            }

            Section {
                NavigationLink { AboutView() } label: {
                    Label("About", systemImage: "info.circle.fill")
                }
            }
        }
        .navigationTitle("Settings")
    }
}

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
        .onAppear { selected = guidelines.active.id }
    }
}

struct NotificationSettingsView: View {
    @Environment(\.openURL) private var openURL
    @State private var authorizationDenied = false
    @State private var quiet = NotificationEngine.QuietHours.current()
    @State private var pendingCount = 0

    var body: some View {
        List {
            if authorizationDenied {
                Section {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        ErrorBanner(error: .notificationsDenied)
                        Button("Open iOS Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                openURL(url)
                            }
                        }
                        .font(.subheadline)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    .listRowBackground(Color.clear)
                }
            }

            Section {
                ForEach(NotificationEngine.Category.allCases, id: \.self) { category in
                    NotificationToggle(category: category)
                }
            } header: {
                Text("Categories")
            } footer: {
                Text("Everything is scheduled on this device. BP Coach sends no push notifications.")
            }

            Section {
                Toggle("Quiet hours", isOn: $quiet.isEnabled)
                if quiet.isEnabled {
                    Picker("From", selection: $quiet.startHour) {
                        ForEach(0..<24, id: \.self) { Text(hourLabel($0)).tag($0) }
                    }
                    Picker("Until", selection: $quiet.endHour) {
                        ForEach(0..<24, id: \.self) { Text(hourLabel($0)).tag($0) }
                    }
                }
            } header: {
                Text("Quiet hours")
            } footer: {
                Text("""
                Reminders due during quiet hours move to \(hourLabel(quiet.endHour)) rather \
                than being dropped — a medication reminder that never arrives is worse than \
                a late one.
                """)
            }

            Section {
                LabeledContent("Scheduled reminders", value: "\(pendingCount)")
                Button("Open iOS notification settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
            } footer: {
                Text("Sounds, banners and the lock screen are controlled by iOS.")
            }
        }
        .navigationTitle("Notifications")
        .onChange(of: quiet.isEnabled) { _, _ in quiet.save() }
        .onChange(of: quiet.startHour) { _, _ in quiet.save() }
        .onChange(of: quiet.endHour) { _, _ in quiet.save() }
        .task {
            authorizationDenied = await !NotificationEngine.shared.isAuthorized()
            pendingCount = await NotificationEngine.shared.pendingCount()
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        let date = Calendar.current.date(from: components) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }
}

struct NotificationToggle: View {
    let category: NotificationEngine.Category
    @State private var isOn = true

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(category.label)
                Text(category.explanation)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .onAppear { isOn = NotificationEngine.shared.isEnabled(category) }
        .onChange(of: isOn) { _, new in
            NotificationEngine.shared.setEnabled(new, for: category)
            if new { Task { await NotificationEngine.shared.requestAuthorization() } }
        }
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
        .onChange(of: target) { _, new in SodiumSettings.dailyTarget = new }
    }
}

struct CoachSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        List {
            Section {
                LabeledContent("Status", value: app.coach.isConfigured ? "Configured" : "Not configured")
                LabeledContent("Endpoint", value: BackendConfig.baseURL?.host() ?? "none")
            } footer: {
                Text("""
                No AI provider is connected. When one is added it will sit behind the same \
                service protocol, receive only the capped summary shown in the Coach tab, \
                and never be consulted about urgency.
                """)
            }

            Section("Limits enforced in code") {
                ForEach(CoachGuardrails.prohibited, id: \.self) { rule in
                    Label(rule.capitalized, systemImage: "xmark.circle")
                        .font(.subheadline)
                }
            }

            Section {
                LabeledContent("Reading cap", value: "\(AIContextEngine.readingLimit)")
            } footer: {
                Text("The most readings that can ever be included in a single request.")
            }
        }
        .navigationTitle("AI coach")
    }
}

struct AboutView: View {
    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
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
    }
}
