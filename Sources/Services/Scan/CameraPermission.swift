import AVFoundation
import Foundation
import Observation

/// Camera authorisation, surfaced as explicit states.
///
/// The distinction between "not asked" and "denied" matters: the first can be
/// resolved with a prompt, the second only in Settings. Collapsing them into a
/// boolean produces a button that silently does nothing.
@Observable
@MainActor
final class CameraPermission {

    enum State: Equatable {
        case notDetermined
        case authorised
        case denied
        case restricted
        /// No camera at all — simulator, or hardware without one.
        case unavailable

        var canPrompt: Bool { self == .notDetermined }
        var isUsable: Bool { self == .authorised }

        var message: String? {
            switch self {
            case .authorised, .notDetermined: nil
            case .denied:
                "BP Coach does not have camera access. You can turn it on in Settings."
            case .restricted:
                "Camera access is restricted on this device."
            case .unavailable:
                "This device has no camera available. You can still choose a photo or file."
            }
        }
    }

    private(set) var state: State = .notDetermined

    init() { refresh() }

    func refresh() {
        guard !AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        ).devices.isEmpty else {
            state = .unavailable
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: state = .authorised
        case .denied: state = .denied
        case .restricted: state = .restricted
        case .notDetermined: state = .notDetermined
        @unknown default: state = .denied
        }
    }

    /// Prompts only when the system will actually show a prompt. Calling this
    /// after a denial does nothing, which is why `canPrompt` exists.
    @discardableResult
    func request() async -> Bool {
        guard state.canPrompt else { return state.isUsable }
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        refresh()
        return granted
    }
}
