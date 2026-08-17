import SwiftUI

/// "What SnapCal knows about you".
///
/// Personalization that a user cannot see or correct reads as the app making
/// things up. Every memory here is editable and deletable, and a correction is
/// permanent — extraction will never overwrite something the user has told us
/// directly.
struct BrainView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var app
    @Environment(EntitlementStore.self) private var entitlements

    @State private var memories: BrainMemories?
    @State private var loading = true
    @State private var editing: BrainMemory?
    @State private var draft = ""
    @State private var error: String?
    @State private var showPaywall = false

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let memories, memories.total > 0 {
                    list(memories)
                } else {
                    emptyState
                }
            }
            .background(Theme.bg)
            .navigationTitle("What I know about you")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
            .alert("Couldn't update", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
            .sheet(item: $editing) { memory in
                editSheet(memory)
            }
            .sheet(isPresented: $showPaywall) { PaywallView(context: .brain, source: "brain_empty") }
        }
    }

    private func list(_ memories: BrainMemories) -> some View {
        List {
            Section {
                Text("These are things I've picked up as you've used SnapCal. Correct anything that's wrong — I'll take your word over mine.")
                    .font(.jakarta(12, .medium))
                    .foregroundStyle(Theme.secondary)
                    .listRowBackground(Color.clear)
            }

            ForEach(memories.orderedLayers, id: \.label) { group in
                Section(group.label) {
                    ForEach(group.memories) { memory in
                        row(memory)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func row(_ memory: BrainMemory) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(memory.content)
                    .font(.body_)
                    .fixedSize(horizontal: false, vertical: true)

                // Confidence is shown as words, never a number — "0.72" invites
                // an argument about a figure that is only ever an estimate.
                if memory.userEdited {
                    Label("You told me this", systemImage: "person.fill.checkmark")
                        .font(.jakarta(11, .semibold))
                        .foregroundStyle(Theme.accent)
                } else if memory.evidenceCount >= 4 {
                    Text("Seen many times")
                        .font(.jakarta(11, .medium))
                        .foregroundStyle(Theme.secondary)
                } else {
                    Text("Still learning this")
                        .font(.jakarta(11, .medium))
                        .foregroundStyle(Theme.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .contentShape(.rect)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                Task { await forget(memory) }
            } label: {
                Label("Forget", systemImage: "trash")
            }

            Button {
                draft = memory.content
                editing = memory
            } label: {
                Label("Correct", systemImage: "pencil")
            }
            .tint(Theme.accent)
        }
    }

    private func editSheet(_ memory: BrainMemory) -> some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What's true instead?", text: $draft, axis: .vertical)
                        .lineLimit(2...5)
                } footer: {
                    Text("Once you correct something, I won't overwrite it.")
                }
            }
            .navigationTitle("Correct this")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { editing = nil }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        Task { await save(memory) }
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).count < 3)
                }
            }
        }
        .presentationDetents([.height(280)])
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.m) {
            Spacer()
            Image(systemName: "brain")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("I'll learn as you go")
                .font(.jakarta(20, .bold))
            Text("Log meals and workouts for a week or two and I'll start noticing your patterns — when you eat, what works for you, where things slip.")
                .font(.body_)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Space.l)

            // Shown to free users only, and framed as what this becomes rather
            // than a wall. Nothing here is gated yet — the memory is being
            // built either way.
            if !entitlements.isPro {
                Button {
                    Haptics.tap()
                    showPaywall = true
                } label: {
                    Text("See what Premium adds")
                        .font(.jakarta(14, .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .padding(.top, Theme.Space.s)
            }

            Spacer()
        }
    }

    // MARK: - Actions

    private func load() async {
        loading = true
        memories = try? await APIClient.shared.brainMemories()
        loading = false
    }

    private func save(_ memory: BrainMemory) async {
        let content = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        editing = nil
        do {
            try await APIClient.shared.editMemory(id: memory.id, content: content)
            Haptics.success()
            await load()
        } catch {
            self.error = "Couldn't save that correction."
        }
    }

    private func forget(_ memory: BrainMemory) async {
        do {
            try await APIClient.shared.forgetMemory(id: memory.id)
            Haptics.tap()
            await load()
        } catch {
            self.error = "Couldn't remove that."
        }
    }
}
