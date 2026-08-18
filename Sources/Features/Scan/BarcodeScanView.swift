import SwiftData
import SwiftUI

/// Barcode → nutrition lookup.
///
/// The lookup goes through the app's own food provider, so a barcode with no
/// match produces an honest "not found" rather than an invented figure.
struct BarcodeScanView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var permission = CameraPermission()
    @State private var state: ScanState<FoodItem> = .idle
    @State private var scannedCode: String?
    @State private var grams: Double = 100
    @State private var mealType: MealType = .snack

    var body: some View {
        NavigationStack {
            Group {
                switch state {
                case .idle: scanner
                case .capturing, .processing: processing
                case .result(let item): review(item)
                case .failed(let message): failure(message)
                }
            }
            .background(Theme.background)
            .navigationTitle("Scan barcode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private var scanner: some View {
        Group {
            if permission.state.isUsable {
                ZStack {
                    BarcodeScanner { code in
                        guard scannedCode == nil else { return }
                        scannedCode = code
                        lookUp(code)
                    }
                    .ignoresSafeArea()

                    VStack {
                        Spacer()
                        Text("Point at the barcode on the packet")
                            .font(.subheadline.weight(.medium))
                            .padding(Theme.Spacing.md)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                            .padding(.bottom, Theme.Spacing.xxl)
                    }
                }
            } else {
                CameraUnavailableView(state: permission.state) {
                    Task { await permission.request() }
                }
                .padding(Theme.Spacing.lg)
            }
        }
        .task { permission.refresh() }
    }

    private var processing: some View {
        VStack(spacing: Theme.Spacing.md) {
            ProgressView()
            Text("Looking up \(scannedCode ?? "")…")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: Theme.Spacing.lg) {
            EmptyStateView(
                symbol: "barcode.viewfinder",
                title: "Not found",
                message: message
            )
            Button("Enter it from the label instead") { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            Button("Scan another") {
                scannedCode = nil
                state = .idle
            }
        }
        .padding(Theme.Spacing.lg)
    }

    private func review(_ item: FoodItem) -> some View {
        let sodium = FoodPortion.sodiumMilligrams(for: item, grams: grams)

        return ScrollView {
            VStack(spacing: Theme.Spacing.lg) {
                CardView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Text(item.name).font(.headline)
                        if let brand = item.brand {
                            Text(brand).font(.subheadline).foregroundStyle(Theme.textSecondary)
                        }
                        Text(item.source).font(.caption).foregroundStyle(Theme.textTertiary)
                    }
                }

                CardView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        SectionHeader(title: "Portion")
                        HStack {
                            Text("\(Int(grams)) g")
                                .font(Theme.number(24, weight: .semibold))
                                .monospacedDigit()
                            Spacer()
                        }
                        Slider(value: $grams, in: 10...500, step: 5)
                    }
                }

                CardView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        SectionHeader(title: "In this portion")
                        HStack {
                            StatTile(
                                title: "Sodium",
                                value: "\(Int(sodium)) mg",
                                caption: "\(Int(sodium / Double(SodiumSettings.dailyTarget) * 100))% of target",
                                tint: sodium > Double(SodiumSettings.dailyTarget) / 3
                                    ? Theme.statusElevated : Theme.statusNormal
                            )
                            if let calories = FoodPortion.calories(for: item, grams: grams) {
                                StatTile(title: "Calories", value: "\(Int(calories)) kcal")
                            }
                        }
                    }
                }

                Picker("Meal", selection: $mealType) {
                    ForEach(MealType.allCases, id: \.self) {
                        Text($0.label).tag($0)
                    }
                }
                .pickerStyle(.segmented)

                Button("Save to today") { save(item, sodium: sodium) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(Theme.accent)
            }
            .padding(Theme.Spacing.lg)
        }
    }

    private func lookUp(_ code: String) {
        state = .processing("Looking up…")
        Task {
            guard app.foodProvider.isAvailable else {
                state = .failed("No food database is connected in this build.")
                return
            }
            do {
                // Barcodes are searched as text; USDA indexes GTINs on branded
                // items. A miss is reported as a miss.
                let matches = try await app.foodProvider.search(code, limit: 1)
                if let first = matches.first {
                    state = .result(first)
                } else {
                    state = .failed("""
                    Barcode \(code) is not in the food database. Not every product is \
                    listed — you can enter the sodium from the label instead.
                    """)
                }
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func save(_ item: FoodItem, sodium: Double) {
        let entry = LifestyleEntry(
            profileID: app.activeProfile.id,
            kind: .sodium,
            value: sodium,
            unit: "mg",
            label: "\(mealType.label): \(item.name)",
            // A database lookup, not an estimate — so it is not tagged as one.
            provenance: .databaseLookup
        )
        context.insert(entry)
        try? context.save()
        Haptics.success()
        dismiss()
    }
}
