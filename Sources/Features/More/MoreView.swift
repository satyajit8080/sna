import SwiftData
import SwiftUI

struct MoreView: View {
    @Environment(AppModel.self) private var app
    @Query private var allReadings: [BPReading]
    @Query private var allMedications: [Medication]

    var body: some View {
        List {
            Section {
                if app.isMultiProfile {
                    ProfileSwitcher()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }

            Section("Health management") {
                NavigationLink { MedicationListView() } label: {
                    LabeledContent {
                        Text("\(activeMedicationCount)")
                    } label: {
                        Label("Medications", systemImage: "pills.fill")
                    }
                }
                NavigationLink { SodiumListView() } label: {
                    Label("Lifestyle & sodium", systemImage: "leaf.fill")
                }
                NavigationLink { HealthDataView() } label: {
                    Label("Apple Health", systemImage: "heart.fill")
                }
            }

            Section("Your data") {
                NavigationLink { HistoryView() } label: {
                    LabeledContent {
                        Text("\(readingCount)")
                    } label: {
                        Label("All readings", systemImage: "list.bullet.rectangle")
                    }
                }
                NavigationLink { DataManagementView() } label: {
                    Label("Export & delete", systemImage: "square.and.arrow.up")
                }
            }

            Section("App") {
                NavigationLink { SettingsView() } label: {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                NavigationLink { PrivacyView() } label: {
                    Label("Privacy", systemImage: "lock.fill")
                }
                NavigationLink { MeasurementGuideView() } label: {
                    Label("How to measure", systemImage: "book.fill")
                }
                NavigationLink { AboutView() } label: {
                    Label("About", systemImage: "info.circle.fill")
                }
            }
        }
        .navigationTitle("More")
    }

    private var readingCount: Int {
        allReadings.filter { $0.profileID == app.activeProfile.id }.count
    }

    private var activeMedicationCount: Int {
        allMedications.filter { $0.profileID == app.activeProfile.id && !$0.isArchived }.count
    }
}

/// Measurement technique. Fixed editorial content following standard home-monitoring
/// guidance — not generated, and not personalised.
struct MeasurementGuideView: View {
    private let steps: [(String, String, String)] = [
        ("timer", "Rest first",
         "Sit quietly for five minutes before measuring. Talking, moving or measuring straight after activity all push the reading up."),
        ("figure.seated.side", "Sit properly",
         "Back supported, feet flat on the floor, legs uncrossed. Crossed legs alone can add several points."),
        ("hand.raised", "Position your arm",
         "Rest your arm on a table so the cuff sits level with your heart. An arm below heart height reads high."),
        ("bandage", "Fit the cuff",
         "Directly on bare skin, snug enough for two fingers underneath. A cuff over clothing or one that is too small reads high."),
        ("mouth", "Stay quiet",
         "Do not talk or check your phone while the cuff inflates."),
        ("arrow.clockwise", "Measure more than once",
         "Take two or three readings a minute apart and use the average. Single readings bounce around more than people expect."),
        ("clock", "Be consistent",
         "Measure at the same times each day — typically morning before medication and evening. Consistency is what makes the trend meaningful."),
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
