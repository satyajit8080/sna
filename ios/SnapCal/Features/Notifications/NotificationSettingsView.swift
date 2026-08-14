import SwiftUI
import UserNotifications

struct NotificationSettingsView: View {
    @Environment(NotificationService.self) private var notifications
    @State private var prefs: NotificationPrefs = .default
    @State private var morningTime = Date()
    @State private var showPrimer = false

    var body: some View {
        Form {
            if notifications.permission == .denied {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Notifications are turned off").font(.system(size: 15, weight: .semibold))
                        Text("Turn them back on in iOS Settings to get your daily coach message.")
                            .font(.caption_).foregroundStyle(.secondary)
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    }
                }
            } else if notifications.permission == .notDetermined {
                Section {
                    Button("Enable Notifications") { showPrimer = true }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }

            Section("Daily Coach") {
                Toggle("Morning message", isOn: $prefs.dailyCoach)
                if prefs.dailyCoach {
                    DatePicker("Morning time", selection: $morningTime, displayedComponents: .hourAndMinute)
                }
            }

            Section("Reminders") {
                Toggle("Meal reminders", isOn: $prefs.mealReminders)
                Toggle("Food logging reminder", isOn: $prefs.foodLogging)
                Toggle("AI Coach reminder", isOn: $prefs.coachReminder)
            }

            Section {
                Toggle("Premium offers", isOn: $prefs.premiumOffers)
            } footer: {
                Text("Occasional suggestions about Premium. Never more than one every few days, and never if you're already subscribed.")
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPrimer) {
            NotificationPrimerView { await notifications.requestPermission() }
                .presentationDetents([.height(420)])
        }
        .task {
            await notifications.loadPrefs()
            prefs = notifications.prefs
            morningTime = Calendar.current.date(
                bySettingHour: prefs.morningHour, minute: prefs.morningMinute, second: 0, of: .now) ?? .now
        }
        // Every change persists to the backend and reschedules immediately.
        .onChange(of: prefs) { _, new in persist(new) }
        .onChange(of: morningTime) { _, new in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: new)
            var updated = prefs
            updated.morningHour = parts.hour ?? 8
            updated.morningMinute = parts.minute ?? 0
            prefs = updated
        }
    }

    private func persist(_ new: NotificationPrefs) {
        Task { await notifications.update(new) }
    }
}

extension NotificationPrefs: Equatable {
    static func == (a: NotificationPrefs, b: NotificationPrefs) -> Bool {
        a.dailyCoach == b.dailyCoach && a.morningHour == b.morningHour
            && a.morningMinute == b.morningMinute && a.mealReminders == b.mealReminders
            && a.foodLogging == b.foodLogging && a.coachReminder == b.coachReminder
            && a.premiumOffers == b.premiumOffers && a.permission == b.permission
    }
}

/// Shown before iOS's own prompt. Asking cold burns the one chance the system
/// gives us; explaining first converts far better.
struct NotificationPrimerView: View {
    @Environment(\.dismiss) private var dismiss
    let onEnable: () async -> Bool

    @State private var working = false

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            Spacer()

            Image(systemName: "bell.badge")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.accent)

            VStack(spacing: Theme.Space.s) {
                Text("Stay on Track Every Day")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                Text("Get helpful reminders from your AI Coach.")
                    .font(.body_).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            VStack(spacing: Theme.Space.s) {
                Button {
                    working = true
                    Task {
                        _ = await onEnable()
                        working = false
                        dismiss()
                    }
                } label: {
                    if working { ProgressView().tint(.white) } else { Text("Enable Notifications") }
                }
                .buttonStyle(PrimaryButtonStyle())

                Button("Not now") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(Theme.Space.l)
    }
}
