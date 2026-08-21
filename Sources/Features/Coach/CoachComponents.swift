import SwiftData
import SwiftUI
import UIKit

/// One message, with the actions people actually want on an answer.
struct MessageBubble: View {
    @Environment(\.modelContext) private var context
    let message: AIMessage

    @State private var didCopy = false
    @State private var isSharing = false

    var body: some View {
        HStack(alignment: .bottom) {
            if message.isFromUser { Spacer(minLength: 48) }

            VStack(alignment: message.isFromUser ? .trailing : .leading, spacing: 4) {
                Text(message.text)
                    .font(.system(size: 14))
                    .padding(14)
                    .background(message.isFromUser ? Brand.accent.opacity(0.2) : Brand.background)
                    .foregroundStyle(Brand.textPrimary)
                    // The corner nearest the speaker is square, which is what
                    // gives each bubble its direction in the design.
                    .clipShape(
                        .rect(
                            topLeadingRadius: 12,
                            bottomLeadingRadius: message.isFromUser ? 12 : 0,
                            bottomTrailingRadius: message.isFromUser ? 0 : 12,
                            topTrailingRadius: 12
                        )
                    )
                    .overlay {
                        UnevenRoundedRectangle(
                            topLeadingRadius: 12,
                            bottomLeadingRadius: message.isFromUser ? 12 : 0,
                            bottomTrailingRadius: message.isFromUser ? 0 : 12,
                            topTrailingRadius: 12
                        )
                        .strokeBorder(
                            message.isFromUser
                                ? Brand.accent.opacity(0.5)
                                : Color.white.opacity(0.2),
                            lineWidth: 1
                        )
                    }
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 5) {
                    Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Brand.textSecondary)

                    // Only on the user's own messages, and it means "sent", not
                    // "read" — there is no one at the other end to read it.
                    if message.isFromUser {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Brand.accent)
                            .accessibilityLabel("Sent")
                    }
                }

                if !message.isFromUser {
                    HStack(spacing: Theme.Spacing.md) {
                        Button {
                            UIPasteboard.general.string = message.text
                            didCopy = true
                            Haptics.success()
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                didCopy = false
                            }
                        } label: {
                            Label(didCopy ? "Copied" : "Copy",
                                  systemImage: didCopy ? "checkmark" : "doc.on.doc")
                        }

                        ShareLink(item: message.text) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Brand.textSecondary)
                    .labelStyle(.titleAndIcon)
                }
            }

            if !message.isFromUser { Spacer(minLength: 48) }
        }
    }
}

/// Quick actions that map to the structured `CoachRequest` cases, so those are
/// reachable rather than existing only in the enum.
struct CoachQuickActions: View {
    let isConfigured: Bool
    let onSelect: (CoachRequest) -> Void

    private let actions: [(String, String, CoachRequest)] = [
        ("What moved my BP?", "arrow.up.arrow.down", .whatMovedMyBP),
        ("Weekly review", "calendar.badge.clock", .weeklyReview),
        ("Questions for my doctor", "questionmark.bubble", .questionsForDoctor),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                    Button {
                        onSelect(action.2)
                    } label: {
                        Label(action.0, systemImage: action.1)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Brand.accent.opacity(0.15))
                            .foregroundStyle(Brand.accent)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!isConfigured)
                    .opacity(isConfigured ? 1 : 0.5)
                }
            }
        }
    }
}

/// A prompt the user can tap instead of typing.
///
/// Suggestions adapt to what the person actually has: offering "explain my
/// report" to someone with no documents is noise.
struct SuggestedQuestion: Identifiable {
    let id = UUID()
    let text: String

    static func forContext(
        _ context: BPContextSnapshot,
        hasDocuments: Bool
    ) -> [SuggestedQuestion] {
        var items: [String] = []

        if context.isTooSparse {
            items.append("How should I be taking my readings?")
            items.append("What do the blood pressure categories mean?")
        } else {
            items.append("What moved my blood pressure recently?")
            if context.morningVsEvening != nil {
                items.append("Why are my mornings different from my evenings?")
            }
            if let variability = context.variabilitySD, variability > 8 {
                items.append("My readings vary a lot — what does that mean?")
            }
        }

        if !context.medications.isEmpty {
            items.append("How has my medication adherence been?")
        }
        if hasDocuments {
            items.append("Explain the terms in my latest report")
        }
        items.append("What should I ask my doctor next visit?")

        return items.prefix(5).map { SuggestedQuestion(text: $0) }
    }
}

/// Shows what was read from an attachment before it is sent.
struct AttachmentChip: View {
    let attachment: CoachAttachment
    let onRemove: () -> Void

    @State private var isShowingPreview = false

    var body: some View {
        Button { isShowingPreview = true } label: {
            HStack(spacing: 6) {
                Image(systemName: attachment.kind.symbol).font(.caption)
                Text(attachment.name).font(.caption.weight(.medium)).lineLimit(1)
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill").font(.caption)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(attachment.name)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Brand.accent.opacity(0.15))
            .foregroundStyle(Brand.accent)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isShowingPreview) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Text read from \(attachment.name)")
                    .font(.caption.weight(.semibold))
                Text(attachment.preview)
                    .font(.caption)
                    .foregroundStyle(Brand.textSecondary)
                Text("Only this text is sent — never the image itself.")
                    .font(.caption2)
                    .foregroundStyle(Brand.textSecondary)
            }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: 320)
            .presentationCompactAdaptation(.popover)
        }
    }
}

