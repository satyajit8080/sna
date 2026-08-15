import SwiftUI

struct MealPlannerView: View {
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(AppState.self) private var app

    @State private var plan: MealPlan?
    @State private var span = "day"
    @State private var generating = false
    @State private var error: String?
    @State private var loggedMeals = Set<UUID>()

    var body: some View {
        NavigationStack {
            Group {
                if !entitlements.isPro {
                    preview
                } else if let plan, !plan.days.isEmpty {
                    planList(plan)
                } else {
                    emptyPro
                }
            }
            .background(Theme.bg)
            .navigationTitle("Meal Plan")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                Analytics.track(.mealPlannerOpened, ["plan": entitlements.entitlements.plan])
                if entitlements.isPro, !app.isGuest {
                    plan = try? await APIClient.shared.latestMealPlan()
                }
            }
            .alert("Couldn't build a plan", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    // Free users see what the feature does before being asked to pay for it.
    private var preview: some View {
        ScrollView {
            VStack(spacing: Theme.Space.l) {
                VStack(spacing: Theme.Space.s) {
                    Text("Premium Feature")
                        .font(.caption_).textCase(.uppercase)
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Theme.accentSoft, in: Capsule())

                    Text("Plan your meals effortlessly")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)

                    Text("Premium creates personalized meals around your calories, protein target and preferences.")
                        .font(.body_).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, Theme.Space.l)
                .padding(.horizontal, Theme.Space.m)

                // A real, non-interactive sample so the value is visible.
                VStack(spacing: Theme.Space.s) {
                    sampleRow("Breakfast", "Oatmeal with berries", 290, 9)
                    sampleRow("Lunch", "Turkey sandwich · side salad", 520, 28)
                    sampleRow("Dinner", "Grilled steak · rice · broccoli", 610, 46)
                }
                .padding(.horizontal, Theme.Space.m)
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [Theme.bg.opacity(0), Theme.bg],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 60).allowsHitTesting(false)
                }

                Button("Unlock Premium") {
                    Haptics.commit()
                    Analytics.track(.premiumCTAClicked, ["source": "meal_planner"])
                    entitlements.present(.mealPlan, source: "meal_planner")
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, Theme.Space.m)

                Text("Maybe Later")
                    .font(.caption_).foregroundStyle(.tertiary)
                    .padding(.bottom, Theme.Space.l)
            }
        }
    }

    private func sampleRow(_ slot: String, _ name: String, _ kcal: Int, _ protein: Int) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(slot).font(.caption_).foregroundStyle(.secondary)
                Text(name).font(.system(size: 15, weight: .medium))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(kcal) cal")
                    .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                Text("\(protein)g protein").font(.caption_).foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private var emptyPro: some View {
        VStack(spacing: Theme.Space.l) {
            Spacer()
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("Build your first plan")
                .font(.system(size: 22, weight: .semibold))
            Text("Built around today's calorie and protein targets, and what you actually like eating.")
                .font(.body_).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Space.l)
            Spacer()
            generateBar
        }
    }

    private func planList(_ plan: MealPlan) -> some View {
        VStack(spacing: 0) {
            List {
                if let note = plan.note, !note.isEmpty {
                    Section { Text(note).font(.caption_).foregroundStyle(.secondary) }
                }

                ForEach(plan.days) { day in
                    Section {
                        ForEach(day.meals) { meal in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(meal.slot.capitalized)
                                        .font(.caption_).foregroundStyle(.secondary)
                                    Text(meal.name).font(.body_)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("\(meal.kcal)")
                                        .font(.system(size: 15, weight: .medium, design: .rounded).monospacedDigit())
                                    Text("P\(meal.protein_g)")
                                        .font(.system(size: 11, design: .rounded))
                                        .foregroundStyle(.tertiary)
                                }
                                Button {
                                    Haptics.tap()
                                    log(meal)
                                } label: {
                                    Image(systemName: loggedMeals.contains(meal.id)
                                          ? "checkmark.circle.fill" : "plus.circle")
                                        .foregroundStyle(loggedMeals.contains(meal.id) ? Theme.accent : .secondary)
                                }
                                .buttonStyle(.plain)
                                .disabled(loggedMeals.contains(meal.id))
                            }
                        }
                    } header: {
                        HStack {
                            Text(day.date)
                            Spacer()
                            Text("\(day.totalKcal) cal · \(day.totalProtein)g protein")
                        }
                        .font(.label)
                    }
                }
            }
            .listStyle(.insetGrouped)

            generateBar
        }
    }

    private var generateBar: some View {
        VStack(spacing: Theme.Space.s) {
            Picker("Span", selection: $span) {
                Text("Today").tag("day")
                Text("This week").tag("week")
            }
            .pickerStyle(.segmented)

            Button {
                Haptics.commit()
                generate()
            } label: {
                if generating { ProgressView().tint(.white) } else { Text("Generate plan") }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(generating)
        }
        .padding(Theme.Space.m)
        .background(.bar)
    }

    private func generate() {
        guard app.requireAccount(for: "build a meal plan") else { return }
        generating = true
        Task {
            defer { generating = false }
            do {
                let fresh = try await APIClient.shared.generateMealPlan(span: span)
                withAnimation(Theme.snap) { plan = fresh; loggedMeals.removeAll() }
                Analytics.track(.mealPlanGenerated, ["span": span, "days": fresh.days.count])
                Haptics.success()
                await entitlements.refresh()
            } catch {
                if !entitlements.handle(error, source: "meal_planner") {
                    self.error = (error as? APIError)?.errorDescription ?? "Try again in a moment."
                }
            }
        }
    }

    /// Logs a planned meal straight into the diary — no second AI call, the
    /// macros are already known.
    private func log(_ meal: PlannedMeal) {
        guard app.requireAccount(for: "save meals") else { return }
        let slot = MealSlot(rawValue: meal.slot) ?? .snack
        let item = meal.asFoodItem
        loggedMeals.insert(meal.id)
        app.applyLocally([item], slot: slot)

        Task {
            do {
                _ = try await APIClient.shared.saveMeal(
                    slot: slot, method: "manual", items: [item], confidence: nil)
                await app.refresh()
                Haptics.success()
            } catch {
                loggedMeals.remove(meal.id)
                await app.refresh()
            }
        }
    }
}
