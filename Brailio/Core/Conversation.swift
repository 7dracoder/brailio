import Foundation
import Speech
import AVFoundation

@MainActor
final class Conversation: ObservableObject {
    @Published var transcript = ""
    @Published var listening = false
    @Published var error: String?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var hasTap = false
    private var sessionActive = false
    private var generation = UUID()
    func start() async {
        let attempt = UUID(); generation = attempt
        let allowed = await withCheckedContinuation { continuation in SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) } }
        guard generation == attempt else { return }
        guard allowed else { error = "Allow Speech Recognition in iPhone Settings to transcribe a conversation."; return }
        let microphone = await withCheckedContinuation { continuation in AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) } }
        guard generation == attempt else { return }
        guard microphone else { error = "Allow microphone access in iPhone Settings to listen."; return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.isAvailable else { error = "Speech recognition is currently unavailable."; return }
        stop(); generation = attempt
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
            try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            try session.setActive(true); sessionActive = true
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            self.request = request
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else { throw ServiceError.message("No microphone input is available.") }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
            hasTap = true; transcript = ""
            recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard self?.generation == attempt else { return }
                    if let result { self?.transcript = result.bestTranscription.formattedString }
                    if result?.isFinal == true || error != nil {
                        self?.stop()
                        if let error { self?.error = "Transcription stopped: \(error.localizedDescription)" }
                    }
                }
            }
            engine.prepare(); try engine.start(); listening = true
        } catch { stop(); self.error = error.localizedDescription }
    }
    func stop() {
        generation = UUID()
        engine.stop()
        if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
        request?.endAudio(); recognition?.cancel(); recognition = nil; request = nil; listening = false
        if sessionActive { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation); sessionActive = false }
    }
}
