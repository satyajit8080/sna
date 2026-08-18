import SwiftData
import SwiftUI

@main
struct BPCoachApp: App {

    @State private var appModel: AppModel
    private let container: ModelContainer

    init() {
        do {
            let container = try PersistenceController.makeContainer()
            self.container = container
            self._appModel = State(initialValue: AppModel(context: container.mainContext))
        } catch {
            fatalError("Could not create the local data store: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
                .environment(appModel.guidelines)
                .environment(appModel.health)
                .tint(Theme.accent)
        }
        .modelContainer(container)
    }
}
