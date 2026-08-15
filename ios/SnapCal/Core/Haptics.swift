import UIKit

/// UIFeedbackGenerator is main-actor isolated. Every caller is a SwiftUI view
/// or a view model that already runs on the main actor, so isolating the whole
/// enum costs nothing and silences the Swift 6 concurrency errors.
@MainActor
enum Haptics {
    static func tap()     { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func commit()  { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warn()    { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}
