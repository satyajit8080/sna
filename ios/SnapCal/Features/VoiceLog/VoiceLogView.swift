import SwiftUI
import Speech

/// Transcription runs on-device where the device supports it, so raw audio
/// never leaves the phone — only the resulting text reaches our backend.
@MainActor
@Observable
final class SpeechRecognizer {
    var transcript = ""
    var isRecording = false
    var permissionDenied = false

    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let engine = AVAudioEngine()

    func requestAccess() async -> Bool {
        let speech = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
        let mic = await AVAudioApplication.requestRecordPermission()
        permissionDenied = !(speech && mic)
        return speech && mic
    }

    func start() throws {
        stop()
        transcript = ""

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer?.supportsOnDeviceRecognition ?? false
        self.request = request

        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }

        engine.prepare()
        try engine.start()
        isRecording = true

        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result { self.transcript = result.bestTranscription.formattedString }
            if error != nil || result?.isFinal == true { self.stop() }
        }
    }

    func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isRecording = false
    }
}

struct VoiceLogView: View {
    let onSubmit: (String) -> Void

    @State private var speech = SpeechRecognizer()
    @State private var level: CGFloat = 0.4

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            Spacer()

            Text(speech.transcript.isEmpty
                 ? (speech.isRecording ? "Listening…" : "Tap and tell me what you ate")
                 : speech.transcript)
                .font(.system(size: speech.transcript.isEmpty ? 20 : 26, weight: .medium, design: .rounded))
                .foregroundStyle(speech.transcript.isEmpty ? .secondary : .primary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Space.l)
                .animation(Theme.quick, value: speech.transcript)

            Spacer()

            ZStack {
                Circle()
                    .fill(Theme.accentSoft)
                    .frame(width: 140, height: 140)
                    .scaleEffect(speech.isRecording ? level : 1)

                Button {
                    Haptics.commit()
                    toggle()
                } label: {
                    Image(systemName: speech.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.white)
                        .frame(width: 92, height: 92)
                        .background(speech.isRecording ? Theme.danger : Theme.accent, in: Circle())
                }
                .buttonStyle(.plain)
            }

            if speech.permissionDenied {
                Text("Enable microphone and speech access in Settings to use voice logging.")
                    .font(.caption_).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Space.l)
            }

            Button("Use this") { onSubmit(speech.transcript) }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(speech.transcript.count < 3)
                .opacity(speech.transcript.count < 3 ? 0.35 : 1)
                .padding(Theme.Space.l)
        }
        .task {
            _ = await speech.requestAccess()
            withAnimation(.easeInOut(duration: 0.7).repeatForever()) { level = 1.15 }
        }
        .onDisappear { speech.stop() }
    }

    private func toggle() {
        if speech.isRecording {
            speech.stop()
        } else {
            try? speech.start()
        }
    }
}
