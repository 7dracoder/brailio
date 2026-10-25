import SwiftUI
import CoreHaptics

@MainActor
final class HapticReader: ObservableObject {
    @Published var cells: [BrailleCell] = []
    @Published var index = 0
    @Published var activeDot: Int?
    @Published var isPlaying = false
    @Published var error: String?
    var onFinished: (() -> Void)?
    let supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    private var engine: CHHapticEngine?
    private var player: CHHapticPatternPlayer?
    private var task: Task<Void, Never>?
    var current: BrailleCell? { cells.indices.contains(index) ? cells[index] : nil }
    var slotDuration: Double { UserDefaults.standard.double(forKey: "slotDuration").nonzeroOr(0.30) }

    func playText(_ text: String) {
        let result = Braille.translate(text)
        guard result.unsupported.isEmpty else {
            stop(); error = "Please replace unsupported characters: " + result.unsupported.joined(separator: " "); return
        }
        load(result.cells); play()
    }
    func load(_ cells: [BrailleCell]) {
        stop(); self.cells = cells; index = 0; error = nil
    }
    func move(_ offset: Int) {
        stop(); index = max(0, min(cells.count - 1, index + offset))
    }
    func stop() {
        task?.cancel(); task = nil
        try? player?.stop(atTime: CHHapticTimeImmediate)
        player = nil; isPlaying = false; activeDot = nil
    }
    func play(single: Bool = false) {
        stop()
        guard !cells.isEmpty else { return }
        error = nil
        if supportsHaptics {
            do {
                if engine == nil {
                    let newEngine = try CHHapticEngine()
                    newEngine.playsHapticsOnly = true
                    newEngine.isAutoShutdownEnabled = true
                    newEngine.stoppedHandler = { [weak self] _ in
                        Task { @MainActor in
                            guard let self, self.isPlaying else { return }
                            self.stop(); self.error = "Vibration was interrupted. Tap play to resume this character."
                        }
                    }
                    newEngine.resetHandler = { [weak self] in
                        Task { @MainActor in self?.stop(); self?.engine = nil }
                    }
                    engine = newEngine
                }
                try engine?.start()
            } catch { self.error = "Could not start vibrations: \(error.localizedDescription)"; return }
        }
        isPlaying = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                repeat {
                    guard let cell = self.current else { break }
                    let slot = self.slotDuration
                    if self.supportsHaptics, !cell.dots.isEmpty {
                        let intensity = Float(UserDefaults.standard.double(forKey: "intensity").nonzeroOr(0.8))
                        let events = cell.dots.sorted().map { dot in
                            CHHapticEvent(eventType: .hapticContinuous, parameters: [
                                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.6)
                            ], relativeTime: Double(dot - 1) * slot, duration: slot * 0.48)
                        }
                        let pattern = try CHHapticPattern(events: events, parameters: [])
                        self.player = try self.engine?.makePlayer(with: pattern)
                        try self.player?.start(atTime: CHHapticTimeImmediate)
                    }
                    for dot in 1...6 {
                        try Task.checkCancellation()
                        self.activeDot = dot
                        try await Task.sleep(for: .seconds(slot))
                    }
                    self.activeDot = nil
                    try await Task.sleep(for: .seconds(slot * 2))
                    if single || self.index == self.cells.count - 1 { break }
                    self.index += 1
                } while !Task.isCancelled
                self.isPlaying = false; self.activeDot = nil
                if !single && !Task.isCancelled { self.onFinished?() }
            } catch is CancellationError { /* stop() owns cancellation state. */ }
            catch { self.stop(); self.error = "Vibration failed. \(error.localizedDescription)" }
        }
    }
}
private extension Double {
    func nonzeroOr(_ fallback: Double) -> Double { self > 0 ? self : fallback }
}
