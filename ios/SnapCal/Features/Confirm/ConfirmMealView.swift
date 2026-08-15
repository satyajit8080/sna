import SwiftUI

struct ConfirmMealView: View {
    @Environment(AppState.self) private var app
    @Environment(EntitlementStore.self) private var entitlements

    let payload: AnalysisPayload
    @Binding var slot: MealSlot
    let onSaved: () -> Void

    @State private var items: [FoodItem] = []
    @State private var saving = false
    @State private var showSearch = false
    @State private var error: String?

    private var total: MacroTotal {
        MacroTotal(
            calories: items.reduce(0) { $0 + $1.calories },
            protein_g: items.reduce(0) { $0 + $1.protein },
            carbs_g: items.reduce(0) { $0 + $1.carbs },
            fat_g: items.reduce(0) { $0 + $1.fat }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: Theme.Space.m) {
                    totalCard
                    slotPicker

                    ForEach($items) { $item in
                        FoodRow(item: $item) {
                            withAnimation(Theme.snap) { items.removeAll { $0.id == item.id } }
                        }
                    }

                    Button {
                        Haptics.tap()
                        showSearch = true
                    } label: {
                        Label("Add another food", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryButtonStyle())

                    if !payload.assumptions.isEmpty {
                        assumptionsCard
                    }

                    // Shown only after the user has the result in hand.
                    if !entitlements.isPro,
                       let warning = entitlements.warningAfterUse(of: entitlements.entitlements.foodScan) {
                        Button {
                            Analytics.track(.freeLimitWarning, ["feature": "food_scan"])
                            entitlements.present(.foodScan, source: "confirm_warning")
                        } label: {
                            HStack {
                                Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                                Text(warning).font(.caption_)
                                Spacer()
                                Text("Unlock Unlimited")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.accent)
                            }
                            .card()
                        }
                        .buttonStyle(.plain)
                    }

                    if items.isEmpty {
                        Text("Add at least one food to save this meal.")
                            .font(.caption_).foregroundStyle(.tertiary)
                    }

                    Color.clear.frame(height: 80)
                }
                .padding(Theme.Space.m)
            }

