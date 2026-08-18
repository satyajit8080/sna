import SwiftData
import SwiftUI
import UIKit

struct DataManagementView: View {
    @Environment(AppModel.self) private var app
    @Environment(GuidelineEngine.self) private var guidelines
    @Query private var allReadings: [BPReading]
    @Query private var allMedications: [Medication]
    @Query private var allDoses: [MedicationDose]

    @State private var exportURL: URL?
    @State private var isConfirmingDelete = false
    @State private var error: AppError?

    private var readings: [BPReading] {
        allReadings.filter { $0.profileID == app.activeProfile.id }
    }

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
                LabeledContent("Readings", value: "\(readings.count)")
                LabeledContent("Medications", value: "\(allMedications.filter { $0.profileID == app.activeProfile.id }.count)")
                LabeledContent("Profile", value: app.activeProfile.name)
            } header: {
                Text("Stored on this device")
            }

            Section {
                Button {
                    exportReadings()
                } label: {
                    Label("Export readings as CSV", systemImage: "square.and.arrow.up")
                }
                .disabled(readings.isEmpty)

                Button {
                    exportMedications()
                } label: {
                    Label("Export medication history", systemImage: "square.and.arrow.up")
                }
                .disabled(allDoses.isEmpty)
            } footer: {
                Text("The file is written on this device and shared through the system share sheet. Nothing is uploaded.")
            }

            Section {
                Button("Delete all data for \(app.activeProfile.name)", role: .destructive) {
                    isConfirmingDelete = true
                }
            } footer: {
                Text("Removes every reading, medication and lifestyle entry for this profile. It does not remove anything from Apple Health.")
            }
        }
        .navigationTitle("Export & delete")
        .sheet(item: Binding(
            get: { exportURL.map(ShareItem.init) },
            set: { _ in exportURL = nil }
        )) { item in
            ShareSheet(url: item.url)
        }
        .confirmationDialog(
            "Delete all data for \(app.activeProfile.name)?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete everything", role: .destructive) {
                app.deleteAllData(for: app.activeProfile.id)
                Haptics.success()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone. Export first if you want a copy.")
        }
    }

    private func exportReadings() {
        do {
            let csv = DataExporter.readingsCSV(readings, guideline: guidelines.active)
            exportURL = try DataExporter.write(csv, filename: "bp-readings.csv")
        } catch {
            self.error = .exportFailed(error.localizedDescription)
        }
    }

    private func exportMedications() {
        do {
            let mine = allDoses.filter { $0.profileID == app.activeProfile.id }
            let csv = DataExporter.medicationCSV(mine, medications: allMedications)
            exportURL = try DataExporter.write(csv, filename: "bp-medications.csv")
        } catch {
            self.error = .exportFailed(error.localizedDescription)
        }
    }
}

struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct ProfileSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var isAdding = false
    @State private var newName = ""
    @State private var newKind: ProfileKind = .spouse

    var body: some View {
        List {
            Section {
                ForEach(app.profiles) { profile in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name)
                            Text(profile.isOwner ? "Owner · Apple Health enabled" : "\(profile.kind.label) · manual entry only")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        if profile.id == app.activeProfile.id {
                            Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { app.setActive(profile) }
                    .swipeActions {
                        if !profile.isOwner {
                            Button("Delete", role: .destructive) { app.deleteProfile(profile) }
                        }
                    }
                }
            } footer: {
                Text("""
                Apple Health belongs to the device owner. Other profiles hold only readings \
                you enter by hand, and their data is never mixed with yours.
                """)
            }

            Section {
                Button {
                    isAdding = true
                } label: {
                    Label("Add profile", systemImage: "person.badge.plus")
                }
            }
        }
        .navigationTitle("Profiles")
        .alert("Add profile", isPresented: $isAdding) {
            TextField("Name", text: $newName)
            Button("Add") {
                guard !newName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                app.addProfile(name: newName, kind: newKind)
                newName = ""
            }
            Button("Cancel", role: .cancel) { newName = "" }
        } message: {
            Text("Family profiles use readings you enter by hand.")
        }
    }
}
