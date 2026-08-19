import SwiftData
import SwiftUI

/// The Add screen, implemented from the Figma design.
///
/// Six routes, in the design's order. History is reachable from Home and More
/// rather than duplicated here.
struct AddMenuView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var route: Route?

    enum Route: String, Identifiable {
        case bloodPressure, medicine, food, weight, symptoms, appointment, ruleOfThree
        var id: String { rawValue }
    }

    var body: some View {
        BrandScreen {
            BrandHeader(title: "Add", subtitle: "Quickly log your health data")

            BrandHeroCard(
                title: "Track Today,\nImprove Tomorrow",
                message: "Every entry helps your AI coach guide you better.",
                symbol: "plus.circle.fill"
            )

            VStack(spacing: 12) {
                BrandListRow(
                    title: "Blood Pressure",
                    subtitle: "Add your BP reading manually.",
                    symbol: "heart.text.square.fill"
                ) { route = .bloodPressure }

                BrandListRow(
                    title: "Medicine Reminder",
                    subtitle: "Set reminders and track your medicines.",
                    symbol: "pills.fill",
                    tint: Brand.medication
                ) { route = .medicine }

                BrandListRow(
                    title: "Food",
                    subtitle: "Log your meals and sodium intake.",
                    symbol: "fork.knife",
                    tint: Brand.steps
                ) { route = .food }

                BrandListRow(
                    title: "Weight",
                    subtitle: "Track your weight.",
                    symbol: "scalemass.fill",
                    tint: Brand.weight
                ) { route = .weight }

                BrandListRow(
                    title: "Symptoms",
                    subtitle: "Record how you feel.",
                    symbol: "list.bullet.clipboard.fill",
                    tint: Brand.restingHeartRate
                ) { route = .symptoms }

                BrandListRow(
                    title: "Doctor Appointment",
                    subtitle: "Schedule and manage your appointments.",
                    symbol: "calendar",
                    tint: Brand.sleep
                ) { route = .appointment }

                // Not in the design, but the Rule of 3 is the most clinically
                // useful way to take a reading and would be buried otherwise.
                BrandListRow(
                    title: "Rule of 3",
                    subtitle: "Rest, then average two or three readings.",
                    symbol: "list.number"
                ) { route = .ruleOfThree }
            }
        }
        .sheet(item: $route) { destination(for: $0) }
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .bloodPressure: AddBPView()
        case .ruleOfThree: RuleOfThreeView()
        case .medicine: NavigationStack { MedicationListView() }
        case .food: AddSodiumView()
        case .weight: AddWeightView()
        case .symptoms: AddSymptomView()
        case .appointment: AppointmentEditorView(appointment: nil)
        }
    }
}