            saveBar
        }
        .navigationTitle("Confirm")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showSearch) {
            FoodSearchView { picked in
                withAnimation(Theme.snap) { items.append(contentsOf: picked) }
                showSearch = false
            }
        }
        .alert("Couldn't save", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
        .onAppear { if items.isEmpty { items = payload.items } }
    }

    // MARK: - Pieces

    private var totalCard: some View {
        VStack(spacing: Theme.Space.s) {
            Text("\(total.calories)")
                .font(.hero)
                .contentTransition(.numericText())
                .animation(Theme.snap, value: total.calories)

            Text("calories").font(.label).foregroundStyle(.secondary).textCase(.uppercase)

            HStack(spacing: Theme.Space.l) {
                macro("P", total.protein_g, Theme.protein)
                macro("C", total.carbs_g, Theme.carbs)
                macro("F", total.fat_g, Theme.fat)
            }
            .padding(.top, Theme.Space.xs)

            if let confidence = payload.confidence, confidence < 0.7, payload.method != "search" {
                Label("Lower confidence — worth a quick check", systemImage: "exclamationmark.circle")
                    .font(.caption_)
                    .foregroundStyle(.orange)
                    .padding(.top, Theme.Space.xs)
            }
        }
        .frame(maxWidth: .infinity)
        .card()
    }

    private func macro(_ letter: String, _ grams: Int, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("\(letter) \(grams)g")
                .font(.system(size: 14, weight: .medium, design: .rounded).monospacedDigit())
        }
    }

    private var slotPicker: some View {
        Picker("Meal", selection: $slot) {
            ForEach(MealSlot.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    private var assumptionsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("What we assumed", systemImage: "info.circle")
                .font(.label).foregroundStyle(.secondary)
            ForEach(payload.assumptions, id: \.self) { line in
                Text("• \(line)").font(.caption_).foregroundStyle(.secondary)
            }
            Text(payload.disclaimer.isEmpty
                 ? "AI estimate, not a clinical measurement."
                 : payload.disclaimer)
                .font(.caption_).foregroundStyle(.tertiary).padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var saveBar: some View {
        Button {
            Haptics.commit()
            save()
        } label: {
            if saving { ProgressView().tint(.white) } else { Text("Add to Diary") }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(items.isEmpty || saving)
        .opacity(items.isEmpty ? 0.4 : 1)
        .padding(Theme.Space.m)
        .background(.bar)
    }

    private func save() {
        saving = true
        // Ring updates immediately; the network call is a background detail.
        app.applyLocally(items, slot: slot)

        Task {
            do {
                _ = try await APIClient.shared.saveMeal(
                    slot: slot, method: payload.method,
                    items: items, confidence: payload.confidence
                )
                Haptics.success()
                await app.refresh()
                onSaved()
            } catch {
                saving = false
                await app.refresh()   // roll back the optimistic update
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Editable food row

struct FoodRow: View {
    @Binding var item: FoodItem
    let onDelete: () -> Void

    @State private var expanded = false

    private var unitLabel: String {
        item.unit == "g" ? "g" : item.unit + (item.quantity == 1 ? "" : "s")
    }

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name.capitalized)
                        .font(.system(size: 16, weight: .medium))
                        .lineLimit(1)

                    Text(item.unit == "g"
                         ? "\(Int(item.grams)) g"
                         : "\(item.quantity.formatted(.number.precision(.fractionLength(0...1)))) \(unitLabel) · \(Int(item.grams)) g")
                        .font(.caption_)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("\(item.calories)")
                    .font(.bigNum)
                    .contentTransition(.numericText())
            }
            .contentShape(.rect)
            .onTapGesture { withAnimation(Theme.snap) { expanded.toggle() } }

            if expanded {
                VStack(spacing: Theme.Space.m) {
                    // Every change here is local arithmetic on per-100g values.
                    // The AI is never called again for a portion tweak.
                    HStack {
                        Button {
                            Haptics.tap()
                            adjust(-stepSize)
                        } label: { Image(systemName: "minus.circle.fill").font(.system(size: 28)) }
                            .buttonStyle(.plain).foregroundStyle(.secondary)

                        Spacer()

                        Text(item.unit == "g"
                             ? "\(Int(item.grams)) g"
                             : "\(item.quantity.formatted(.number.precision(.fractionLength(0...1)))) \(unitLabel)")
                            .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                            .contentTransition(.numericText())

                        Spacer()

                        Button {
                            Haptics.tap()
                            adjust(stepSize)
                        } label: { Image(systemName: "plus.circle.fill").font(.system(size: 28)) }
                            .buttonStyle(.plain).foregroundStyle(Theme.accent)
                    }

                    HStack(spacing: Theme.Space.l) {
                        chip("P", item.protein, Theme.protein)
                        chip("C", item.carbs, Theme.carbs)
                        chip("F", item.fat, Theme.fat)
                        Spacer()
                        Button(role: .destructive, action: onDelete) {
                            Image(systemName: "trash").font(.system(size: 15))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.danger)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .card()
    }

    private var stepSize: Double { item.unit == "g" ? 10 : 0.5 }

    private func adjust(_ delta: Double) {
        withAnimation(Theme.quick) {
            if item.unit == "g" {
                item.grams = max(5, item.grams + delta)
                item.quantity = item.grams
            } else {
                item.setQuantity(item.quantity + delta)
            }
        }
    }

    private func chip(_ letter: String, _ grams: Int, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(letter) \(grams)g")
                .font(.system(size: 13, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Search

struct FoodSearchView: View {
    let onPick: ([FoodItem]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var term = ""
    @State private var results: [FoodItem] = []
    @State private var searching = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(results) { item in
                    Button {
                        Haptics.tap()
                        onPick([item])
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name.capitalized).font(.body_)
                                Text("per \(Int(item.grams))g").font(.caption_).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(item.calories)")
                                .font(.system(size: 16, weight: .medium, design: .rounded).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }

                if results.isEmpty && !term.isEmpty && !searching {
                    ContentUnavailableView("No matches",
                                           systemImage: "magnifyingglass",
                                           description: Text("Try a simpler name, or snap a photo instead."))
                }
            }
            .listStyle(.plain)
            .searchable(text: $term, prompt: "Search foods")
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .task(id: term) {
                guard term.count >= 2 else { results = []; return }
                try? await Task.sleep(for: .milliseconds(280))   // debounce
                guard !Task.isCancelled else { return }
                searching = true
                results = (try? await APIClient.shared.searchFoods(term)) ?? []
                searching = false
            }
        }
    }
}
