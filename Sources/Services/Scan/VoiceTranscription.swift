import AVFoundation
import Foundation
import Observation
import Speech

/// Voice input, transcribed on the device.
///
/// `requiresOnDeviceRecognition` is set wherever the device supports it, so
/// speech is not sent to Apple's servers. In a health app the difference
/// matters: a spoken question about symptoms should not leave the phone any more
/// than a typed one would.
@Observable
@MainActor
final class VoiceTranscription {

    enum State: Equatable {
        case idle
        case denied(String)
        case recording
        case finishing
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var transcript = ""
    /// Rough input level, for the waveform. Not a measurement of anything.
    private(set) var level: Float = 0

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recogniser = SFSpeechRecognizer(locale: Locale.current)
        ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    var isRecording: Bool { state == .recording }

    /// Both permissions are needed: speech recognition and the microphone.
    /// Requested only when the user taps the microphone, never at launch.
    func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else {
            state = .denied("Speech recognition is off for BP Coach. You can turn it on in Settings.")
            return false
        }

        let microphone = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard microphone else {
            state = .denied("Microphone access is off for BP Coach. You can turn it on in Settings.")
            return false
        }
        return true
    }

    func start() async {
        guard await requestPermissions() else { return }
        guard let recogniser, recogniser.isAvailable else {
            state = .failed("Speech recognition is not available right now.")
            return
        }

        stopAudio()
        transcript = ""

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            // Keeps audio on the device where the hardware allows it.
            request.requiresOnDeviceRecognition = recogniser.supportsOnDeviceRecognition
            self.request = request

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                request.append(buffer)
                guard let channel = buffer.floatChannelData?[0] else { return }
                let frames = Int(buffer.frameLength)
                var sum: Float = 0
                for index in 0..<frames { sum += abs(channel[index]) }
                let average = frames > 0 ? sum / Float(frames) : 0
                Task { @MainActor in self?.level = min(average * 12, 1) }
            }

            engine.prepare()
            try engine.start()
            state = .recording

            task = recogniser.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result {
                        self.transcript = result.bestTranscription.formattedString
                    }
                    if error != nil || result?.isFinal == true {
                        self.stopAudio()
                        if self.state == .finishing || self.state == .recording {
                            self.state = .idle
                        }
                    }
                }
            }
        } catch {
            stopAudio()
            state = .failed("Could not start recording: \(error.localizedDescription)")
        }
    }

    /// Ends the recording and returns whatever was transcribed.
    @discardableResult
    func stop() -> String {
        state = .finishing
        request?.endAudio()
        stopAudio()
        state = .idle
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() {
        task?.cancel()
        stopAudio()
        transcript = ""
        state = .idle
    }

    private func stopAudio() {
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request = nil
        task = nil
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
