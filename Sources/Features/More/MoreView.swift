import SwiftData
import SwiftUI

struct MoreView: View {
    @Environment(AppModel.self) private var app
    @Query private var allReadings: [BPReading]
    @Query private var allMedications: [Medication]
    @Query private var allDocuments: [MedicalDocument]
    @Query private var allAppointments: [Appointment]

    var body: some View {
        List {
            if app.isMultiProfile {
                Section {
                    ProfileSwitcher()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }

            Section("Health management") {
                link("Medications", "pills.fill", count: activeMedications) {
                    MedicationListView()
                }
                link("Appointments", "calendar", count: upcomingAppointments) {
                    AppointmentListView()
                }
                link("Symptoms", "list.bullet.clipboard") { SymptomHistoryView() }
                link("Weight", "scalemass.fill") { WeightHistoryView() }
                link("Activity", "figure.walk") { ActivityHistoryView() }
                link("Lifestyle & sodium", "leaf.fill") { SodiumListView() }
            }

            Section("Records") {
                link("All readings", "chart.xyaxis.line", count: readingCount) { HistoryView() }
                link("Documents", "doc.text", count: documentCount) { DocumentListView() }
                link("Scan", "viewfinder") { ScanHubView() }
            }

            Section("Integrations") {
                link("Apple Health", "heart.fill") { HealthDataView() }
                link("Notifications", "bell.fill") { NotificationSettingsView() }
                link("Subscription", "star.fill") { SubscriptionView() }
            }

            Section("App") {
                link("Settings", "gearshape.fill") { SettingsView() }
                link("Privacy & data", "lock.fill") { PrivacyView() }
                link("How to measure", "book.fill") { MeasurementGuideView() }
                link("Help & support", "questionmark.circle.fill") { SupportView() }
                link("About", "info.circle.fill") { AboutView() }
            }
        }
        .navigationTitle("More")
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

    private func link<Destination: View>(
        _ title: String,
        _ symbol: String,
        count: Int? = nil,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            if let count, count > 0 {
                LabeledContent {
                    Text("\(count)")
                } label: {
                    Label(title, systemImage: symbol)
                }
            } else {
                Label(title, systemImage: symbol)
            }
        }
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                Text("Most unexpected readings come down to technique rather than a change in your health.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                    CardView {
                        HStack(alignment: .top, spacing: Theme.Spacing.md) {
                            Image(systemName: step.0)
                                .font(.title3)
                                .foregroundStyle(Theme.accent)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                                Text(step.1).font(.headline)
                                Text(step.2)
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .padding(Theme.Spacing.lg)
        }
        .background(Theme.background)
        .navigationTitle("How to measure")
    }
}
