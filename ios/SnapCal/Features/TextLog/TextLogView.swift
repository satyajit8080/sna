import SwiftUI

struct TextLogView: View {
    let onSubmit: (String) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    /// North American examples by default. The parser handles every cuisine —
    /// these are only the prompts, and a first-run user should see food they
    /// already eat. Other regions surface only when the device locale says so.
    private var examples: [String] {
        switch Locale.current.region?.identifier {
        case "GB": ["beans on toast and a flat white", "roast chicken with potatoes", "full english breakfast"]
        case "AU": ["flat white and avocado toast", "chicken parma with chips", "steak and salad"]
        default:   ["2 eggs, toast and black coffee", "grilled chicken salad", "greek yogurt with berries"]
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
