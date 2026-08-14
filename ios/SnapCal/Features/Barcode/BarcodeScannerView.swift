import SwiftUI
@preconcurrency import AVFoundation

/// Packaged foods go to Open Food Facts, never to the vision model —
/// a label lookup is exact and free.
struct BarcodeScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> BarcodeController {
        let vc = BarcodeController()
        vc.onScan = onScan
        return vc
    }

    func updateUIViewController(_ vc: BarcodeController, context: Context) {}
}

final class BarcodeController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?

    // nonisolated so the background start/stop closures do not capture
    // main-actor state. startRunning()/stopRunning() are blocking calls that
    // must not run on the main thread anyway.
    private nonisolated(unsafe) let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer!
    private var hasScanned = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        session.beginConfiguration()
        if let device = AVCaptureDevice.default(for: .video),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }

        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.ean8, .ean13, .upce, .code128]
        }
        session.commitConfiguration()

        preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)

        let window = UIView()
        window.layer.borderColor = UIColor.white.cgColor
        window.layer.borderWidth = 2
        window.layer.cornerRadius = 14
        window.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(window)

        let label = UILabel()
        label.text = "Point at the barcode"
        label.textColor = .white
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)

        NSLayoutConstraint.activate([
            window.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            window.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            window.widthAnchor.constraint(equalToConstant: 280),
            window.heightAnchor.constraint(equalToConstant: 160),
            label.topAnchor.constraint(equalTo: window.bottomAnchor, constant: 16),
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        hasScanned = false
        Task.detached(priority: .userInitiated) { [session] in session.startRunning() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        Task.detached { [session] in session.stopRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    // Delivered on the queue given to setMetadataObjectsDelegate, so the
    // callback itself must be nonisolated. `hasScanned` is only ever read and
    // written on the main actor, which keeps the debounce race-free.
    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput,
                                    didOutput objects: [AVMetadataObject],
                                    from connection: AVCaptureConnection) {
        guard let obj = objects.first as? AVMetadataMachineReadableCodeObject,
              let value = obj.stringValue else { return }

        Task { @MainActor in
            guard !self.hasScanned else { return }
            self.hasScanned = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            self.stopSession()
            self.onScan?(value)
        }
    }

    private func stopSession() {
        let session = self.session
        Task.detached { session.stopRunning() }
    }
}