/// Recording state, with a live level so it is obvious the mic is working.
struct RecordingBar: View {
    let voice: VoiceTranscription
    let onStop: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Brand.textSecondary)
            }
            .accessibilityLabel("Cancel recording")

            HStack(spacing: 2) {
                ForEach(0..<14, id: \.self) { index in
                    Capsule()
                        .fill(Brand.accent)
                        .frame(width: 3, height: barHeight(index))
                        .animation(.easeOut(duration: 0.15), value: voice.level)
                }
            }
            .frame(maxWidth: .infinity)

            Text(voice.transcript.isEmpty ? "Listening…" : voice.transcript)
                .font(.system(size: 12))
                .foregroundStyle(Brand.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: 120, alignment: .trailing)

            Button(action: onStop) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Brand.accent)
            }
            .accessibilityLabel("Finish recording")
        }
        .accessibilityElement(children: .contain)
    }

    /// Varied by index so the bars do not move as one block.
    private func barHeight(_ index: Int) -> CGFloat {
        let base = CGFloat(voice.level) * 26
        let variation = CGFloat((index * 37) % 10) / 10
        return max(4, base * (0.5 + variation))
    }
}

struct ConversationHistoryView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \AIConversation.startedAt, order: .reverse) private var allConversations: [AIConversation]

    @Binding var selected: AIConversation?

    private var mine: [AIConversation] {
        allConversations.filter { $0.profileID == app.activeProfile.id && !$0.messages.isEmpty }
    }

    var body: some View {
        NavigationStack {
            Group {
                if mine.isEmpty {
                    EmptyStateView(
                        symbol: "bubble.left.and.bubble.right",
                        title: "No conversations yet",
                        message: "Chats you have with the coach are kept here, on this device."
                    )
                } else {
                    List {
                        ForEach(mine) { conversation in
                            Button {
                                selected = conversation
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(conversation.title)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(Brand.textPrimary)
                                        .lineLimit(1)
                                    Text("\(conversation.messages.count) messages · \(conversation.startedAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(Brand.textSecondary)
                                }
                            }
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                let conversation = mine[index]
                                if selected?.id == conversation.id { selected = nil }
                                context.delete(conversation)
                            }
                            try? context.save()
                        }
                    }
                }
            }
            .navigationTitle("Conversations")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(Brand.background)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

struct AttachReportView: View {
    @Environment(\.dismiss) private var dismiss
    let documents: [MedicalDocument]
    let onSelect: (MedicalDocument) -> Void

    var body: some View {
        NavigationStack {
            List(documents) { document in
                Button {
                    onSelect(document)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(document.title)
                            .font(.subheadline)
                            .foregroundStyle(Brand.textPrimary)
                        Text("\(document.kind.label) · \(document.values.count) values")
                            .font(.caption)
                            .foregroundStyle(Brand.textSecondary)
                    }
                }
            }
            .navigationTitle("Attach a report")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(Brand.background)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

/// Confirmation card for something the coach offered to set up.
///
/// Shows every field that will be written, not a summary. The point of the
/// confirmation is that a misheard dose or date can be caught, and it cannot be
/// caught if it is not on screen.
struct CoachActionCard: View {
    let action: CoachAction
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    @State private var state: State = .pending

    enum State { case pending, confirmed, dismissed }

    var body: some View {
        BrandCard(padding: 16, strokeColor: strokeColor) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: state == .confirmed ? "checkmark.circle.fill" : action.symbol)
                        .font(.system(size: 16))
                        .foregroundStyle(state == .confirmed ? Brand.accent : Brand.textPrimary)
                    Text(state == .confirmed ? "Added" : action.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Brand.textPrimary)
                    Spacer(minLength: 0)
                }

                VStack(spacing: 8) {
                    ForEach(action.fields, id: \.0) { label, value in
                        HStack(alignment: .top, spacing: 10) {
                            Text(label)
                                .font(.system(size: 12))
                                .foregroundStyle(Brand.textSecondary)
                                .frame(width: 88, alignment: .leading)
                            Text(value)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Brand.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }

                if let caution = action.caution, state == .pending {
                    Text(caution)
                        .font(.system(size: 11))
                        .foregroundStyle(Brand.statusEstimate)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if state == .pending {
                    HStack(spacing: 10) {
                        Button {
                            state = .confirmed
                            onConfirm()
                        } label: {
                            Text("Confirm")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Brand.onAccent)
                                .frame(maxWidth: .infinity)
                                .frame(height: 38)
                                .background(Brand.accent)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        Button {
                            state = .dismissed
                            onDismiss()
                        } label: {
                            Text("Not now")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Brand.textSecondary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 38)
                                .overlay {
                                    Capsule().strokeBorder(Brand.cardStroke, lineWidth: 1)
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .opacity(state == .dismissed ? 0.5 : 1)
        .animation(.snappy, value: state)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(action.title)
    }

    private var strokeColor: Color {
        switch state {
        case .confirmed: Brand.accent.opacity(0.5)
        case .dismissed: Brand.cardStroke
        case .pending: Brand.accent.opacity(0.35)
        }
    }
}
