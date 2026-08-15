import SwiftUI

struct CoachView: View {
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(AppState.self) private var app

    @State private var messages: [CoachMessage] = []
    @State private var suggestions: [String] = []
    @State private var draft = ""
    @State private var thinking = false
    @State private var suggestion: MealSuggestion?
    @State private var error: String?
    @FocusState private var focused: Bool

    private var usage: FeatureUsage { entitlements.entitlements.coach }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if messages.isEmpty && !thinking {
                    emptyState
                } else {
                    transcript
                }
                composer
            }
            .background(Theme.bg)
            .navigationTitle("Coach")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !entitlements.isPro {
                        Text(usage.badge(noun: "question"))
                            .font(.caption_)
                            .foregroundStyle(usage.isExhausted ? Theme.accent : .secondary)
                    }
                }
            }
            .task {
                Analytics.track(.coachOpened)
                guard !app.isGuest else { return }
                messages = (try? await APIClient.shared.coachHistory()) ?? []
                suggestions = (try? await APIClient.shared.coachSuggestions()) ?? []
                // Free and quota-less, so the screen is useful even with the
                // AI allowance spent.
                await refreshSuggestion()
            }
            .alert("Coach unavailable", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: Theme.Space.l) {
                Spacer(minLength: 40)

                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Theme.accent)

                VStack(spacing: 6) {
                    Text("Ask your coach")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("Short, practical answers based on what you've logged today.")
                        .font(.body_)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Theme.Space.l)
                }

                VStack(spacing: Theme.Space.s) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button {
                            Haptics.tap()
                            send(suggestion)
                        } label: {
                            HStack {
                                Text(suggestion).font(.system(size: 15))
                                Spacer()
                                Image(systemName: "arrow.up.circle.fill").foregroundStyle(Theme.accent)
                            }
                            .padding(Theme.Space.m)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control)
                                .stroke(Theme.hairline, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Theme.Space.m)
            }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: Theme.Space.m) {
                    ForEach(messages) { message in
                        HStack {
                            if message.isUser { Spacer(minLength: 40) }
                            Text(message.content)
                                .font(.body_)
                                .padding(.horizontal, Theme.Space.m)
                                .padding(.vertical, 11)
                                .background(
                                    message.isUser ? Theme.accent : Theme.card,
                                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                                )
                                .foregroundStyle(message.isUser ? .white : .primary)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(message.isUser ? .clear : Theme.hairline, lineWidth: 1)
                                )
                            if !message.isUser { Spacer(minLength: 40) }
                        }
                        .id(message.id)
                    }

                    if let suggestion {
                        SuggestionCard(suggestion: suggestion) {
                            // Once logged, the numbers behind it are stale.
                            withAnimation(Theme.snap) { self.suggestion = nil }
                            Task { await refreshSuggestion() }
                        }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    if thinking {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Thinking…").font(.caption_).foregroundStyle(.secondary)
                            Spacer()
                        }
                        .id("thinking")
                    }
                }
                .padding(Theme.Space.m)
            }
            .onChange(of: messages.count) { _, _ in
                withAnimation(Theme.snap) { proxy.scrollTo(messages.last?.id, anchor: .bottom) }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: Theme.Space.s) {
            if !entitlements.isPro, usage.remaining == 1 {
                Button {
                    entitlements.present(.coach, source: "coach_warning")
                } label: {
                    Text("1 free AI Coach question remaining · **Go Premium**")
                        .font(.caption_)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: Theme.Space.s) {
                TextField("Ask anything about your day", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($focused)
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.vertical, 11)
                    .background(Theme.card, in: Capsule())
                    .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))

                Button {
                    Haptics.commit()
                    send(draft)
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Theme.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespaces).count < 2 || thinking)
                .opacity(draft.trimmingCharacters(in: .whitespaces).count < 2 ? 0.4 : 1)
            }
        }
        .padding(Theme.Space.m)
        .background(.bar)
    }

    private func refreshSuggestion() async {
        guard !app.isGuest else { return }
        let fresh = try? await APIClient.shared.nextMealSuggestion()
        withAnimation(Theme.snap) { suggestion = fresh?.suggestion }
    }

    private func send(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard question.count >= 2, !thinking else { return }
        guard app.requireAccount(for: "ask your coach") else { return }

        draft = ""
        focused = false
        withAnimation(Theme.snap) {
            messages.append(CoachMessage(role: "user", content: question))
            thinking = true
        }
        Analytics.track(.coachQuestionSent, ["length": question.count])

        Task {
            defer { thinking = false }
            do {
                let result = try await APIClient.shared.askCoach(question)
                withAnimation(Theme.snap) {
                    messages.append(CoachMessage(role: "assistant", content: result.answer))
                    suggestion = result.suggestion
                }
                await entitlements.refresh()
                Haptics.success()
            } catch {
                // The server refused: drop the optimistic bubble and show the
                // paywall that matches what they were trying to do.
                withAnimation(Theme.snap) { messages.removeLast() }
                if !entitlements.handle(error, source: "coach") {
                    self.error = (error as? APIError)?.errorDescription ?? "Try again in a moment."
                }
            }
        }
    }
}
