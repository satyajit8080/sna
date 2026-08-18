import SwiftData
import SwiftUI

struct HealthDataView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query private var allReadings: [BPReading]

    @State private var error: AppError?
    @State private var isImporting = false
    @State private var importResult: String?

    var body: some View {
        List {
            if let error {
                Section {
                    ErrorBanner(error: error) { self.error = nil }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }

            Section {
                LabeledContent("Available on this device", value: app.health.isAvailable ? "Yes" : "No")
                LabeledContent(
                    "Last sync",
                    value: app.health.lastSyncedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Never"
                )
            } header: {
                Text("Apple Health")
            } footer: {
                Text("""
                Health data flows one way: Apple Health into BP Coach, stored on this device. \
                Nothing is sent to a server. Readings you enter here can be written back to \
                Health if you choose.
                """)
            }

            if !app.health.isAvailable {
                Section { ErrorBanner(error: .healthKitUnavailable) }
            } else if !app.activeProfile.kind.canUseHealthKit {
                Section { ErrorBanner(error: .healthKitNotOwner(app.activeProfile.name)) }
            } else {
                Section {
                    Button("Connect Apple Health") {
                        Task {
                            do { try await app.health.requestAuthorization(for: app.activeProfile) }
                            catch { self.error = .healthKitDenied }
                        }
                    }

                    Button {
                        importReadings()
                    } label: {
                        if isImporting {
                            HStack { ProgressView(); Text("Importing…") }
                        } else {
                            Label("Import blood pressure", systemImage: "square.and.arrow.down")
                        }
                    }
                    .disabled(isImporting)
                } footer: {
                    if let importResult {
                        Text(importResult)
                    } else {
                        Text("Imports the last year of blood pressure. Readings already in BP Coach are skipped.")
                    }
                }

                Section("What BP Coach reads") {
                    metricRow("Blood pressure", "heart.fill")
                    metricRow("Heart rate and HRV", "waveform.path.ecg")
                    metricRow("Steps and active energy", "figure.walk")
                    metricRow("Sleep", "bed.double.fill")
                    metricRow("Weight", "scalemass.fill")
                }

                if !app.health.snapshot.isEmpty {
                    Section("Today") {
                        let snapshot = app.health.snapshot
                        if let steps = snapshot.steps { LabeledContent("Steps", value: "\(steps)") }
                        if let energy = snapshot.activeEnergyKilocalories {
                            LabeledContent("Active energy", value: "\(energy) kcal")
                        }
                        if let hr = snapshot.restingHeartRate {
                            LabeledContent("Resting heart rate", value: "\(hr) bpm")
                        }
                        if let sleep = snapshot.sleepMinutes {
                            LabeledContent("Sleep", value: "\(sleep / 60)h \(sleep % 60)m")
                        }
                    }
                }
            }
        }
        .navigationTitle("Apple Health")
        .task { await app.health.refreshSnapshot(for: app.activeProfile) }
    }

    private func metricRow(_ label: String, _ symbol: String) -> some View {
        Label(label, systemImage: symbol).font(.subheadline)
    }

    private func importReadings() {
        isImporting = true
        Task {
            defer { isImporting = false }
            do {
                let existing = allReadings.filter { $0.profileID == app.activeProfile.id }
                let count = try await app.health.importBloodPressure(
                    for: app.activeProfile,
                    since: Date.now.addingTimeInterval(-365 * 86_400),
                    existing: existing
                ) { context.insert($0) }

                try? context.save()
                importResult = count == 0
                    ? "Nothing new to import — everything in Health is already here."
                    : "Imported \(count) reading\(count == 1 ? "" : "s")."
                Haptics.success()
            } catch {
                self.error = .healthKitDenied
            }
        }
    }
}

struct PrivacyView: View {
    var body: some View {
        List {
            Section {
                Label("Your readings stay on this device", systemImage: "iphone")
                Label("No account required", systemImage: "person.crop.circle.badge.xmark")
                Label("No analytics or tracking", systemImage: "eye.slash")
                Label("No ads", systemImage: "rectangle.slash")
                Label("No server", systemImage: "externaldrive.badge.xmark")
            } header: {
                Text("How BP Coach handles your data")
            } footer: {
                Text("""
                Blood pressure, medications and lifestyle entries are stored locally using \
                Apple's on-device database. Health data read from Apple Health is not sent \
                anywhere. If a future feature ever needs to send data off the device, it \
                will ask first and explain exactly what it sends.
                """)
            }

            Section("Profiles") {
                Text("""
                Each profile's data is kept separate. Queries, exports and anything sent to \
                the AI coach are filtered by profile before they are built, not afterwards.
                """)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
            }
        }
        .navigationTitle("Privacy")
    }
}
