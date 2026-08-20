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
    @FocusState private var isComposerFocused: Bool

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
        ZStack {
            Brand.background.ignoresSafeArea()
            VStack(spacing: 0) {
                BrandHeader(
                    title: "Ai Coach",
                    subtitle: "Your personal BP coach",
                    trailing: [
                        ("clock.arrow.circlepath", { isShowingHistory = true }),
                        ("square.and.pencil", { newConversation() }),
                    ]
                )
                .padding(.horizontal, Brand.Metric.pagePadding)

                transcript
                composer
            }
        }
        .navigationBarHidden(true)
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
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small).tint(Brand.accent)
                            Text("Thinking")
                                .font(.system(size: 12))
                                .foregroundStyle(Brand.textSecondary)
                        }
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
                .padding(.horizontal, Brand.Metric.pagePadding)
                .padding(.vertical, 16)
            }
            // Without these the keyboard traps the user: the tab bar is covered
            // and there is no other way back.
            .scrollDismissesKeyboard(.interactively)
            .contentShape(Rectangle())
            .onTapGesture { isComposerFocused = false }
            .onChange(of: messages.count) { _, _ in
                withAnimation { proxy.scrollTo(messages.last?.id, anchor: .bottom) }
            }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            greetingCard

            if !app.coach.isConfigured {
                BrandCard(padding: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Coach not connected", systemImage: "exclamationmark.circle")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Brand.textPrimary)
                        Text("""
                        No AI service is reachable from this build. Everything else in \
                        BP Coach works without it.
                        """)
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            quickActionChips

            BrandCard(padding: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Things you can ask me")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Brand.textPrimary)

                    ForEach(SuggestedQuestion.forContext(
                        snapshot, hasDocuments: !myDocuments.isEmpty
                    )) { item in
                        Button { draft = item.text } label: {
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(Brand.accent)
                                    .frame(width: 6, height: 6)
                                Text(item.text)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Brand.textSecondary)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            BrandCard(padding: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("What it will never do", systemImage: "xmark.shield")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Brand.textPrimary)
                    ForEach(CoachGuardrails.prohibited, id: \.self) { rule in
                        Text("· \(rule.capitalized)")
                            .font(.system(size: 12))
                            .foregroundStyle(Brand.textSecondary)
                    }
                }
            }
        }
    }

    /// Greeting with a streak count.
    ///
    /// The streak is consecutive days with a reading, computed from stored data
    /// — not a number that only ever goes up. A fabricated streak in a health
    /// app would be the worst kind of engagement metric.
    private var greetingCard: some View {
        BrandCard {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Hi \(app.activeProfile.name)!")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Brand.textPrimary)
                    Text("How can I help you today?")
                        .font(.system(size: 14))
                        .foregroundStyle(Brand.textSecondary)
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Brand.accent)
                        Text("Evidence-based guidance. Always here for you.")
                            .font(.system(size: 12))
                            .foregroundStyle(Brand.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 4)
                }

                if streakDays > 0 {
                    VStack(spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: "flame.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(Brand.accent)
                            Text("\(streakDays)")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(Brand.textPrimary)
                        }
                        Text("Day Streak")
                            .font(.system(size: 12))
                            .foregroundStyle(Brand.textSecondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Brand.background)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Brand.cardStroke, lineWidth: 1)
                    }
                }
            }
        }
    }

    /// Consecutive days ending today or yesterday that have a reading.
    private var streakDays: Int {
        let calendar = Calendar.current
        let days = Set(allReadings
            .filter { $0.profileID == app.activeProfile.id }
            .map { calendar.startOfDay(for: $0.recordedAt) })
        guard !days.isEmpty else { return 0 }

        var cursor = calendar.startOfDay(for: .now)
        // A streak still counts if today's reading has not been taken yet.
        if !days.contains(cursor) {
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
            guard days.contains(cursor) else { return 0 }
        }

        var count = 0
        while days.contains(cursor) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor)
            else { break }
            cursor = previous
        }
        return count
    }

    private var quickActionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                chip("Share BP Log", "chart.xyaxis.line") { attachHealthData() }
                chip("Send Photo", "photo") { isShowingCamera = true }
                chip("Voice Note", "mic.fill") { Task { await voice.start() } }
            }
        }
    }

    private func chip(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 12))
                Text(title).font(.system(size: 12))
            }
            .foregroundStyle(Brand.textPrimary)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(Brand.background)
            .overlay { Capsule().strokeBorder(Brand.cardStroke, lineWidth: 1) }
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Composer
    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: Theme.Spacing.sm) {
            if let attachmentError {
                Text(attachmentError)
                    .font(.system(size: 12))
                    .foregroundStyle(Brand.restingHeartRate)
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
                        Circle()
                            .fill(Brand.accent)
                            .frame(width: 45, height: 45)
                            .overlay {
                                Image(systemName: "plus")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(Brand.onAccent)
                            }
                    }
                    .accessibilityLabel("Add an attachment")

                    HStack(spacing: 10) {
                        TextField(
                            "",
                            text: $draft,
                            prompt: Text("Ask anything...").foregroundStyle(Brand.textSecondary),
                            axis: .vertical
                        )
                            .foregroundStyle(Brand.textPrimary)
                            .lineLimit(1...4)
                            .focused($isComposerFocused)
                            .submitLabel(.send)

                        Button { Task { await voice.start() } } label: {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(Brand.textSecondary)
                        }
                        .accessibilityLabel("Dictate")
                    }
                    .padding(.horizontal, 18)
                    .frame(minHeight: 45)
                    .background(Brand.background)
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(Brand.cardStroke, lineWidth: 1)
                    }

                    Button { send() } label: {
                        Circle()
                            .fill(canSend ? Brand.accent : Brand.accent.opacity(0.3))
                            .frame(width: 45, height: 45)
                            .overlay {
                                Image(systemName: "paperplane.fill")
                                    .font(.system(size: 16))
                                    .foregroundStyle(Brand.onAccent)
                            }
                    }
                    .disabled(!canSend)
                    .accessibilityLabel("Send")
                }
            }

            if case .denied(let message) = voice.state {
                Text(message).font(.system(size: 12)).foregroundStyle(Brand.textSecondary)
            }
            if case .failed(let message) = voice.state {
                Text(message).font(.system(size: 12)).foregroundStyle(Brand.restingHeartRate)
            }
        }
        .padding(.horizontal, Brand.Metric.pagePadding)
        .padding(.top, 14)
        // The tab bar sits over the bottom of this view, so the composer needs
        // clearance of its own — the scaffold's inset does not apply inside a
        // VStack that fills the screen.
        .padding(.bottom, 22)
        .background(Brand.background)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { isComposerFocused = false }
            }
        }
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

    /// Sends a structured request rather than free text, so the backend prompt
    /// can treat these consistently.
    private func send(request: CoachRequest) {
        let label: String
        switch request {
        case .whatMovedMyBP: label = "What moved my blood pressure recently?"
        case .weeklyReview: label = "Give me a short review of my week."
        case .questionsForDoctor: label = "What should I ask my doctor at my next appointment?"
        case .explainReading: label = "Explain my latest reading."
        case .freeform(let text): label = text
        }
        draft = label
        send()
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
        isComposerFocused = false
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
                // Each failure needs its own message. Reporting a network error
                // as "could not save" sends the user looking in the wrong place.
                switch coachError {
                case .notConfigured:
                    self.error = .coachUnavailable
                case .offline:
                    self.error = .coachOffline
                case .refused(let reason):
                    self.error = .coachRefused(reason)
                }
            } catch {
                self.error = .coachOffline
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
