import SwiftUI
@preconcurrency import AVFoundation

/// Minimal AVFoundation camera. No filters, no modes — one shutter button,
/// because every extra control costs seconds on the primary path.
struct CameraCaptureView: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void

    func makeUIViewController(context: Context) -> CameraController {
        let vc = CameraController()
        vc.onCapture = onCapture
        return vc
    }

    func updateUIViewController(_ vc: CameraController, context: Context) {}
}

final class CameraController: UIViewController, AVCapturePhotoCaptureDelegate {
    var onCapture: ((UIImage) -> Void)?

    // nonisolated so the background start/stop closures do not capture
    // main-actor state. startRunning()/stopRunning() are blocking calls that
    // must not run on the main thread anyway.
    private nonisolated(unsafe) let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private var preview: AVCaptureVideoPreviewLayer!
    private let shutter = UIButton(type: .custom)
    private let hint = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
        configureUI()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard !session.isRunning else { return }
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

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .photo

        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()

        preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        view.layer.insertSublayer(preview, at: 0)
    }

    private func configureUI() {
        // Framing guide: users who fill the frame get materially better estimates.
        let guideSize: CGFloat = 280
        let guide = UIView()
        guide.layer.borderColor = UIColor.white.withAlphaComponent(0.6).cgColor
        guide.layer.borderWidth = 2
        guide.layer.cornerRadius = 28
        guide.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(guide)

        hint.text = "Fit the whole plate in the frame"
        hint.font = .systemFont(ofSize: 14, weight: .medium)
        hint.textColor = .white.withAlphaComponent(0.9)
        hint.textAlignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hint)

        shutter.backgroundColor = .white
        shutter.layer.cornerRadius = 36
        shutter.layer.borderColor = UIColor.white.withAlphaComponent(0.4).cgColor
        shutter.layer.borderWidth = 5
        shutter.translatesAutoresizingMaskIntoConstraints = false
        shutter.addTarget(self, action: #selector(capture), for: .touchUpInside)
        view.addSubview(shutter)

        NSLayoutConstraint.activate([
            guide.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            guide.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),
            guide.widthAnchor.constraint(equalToConstant: guideSize),
            guide.heightAnchor.constraint(equalToConstant: guideSize),

            hint.topAnchor.constraint(equalTo: guide.bottomAnchor, constant: 16),
            hint.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            shutter.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            shutter.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -32),
            shutter.widthAnchor.constraint(equalToConstant: 72),
            shutter.heightAnchor.constraint(equalToConstant: 72),
        ])
    }

    @objc private func capture() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let settings = AVCapturePhotoSettings()
        settings.photoQualityPrioritization = .speed   // speed is the product
        output.capturePhoto(with: settings, delegate: self)
    }

    // AVFoundation calls this on its own queue, so it cannot satisfy the
    // protocol while main-actor isolated. Decode off the main thread, then hop
    // back before touching any UI state.
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data)
        else { return }

        Task { @MainActor in
            self.onCapture?(image)
        }
    }
}
