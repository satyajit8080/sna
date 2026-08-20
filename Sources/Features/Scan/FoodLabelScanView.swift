import PhotosUI
import SwiftData
import SwiftUI
import UIKit

/// Reads sodium from a photographed nutrition label.
///
/// The honest version of "food scanning": the packet already states the sodium,
/// and reading printed text on-device is reliable. Estimating sodium from a
/// photograph of a plate of food is guesswork, and a wrong number in a sodium
/// tracker is worse than no number.
struct FoodLabelScanView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var permission = CameraPermission()
    @State private var state: ScanState<LabelResult> = .idle
    @State private var isShowingCamera = false
    @State private var selectedPhoto: PhotosPickerItem?

    @State private var name = ""
    @State private var grams: Double = 100
    @State private var mealType: MealType = .snack

    struct LabelResult: Equatable {
        let reading: NutritionLabelExtraction.Result
        let recognisedLines: [String]
    }

    var body: some View {
        NavigationStack {
            Group {
                switch state {
                case .idle: sourceChooser
                case .capturing, .processing: LoadingView(message: "Reading the label…")
                case .result(let result): review(result)
                case .failed(let message): failure(message)
                }
            }
            .background(Brand.background)
            .navigationTitle("Scan label")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .fullScreenCover(isPresented: $isShowingCamera) {
                CameraPicker { process(image: $0) }.ignoresSafeArea()
            }
            .onChange(of: selectedPhoto) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        process(image: image)
                    } else {
                        state = .failed("That photo could not be opened.")
                    }
                    selectedPhoto = nil
                }
            }
        }
    }

    private var sourceChooser: some View {
        ScrollView {
            VStack(spacing: 16) {
                BrandCard(padding: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Photograph the nutrition label", systemImage: "text.viewfinder")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Brand.textPrimary)
                        Text("""
                        Not the food itself — the printed panel on the packet. BP Coach reads \
                        the sodium from it on your device, so the figure comes from the label \
                        rather than a guess.
                        """)
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if permission.state.isUsable {
                    Button { isShowingCamera = true } label: {
                        sourceLabel("Take a photo", "camera.fill")
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
                    sourceLabel("Choose a photo", "photo.on.rectangle")
                }
            }
            .padding(Brand.Metric.pagePadding)
        }
        .task { permission.refresh() }
    }

    private func sourceLabel(_ title: String, _ symbol: String) -> some View {
        BrandCard(padding: 12) {
            HStack(spacing: 14) {
                BrandIconTile(symbol: symbol, tint: Brand.accent, size: 44)
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
                symbol: "text.viewfinder",
                title: "Could not read the sodium",
                message: message,
                actionTitle: "Try again",
                action: { state = .idle }
            )
            Button("Enter it by hand instead") { dismiss() }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Brand.accent)
        }
        .padding(Brand.Metric.pagePadding)
    }

    private func review(_ result: LabelResult) -> some View {
        // The label states sodium per serving or per 100g. Scaling assumes the
        // stated basis, so the basis is shown rather than hidden.
        let perGram = result.reading.sodiumMilligrams / 100
        let total = result.reading.basis == .per100g
            ? perGram * grams
            : result.reading.sodiumMilligrams

        return ScrollView {
            VStack(spacing: 16) {
                BrandCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Sodium found")
                            .font(.system(size: 12))
                            .foregroundStyle(Brand.textSecondary)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(Int(result.reading.sodiumMilligrams))")
                                .font(.system(size: 30, weight: .bold))
                                .foregroundStyle(Brand.accent)
                            Text("mg \(result.reading.basis.label)")
                                .font(.system(size: 13))
                                .foregroundStyle(Brand.textSecondary)
                        }

                        if result.reading.wasDerivedFromSalt {
                            Label(
                                "Calculated from the salt figure on the label — about 40% of salt is sodium.",
                                systemImage: "info.circle"
                            )
                            .font(.system(size: 11))
                            .foregroundStyle(Brand.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }

                        Text("Read from: \(result.reading.sourceLine)")
                            .font(.system(size: 11).monospaced())
                            .foregroundStyle(Brand.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                BrandFormSection("What was it?") {
                    BrandTextField(
                        title: "Name",
                        placeholder: "e.g. Tomato soup",
                        text: $name,
                        symbol: "fork.knife",
                        autocapitalization: .sentences
                    )
                }

                if result.reading.basis == .per100g {
                    BrandCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("How much did you have?")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Brand.textPrimary)
                            Text("\(Int(grams)) g")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(Brand.textPrimary)
                            Slider(value: $grams, in: 10...500, step: 5)
                                .tint(Brand.accent)
                        }
                    }
                }

                BrandCard {
                    HStack {
                        Text("In your portion")
                            .font(.system(size: 15))
                            .foregroundStyle(Brand.textSecondary)
                        Spacer()
                        Text("\(Int(total)) mg")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(
                                total > Double(SodiumSettings.dailyTarget) / 3
                                    ? Brand.restingHeartRate : Brand.accent
                            )
                    }
                }

                BrandSegmented(
                    options: MealType.allCases.map { ($0, $0.label) },
                    selection: $mealType
                )

                BrandPrimaryButton(
                    title: "Save",
                    isEnabled: !name.trimmingCharacters(in: .whitespaces).isEmpty
                ) { save(total) }
            }
            .padding(Brand.Metric.pagePadding)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func process(image: UIImage) {
        state = .processing("Reading the label…")
        Task {
            do {
                let recognised = try await TextRecognition.recognise(in: image)
                guard let reading = NutritionLabelExtraction.extract(from: recognised.lines) else {
                    state = .failed("""
                    No sodium or salt figure was found on that image. Make sure the nutrition \
                    panel fills the frame and is in focus.
                    """)
                    return
                }
                state = .result(LabelResult(reading: reading, recognisedLines: recognised.lines))
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func save(_ milligrams: Double) {
        let entry = LifestyleEntry(
            profileID: app.activeProfile.id,
            kind: .sodium,
            value: milligrams,
            unit: "mg",
            label: "\(mealType.label): \(name)",
            // Read from a printed label, so it is a real value rather than an
            // estimate — but salt-derived figures carry a small conversion.
            provenance: .userEntered
        )
        context.insert(entry)
        try? context.save()
        Haptics.success()
        dismiss()
    }
}
