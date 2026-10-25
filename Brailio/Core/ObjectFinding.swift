import Foundation
import Vision
import ImageIO

struct ObjectBox: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    var valid: Bool { [x,y,width,height].allSatisfy(\.isFinite) && x >= 0 && y >= 0 && width > 0 && height > 0 && x + width <= 1.001 && y + height <= 1.001 }
    var horizontal: String { x + width / 2 < 0.38 ? "left" : x + width / 2 > 0.62 ? "right" : "center" }
}

enum FindingPolicy {
    static func canPulse(frameAge: TimeInterval, semanticAge: TimeInterval, confidence: Double, box: ObjectBox?) -> Bool {
        frameAge >= 0 && frameAge < 2.5 && semanticAge >= 0 && semanticAge < 12 && confidence >= 0.6 && confidence <= 1 && box?.valid == true
    }
    static func verdict(_ result: AIResult, age: TimeInterval) -> String {
        guard age >= 0, age < 8, let confidence = result.confidence, confidence >= 0.8, confidence <= 1 else { return "uncertain" }
        return ["yes", "no"].contains(result.verdict ?? "") ? result.verdict! : "uncertain"
    }
    static func samples(_ frames: [RoomFrame], maximum: Int = 8) -> [Data] {
        guard maximum > 0, !frames.isEmpty else { return [] }
        if frames.count <= maximum { return frames.map(\.jpeg) }
        if maximum == 1 { return [frames[frames.count - 1].jpeg] }
        return (0..<maximum).map { frames[Int(Double($0) * Double(frames.count - 1) / Double(maximum - 1))].jpeg }
    }
}

actor VisualObjectTracker {
    private var sequence = VNSequenceRequestHandler()
    private var request: VNTrackObjectRequest?
    func clear() { request = nil; sequence = VNSequenceRequestHandler() }
    func seed(_ box: ObjectBox, image: Data) throws {
        guard box.valid else { return }
        sequence = VNSequenceRequestHandler()
        let observation = VNDetectedObjectObservation(boundingBox: CGRect(x: box.x, y: 1 - box.y - box.height, width: box.width, height: box.height))
        let request = VNTrackObjectRequest(detectedObjectObservation: observation); request.trackingLevel = .accurate
        guard let source = CGImageSourceCreateWithData(image as CFData, nil), let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        try sequence.perform([request], on: cg); self.request = request
    }
    func track(_ data: Data) throws -> (ObjectBox, Double)? {
        guard let request, let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        try sequence.perform([request], on: image)
        guard let result = request.results?.first as? VNDetectedObjectObservation, result.confidence >= 0.6 else { self.request = nil; return nil }
        request.inputObservation = result
        let box = result.boundingBox
        return (ObjectBox(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height), Double(result.confidence))
    }
}

