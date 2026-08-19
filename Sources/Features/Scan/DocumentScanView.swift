import PDFKit
import PhotosUI
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Medical report scanning: camera, photo or file, then on-device OCR and
/// rule-based extraction, then user review before anything is saved.
struct DocumentScanView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let kind: DocumentKind

    @State private var permission = CameraPermission()
    @State private var state: ScanState<ExtractionOutput> = .idle
    @State private var isShowingCamera = false
    @State private var isShowingFiles = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var documentKind: DocumentKind
    @State private var title = ""

    init(kind: DocumentKind) {
        self.kind = kind
        _documentKind = State(initialValue: kind)
    }

    struct ExtractionOutput: Equatable {
        let text: String
        let candidates: [ValueExtraction.Candidate]
        let imageData: Data?
        let fileExtension: String

        static func == (a: ExtractionOutput, b: ExtractionOutput) -> Bool {
            a.text == b.text && a.candidates.count == b.candidates.count
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch state {
                case .idle: sourceChooser
                case .capturing, .processing: processing
                case .result(let output): review(output)
                case .failed(let message): failure(message)
                }
            }
            .background(Theme.background)
            .navigationTitle("Scan report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .fullScreenCover(isPresented: $isShowingCamera) {
                CameraPicker { image in process(image: image) }
                    .ignoresSafeArea()
            }
            .sheet(isPresented: $isShowingFiles) {
                DocumentPicker(types: [.pdf, .image]) { url in process(fileAt: url) }
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

    // MARK: - Source

    private var sourceChooser: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.lg) {
                CardView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Label("Read on this device", systemImage: "lock.shield")
                            .font(.subheadline.weight(.semibold))
                        Text("""
                        Text is recognised using Apple's Vision framework, on your phone. \
                        The image is not uploaded anywhere.
                        """)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                    }
                }

                if permission.state.isUsable {
                    sourceButton("Take a photo", "camera.fill") { isShowingCamera = true }
                } else {
                    CardView { CameraUnavailableView(state: permission.state) {
                        Task { await permission.request() }
                    } }
                }

                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    sourceLabel("Choose a photo", "photo.on.rectangle")
                }

                sourceButton("Choose a PDF or file", "doc.fill") { isShowingFiles = true }

                CardView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        SectionHeader(title: "For the best result")
                        bullet("Lay the page flat and fill the frame")
                        bullet("Good even light, no shadow across the text")
                        bullet("Hold square to the page rather than at an angle")
                    }
                }
            }
            .padding(Theme.Spacing.lg)
        }
        .task { permission.refresh() }
    }

    private func bullet(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle")
            .font(.footnote)
            .foregroundStyle(Theme.textSecondary)
    }

    private func sourceButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { sourceLabel(title, symbol) }.buttonStyle(.plain)
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

    // MARK: - Processing

    private var processing: some View {
        VStack(spacing: Theme.Spacing.md) {
            ProgressView()
            if case .processing(let message) = state {
                Text(message).font(.subheadline).foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: Theme.Spacing.lg) {
            EmptyStateView(
                symbol: "exclamationmark.triangle",
                title: "Could not read that",
                message: message,
                actionTitle: "Try again",
                action: { state = .idle }
            )
        }
        .padding(Theme.Spacing.lg)
    }

    // MARK: - Review

    private func review(_ output: ExtractionOutput) -> some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.lg) {
                CardView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        SectionHeader(title: "Details")
                        TextField("Title", text: $title)
                            .textFieldStyle(.roundedBorder)
                        Picker("Type", selection: $documentKind) {
                            ForEach(DocumentKind.allCases, id: \.self) {
                                Text($0.label).tag($0)
                            }
                        }
                    }
                }

                if output.candidates.isEmpty {
                    CardView {
                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            Label("No values recognised", systemImage: "questionmark.circle")
                                .font(.subheadline.weight(.semibold))
                            Text("""
                            The text was read but no known lab values were found. The document \
                            is still saved with its full text, and you can read it here or ask \
                            the Coach about it.
                            """)
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                        }
                    }
                } else {
                    CardView {
                        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                            SectionHeader(
                                title: "Values found",
                                subtitle: "Check these against the original before relying on them"
                            )
                            ForEach(output.candidates, id: \.name) { candidate in
                                valueRow(candidate)
                            }
                        }
                    }
                }

                DisclosureGroup("Recognised text") {
                    Text(output.text)
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, Theme.Spacing.sm)
                }
                .padding(Theme.Spacing.lg)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))

                Button("Save document") { save(output) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(Theme.accent)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(Theme.Spacing.lg)
        }
        // Text fields sit inside this scroll view; without this the keyboard
        // covers the Save button with no way to dismiss it.
        .scrollDismissesKeyboard(.interactively)
    }

    private func valueRow(_ candidate: ValueExtraction.Candidate) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(candidate.name).font(.subheadline.weight(.medium))
                Spacer()
                Text("\(candidate.value) \(candidate.unit ?? "")")
                    .font(Theme.number(16, weight: .semibold))
            }
            HStack(spacing: 6) {
                if let range = candidate.referenceRange {
                    Text("Range \(range)").font(.caption).foregroundStyle(Theme.textTertiary)
                }
                // Only stated when the document printed a range. Silence here
                // means unknown, not normal.
                if let within = candidate.isWithinRange {
                    Text(within ? "In range" : "Outside range")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((within ? Theme.statusNormal : Theme.statusElevated).opacity(0.15))
                        .foregroundStyle(within ? Theme.statusNormal : Theme.statusElevated)
                        .clipShape(Capsule())
                }
                if candidate.confidence.needsReview {
                    Text(candidate.confidence.label)
                        .font(.caption2)
                        .foregroundStyle(Theme.statusElevated)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Work

    private func process(image: UIImage) {
        state = .processing("Reading the page…")
        Task {
            do {
                let recognised = try await TextRecognition.recognise(in: image)
                let candidates = ValueExtraction.extract(
                    from: recognised.lines,
                    ocrConfidence: recognised.averageConfidence
                )
                if title.isEmpty { title = suggestedTitle(from: recognised.lines) }
                state = .result(ExtractionOutput(
                    text: recognised.text,
                    candidates: candidates,
                    imageData: image.jpegData(compressionQuality: 0.8),
                    fileExtension: "jpg"
                ))
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func process(fileAt url: URL) {
        state = .processing("Opening the file…")
        Task {
            guard let data = try? Data(contentsOf: url) else {
                state = .failed("That file could not be opened.")
                return
            }

            if url.pathExtension.lowercased() == "pdf" {
                guard let document = PDFDocument(data: data), document.pageCount > 0 else {
                    state = .failed("That PDF could not be read.")
                    return
                }
                // A text-layer PDF needs no OCR at all, and reading it directly
                // is both faster and more accurate than rasterising first.
                let text = (0..<document.pageCount)
                    .compactMap { document.page(at: $0)?.string }
                    .joined(separator: "\n")

                if text.count > 40 {
                    let lines = text.split(separator: "\n").map(String.init)
                    if title.isEmpty { title = suggestedTitle(from: lines) }
                    state = .result(ExtractionOutput(
                        text: text,
                        candidates: ValueExtraction.extract(from: lines, ocrConfidence: 0.95),
                        imageData: data,
                        fileExtension: "pdf"
                    ))
                } else if let page = document.page(at: 0) {
                    // Scanned PDF with no text layer — rasterise and OCR.
                    let image = page.thumbnail(of: CGSize(width: 2000, height: 2600), for: .mediaBox)
                    process(image: image)
                } else {
                    state = .failed("That PDF has no readable content.")
                }
            } else if let image = UIImage(data: data) {
                process(image: image)
            } else {
                state = .failed("That file type is not supported.")
            }
        }
    }

    private func suggestedTitle(from lines: [String]) -> String {
        lines.first {
            $0.trimmingCharacters(in: .whitespaces).count > 6
                && $0.rangeOfCharacter(from: .letters) != nil
        }?
        .trimmingCharacters(in: .whitespaces)
        .prefix(60)
        .description ?? documentKind.label
    }

    private func save(_ output: ExtractionOutput) {
        let document = MedicalDocument(
            profileID: app.activeProfile.id,
            kind: documentKind,
            title: title,
            documentDate: .now,
            sourceName: "Scanned"
        )
        document.recognisedText = output.text

        if let data = output.imageData,
           let fileName = try? DocumentStore.save(data, extension: output.fileExtension) {
            document.fileName = fileName
            document.fileExtension = output.fileExtension
        }

        for candidate in output.candidates {
            let value = ExtractedValue(
                name: candidate.name,
                value: candidate.value,
                unit: candidate.unit,
                referenceRange: candidate.referenceRange,
                isWithinRange: candidate.isWithinRange,
                sourceLine: candidate.sourceLine,
                confidence: candidate.confidence
            )
            document.values.append(value)
        }

        context.insert(document)
        try? context.save()
        Haptics.success()
        dismiss()
    }
}
