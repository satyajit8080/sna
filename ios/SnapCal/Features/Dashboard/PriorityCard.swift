import SwiftUI

/// One of today's priorities.
///
/// The reason is not decoration. A coach that says "walk more" is an app
/// nagging; one that says "walk more — you're at 2,100 steps against a usual
/// 7,400" is telling you something you didn't know. The card is built so the
/// reason cannot be dropped for space.
struct PriorityCard: View {
    @Environment(AppState.self) private var app

    let action: PriorityAction
    var onResponded: (() -> Void)?

    @State private var responding = false
    @State private var resolved: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: action.icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(action.tint)
                    .frame(width: 38, height: 38)
                    .background(action.tint.opacity(0.10), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(action.action)
                        .font(.jakarta(16, .semibold))
                        .fixedSize(horizontal: false, vertical: true)

                    Text(action.reason)
                        .font(.jakarta(12, .medium))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            if let resolved {
                Label(resolved == "completed" ? "Done" : "Skipped today",
                      systemImage: resolved == "completed" ? "checkmark.circle.fill" : "xmark.circle")
                    .font(.jakarta(13, .semibold))
                    .foregroundStyle(resolved == "completed" ? Theme.accent : Theme.secondary)
            } else {
                HStack(spacing: Theme.Space.s) {
                    Button {
                        Haptics.success()
                        respond("completed")
                    } label: {
                        Text("Done")
                            .font(.jakarta(14, .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(action.tint.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .foregroundStyle(action.tint)
                    }
                    .buttonStyle(.plain)

                    // "Not today" rather than "Dismiss": skipping one day is a
                    // normal thing to do, not a failure to record.
                    Button {
                        Haptics.tap()
                        respond("dismissed")
                    } label: {
                        Text("Not today")
                            .font(.jakarta(14, .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .foregroundStyle(Theme.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .disabled(responding)
                .opacity(responding ? 0.5 : 1)
            }
        }
        .padding(14)
        .card(radius: Theme.Radius.row, padding: 0)
        .animation(Theme.snap, value: resolved)
    }

    private func respond(_ status: String) {
        guard app.requireAccount(for: "track your progress") else { return }
        responding = true

        // Optimistic: the tap should feel instant, and a failed response only
        // costs us one data point rather than the user's trust.
        withAnimation(Theme.snap) { resolved = status }

        Task {
            try? await APIClient.shared.respondToAction(id: action.id, status: status)
            responding = false
            onResponded?()
        }
    }
}
