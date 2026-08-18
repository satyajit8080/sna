import SwiftUI

/// The Add sheet. One route per thing a user can record.
struct AddMenuView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var route: Route?

    enum Route: String, Identifiable {
        case bloodPressure, ruleOfThree, medication, food
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Blood pressure") {
                    row("Single reading", "square.and.pencil",
                        "One measurement", .bloodPressure)
                    row("Rule of 3", "list.number",
                        "Rest, then two or three readings averaged", .ruleOfThree)
                }
                Section("Other") {
                    row("Medication dose", "pills.fill", nil, .medication)
                    row("Food & sodium", "fork.knife", nil, .food)
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
                switch route {
                case .bloodPressure: AddBPView()
                case .ruleOfThree: RuleOfThreeView()
                case .medication: MedicationListView()
                case .food: AddSodiumView()
                }
            }
        }
    }

    private func row(_ title: String, _ symbol: String, _ subtitle: String?, _ target: Route) -> some View {
        Button { route = target } label: {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: symbol)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(Theme.textPrimary)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textTertiary)
            }
        }
    }
}