@MainActor
final class ObjectFinding: ObservableObject {
    enum Mode: String { case idle, captured, searching, guiding, checking, yes, no, uncertain, unavailable }
    @Published var mode: Mode = .idle
    @Published var message = "Hold the center to scan"
    @Published var result: AIResult?
    @Published var box: ObjectBox?
    @Published var latest: RoomFrame?
    @Published var lastVerdict = ""
    var onCue: ((Set<Int>) -> Void)?
    var onVerdict: ((String) -> Void)?
    var onNeedsLive: (() -> Void)?
    var onStopFeedback: (() -> Void)?
    private let tracker = VisualObjectTracker()
    private var pulse: Task<Void, Never>?
    private var request: Task<Void, Never>?
    private var generation = UUID()
    private var modelAt = Date.distantPast
    private var frameAt = Date.distantPast
    private var lastInference = Date.distantPast
    private var confidence = 0.0
    private var object = ""
    private var modelBusy = false
    private var exploring = false
    func captured() { cancel(); mode = .captured; message = "Room captured. Write the object name." }
    func cancel() {
        generation = UUID(); pulse?.cancel(); pulse = nil; request?.cancel(); request = nil
        modelBusy = false; box = nil; confidence = 0; latest = nil; mode = .idle; onStopFeedback?()
        Task { await tracker.clear() }
    }
    func suspendFeedback() { exploring = true; onStopFeedback?() }
    func resumeFeedback() { exploring = false; if mode == .guiding { startPulses() } }
    func searchRoom(_ frames: [RoomFrame], object: String) {
        cancel(); self.object = object; result = nil; lastVerdict = ""; exploring = false
        guard !BackendAccess.token.isEmpty else { mode = .unavailable; message = "AI not connected. Companion setup needed."; onVerdict?("AI not connected"); return }
        guard !frames.isEmpty, !object.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { message = "Record a room and write an object name first."; onVerdict?("record room first"); return }
        mode = .searching; message = "Searching recorded views"
        let session = generation
        request = Task {
            do {
                let response = try await AIClient.request(task: "find_room", text: object, images: FindingPolicy.samples(frames))
                guard session == generation, !Task.isCancelled else { return }
                result = response; message = response.text
                if response.found == true { beginLive(object) }
                else { mode = .uncertain; onVerdict?("not found") }
            } catch { guard session == generation else { return }; mode = .unavailable; message = error.localizedDescription; onVerdict?("unavailable") }
        }
    }
    func beginLive(_ object: String) {
        self.object = object; exploring = false
        guard !BackendAccess.token.isEmpty else { mode = .unavailable; message = "AI not connected. Companion setup needed."; onVerdict?("AI not connected"); return }
        mode = .guiding; message = "Looking for a fresh view. Pulses do not measure distance."; lastInference = .distantPast
        onNeedsLive?(); startPulses()
    }
    func ingest(_ frame: RoomFrame) {
        latest = frame
        guard mode == .guiding else { return }
        let session = generation
        Task {
            let tracked = try? await tracker.track(frame.jpeg)
            guard session == generation, mode == .guiding else { return }
            if let (box, score) = tracked { self.box = box; confidence = score; frameAt = frame.captured }
            else { self.box = nil; confidence = 0; if !exploring { onStopFeedback?() } }
        }
        guard !modelBusy, Date().timeIntervalSince(lastInference) >= 6 else { return }
        lastInference = Date(); modelBusy = true
        request = Task {
            defer { if session == generation { modelBusy = false } }
            do {
                let response = try await AIClient.request(task: "find", text: object, image: frame.jpeg)
                guard session == generation, mode == .guiding, !Task.isCancelled else { return }
                result = response; message = response.text
                if response.found == true, (response.confidence ?? 0) >= 0.7, let box = response.box, box.valid, Date().timeIntervalSince(frame.captured) < 3 {
                    try await tracker.seed(box, image: frame.jpeg)
                    guard session == generation, mode == .guiding else { return }
                    self.box = box; confidence = response.confidence ?? 0; modelAt = Date(); frameAt = frame.captured
                } else { self.box = nil; confidence = 0; if !exploring { onStopFeedback?() }; await tracker.clear() }
            } catch { guard session == generation else { return }; box = nil; confidence = 0; message = "Tracking unavailable. Pulses paused."; if !exploring { onStopFeedback?() }; await tracker.clear() }
        }
    }
    func check() {
        generation = UUID(); let session = generation
        request?.cancel(); pulse?.cancel(); onStopFeedback?(); box = nil; modelBusy = false
        guard !object.isEmpty, let frame = latest, Date().timeIntervalSince(frame.captured) >= 0, Date().timeIntervalSince(frame.captured) < 2.5 else {
            mode = .uncertain; message = "No fresh view is available."; lastVerdict = "uncertain"; onVerdict?("uncertain"); return
        }
        mode = .checking; message = "Checking the current view"
        request = Task {
            do {
                let response = try await AIClient.request(task: "verify", text: object, image: frame.jpeg)
                guard session == generation, !Task.isCancelled else { return }
                let verdict = FindingPolicy.verdict(response, age: Date().timeIntervalSince(frame.captured))
                lastVerdict = verdict; mode = Mode(rawValue: verdict) ?? .uncertain; message = response.text; result = response; onVerdict?(verdict)
            } catch { guard session == generation else { return }; mode = .uncertain; lastVerdict = "uncertain"; message = error.localizedDescription; onVerdict?("uncertain") }
        }
    }
    func reject() {
        generation = UUID(); request?.cancel(); pulse?.cancel(); onStopFeedback?(); box = nil; confidence = 0; modelBusy = false
        mode = .no; lastVerdict = "no"; message = "Rejected by you. Resume or rescan to try again."; onVerdict?("no")
        Task { await tracker.clear() }
    }
    private func startPulses() {
        pulse?.cancel()
        pulse = Task {
            while !Task.isCancelled && mode == .guiding {
                if !exploring, FindingPolicy.canPulse(frameAge: Date().timeIntervalSince(frameAt), semanticAge: Date().timeIntervalSince(modelAt), confidence: confidence, box: box), let box {
                    onCue?(box.horizontal == "left" ? [1] : box.horizontal == "right" ? [1,2] : [1,2,3])
                }
                let slot = UserDefaults.standard.double(forKey: "slotDuration")
                do { try await Task.sleep(for: .seconds(max(2.5, (slot > 0 ? slot : 0.3) * 8 + 0.3))) } catch { return }
            }
        }
    }
}
