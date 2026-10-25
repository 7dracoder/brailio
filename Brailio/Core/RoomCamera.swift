import SwiftUI
import ARKit
import CoreImage
import simd

struct RoomFrame: Equatable {
    let id = UUID()
    let jpeg: Data
    let captured: Date
}
struct SpatialFeature {
    let point: SIMD3<Float>
    let image: CGPoint
}
struct SpatialSnapshot {
    let frame: RoomFrame
    let features: [SpatialFeature]
    func position(in box: ObjectBox) -> SIMD3<Float>? {
        guard box.valid else { return nil }
        let center = CGPoint(x: box.x + box.width / 2, y: box.y + box.height / 2)
        let candidates = features.filter { $0.image.x >= box.x && $0.image.x <= box.x + box.width && $0.image.y >= box.y && $0.image.y <= box.y + box.height }
            .sorted { hypot($0.image.x-center.x, $0.image.y-center.y) < hypot($1.image.x-center.x, $1.image.y-center.y) }
        guard let first = candidates.first, hypot(first.image.x-center.x, first.image.y-center.y) < 0.15 else { return nil }
        // Sparse camera features estimate a surface position, not an exact object center.
        let cluster = candidates.prefix(8).filter { simd_distance($0.point, first.point) < 0.25 }
        guard cluster.count >= 3 else { return nil }
        return cluster.reduce(SIMD3<Float>.zero) { $0 + $1.point } / Float(cluster.count)
    }
}
struct RoomPin: Codable, Identifiable {
    let id: UUID
    let name: String
    let x: Float
    let y: Float
    let z: Float
    var point: SIMD3<Float> { SIMD3(x,y,z) }
}
enum PinGuidance {
    static func available(age: TimeInterval, normal: Bool, localized: Bool) -> Bool { age >= 0 && age < 2 && normal && localized }
    static func cue(camera: simd_float4x4, target: SIMD3<Float>) -> String? {
        guard [target.x,target.y,target.z].allSatisfy(\.isFinite), camera.determinant.isFinite, abs(camera.determinant) > 0.0001 else { return nil }
        let local = camera.inverse * SIMD4(target.x,target.y,target.z,1)
        if simd_length(SIMD3(local.x, local.y, local.z)) < 0.8 { return "near saved position" }
        if local.z > 0 { return "behind" }
        let angle = atan2(local.x, -local.z)
        return angle < -0.22 ? "left" : angle > 0.22 ? "right" : "ahead"
    }
}

