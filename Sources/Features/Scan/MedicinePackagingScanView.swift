import PhotosUI
import SwiftData
import SwiftUI
import UIKit

/// Reads the *name* off a medicine box so it can be typed for you.
///
/// It deliberately does not identify the medicine or show uses and warnings.
/// Photo-based identification is not reliable enough to carry that: showing the
/// wrong drug's warnings is a serious harm, and there is no safe way to present
/// an uncertain identification as anything other than a guess.
///
/// So the flow is narrow and honest — read candidate text, let the user pick and
/// correct it, save it as a medicine name they confirmed.
struct MedicinePackagingScanView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var permission = CameraPermission()
    @State private var state: ScanState<[String]> = .idle
    @State private var isShowingCamera = false
    @State private var selectedPhoto: PhotosPickerItem?

    @State private var name = ""
    @State private var dose = ""
    @State private var frequency: MedicationFrequency = .onceDaily

    var body: some View {
        NavigationStack {
            Group {
                switch state {
                case .idle: sourceChooser
                case .capturing, .processing: processing
                case .result(let lines): review(lines)
                case .failed(let message): failure(message)
                }
            }
            .background(Theme.background)
            .navigationTitle("Scan packaging")
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
                        Label("This reads text, it does not identify medicines",
                              systemImage: "info.circle")
                            .font(.subheadline.weight(.semibold))
                        Text("""
                        BP Coach will read what is printed on the box so you do not have to \
                        type it. It will not tell you what the medicine is, what it treats, \
                        or how to take it — a photograph is not a reliable way to identify a \
                        medicine, and getting that wrong matters.

                        For what a medicine does, read the leaflet or ask your pharmacist.
                        """)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if permission.state.isUsable {
                    Button { isShowingCamera = true } label: {
                        sourceLabel("Photograph the box", "camera.fill")
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
            Text("Reading the packaging…").font(.subheadline).foregroundStyle(Theme.textSecondary)
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

    private func review(_ lines: [String]) -> some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.lg) {
                CardView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        SectionHeader(
                            title: "Confirm the medicine",
                            subtitle: "Tap a line to use it, then correct anything wrong"
                        )

                        TextField("Medicine name", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.words)

                        HStack {
                            TextField("Dose, e.g. 5 mg", text: $dose)
                                .textFieldStyle(.roundedBorder)
                            Picker("", selection: $frequency) {
                                ForEach(MedicationFrequency.allCases, id: \.self) {
                                    Text($0.label).tag($0)
                                }
                            }
                            .labelsHidden()
                        }
                    }
                }

                CardView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        SectionHeader(title: "Text found on the box")
                        ForEach(Array(lines.prefix(15).enumerated()), id: \.offset) { _, line in
                            Button {
                                apply(line)
                            } label: {
                                HStack {
                                    Text(line)
                                        .font(.subheadline)
                                        .foregroundStyle(Theme.textPrimary)
                                        .multilineTextAlignment(.leading)
                                    Spacer()
                                    Image(systemName: "arrow.up.left")
                                        .font(.caption)
                                        .foregroundStyle(Theme.textTertiary)
                                }
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                }

                Button("Save medicine") { save() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(Theme.accent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(Theme.Spacing.lg)
        }
    }

    /// A tapped line fills the name, and its strength fills the dose if one is
    /// present — but both stay editable.
    private func apply(_ line: String) {
        if let match = line.range(
            of: #"(\d{1,4}(?:\.\d{1,2})?)\s*(mg|mcg|g|ml|iu)"#,
            options: [.regularExpression, .caseInsensitive]
        ) {
            dose = String(line[match])
            name = line.replacingCharacters(in: match, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: " -–—:•*.,()"))
        } else {
            name = line.trimmingCharacters(in: .whitespaces)
        }
        Haptics.selection()
    }

    private func process(image: UIImage) {
        state = .processing("Reading…")
        Task {
            do {
                let recognised = try await TextRecognition.recognise(in: image)
                // Longest lines first: brand and generic names are usually the
                // most prominent text on a box.
                let candidates = recognised.lines
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { $0.count >= 3 && $0.rangeOfCharacter(from: .letters) != nil }
                    .sorted { $0.count > $1.count }
                state = .result(Array(candidates.prefix(20)))
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func save() {
        let medication = Medication(
            profileID: app.activeProfile.id,
            name: name.trimmingCharacters(in: .whitespaces),
            dose: dose,
            frequency: frequency
        )
        medication.notes = "Name read from packaging and confirmed by you."
        context.insert(medication)
        try? context.save()
        Haptics.success()
        dismiss()
    }
}
