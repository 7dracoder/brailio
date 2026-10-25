import Foundation
import CoreHaptics

/// Route-error intensity is separate from the six-slot Braille language.
@MainActor final class NavigationHaptics: ObservableObject {
    @Published var error: String?
    private var engine: CHHapticEngine?
    private var player: CHHapticPatternPlayer?
    private var previewTask: Task<Void, Never>?
    private var loop: Task<Void, Never>?
    private var current = RouteFeedback.paused
    func stop() { previewTask?.cancel(); previewTask = nil; current = .paused; loop?.cancel(); loop = nil; try? player?.stop(atTime: CHHapticTimeImmediate); player = nil }
    func preview(_ feedback: RouteFeedback) {
        update(feedback)
        previewTask = Task {
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            stop()
        }
    }
    func update(_ feedback: RouteFeedback) {
        guard current != feedback else { return }
        if current.kind == feedback.kind { current=feedback; return }
        stop(); current = feedback
        guard [.deviated,.uncertain,.approaching,.end].contains(feedback.kind) else { return }
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            if engine == nil {
                let engine = try CHHapticEngine(); engine.playsHapticsOnly = true; engine.isAutoShutdownEnabled = true
                engine.stoppedHandler = { [weak self] reason in Task { @MainActor in guard reason != .idleTimeout, let self, [.deviated, .uncertain, .approaching, .end].contains(self.current.kind) else { return }; self.stop(); self.error = "Guidance vibrations stopped. Resume after checking your position." } }
                engine.resetHandler = { [weak self] in Task { @MainActor in self?.stop(); self?.engine = nil; self?.error = "Guidance vibrations reset. Resume guidance." } }
                self.engine = engine
            }
            try engine?.start()
        } catch { stop(); self.error = "Guidance vibrations could not start."; return }
        loop = Task {
            do {
                while !Task.isCancelled {
                    let feedback=current
                    guard let pulse=HapticPulseSpec.make(feedback) else { return }
                    let ceiling = UserDefaults.standard.double(forKey: "intensity")
                    let strength = Float(pulse.intensity) * Float(ceiling > 0 ? min(1, ceiling) : 0.8)
                    let times=pulse.times
                    let events = times.map { CHHapticEvent(eventType: .hapticContinuous, parameters: [.init(parameterID: .hapticIntensity, value: strength), .init(parameterID: .hapticSharpness, value: 0.7)], relativeTime: $0, duration: pulse.duration) }
                    let pattern = try CHHapticPattern(events: events, parameters: [])
                    try await engine?.start(); try Task.checkCancellation(); player = try engine?.makePlayer(with: pattern); try player?.start(atTime: CHHapticTimeImmediate)
                    try await Task.sleep(for: .seconds(pulse.interval))
                }
            } catch is CancellationError { } catch { stop(); self.error = "Guidance vibrations failed. Guidance paused." }
        }
    }
}
