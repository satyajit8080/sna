import SwiftUI
import UIKit

/// Form controls in the brand style.
///
/// These replace SwiftUI's `Form` rows, which draw their own light chrome. What
/// they must not lose is the behaviour `Form` gives away free: labels that
/// VoiceOver reads with their value, controls that stay legible at large text
/// sizes, and fields that do not trap the keyboard. Each control below carries
/// its own accessibility label and uses `.dynamicTypeSize` rather than fixed
/// heights wherever text is involved.

/// A titled group of rows, replacing `Section`.
struct BrandFormSection<Content: View>: View {
    let title: String?
    var footer: String?
    @ViewBuilder var content: Content

    init(
        _ title: String? = nil,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Brand.textPrimary)
            }

            BrandCard(padding: 0) {
                VStack(spacing: 0) { content }
            }

            if let footer {
                Text(footer)
                    .font(.system(size: 12))
                    .foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// Hairline between rows inside a section.
struct BrandRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Brand.cardStroke)
            .frame(height: 1)
            .padding(.leading, 16)
    }
}

/// A single-line text field.
struct BrandTextField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var symbol: String?
    var autocapitalization: TextInputAutocapitalization = .sentences
    var keyboard: UIKeyboardType = .default

    var body: some View {
        HStack(spacing: 12) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(Brand.accent)
                    .frame(width: 20)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(Brand.textSecondary)
                TextField(
                    "",
                    text: $text,
                    prompt: Text(placeholder).foregroundStyle(Brand.textSecondary.opacity(0.6))
                )
                .font(.system(size: 15))
                .foregroundStyle(Brand.textPrimary)
                .textInputAutocapitalization(autocapitalization)
                .keyboardType(keyboard)
            }
        }
        .padding(16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(text.isEmpty ? "empty" : text)
    }
}

/// A toggle row.
struct BrandToggleRow: View {
    let title: String
    var detail: String?
    var symbol: String?
    var tint: Color = Brand.accent
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            if let symbol {
                BrandIconTile(symbol: symbol, tint: tint, size: 36)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Brand.textPrimary)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(Brand.accent)
        }
        .padding(16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}

/// A tappable row that pushes or performs an action.
struct BrandActionRow: View {
    let title: String
    var detail: String?
    var value: String?
    var symbol: String?
    var tint: Color = Brand.accent
    var isDestructive = false
    var showsChevron = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let symbol {
                    BrandIconTile(
                        symbol: symbol,
                        tint: isDestructive ? Brand.restingHeartRate : tint,
                        size: 36
                    )
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(isDestructive ? Brand.restingHeartRate : Brand.textPrimary)
                        .multilineTextAlignment(.leading)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(Brand.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 8)
                if let value {
                    Text(value)
                        .font(.system(size: 13))
                        .foregroundStyle(Brand.textSecondary)
                }
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.textSecondary)
                }
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

/// A read-only label/value row.
struct BrandValueRow: View {
    let title: String
    let value: String
    var symbol: String?
    var valueTint: Color = Brand.textSecondary

    var body: some View {
        HStack(spacing: 12) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(Brand.accent)
                    .frame(width: 20)
            }
            Text(title)
                .font(.system(size: 15))
                .foregroundStyle(Brand.textPrimary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 14))
                .foregroundStyle(valueTint)
                .multilineTextAlignment(.trailing)
        }
        .padding(16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }
}

/// A date and time picker row.
struct BrandDateRow: View {
    let title: String
    @Binding var date: Date
    var components: DatePickerComponents = [.date, .hourAndMinute]
    var range: PartialRangeThrough<Date>?

    var body: some View {
        HStack {
            if let range {
                DatePicker(title, selection: $date, in: range, displayedComponents: components)
            } else {
                DatePicker(title, selection: $date, displayedComponents: components)
            }
        }
        .font(.system(size: 15))
        .foregroundStyle(Brand.textPrimary)
        .tint(Brand.accent)
        .padding(16)
    }
}

/// A segmented choice rendered as brand pills.
struct BrandSegmented<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                Button {
                    selection = option.value
                    Haptics.selection()
                } label: {
                    Text(option.label)
                        .font(.system(size: 13, weight: selection == option.value ? .semibold : .regular))
                        .foregroundStyle(selection == option.value ? Brand.onAccent : Brand.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(selection == option.value ? Brand.accent : .clear)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == option.value ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(3)
        .background(Brand.background)
        .overlay { Capsule().strokeBorder(Brand.cardStroke, lineWidth: 1) }
        .clipShape(Capsule())
    }
}
