import SwiftUI

struct DiaryView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var offsetDays = 0

    private var meals: [Meal] { app.dashboard.meals }
    private var isToday: Bool { offsetDays == 0 }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Button {
                            Haptics.tap()
                            offsetDays -= 1
                        } label: { Image(systemName: "chevron.left") }
                            .buttonStyle(.plain)

                        Spacer()

                        Text(dayLabel)
                            .font(.system(size: 16, weight: .semibold))
                            .contentTransition(.opacity)

                        Spacer()

                        Button {
                            Haptics.tap()
                            offsetDays += 1
                        } label: { Image(systemName: "chevron.right") }
                            .buttonStyle(.plain)
                            .disabled(isToday)
                            .opacity(isToday ? 0.3 : 1)
                    }
                    .listRowBackground(Color.clear)
                }

                ForEach(MealSlot.allCases) { slot in
                    let slotMeals = meals.filter { $0.slot == slot }

                    Section {
                        if slotMeals.isEmpty {
                            Text("Nothing logged")
                                .font(.caption_)
                                .foregroundStyle(.tertiary)
                        } else {
                            ForEach(slotMeals) { meal in
                                ForEach(meal.items) { item in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.name.capitalized).font(.body_)
                                            Text(portionLabel(item))
                                                .font(.caption_).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        VStack(alignment: .trailing, spacing: 2) {
                                            Text("\(item.calories) cal")
                                                .font(.system(size: 15, weight: .medium, design: .rounded).monospacedDigit())
                                            Text("P\(item.protein) C\(item.carbs) F\(item.fat)")
                                                .font(.system(size: 11, design: .rounded).monospacedDigit())
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                }
                                .onDelete { _ in delete(meal) }
                            }
                        }
                    } header: {
                        HStack {
                            Label(slot.title, systemImage: slot.icon)
                            Spacer()
                            let cal = slotMeals.reduce(0) { $0 + $1.calories }
                            if cal > 0 { Text("\(cal) cal") }
                        }
                        .font(.label)
                    }
                }

                Section {
                    HStack {
                        Text("Day total").font(.system(size: 16, weight: .semibold))
                        Spacer()
                        Text("\(app.dashboard.consumed.calories) / \(app.dashboard.targets.calories)")
                            .font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(app.dashboard.consumed.calories > app.dashboard.targets.calories
                                             ? Theme.danger : Theme.accent)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Diary")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            .refreshable { await app.refresh() }
            .overlay {
                if meals.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing here yet", systemImage: "fork.knife")
                    } description: {
                        Text("Meals you scan will show up here, grouped by time of day.")
                    }
                }
            }
        }
    }

    private var dayLabel: String {
        guard let date = Calendar.current.date(byAdding: .day, value: offsetDays, to: .now) else { return "Today" }
        if offsetDays == 0 { return "Today" }
        if offsetDays == -1 { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }

    private func portionLabel(_ item: FoodItem) -> String {
        item.unit == "g"
            ? "\(Int(item.grams)) g"
            : "\(item.quantity.formatted(.number.precision(.fractionLength(0...1)))) \(item.unit) · \(Int(item.grams)) g"
    }

    private func delete(_ meal: Meal) {
        Haptics.warn()
        withAnimation(Theme.snap) {
            app.dashboard.meals.removeAll { $0.id == meal.id }
            app.dashboard.consumed.calories -= meal.calories
            app.dashboard.remaining.calories += meal.calories
        }
        Task {
            try? await APIClient.shared.deleteMeal(id: meal.id)
            await app.refresh()
        }
    }
}
