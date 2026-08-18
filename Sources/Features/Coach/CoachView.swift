import PhotosUI
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct CoachView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context

    @Query(sort: \BPReading.recordedAt, order: .reverse) private var allReadings: [BPReading]
    @Query private var allMedications: [Medication]
    @Query private var allDoses: [MedicationDose]
    @Query private var allLifestyle: [LifestyleEntry]
    @Query(sort: \MedicalDocument.importedAt, order: .reverse) private var allDocuments: [MedicalDocument]
    @Query(sort: \AIConversation.startedAt, order: .reverse) private var allConversations: [AIConversation]

    @State private var conversation: AIConversation?
    @State private var draft = ""
    @State private var attachments: [CoachAttachment] = []
    @State private var isThinking = false
    @State private var error: AppError?
    @State private var lastFailedQuestion: String?

    @State private var voice = VoiceTranscription()
    @State private var isShowingAttachMenu = false
    @State private var isShowingCamera = false
    @State private var isShowingFiles = false
    @State private var isShowingReports = false
    @State private var isShowingHistory = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var attachmentError: String?

    private var messages: [AIMessage] {
        (conversation?.messages ?? []).sorted { $0.createdAt < $1.createdAt }
    }

    private var snapshot: BPContextSnapshot {
        app.contextEngine.makeSnapshot(
            profileID: app.activeProfile.id,
            readings: allReadings,
            medications: allMedications,
            doses: allDoses,
            lifestyle: allLifestyle,
            healthSnapshot: app.health.snapshot
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            composer
        }
        .background(Theme.background)
        .navigationTitle("AI Coach")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { isShowingHistory = true } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .accessibilityLabel("Conversation history")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { newConversation() } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("New conversation")
            }
        }
        .sheet(isPresented: $isShowingHistory) {
            ConversationHistoryView(selected: $conversation)
        }
        .sheet(isPresented: $isShowingReports) {
            AttachReportView(documents: myDocuments) { attach(document: $0) }
        }
        .fullScreenCover(isPresented: $isShowingCamera) {
            CameraPicker { attach(image: $0, name: "Photo") }.ignoresSafeArea()
        }
        .sheet(isPresented: $isShowingFiles) {
            DocumentPicker(types: [.pdf, .image, .plainText]) { attach(fileAt: $0) }
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    attach(image: image, name: "Photo")
                } else {
                    attachmentError = "That photo could not be opened."
                }
                selectedPhoto = nil
            }
        }
        .task { if conversation == nil { conversation = allConversations.first } }
    }

    private var myDocuments: [MedicalDocument] {
        allDocuments.filter { $0.profileID == app.activeProfile.id }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    if messages.isEmpty { welcome }

                    ForEach(messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }

                    if isThinking {
                        HStack(spacing: Theme.Spacing.sm) {
                            ProgressView().controlSize(.small)
                            Text("Thinking").font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.horizontal, Theme.Spacing.md)
                    }

                    if let error {
                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            ErrorBanner(error: error) { self.error = nil }
                            if lastFailedQuestion != nil {
                                Button("Try again") { retry() }
                                    .font(.subheadline)
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                }
                .padding(Theme.Spacing.lg)
            }
            .onChange(of: messages.count) { _, _ in
                withAnimation { proxy.scrollTo(messages.last?.id, anchor: .bottom) }
            }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            if !app.coach.isConfigured {
                CardView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Label("Coach not set up yet", systemImage: "sparkles").font(.headline)
                        Text("""
                        No AI service is connected in this build, so the coach cannot answer. \
                        Everything else in BP Coach works without it.
                        """)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                    }
                }
            }

            CardView {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    SectionHeader(
                        title: "What it can help with",
                        subtitle: "It explains your own data — it does not diagnose"
                    )
                    ForEach(SuggestedQuestion.forContext(snapshot, hasDocuments: !myDocuments.isEmpty)) { item in
                        Button {
                            draft = item.text
                        } label: {
                            HStack {
                                Text(item.text)
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

            CardView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Label("What it will never do", systemImage: "xmark.shield")
                        .font(.subheadline.weight(.semibold))
                    ForEach(CoachGuardrails.prohibited, id: \.self) { rule in
                        Text("· \(rule.capitalized)")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: Theme.Spacing.sm) {
            if let attachmentError {
                Text(attachmentError)
                    .font(.caption)
                    .foregroundStyle(Theme.statusModerate)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.sm) {
                        ForEach(attachments) { attachment in
                            AttachmentChip(attachment: attachment) {
                                attachments.removeAll { $0.id == attachment.id }
                            }
                        }
                    }
                }
            }

            if voice.isRecording {
                RecordingBar(voice: voice) {
                    let text = voice.stop()
                    if !text.isEmpty {
                        draft = draft.isEmpty ? text : "\(draft) \(text)"
                    }
                } onCancel: {
                    voice.cancel()
                }
            } else {
                HStack(spacing: Theme.Spacing.sm) {
                    Menu {
                        Button { isShowingCamera = true } label: {
                            Label("Camera", systemImage: "camera")
                        }
                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            Label("Photo", systemImage: "photo")
                        }
                        Button { isShowingFiles = true } label: {
                            Label("File or PDF", systemImage: "doc")
                        }
                        if !myDocuments.isEmpty {
                            Button { isShowingReports = true } label: {
                                Label("Saved report", systemImage: "doc.text.magnifyingglass")
                            }
                        }
                        Button { attachHealthData() } label: {
                            Label("Health data", systemImage: "heart.text.square")
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Theme.accent)
                    }
                    .accessibilityLabel("Add an attachment")

                    TextField("Ask about your readings", text: $draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...5)

                    Button {
                        Task { await voice.start() }
                    } label: {
                        Image(systemName: "mic.fill")
                            .font(.title3)
                            .foregroundStyle(Theme.accent)
                    }
                    .accessibilityLabel("Dictate")

                    Button {
                        send()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                    .disabled(!canSend)
                    .accessibilityLabel("Send")
                }
            }

            if case .denied(let message) = voice.state {
                Text(message).font(.caption).foregroundStyle(Theme.statusElevated)
            }
            if case .failed(let message) = voice.state {
                Text(message).font(.caption).foregroundStyle(Theme.statusModerate)
            }
        }
        .padding(Theme.Spacing.lg)
        .background(Theme.surface)
    }

    private var canSend: Bool {
        !isThinking
            && (!draft.trimmingCharacters(in: .whitespaces).isEmpty || !attachments.isEmpty)
    }

    // MARK: - Attaching

    private func attach(image: UIImage, name: String) {
        attachmentError = nil
        Task {
            do {
                attachments.append(try await AttachmentReader.read(image: image, name: name))
                Haptics.success()
            } catch {
                attachmentError = error.localizedDescription
            }
        }
    }

    private func attach(fileAt url: URL) {
        attachmentError = nil
        Task {
            do {
                attachments.append(try await AttachmentReader.read(fileAt: url))
                Haptics.success()
            } catch {
                attachmentError = error.localizedDescription
            }
        }
    }

    private func attach(document: MedicalDocument) {
        attachments.append(AttachmentReader.read(document: document))
        Haptics.success()
    }

    /// The context snapshot already accompanies every message. This makes that
    /// visible and explicit when the user asks for it.
    private func attachHealthData() {
        let context = snapshot
        var lines = ["Recent health summary (\(context.guidelineName))"]
        for average in context.averages {
            lines.append("  \(average.days)-day average: \(average.systolic)/\(average.diastolic) from \(average.count) readings")
        }
        if let steps = context.stepsToday { lines.append("  Steps today: \(steps)") }
        if let hr = context.restingHeartRate { lines.append("  Resting heart rate: \(hr) bpm") }
        for medication in context.medications {
            let adherence = medication.adherencePercent.map { " — \(Int($0))% taken" } ?? ""
            lines.append("  \(medication.name) \(medication.dose)\(adherence)")
        }

        attachments.append(CoachAttachment(
            kind: .healthData,
            name: "Health summary",
            text: lines.joined(separator: "\n")
        ))
        Haptics.success()
    }

    // MARK: - Sending

    private func newConversation() {
        let fresh = AIConversation(profileID: app.activeProfile.id)
        context.insert(fresh)
        try? context.save()
        conversation = fresh
        attachments = []
        draft = ""
        error = nil
    }

    private func send() {
        let question = draft.trimmingCharacters(in: .whitespaces)
        let payloads = attachments.map {
            CoachAttachmentPayload(kind: $0.kind.rawValue, name: $0.name, text: $0.text)
        }

        let target: AIConversation
        if let conversation {
            target = conversation
        } else {
            target = AIConversation(profileID: app.activeProfile.id)
            context.insert(target)
            conversation = target
        }

        // The title comes from the first question, so history is scannable.
        if target.messages.isEmpty, !question.isEmpty {
            target.title = String(question.prefix(48))
        }

        var displayed = question
        if !attachments.isEmpty {
            let names = attachments.map(\.name).joined(separator: ", ")
            displayed += displayed.isEmpty ? "Attached: \(names)" : "\n\nAttached: \(names)"
        }

        let userMessage = AIMessage(isFromUser: true, text: displayed)
        target.messages.append(userMessage)
        try? context.save()

        draft = ""
        attachments = []
        error = nil
        lastFailedQuestion = question
        isThinking = true

        let contextSnapshot = snapshot
        Task {
            defer { isThinking = false }
            do {
                let response = try await app.coach.respond(
                    to: .freeform(question.isEmpty ? "What does this say?" : question),
                    context: contextSnapshot,
                    attachments: payloads
                )
                target.messages.append(AIMessage(isFromUser: false, text: response.text))
                try? context.save()
                lastFailedQuestion = nil
            } catch let coachError as CoachError {
                self.error = coachError == .notConfigured ? .coachUnavailable
                    : .saveFailed(coachError.errorDescription ?? "The coach could not answer.")
            } catch {
                self.error = .coachUnavailable
            }
        }
    }

    private func retry() {
        guard let question = lastFailedQuestion else { return }
        draft = question
        error = nil
        send()
    }
}
