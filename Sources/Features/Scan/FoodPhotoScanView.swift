import PhotosUI
import SwiftData
import SwiftUI
import UIKit

/// Food photo analysis.
///
/// Every figure here is an estimate and is labelled as one. Portion size from a
/// photograph is genuinely uncertain, and in a sodium tracker a confident wrong
/// number is worse than an obviously approximate one — so the user can adjust
/// each portion before anything is saved, and saved entries carry the estimate
/// provenance so History shows where they came from.
struct FoodPhotoScanView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var permission = CameraPermission()
    @State private var state: ScanState<[FoodVisionService.DetectedFood]> = .idle
    @State private var isShowingCamera = false
    @State private var selectedPhoto: PhotosPickerItem?

    /// Portions the user has adjusted, keyed by food name.
    @State private var portions: [String: Double] = [:]
    @State private var excluded: Set<String> = []
    @State private var mealType: MealType = .lunch

    var body: some View {
        NavigationStack {
            Group {
                switch state {
                case .idle: sourceChooser
                case .capturing, .processing:
                    LoadingView(message: "Looking at your photo…")
                case .result(let foods): review(foods)
                case .failed(let message): failure(message)
                }
            }
            .background(Brand.background)
            .navigationTitle("Food Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .fullScreenCover(isPresented: $isShowingCamera) {
                CameraPicker { analyse($0) }.ignoresSafeArea()
            }
            .onChange(of: selectedPhoto) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        analyse(image)
                    } else {
                        state = .failed("That photo could not be opened.")
                    }
                    selectedPhoto = nil
                }
            }
        }
    }

    // MARK: - Source

    private var sourceChooser: some View {
        ScrollView {
            VStack(spacing: 16) {
                BrandCard(padding: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Photograph your meal", systemImage: "camera.macro")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Brand.textPrimary)
                        Text("""
                        BP Coach identifies the food and estimates portions, then looks the \
                        nutrition up in the USDA database.

                        These are estimates. A photo cannot show how much salt went into a \
                        dish, so check the portions before saving — and use the label scan \
                        for packaged food, which is exact.
                        """)
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if permission.state.isUsable {
                    Button { isShowingCamera = true } label: {
                        row("Take a photo", "camera.fill")
                    }
                    .buttonStyle(.plain)
                } else {
                    BrandCard {
                        CameraUnavailableView(state: permission.state) {
                            Task { await permission.request() }
                        }
                    }
                }

                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    row("Choose a photo", "photo.on.rectangle")
                }
            }
            .padding(Brand.Metric.pagePadding)
        }
        .task { permission.refresh() }
    }

    private func row(_ title: String, _ symbol: String) -> some View {
        BrandCard(padding: 12) {
            HStack(spacing: 14) {
                BrandIconTile(symbol: symbol, tint: Brand.steps, size: 44)
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Brand.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundStyle(Brand.textSecondary)
            }
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 16) {
            EmptyStateView(
                symbol: "camera.metering.unknown",
                title: "Could not read that photo",
                message: message,
                actionTitle: "Try again",
                action: { state = .idle }
            )
            Button("Scan a nutrition label instead") { dismiss() }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Brand.accent)
        }
        .padding(Brand.Metric.pagePadding)
    }

    // MARK: - Review

    private func review(_ foods: [FoodVisionService.DetectedFood]) -> some View {
        let included = foods.filter { !excluded.contains($0.name) }
        let sodium = included.reduce(0.0) { total, food in
            total + scaledSodium(food)
        }
        let calories = included.reduce(0.0) { total, food in
            guard let base = food.calories else { return total }
            return total + Double(base) * (portion(for: food) / Double(food.estimatedGrams))
        }

        return ScrollView {
            VStack(spacing: 16) {
                BrandCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Estimated, not measured", systemImage: "exclamationmark.circle")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Brand.statusEstimate)
                        Text("""
                        Portions come from a photograph and nutrition from a database match. \
                        Adjust anything that looks wrong before saving.
                        """)
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }

                ForEach(foods) { food in
                    foodCard(food)
                }

                BrandCard {
                    VStack(spacing: 10) {
                        HStack {
                            Text("Total sodium")
                                .font(.system(size: 15))
                                .foregroundStyle(Brand.textSecondary)
                            Spacer()
                            Text("\(Int(sodium)) mg")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(
                                    sodium > Double(SodiumSettings.dailyTarget) / 3
                                        ? Brand.restingHeartRate : Brand.accent
                                )
                        }
                        if calories > 0 {
                            HStack {
                                Text("Calories")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Brand.textSecondary)
                                Spacer()
                                Text("\(Int(calories)) kcal")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Brand.textSecondary)
                            }
                        }
                    }
                }

                BrandSegmented(
                    options: MealType.allCases.map { ($0, $0.label) },
                    selection: $mealType
                )

                BrandPrimaryButton(
                    title: "Save \(included.count) item\(included.count == 1 ? "" : "s")",
                    isEnabled: !included.isEmpty && sodium > 0
                ) { save(included) }

                if included.contains(where: { !$0.hasNutrition }) {
                    Text("""
                    Items without a database match are saved by name only, with no sodium \
                    figure — an invented number would be worse than none.
                    """)
                    .font(.system(size: 11))
                    .foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Brand.Metric.pagePadding)
        }
    }

    private func foodCard(_ food: FoodVisionService.DetectedFood) -> some View {
        let isExcluded = excluded.contains(food.name)

        return BrandCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Button {
                        if isExcluded { excluded.remove(food.name) }
                        else { excluded.insert(food.name) }
                        Haptics.selection()
                    } label: {
                        Image(systemName: isExcluded ? "circle" : "checkmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(isExcluded ? Brand.textSecondary : Brand.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExcluded ? "Include \(food.name)" : "Exclude \(food.name)")

                    VStack(alignment: .leading, spacing: 3) {
                        Text(food.name.capitalized)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(isExcluded ? Brand.textSecondary : Brand.textPrimary)

                        HStack(spacing: 6) {
                            if food.confidence.needsReview {
                                Text(food.confidence.label)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Brand.statusEstimate)
                            }
                            Text(food.nutritionSource == "unavailable"
                                 ? "No database match"
                                 : food.nutritionSource)
                                .font(.system(size: 11))
                                .foregroundStyle(Brand.textSecondary)
                        }

                        if let note = food.note {
                            Text(note)
                                .font(.system(size: 11))
                                .foregroundStyle(Brand.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }

                if !isExcluded {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("\(Int(portion(for: food))) g")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(Brand.textPrimary)
                            Spacer()
                            if food.hasNutrition {
                                Text("\(Int(scaledSodium(food))) mg sodium")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Brand.accent)
                            }
                        }
                        Slider(
                            value: Binding(
                                get: { portion(for: food) },
                                set: { portions[food.name] = $0 }
                            ),
                            in: 10...600,
                            step: 5
                        )
                        .tint(Brand.accent)
                    }
                }
            }
        }
    }

    private func portion(for food: FoodVisionService.DetectedFood) -> Double {
        portions[food.name] ?? Double(food.estimatedGrams)
    }

    private func scaledSodium(_ food: FoodVisionService.DetectedFood) -> Double {
        guard let base = food.sodiumMilligrams, food.estimatedGrams > 0 else { return 0 }
        return Double(base) * (portion(for: food) / Double(food.estimatedGrams))
    }

    // MARK: - Work

    private func analyse(_ image: UIImage) {
        guard let vision = app.foodVision else {
            state = .failed("Food photo analysis needs a backend connection.")
            return
        }
        state = .processing("Looking at your photo…")
        Task {
            do {
                state = .result(try await vision.analyse(image))
            } catch {
                state = .failed(
                    (error as? FoodVisionService.VisionError)?.errorDescription
                        ?? error.localizedDescription
                )
            }
        }
    }

    private func save(_ foods: [FoodVisionService.DetectedFood]) {
        for food in foods where food.hasNutrition {
            let entry = LifestyleEntry(
                profileID: app.activeProfile.id,
                kind: .sodium,
                value: scaledSodium(food),
                unit: "mg",
                label: "\(mealType.label): \(food.name.capitalized)",
                // Marked as an estimate so History and the AI context both know
                // this figure came from a photograph rather than a label.
                provenance: .estimated
            )
            context.insert(entry)
        }
        try? context.save()
        Haptics.success()
        dismiss()
    }
}
