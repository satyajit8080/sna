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

                // Describes what the feature does rather than fabricating a
                // plan. Invented meals with invented calories are
                // indistinguishable from real ones on screen.
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    benefit("target", "Built around your calorie and protein targets")
                    benefit("fork.knife", "Respects your diet, allergies and dislikes")
                    benefit("arrow.clockwise", "Adapts to what you've already eaten today")
                    benefit("plus.circle", "Log any planned meal in one tap")
                }
                .card()
                .padding(.horizontal, Theme.Space.m)

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

    private func benefit(_ icon: String, _ text: String) -> some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: icon)
                .frame(width: 22)
                .foregroundStyle(Theme.accent)
            Text(text)
                .font(.body_)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
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
                if plan.isRestOfDay, let budget = plan.budgetKcal {
                    Section {
                        Label("Planned around your remaining \(budget) cal today",
                              systemImage: "clock.arrow.circlepath")
                            .font(.caption_)
                            .foregroundStyle(Theme.accent)
                    }
                }

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
    /// Macros are already known from the plan, so this never calls the AI.
    private func log(_ meal: PlannedMeal) {
        let slot = MealSlot(rawValue: meal.slot) ?? .snack
        loggedMeals.insert(meal.id)

        Task {
            let ok = await app.logKnownItem(meal.asFoodItem, slot: slot)
            if !ok { loggedMeals.remove(meal.id) }
        }
    }
}
