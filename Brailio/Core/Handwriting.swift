import SwiftUI
import PencilKit
import Vision

@MainActor
final class Handwriting: ObservableObject {
    @Published var strokes: [[CGPoint]] = []
    @Published var recognizing = false
    @Published var message = "Write a word"
    @Published var preview = ""
    @Published var committing = false
    @Published var lastRecognition = ""
    var prefersDigits = false
    private var pending: Task<Void, Never>?
    private var revision = UUID()
    var onRecognized: ((String) -> Void)?
    var onBegin: (() -> Void)?
    var onPreview: ((String) -> Void)?
    var onFailure: (() -> Void)?
    func begin(_ point: CGPoint) {
        guard !committing else { return }
        pending?.cancel(); revision = UUID(); recognizing = false
        message = "Writing"; preview = ""
        guard strokes.reduce(0, { $0 + $1.count }) < 20_000 else { message = "Use Space or Done to finish this word"; return }
        strokes.append([point]); onBegin?()
    }
    func move(_ points: [CGPoint]) {
        guard !strokes.isEmpty else { return }
        strokes[strokes.count - 1].append(contentsOf: points.prefix(256))
    }
    func lift() {
        let request = revision
        pending?.cancel()
        pending = Task {
            do { try await Task.sleep(for: .milliseconds(1100)) } catch { return }
            guard request == revision, !Task.isCancelled else { return }
            await recognize(request, commit: false)
        }
    }
    func finishNow() {
        guard !committing else { return }
        pending?.cancel(); committing = true
        let request = revision
        pending = Task { await recognize(request, commit: true) }
    }
    func clear() { pending?.cancel(); revision = UUID(); strokes = []; recognizing = false; committing = false; preview = ""; message = "Write a word" }
    private func recognize(_ request: UUID, commit: Bool) async {
        let ink = strokes.filter { !$0.isEmpty }
        guard !ink.isEmpty else { committing = false; return }
        recognizing = true; message = "Recognizing"
        let text = await Self.read(ink, digitsOnly: prefersDigits)
        guard request == revision, !Task.isCancelled else { return }
        recognizing = false; committing = false
        guard let text = Self.accepted(text), !text.isEmpty else {
            message = "Unclear. Keep writing, clear, or use Braille."; if commit { onFailure?() }; return
        }
        lastRecognition = text; message = text; preview = text
        if commit { strokes = []; preview = ""; revision = UUID(); onRecognized?(text) }
        else { onPreview?(text) }
    }
    static func accepted(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty, result.count <= 40, Braille.translate(result).unsupported.isEmpty else { return nil }
        return result
    }
    static func drawing(_ strokes: [[CGPoint]]) -> PKDrawing {
        let ink = PKInk(.pen, color: .black)
        let paths = strokes.filter { !$0.isEmpty }.enumerated().map { strokeIndex, raw in
            let points = raw.count == 1 ? [raw[0], CGPoint(x: raw[0].x + 0.2, y: raw[0].y + 0.2)] : raw
            let controls = points.enumerated().map { index, point in
                PKStrokePoint(location: point, timeOffset: Double(index) * 0.015, size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(ink: ink, path: PKStrokePath(controlPoints: controls, creationDate: Date(timeIntervalSince1970: Double(strokeIndex) * 2)))
        }
        return PKDrawing(strokes: paths)
    }
    static func read(_ strokes: [[CGPoint]], digitsOnly: Bool = false) async -> String? {
        let drawing = drawing(strokes)
        if #available(iOS 27.0, *) {
            let recognizer = PKStrokeRecognizer(preferredLanguages: [Locale.Language(identifier: "en")])
            await recognizer.updateDrawing(drawing)
            if let text = await recognizer.recognizedText(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        }
        // Older devices use local image OCR. Single-letter accuracy can be lower.
        let bounds = drawing.bounds.insetBy(dx: -30, dy: -30)
        guard !bounds.isEmpty else { return nil }
        let image = drawing.image(from: bounds, scale: 3)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let opaque = UIGraphicsImageRenderer(size: image.size, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: image.size)); image.draw(at: .zero)
        }
        guard let data = opaque.pngData() else { return nil }
        let ocr = await Task.detached(priority: .userInitiated) {
            do {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate; request.recognitionLanguages = ["en-US"]; request.usesLanguageCorrection = true
                try VNImageRequestHandler(data: data).perform([request])
                return request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator:" ")
            } catch { return nil }
        }.value
        if let ocr, accepted(ocr) != nil { return ocr }
        return await Task.detached(priority: .userInitiated) { InkWordMatcher.recognize(strokes, digitsOnly: digitsOnly) }.value
    }
}

struct FingerInkCanvas: UIViewRepresentable {
    @ObservedObject var ink: Handwriting
    func makeUIView(context: Context) -> InkView {
        let view = InkView(); view.model = ink
        view.isAccessibilityElement = true; view.accessibilityLabel = "Handwriting canvas"
        view.accessibilityIdentifier = "handwritingCanvas"; view.accessibilityTraits = [.allowsDirectInteraction]
        view.backgroundColor = .clear
        return view
    }
    func updateUIView(_ view: InkView, context: Context) { view.model = ink; view.setNeedsDisplay() }
    final class InkView: UIView {
        weak var model: Handwriting?
        private var acceptingTouch = false
        override func draw(_ rect: CGRect) {
            guard let context = UIGraphicsGetCurrentContext(), let model else { return }
            let color = UIColor { $0.userInterfaceStyle == .dark ? .white : .black }
            context.setStrokeColor(color.cgColor); context.setLineWidth(5); context.setLineCap(.round); context.setLineJoin(.round)
            for stroke in model.strokes {
                guard let first = stroke.first else { continue }
                context.beginPath(); context.move(to: first)
                for point in stroke.dropFirst() { context.addLine(to: point) }
                context.strokePath()
            }
        }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            acceptingTouch = model?.committing == false
            guard acceptingTouch, touches.count == 1, let touch = touches.first else { return }
            model?.begin(touch.location(in: self)); setNeedsDisplay()
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard acceptingTouch, let touch = touches.first else { return }
            model?.move((event?.coalescedTouches(for: touch) ?? [touch]).map { $0.location(in: self) }); setNeedsDisplay()
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { if acceptingTouch { model?.lift() }; acceptingTouch = false }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { model?.clear() }
    }
}
