import AVFoundation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The states every scan flow moves through. Shared so all five behave the same
/// and none of them can quietly skip an error case.
enum ScanState<Output>: Equatable where Output: Equatable {
    case idle
    case capturing
    case processing(String)
    case result(Output)
    case failed(String)

    var isBusy: Bool {
        if case .processing = self { return true }
        if case .capturing = self { return true }
        return false
    }
}

/// Camera capture via `UIImagePickerController`.
///
/// A full `AVCaptureSession` would give more control, but the system camera
/// brings focus, exposure and flash handling that materially improve OCR on a
/// printed page — which is what these scans are.
struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.onCapture(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

/// File import for PDFs and images.
struct DocumentPicker: UIViewControllerRepresentable {
    let types: [UTType]
    let onPick: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forOpeningContentTypes: types)
        controller.delegate = context.coordinator
        controller.allowsMultipleSelection = false
        return controller
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let parent: DocumentPicker
        init(_ parent: DocumentPicker) { self.parent = parent }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            guard let url = urls.first else { return }
            // Files outside the sandbox need an explicit security scope, or the
            // read silently returns nothing.
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
            parent.onPick(url)
        }
    }
}

/// Barcode scanning via AVFoundation.
struct BarcodeScanner: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> BarcodeScannerController {
        let controller = BarcodeScannerController()
        controller.onScan = onScan
        return controller
    }

    func updateUIViewController(_ controller: BarcodeScannerController, context: Context) {}
}

final class BarcodeScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?
    private let session = AVCaptureSession()
    /// Barcodes fire continuously while the camera is pointed at one; without
    /// this the callback runs dozens of times per second.
    private var hasScanned = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.ean13, .ean8, .upce, .code128, .code39]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = view.layer.bounds
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)

        Task.detached { [session] in session.startRunning() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        session.stopRunning()
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput objects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !hasScanned,
              let object = objects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue else { return }
        hasScanned = true
        AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
        onScan?(value)
    }
}

/// Shown when the camera cannot be used, with the only action that helps.
struct CameraUnavailableView: View {
    let state: CameraPermission.State
    let onRequest: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "camera.fill")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Theme.textTertiary)

            Text(state.message ?? "Camera unavailable")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)

            if state.canPrompt {
                Button("Allow camera", action: onRequest)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            } else if state == .denied {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.xl)
    }
}
