import SwiftData
import SwiftUI

@main
struct BPCoachApp: App {

    @State private var appModel: AppModel
    private let stack: PersistenceController.Stack

    init() {
        // Never crash on launch. If the disk store cannot open, the stack falls
        // back to memory and the app says so rather than dying silently.
        let stack = PersistenceController.makeStack()
        self.stack = stack
        self._appModel = State(initialValue: AppModel(context: stack.container.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
                .environment(appModel.guidelines)
                .environment(appModel.health)
                .tint(Theme.accent)
                .preferredColorScheme(appModel.settings.appearance.colorScheme)
                .overlay(alignment: .top) {
                    if stack.isEphemeral { StorageWarningBanner() }
                }
        }
        .modelContainer(stack.container)
    }
}

/// Shown when persistence fell back to memory. Readings will not survive a
/// relaunch, and the user needs to know that before they rely on the app.
struct StorageWarningBanner: View {
    var body: some View {
        Label(
            "Storage unavailable — readings won't be saved after you close the app.",
            systemImage: "exclamationmark.triangle.fill"
        )
        .font(.footnote.weight(.medium))
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.statusSevere)
        .foregroundStyle(.white)
        .accessibilityAddTraits(.isStaticText)
    }
}
