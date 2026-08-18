import PhotosUI
import SwiftData
import SwiftUI
import UIKit

/// Prescription scanning.
///
/// Every suggestion is editable and every one starts **unselected**. Nothing is
/// saved unless the user ticks it and taps save. A misread strength on a
/// prescription is the kind of error that must never happen silently, so the
/// design makes confirmation the only path forward rather than a formality.
struct PrescriptionScanView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var permission = CameraPermission()
    @State private var state: ScanState<[PrescriptionExtraction.Suggestion]> = .idle
    @State private var isShowingCamera = false
    @State private var selectedPhoto: PhotosPickerItem?

    /// Edited copies. The originals stay untouched so "what was read" and "what
    /// I confirmed" remain distinguishable.
    @State private var drafts: [UUID: MedicineDraft] = [:]
    @State private var confirmed: Set<UUID> = []

    struct MedicineDraft {
        var name: String
        var dose: String
        var frequency: MedicationFrequency
    }

    var body: some View {
        NavigationStack {
            Group {
                switch state {
                case .idle: sourceChooser
                case .capturing, .processing: processing
                case .result(let suggestions): review(suggestions)
                case .failed(let message): failure(message)
                }
            }
            .background(Theme.background)
            .navigationTitle("Scan prescription")
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
                }
            }
        }
    }

    private var sourceChooser: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.lg) {
                CardView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Label("You confirm every medicine", systemImage: "checkmark.shield")
                            .font(.subheadline.weight(.semibold))
                        Text("""
                        Text is read on your device. Whatever it finds is a suggestion you \
                        edit and confirm — nothing is saved automatically, and BP Coach \
                        never treats a scan as a confirmed medical fact.
                        """)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if permission.state.isUsable {
                    Button { isShowingCamera = true } label: {
                        sourceLabel("Take a photo", "camera.fill")
                    }
                    .buttonStyle(.plain)
                } else {
                    CardView {
                        CameraUnavailableView(state: permission.state) {
                            Task { await permission.request() }
                        }
                    }
                }

                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    sourceLabel("Choose a photo", "photo.on.rectangle")
                }
            }
            .padding(Theme.Spacing.lg)
        }
        .task { permission.refresh() }
    }

    private func sourceLabel(_ title: String, _ symbol: String) -> some View {
        CardView {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: symbol).font(.title3).foregroundStyle(Theme.accent).frame(width: 28)
                Text(title).foregroundStyle(Theme.textPrimary)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private var processing: some View {
        VStack(spacing: Theme.Spacing.md) {
            ProgressView()
            Text("Reading the prescription…")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failure(_ message: String) -> some View {
        EmptyStateView(
            symbol: "exclamationmark.triangle",
            title: "Could not read that",
            message: message,
            actionTitle: "Try again",
            action: { state = .idle }
        )
        .padding(Theme.Spacing.lg)
    }

    private func review(_ suggestions: [PrescriptionExtraction.Suggestion]) -> some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.lg) {
                CardView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Label("Check each one against the prescription",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.statusElevated)
                        Text("""
                        Scanned text is often imperfect, particularly with handwriting. \
                        Correct anything that is wrong, tick what you want to keep, and \
                        leave the rest.
                        """)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if suggestions.isEmpty {
                    EmptyStateView(
                        symbol: "doc.questionmark",
                        title: "No medicines recognised",
                        message: "Nothing that looked like a medicine and dose was found. You can add medicines by hand instead.",
                        actionTitle: "Try again",
                        action: { state = .idle }
                    )
                } else {
                    ForEach(suggestions) { suggestion in
                        suggestionCard(suggestion)
                    }

                    Button("Save \(confirmed.count) medicine\(confirmed.count == 1 ? "" : "s")") {
                        save(suggestions)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(Theme.accent)
                    .disabled(confirmed.isEmpty)
                }
            }
            .padding(Theme.Spacing.lg)
        }
    }

    private func suggestionCard(_ suggestion: PrescriptionExtraction.Suggestion) -> some View {
        let binding = Binding<MedicineDraft>(
            get: {
                drafts[suggestion.id] ?? MedicineDraft(
                    name: suggestion.name,
                    dose: suggestion.dose ?? "",
                    frequency: suggestion.frequency ?? .onceDaily
                )
            },
            set: { drafts[suggestion.id] = $0 }
        )

        return CardView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HStack {
                    Button {
                        toggle(suggestion.id)
                    } label: {
                        Image(systemName: confirmed.contains(suggestion.id)
                              ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(confirmed.contains(suggestion.id)
                                             ? Theme.accent : Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        confirmed.contains(suggestion.id)
                            ? "Confirmed, tap to unconfirm" : "Tap to confirm this medicine"
                    )

                    Text("Suggested from the scan")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                    Text(suggestion.confidence.label)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Theme.statusElevated)
                }

                TextField("Medicine name", text: binding.name)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.words)

                HStack {
                    TextField("Dose", text: binding.dose)
                        .textFieldStyle(.roundedBorder)
                    Picker("", selection: binding.frequency) {
                        ForEach(MedicationFrequency.allCases, id: \.self) {
                            Text($0.label).tag($0)
                        }
                    }
                    .labelsHidden()
                }

                DisclosureGroup("What was read") {
                    Text(suggestion.sourceLine)
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
                .font(.caption)
            }
        }
    }

    private func toggle(_ id: UUID) {
        if confirmed.contains(id) { confirmed.remove(id) } else { confirmed.insert(id) }
        Haptics.selection()
    }

    private func process(image: UIImage) {
        state = .processing("Reading…")
        Task {
            do {
                let recognised = try await TextRecognition.recognise(in: image)
                let suggestions = PrescriptionExtraction.suggestions(
                    from: recognised.lines,
                    ocrConfidence: recognised.averageConfidence
                )
                state = .result(suggestions)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func save(_ suggestions: [PrescriptionExtraction.Suggestion]) {
        for suggestion in suggestions where confirmed.contains(suggestion.id) {
            let draft = drafts[suggestion.id] ?? MedicineDraft(
                name: suggestion.name,
                dose: suggestion.dose ?? "",
                frequency: suggestion.frequency ?? .onceDaily
            )
            guard !draft.name.trimmingCharacters(in: .whitespaces).isEmpty else { continue }

            let medication = Medication(
                profileID: app.activeProfile.id,
                name: draft.name,
                dose: draft.dose,
                frequency: draft.frequency
            )
            medication.notes = "Added from a scanned prescription and confirmed by you."
            context.insert(medication)
        }
        try? context.save()
        Haptics.success()
        dismiss()
    }
}
