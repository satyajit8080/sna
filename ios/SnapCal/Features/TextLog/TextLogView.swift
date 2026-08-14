import SwiftUI

struct TextLogView: View {
    let onSubmit: (String) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    /// Locale-aware examples — an Indian user should see food they recognise.
    private var examples: [String] {
        switch Locale.current.region?.identifier {
        case "IN": ["2 rotis, dal and bhindi sabzi", "masala dosa with sambar", "2 idlis and coconut chutney"]
        case "GB": ["beans on toast and a flat white", "chicken tikka masala with rice", "full english breakfast"]
        case "AU": ["flat white and avocado toast", "chicken parma with chips", "meat pie"]
        default:   ["2 eggs, toast and black coffee", "chipotle chicken bowl", "greek yogurt with berries"]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text("What did you eat?")
                .font(.system(size: 28, weight: .bold, design: .rounded))

            TextField("", text: $text, axis: .vertical)
                .font(.system(size: 20))
                .lineLimit(3...6)
                .focused($focused)
                .padding(Theme.Space.m)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.control).stroke(Theme.hairline, lineWidth: 1)
                )
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("e.g. \(examples[0])")
                            .font(.system(size: 20))
                            .foregroundStyle(.tertiary)
                            .padding(Theme.Space.m)
                            .allowsHitTesting(false)
                    }
                }

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Try").font(.label).foregroundStyle(.secondary)
                ForEach(examples, id: \.self) { example in
                    Button {
                        Haptics.tap()
                        text = example
                    } label: {
                        Text(example).font(.system(size: 14))
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }

            Spacer()

            Button("Analyze") { onSubmit(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(text.trimmingCharacters(in: .whitespaces).count < 3)
                .opacity(text.trimmingCharacters(in: .whitespaces).count < 3 ? 0.4 : 1)
        }
        .padding(Theme.Space.l)
        .onAppear { focused = true }
    }
}