@MainActor final class RoomCamera: NSObject, ObservableObject, @preconcurrency ARSessionDelegate {
    let session = ARSession()
    @Published var running = false
    @Published var recording = false // scan samples only; never an encoded video
    @Published var roomFrames: [RoomFrame] = []
    @Published var scanVersion = 0
    @Published var error: String?
    @Published var message = "Hold center to map room. No video is saved."
    @Published var pins: [RoomPin] = []
    @Published var guiding = false
    @Published var searching = false
    var onCue: ((Set<Int>) -> Void)?
    var onVerdict: ((String) -> Void)?
    var onStopFeedback: (() -> Void)?
    private var snapshots: [SpatialSnapshot] = []
    private var target: RoomPin?
    private var localized: Set<UUID> = []
    private var lastSample = Date.distantPast
    private var lastCue = Date.distantPast
    private var started = Date.distantPast
    private var exploring = false
    private var loaded = false
    private var search: Task<Void, Never>?
    private var generation = UUID()
    private let context = CIContext()
    private var directory: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RoomMap") }
    override init() {
        super.init()
        // Remove only legacy room movies from earlier app versions.
        for url in (try? FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil)) ?? [] where url.lastPathComponent.hasPrefix("brailio-room-") && url.pathExtension == "mov" { try? FileManager.default.removeItem(at: url) }
        session.delegate = self; session.delegateQueue = .main
        if let data = try? Data(contentsOf: directory.appendingPathComponent("pins.json")), let saved = try? JSONDecoder().decode([RoomPin].self, from: data) { pins = saved }
    }
    func start() {
        guard ARWorldTrackingConfiguration.isSupported else { error = "Room position tracking is unavailable on this device."; return }
        guard !running else { return }
        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized { runTracking(); return }
        let request = generation
        AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
            Task { @MainActor in
                guard let self, request == self.generation else { return }
                guard allowed else { self.error = "Allow Camera access in iPhone Settings."; return }
                self.runTracking()
            }
        }
    }
    private func runTracking() {
        let config = ARWorldTrackingConfiguration(); config.planeDetection = [.horizontal, .vertical]
        if !loaded {
            loaded = true
            if let data = try? Data(contentsOf: directory.appendingPathComponent("world.map")), let map = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) { config.initialWorldMap = map }
        }
        session.run(config); running = true; error = nil
    }

    func recordRoom() {
        cancelSearch(); guiding = false; target = nil; snapshots = []; roomFrames = []; lastSample = .distantPast; started = Date(); recording = true; message = "Mapping room. Release to write object name."; start()
    }
    func finishRoom() {
        guard recording else { return }
        recording = false; scanVersion += 1; message = "Room sampled. Write an object name."
    }
    func stop() { generation = UUID(); cancelSearch(); recording = false; guiding = false; session.pause(); running = false; onStopFeedback?() }
    func discardRoom() { stop(); snapshots = []; roomFrames = []; target = nil; message = "Room scan cleared. Saved positions remain." }
    func deletePins() { discardRoom(); pins = []; localized = []; loaded = false; try? FileManager.default.removeItem(at: directory); if ARWorldTrackingConfiguration.isSupported { session.run(ARWorldTrackingConfiguration(), options: [.resetTracking, .removeExistingAnchors]); session.pause() } }
    private func cancelSearch() { generation = UUID(); search?.cancel(); search = nil; searching = false }
    func suspendFeedback() { exploring = true; onStopFeedback?() }
    func resumeFeedback() { exploring = false }
    func find(_ name: String) {
        cancelSearch(); target = nil; guiding = false; exploring = false; onStopFeedback?()
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
        start()
        guard !query.isEmpty else { message = "Write an object name first."; onVerdict?("empty"); return }
        if snapshots.isEmpty, let pin = pins.first(where: { $0.name.caseInsensitiveCompare(query) == .orderedSame }) { target = pin; guiding = true; message = "Returning to saved position. Keep camera uncovered for tracking."; start(); return }
        guard !snapshots.isEmpty else { message = "No saved position. Map the room or mark the object first."; onVerdict?("scan first"); return }
        guard DemoAccess.configured || !BackendAccess.token.isEmpty else { message = "Connect Baseten in Settings, AI connection. Mark center also works without AI."; onVerdict?("AI not connected"); return }
        let views = sampledSnapshots(); searching = true; message = "Finding object in scan snapshots"; let id = generation
        search = Task {
            do {
                let response = try await AIClient.request(task: "find_room", text: query, images: views.map { $0.frame.jpeg })
                guard id == generation, !Task.isCancelled else { return }
                searching = false
                guard response.found == true, let index = response.evidenceFrame, views.indices.contains(index), let box = response.box, let point = views[index].position(in: box) else { message = "Cannot place a reliable room position. Scan closer or mark center."; onVerdict?("uncertain"); return }
                savePin(query, point: point)
            } catch { guard id == generation else { return }; searching = false; message = error.localizedDescription; onVerdict?("unavailable") }
        }
    }
    private func sampledSnapshots() -> [SpatialSnapshot] {
        if snapshots.count <= 8 { return snapshots }
        return (0..<8).map { snapshots[Int(Double($0) * Double(snapshots.count - 1) / 7)] }
    }
    func markCenter(_ name: String) {
        guard let snapshot = snapshots.last, let point = snapshot.position(in: ObjectBox(x: 0.35, y: 0.35, width: 0.3, height: 0.3)), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { message = "Scan with the object centered on a textured surface first."; onVerdict?("uncertain"); return }
        savePin(name, point: point)
    }
    private func savePin(_ name: String, point: SIMD3<Float>) {
        start()
        var matrix = matrix_identity_float4x4; matrix.columns.3 = SIMD4(point.x,point.y,point.z,1)
        let anchor = ARAnchor(name: name, transform: matrix); session.add(anchor: anchor)
        let pin = RoomPin(id: anchor.identifier, name: name, x: point.x, y: point.y, z: point.z)
        let id = generation; searching = true; message = "Saving estimated room position"
        session.getCurrentWorldMap { [weak self] map, error in
            Task { @MainActor in
                guard let self, id == self.generation else { return }
                self.searching = false
                guard let map, error == nil, map.anchors.contains(where: { $0.identifier == pin.id }) else { self.message = "Map could not be saved. Slowly scan more room detail."; self.onVerdict?("uncertain"); self.session.remove(anchor: anchor); return }
                do {
                    let values = self.pins.filter { $0.name.caseInsensitiveCompare(name) != .orderedSame } + [pin]
                    let mapData = try NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true)
                    try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
                    try mapData.write(to: self.directory.appendingPathComponent("world.map"), options: [.atomic, .completeFileProtection])
                    try JSONEncoder().encode(values).write(to: self.directory.appendingPathComponent("pins.json"), options: [.atomic, .completeFileProtection])
                    self.pins = values; self.localized.insert(pin.id); self.target = pin; self.guiding = true; self.exploring = false
                    let slot = UserDefaults.standard.double(forKey: "slotDuration")
                    self.lastCue = Date().addingTimeInterval(max(0, 5 * 8 * (slot > 0 ? slot : 0.3) - 3))
                    self.snapshots = []; self.roomFrames = []; self.message = "Saved approximate position. Keep camera uncovered. Object may have moved."; self.onVerdict?("saved")
                } catch { self.message = error.localizedDescription; self.onVerdict?("unavailable") }
            }
        }
    }
    func check() {
        exploring = true; onStopFeedback?()
        guard let target, let frame = session.currentFrame, running, PinGuidance.available(age: CACurrentMediaTime() - frame.timestamp, normal: frame.camera.trackingState == .normal, localized: localized.contains(target.id)) else { message = "Room position is not localized."; onVerdict?("uncertain"); return }
        let distance = simd_distance(SIMD3(frame.camera.transform.columns.3.x, frame.camera.transform.columns.3.y, frame.camera.transform.columns.3.z), target.point)
        let near = distance < 0.8
        message = near ? "Yes, near the saved position. Object identity is not checked." : "No, not near the saved position."
        onVerdict?(near ? "yes" : "no")
    }
    func reject() { guiding = false; target = nil; onStopFeedback?(); message = "Wrong object. Saved positions do not follow moving objects. Rescan or mark again."; onVerdict?("no") }
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) { for anchor in anchors where pins.contains(where: { $0.id == anchor.identifier }) { localized.insert(anchor.identifier) } }
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        if recording, Date().timeIntervalSince(started) >= 30 { finishRoom() }
        guard frame.camera.trackingState == .normal else { if guiding { message = "Tracking paused. Slowly face the scanned room."; onStopFeedback?() }; return }
        if recording, Date().timeIntervalSince(lastSample) >= 1 {
            lastSample = Date()
            let original = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
            let scale = min(1, 768 / max(original.extent.width, original.extent.height))
            let image = original.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            if let cg = context.createCGImage(image, from: image.extent), let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.5) {
                let viewport = CGSize(width: image.extent.width, height: image.extent.height)
                let features = (frame.rawFeaturePoints?.points ?? []).compactMap { point -> SpatialFeature? in
                    let relative = frame.camera.transform.inverse * SIMD4(point.x,point.y,point.z,1)
                    guard relative.z < -0.1 else { return nil }
                    let projected = frame.camera.projectPoint(point, orientation: .portrait, viewportSize: viewport)
                    let normalized = CGPoint(x: projected.x / viewport.width, y: projected.y / viewport.height)
                    guard (0...1).contains(normalized.x), (0...1).contains(normalized.y) else { return nil }
                    return SpatialFeature(point: point, image: normalized)
                }
                let sample = RoomFrame(jpeg: jpeg, captured: Date())
                snapshots.append(SpatialSnapshot(frame: sample, features: features)); roomFrames.append(sample)
                if snapshots.count > 30 { snapshots.removeFirst(); roomFrames.removeFirst() }
            }
        }
        guard guiding, !exploring, let target, Date().timeIntervalSince(lastCue) >= max(3, UserDefaults.standard.double(forKey: "slotDuration") * 8 + 0.3) else { return }
        guard PinGuidance.available(age: CACurrentMediaTime() - frame.timestamp, normal: frame.camera.trackingState == .normal, localized: localized.contains(target.id)) else { message = "Relocalize in the saved room before guidance."; onStopFeedback?(); return }
        lastCue = Date()
        guard let cue = PinGuidance.cue(camera: frame.camera.transform, target: target.point) else { return }
        message = cue + ". Saved position only. No obstacle detection."
        onCue?(cue == "left" ? [1] : cue == "right" ? [1,2] : cue == "ahead" ? [1,2,3] : cue == "behind" ? [1,2,3,4] : [1,2,3,4,5])
    }
    func sessionWasInterrupted(_ session: ARSession) { onStopFeedback?(); message = "Tracking interrupted. Reopen Find and face the saved room." }
    func session(_ session: ARSession, didFailWithError error: Error) { self.error = error.localizedDescription; guiding = false; onStopFeedback?() }
    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { true }
}
struct RoomHoldPanel: UIViewRepresentable {
    let session: ARSession
    let recording: Bool
    let guiding: Bool
    let onHold: () -> Void
    let onRelease: () -> Void
    let onCheck: () -> Void
    func makeUIView(context: Context) -> HoldView { let view = HoldView(); view.backgroundColor = .secondarySystemBackground; return view }
    func updateUIView(_ view: HoldView, context: Context) {
        view.scene.session = session; view.scene.isHidden = !recording; view.recording = recording; view.guiding = guiding
        view.onHold = onHold; view.onRelease = onRelease; view.onCheck = onCheck
        view.title.text = recording ? "Release to finish" : guiding ? "Tap for position" : "Hold to scan"
        view.accessibilityLabel = view.title.text; view.accessibilityIdentifier = "roomHoldControl"
    }
    final class HoldView: UIView {
        let scene = ARSCNView()
        let title = UILabel()
        var recording = false
        var guiding = false
        var onHold: (() -> Void)?
        var onRelease: (() -> Void)?
        var onCheck: (() -> Void)?
        private var hold: Task<Void, Never>?
        private var held = false
        private var armed = false
        override init(frame: CGRect) {
            super.init(frame: frame); addSubview(scene)
            title.textAlignment = .center; title.font = .preferredFont(forTextStyle: .title2); title.adjustsFontForContentSizeCategory = true
            title.textColor = .white; title.backgroundColor = UIColor(red: 0.1, green: 0.29, blue: 0.24, alpha: 0.95); title.numberOfLines = 2
            addSubview(title); isAccessibilityElement = true; accessibilityTraits = .button
            layer.cornerRadius = 24; clipsToBounds = true
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layoutSubviews() {
            super.layoutSubviews(); scene.frame = bounds
            let width = min(bounds.width - 32, 240); title.frame = CGRect(x: (bounds.width - width) / 2, y: (bounds.height - 120) / 2, width: width, height: 120); title.layer.cornerRadius = 28; title.clipsToBounds = true
        }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            held = false; hold?.cancel()
            armed = touches.first.map { title.frame.contains($0.location(in: self)) } ?? false
            guard armed else { return }
            hold = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
                guard let self, !Task.isCancelled else { return }; held = true; onHold?()
            }
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { hold?.cancel(); if held { onRelease?() } else if guiding { onCheck?() } }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { hold?.cancel(); if held { onRelease?() } }
        override func accessibilityActivate() -> Bool { if recording { onRelease?() } else if guiding { onCheck?() } else { onHold?() }; return true }
        deinit { hold?.cancel() }
    }
}
