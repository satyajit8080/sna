import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @Environment(SubscriptionManager.self) private var store

    @State private var showPaywall = false
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text(store.isPro ? "SnapCal Pro" : "Free plan")
                            .font(.system(size: 16, weight: .semibold))
                        Spacer()
                        if !store.isPro {
                            Button("Upgrade") { showPaywall = true }
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    if let quota = app.quota, let limit = quota.limit {
                        LabeledContent("Scans this week", value: "\(quota.used) / \(limit)")
                    }
                }

                Section("Targets") {
                    LabeledContent("Calories", value: "\(app.dashboard.targets.calories)")
                    LabeledContent("Protein", value: "\(app.dashboard.targets.protein_g) g")
                    LabeledContent("Carbs", value: "\(app.dashboard.targets.carbs_g) g")
                    LabeledContent("Fat", value: "\(app.dashboard.targets.fat_g) g")
                    NavigationLink("Adjust targets") { TargetEditorView() }
                }

                Section("Privacy") {
                    Link("Privacy policy", destination: URL(string: "https://snapcal.app/privacy")!)
                    Link("Terms of use", destination: URL(string: "https://snapcal.app/terms")!)
                    Text("Meal photos are analysed and immediately discarded. We don't keep the original image.")
                        .font(.caption_).foregroundStyle(.secondary)
                }

                Section {
                    Button("Sign out") { Task { await app.signOut() } }
                    Button("Delete my account and data", role: .destructive) { confirmDelete = true }
                }

                Section {
                    Text("Nutrition figures are AI estimates for general wellness tracking. They are not medical advice — talk to a clinician or dietitian for anything health-critical.")
                        .font(.caption_).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showPaywall) { PaywallView() }
            .confirmationDialog("Delete everything?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete permanently", role: .destructive) {
                    Task {
                        try? await APIClient.shared.deleteAccount()
                        await app.signOut()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes your profile, meals, weight and water history. It can't be undone.")
            }
        }
    }
}

struct TargetEditorView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var calories = 2000
    @State private var protein = 140

    var body: some View {
        Form {
            Section("Daily calories") {
                Stepper("\(calories) cal", value: $calories, in: 1000...6000, step: 25)
            }
            Section("Protein") {
                Stepper("\(protein) g", value: $protein, in: 20...400, step: 5)
            }
            Section {
                Text("Carbs and fat rebalance automatically to fit your calorie target.")
                    .font(.caption_).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Adjust targets")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            calories = app.dashboard.targets.calories
            protein = app.dashboard.targets.protein_g
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") {
                    Haptics.success()
                    dismiss()
                }
            }
        }
    }
}
