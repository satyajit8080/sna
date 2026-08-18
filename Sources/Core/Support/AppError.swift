import Foundation

/// User-facing failure states. Every one of these has a screen or banner that
/// explains what happened and what the user can do — nothing fails silently and
/// nothing crashes because a service is unavailable.
enum AppError: LocalizedError, Equatable {
    case healthKitUnavailable
    case healthKitDenied
    case healthKitNotOwner(String)
    case notificationsDenied
    case invalidReading(String)
    case coachUnavailable
    case coachOffline
    case coachRefused(String)
    case foodProviderUnavailable
    case saveFailed(String)
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .healthKitUnavailable:
            "Apple Health is not available on this device."
        case .healthKitDenied:
            "BP Coach does not have permission to read Apple Health."
        case .healthKitNotOwner(let name):
            "\(name) is not the device owner profile, so Apple Health is not available here."
        case .notificationsDenied:
            "Notifications are turned off for BP Coach."
        case .invalidReading(let reason):
            reason
        case .coachUnavailable:
            "The AI coach is not set up in this build."
        case .coachOffline:
            "Could not reach the coach. Check your connection and try again."
        case .coachRefused(let reason):
            reason
        case .foodProviderUnavailable:
            "No food database is connected, so sodium is entered by hand."
        case .saveFailed(let reason):
            "Could not save: \(reason)"
        case .exportFailed(let reason):
            "Could not export: \(reason)"
        }
    }

    /// What the user can actually do about it. Nil when there is nothing to do.
    var recovery: String? {
        switch self {
        case .healthKitUnavailable:
            "You can still record readings by hand."
        case .healthKitDenied:
            "Open Settings → Health → Data Access to change this."
        case .healthKitNotOwner:
            "Switch to the owner profile to use Apple Health."
        case .notificationsDenied:
            "Open Settings → Notifications → BP Coach to turn them on."
        case .coachUnavailable:
            "Your readings are still saved and your trends still work."
        case .coachOffline:
            "Everything else works offline — your readings are saved either way."
        case .coachRefused:
            nil
        case .foodProviderUnavailable:
            "Read sodium off the label and enter it manually."
        default:
            nil
        }
    }
}
