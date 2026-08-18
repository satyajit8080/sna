import SwiftData
import SwiftUI

/// The Add sheet. One route per thing a user can record.
///
/// History appears here and in the tab bar. Both push the same `HistoryView`
/// over the same `@Query`, so there is one implementation and one data source —
/// two History screens would inevitably drift apart.
struct AddMenuView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var route: Route?

    enum Route: String, Identifiable {
        case bloodPressure, ruleOfThree, medicine, food
        case weight, activity, symptoms, appointment
        case scan, history

        var id: String { rawValue }

        var title: String {
            switch self {
            case .bloodPressure: "Blood Pressure"
            case .ruleOfThree: "Rule of 3"
            case .medicine: "Medicine"
            case .food: "Food"
            case .weight: "Weight"
            case .activity: "Activity"
            case .symptoms: "Symptoms"
            case .appointment: "Doctor Appointment"
            case .scan: "Scan"
            case .history: "History"
            }
        }

        var subtitle: String? {
            switch self {
            case .bloodPressure: "A single measurement"
            case .ruleOfThree: "Rest, then two or three readings averaged"
            case .medicine: "Doses, schedule and reminders"
            case .food: "Sodium and nutrition"
            case .weight: nil
            case .activity: "Walks, workouts and minutes"
            case .symptoms: "How you are feeling"
            case .appointment: "With reminders and a prep report"
            case .scan: "Food, reports, prescriptions, barcodes"
            case .history: "Every reading you have taken"
            }
        }

        var symbol: String {
            switch self {
            case .bloodPressure: "heart.text.square"
            case .ruleOfThree: "list.number"
            case .medicine: "pills.fill"
            case .food: "fork.knife"
            case .weight: "scalemass.fill"
            case .activity: "figure.walk"
            case .symptoms: "list.bullet.clipboard"
            case .appointment: "calendar.badge.plus"
            case .scan: "viewfinder"
            case .history: "chart.xyaxis.line"
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Blood pressure") {
                    row(.bloodPressure)
                    row(.ruleOfThree)
                }

                Section("Health") {
                    row(.medicine)
                    row(.food)
                    row(.weight)
                    row(.activity)
                    row(.symptoms)
                }

                Section("Records") {
                    row(.appointment)
                    row(.scan)
                    row(.history)
                }
            }
            .navigationTitle("Add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(item: $route) { route in
                destination(for: route)
            }
        }
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .bloodPressure:
            AddBPView()
        case .ruleOfThree:
            RuleOfThreeView()
        case .medicine:
            NavigationStack { MedicationListView() }
        case .food:
            AddSodiumView()
        case .weight:
            AddWeightView()
        case .activity:
            AddActivityView()
        case .symptoms:
            AddSymptomView()
        case .appointment:
            AppointmentEditorView(appointment: nil)
        case .scan:
            NavigationStack { ScanHubView() }
        case .history:
            // Same view, same query, same store as the History tab.
            NavigationStack { HistoryView() }
        }
    }

    private func row(_ target: Route) -> some View {
        Button { route = target } label: {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: target.symbol)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.title).foregroundStyle(Theme.textPrimary)
                    if let subtitle = target.subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.vertical, 2)
        }
        .accessibilityElement(children: .combine)
    }
}
