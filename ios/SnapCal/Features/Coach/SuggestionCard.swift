import SwiftUI

/// A concrete next meal with a one-tap log.
///
/// The macros come from the nutrition database, so tapping Add writes straight
/// to the diary — no confirmation screen, no second AI call, and the numbers
/// shown are exactly the numbers saved.
struct SuggestionCard: View {
    @Environment(AppState.self) private var app

    let suggestion: MealSuggestion
    var onLogged: (() -> Void)?

    @State private var logging = false
    @State private var logged = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Label(suggestion.slot.title, systemImage: suggestion.slot.icon)
                    .font(.caption_)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(suggestion.calories) cal")
                    .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
            }

            Text(suggestion.name.capitalized)
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(2)

            Text(suggestion.reason)
                .font(.caption_)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Theme.Space.m) {
                macro("P", suggestion.protein_g, Theme.protein)
                macro("C", suggestion.carbs_g, Theme.carbs)
                macro("F", suggestion.fat_g, Theme.fat)
                Spacer()
            }

            Button {
                Haptics.commit()
                log()
            } label: {
                if logging {
                    ProgressView().tint(.white).frame(maxWidth: .infinity)
                } else {
                    Label(logged ? "Added to Diary" : "Add to Diary",
                          systemImage: logged ? "checkmark" : "plus")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(logging || logged)
            .opacity(logged ? 0.6 : 1)
        }
        .card()
    }

    private func macro(_ letter: String, _ grams: Int, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(letter) \(grams)g")
                .font(.system(size: 13, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func log() {
        logging = true
        Task {
            let ok = await app.logKnownItem(suggestion.asFoodItem, slot: suggestion.slot)
            logging = false
            if ok {
                withAnimation(Theme.snap) { logged = true }
                onLogged?()
            }
        }
    }
}

/// Topic chips for the first coach conversation.
///
/// Each carries an opener built from what onboarding already captured, so
/// choosing one goes deeper rather than starting the questionnaire again.
struct FlowChips: View {
    let topics: [WelcomeTopic]
    var onSelect: (WelcomeTopic) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ForEach(topics) { topic in
                Button {
                    onSelect(topic)
                } label: {
                    HStack {
                        Text(topic.label)
                            .font(.jakarta(15, .semibold))
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 16)
                    .frame(height: 48)
                    .frame(maxWidth: .infinity)
                    .background(Theme.surfaceRaised,
                                in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(Theme.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
