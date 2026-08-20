import SwiftUI

/// Inline, non-blocking failure notice.
struct ErrorBanner: View {
    let error: AppError
    var onDismiss: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                Image(systemName: "exclamationmark.circle.fill")
                VStack(alignment: .leading, spacing: 2) {
                    Text(error.errorDescription ?? "Something went wrong")
                        .font(.subheadline.weight(.medium))
                    if let recovery = error.recovery {
                        Text(recovery)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer()
                if let onDismiss {
                    Button { onDismiss() } label: {
                        Image(systemName: "xmark").font(.caption)
                    }
                    .accessibilityLabel("Dismiss")
                }
            }
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.statusElevated.opacity(0.12))
        .foregroundStyle(Theme.statusElevated)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Attaches an error banner above any content.
struct ErrorContainer<Content: View>: View {
    @Binding var error: AppError?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            if let error {
                ErrorBanner(error: error) { self.error = nil }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            content
        }
        .animation(.snappy, value: error)
    }
}

struct LoadingView: View {
    let message: String

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            ProgressView().tint(Brand.accent)
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(Brand.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.xl)
        .accessibilityElement(children: .combine)
    }
}
