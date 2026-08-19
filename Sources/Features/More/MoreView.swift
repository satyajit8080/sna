import SwiftData
import SwiftUI

struct MoreView: View {
    @Environment(AppModel.self) private var app
    @Query private var allReadings: [BPReading]
    @Query private var allMedications: [Medication]
    @Query private var allDocuments: [MedicalDocument]
    @Query private var allAppointments: [Appointment]

    var body: some View {
        BrandScreen {
            BrandHeader(title: "More", subtitle: "Settings and everything else")

            if app.isMultiProfile {
                ProfileSwitcher()
            }

            group("Health Management") {
                row("Medicine Reminder", "pills.fill", Brand.medication, activeMedications) {
                    MedicationListView()
                }
                row("Doctor Appointments", "calendar", Brand.sleep, upcomingAppointments) {
                    AppointmentListView()
                }
                row("Symptoms", "list.bullet.clipboard.fill", Brand.restingHeartRate) {
                    SymptomHistoryView()
                }
                row("Weight", "scalemass.fill", Brand.weight) { WeightHistoryView() }
                row("Activity", "figure.walk", Brand.accent) { ActivityHistoryView() }
                row("Lifestyle & Sodium", "leaf.fill", Brand.steps) { SodiumListView() }
                row("Apple Health", "heart.fill", Brand.restingHeartRate) { HealthDataView() }
            }

            group("Your Data") {
                row("All Readings", "chart.xyaxis.line", Brand.accent, readingCount) {
                    UnifiedHistoryView()
                }
                row("Medical Reports", "doc.text.fill", Brand.textSecondary, documentCount) {
                    DocumentListView()
                }
                row("Health Report", "square.and.arrow.up.on.square.fill", Brand.accent) {
                    HealthReportView()
                }
                row("Export & Delete", "lock.fill", Brand.weight) { PrivacyView() }
            }

            group("App") {
                row("Settings", "gearshape.fill", Brand.textSecondary) { AppSettingsView() }
                row("Notifications", "bell.fill", Brand.medication) { NotificationSettingsView() }
                row("Subscription", "star.fill", Brand.steps) { SubscriptionView() }
                row("How to measure", "book.fill", Brand.accent) { MeasurementGuideView() }
                row("Help & Support", "questionmark.circle.fill", Brand.sleep) { SupportView() }
                row("About", "info.circle.fill", Brand.textSecondary) { AboutView() }
                row("Terms of Use", "doc.plaintext.fill", Brand.textSecondary) { TermsView() }
            }
        }
    }

    private func group<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Brand.textPrimary)
            content()
        }
    }

    private func row<Destination: View>(
        _ title: String,
        _ symbol: String,
        _ tint: Color,
        _ count: Int? = nil,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink { destination() } label: {
            BrandCard(padding: 12) {
                HStack(spacing: 14) {
                    BrandIconTile(symbol: symbol, tint: tint, size: 49)
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Brand.textPrimary)
                    Spacer(minLength: 0)
                    if let count, count > 0 {
                        Text("\(count)")
                            .font(.system(size: 13))
                            .foregroundStyle(Brand.textSecondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.textSecondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var readingCount: Int {
        allReadings.filter { $0.profileID == app.activeProfile.id }.count
    }
    private var activeMedications: Int {
        allMedications.filter { $0.profileID == app.activeProfile.id && !$0.isArchived }.count
    }
    private var documentCount: Int {
        allDocuments.filter { $0.profileID == app.activeProfile.id }.count
    }
    private var upcomingAppointments: Int {
        allAppointments.filter { $0.profileID == app.activeProfile.id && $0.isUpcoming }.count
    }

}

/// Measurement technique. Fixed editorial content following standard
/// home-monitoring guidance — not generated, not personalised.
struct MeasurementGuideView: View {
    private let steps: [(String, String, String)] = [
        ("timer", "Rest first",
         "Sit quietly for five minutes before measuring. Talking, moving or measuring straight after activity all push the reading up."),
        ("figure.seated.side", "Sit properly",
         "Back supported, feet flat on the floor, legs uncrossed. Crossed legs alone can add several points."),
        ("hand.raised", "Position your arm",
         "Rest your arm on a table so the cuff sits level with your heart. An arm below heart height reads high."),
        ("bandage", "Fit the cuff",
         "Directly on bare skin, snug enough for two fingers underneath. A cuff over clothing, or one too small, reads high."),
        ("mouth", "Stay quiet",
         "Do not talk or check your phone while the cuff inflates."),
        ("arrow.clockwise", "Measure more than once",
         "Take two or three readings a minute apart and use the average. Single readings bounce around more than people expect."),
        ("clock", "Be consistent",
         "Measure at the same times each day — typically morning before medication, and evening. Consistency is what makes the trend meaningful."),
        ("cup.and.saucer", "Avoid the obvious",
         "No caffeine, exercise or smoking in the 30 minutes beforehand. Empty your bladder first."),
    ]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        BrandScreen {
            BrandHeader(title: "How to measure", showsBack: true, onBack: { dismiss() })

            Text("Most unexpected readings come down to technique rather than a change in your health.")
                .font(.system(size: 14))
                .foregroundStyle(Brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                BrandCard(padding: 16) {
                    HStack(alignment: .top, spacing: 14) {
                        BrandIconTile(symbol: step.0, tint: Brand.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(step.1)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Brand.textPrimary)
                            Text(step.2)
                                .font(.system(size: 13))
                                .foregroundStyle(Brand.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}
