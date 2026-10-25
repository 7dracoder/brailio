import XCTest
import PencilKit
@testable import Brailio

final class BrailleTests: XCTestCase {
    func testAlphabetHas26UniquePatterns() {
        XCTAssertEqual(Braille.alphabet.count, 26)
        XCTAssertEqual(Set(Braille.alphabet.map { $0.1 }).count, 26)
        XCTAssertTrue(Braille.alphabet.allSatisfy { $0.1.allSatisfy { (1...6).contains($0) } })
    }
    func testKnownPatternsAndUnicode() {
        let result = Braille.translate("abc w")
        XCTAssertEqual(result.cells.map(\.glyph).joined(), "⠁⠃⠉⠀⠺")
    }
    func testCapitalAndNumbers() {
        let result = Braille.translate("A 10")
        XCTAssertEqual(result.cells.map(\.dots), [[6], [1], [], [3,4,5,6], [1], [2,4,5]])
    }
    func testNumericToLetterTransition() {
        XCTAssertEqual(Braille.translate("1a").cells.map(\.label), ["Number sign", "1", "Letter sign", "a"])
    }
    func testUnsupportedIsExplicit() {
        let result = Braille.translate("hi🙂é🙂")
        XCTAssertEqual(result.unsupported, ["🙂", "é"])
        XCTAssertEqual(result.cells.count, 2)
    }
    func testPunctuationAndWhitespace() {
        let result = Braille.translate("a\nb’c!")
        XCTAssertTrue(result.unsupported.isEmpty)
        XCTAssertEqual(result.cells[1].label, "Space")
        XCTAssertEqual(result.cells[3].dots, [3])
    }
    func testEmptyText() { XCTAssertTrue(Braille.translate("").cells.isEmpty) }
}

final class WritingAndCueTests: XCTestCase {
    func testDotKeyboardRoundTripsAlphabet() {
        for (letter, dots) in Braille.alphabet {
            XCTAssertEqual(BrailleInput.character(for: dots, numbers: false, capitals: false), letter)
            XCTAssertEqual(BrailleInput.character(for: dots, numbers: false, capitals: true), letter.uppercased())
        }
        XCTAssertNil(BrailleInput.character(for: [], numbers: false, capitals: false))
    }
    func testNumberKeyboardRejectsNonDigitPatterns() {
        XCTAssertEqual(BrailleInput.character(for: [1], numbers: true, capitals: false), "1")
        XCTAssertEqual(BrailleInput.character(for: [2,4,5], numbers: true, capitals: false), "0")
        XCTAssertNil(BrailleInput.character(for: [1,3], numbers: true, capitals: false))
    }
    func testCuesAreDistinctAndInstructionsClassify() {
        XCTAssertEqual(Set(TactileCue.allCases.map(\.dots)).count, 4)
        XCTAssertEqual(TactileCue.instruction("Turn left onto Main Street"), .left)
        XCTAssertEqual(TactileCue.instruction("Turn right"), .right)
        XCTAssertEqual(TactileCue.instruction("Continue along Main Street"), .straight)
    }
}

final class HandwritingAndFindingTests: XCTestCase {
    @MainActor func testHandwritingRejectsUnsupportedAndOverlongResults() {
        XCTAssertEqual(Handwriting.accepted(" a \n"), "a")
        XCTAssertNil(Handwriting.accepted("🙂"))
        XCTAssertNil(Handwriting.accepted(String(repeating: "a", count: 41)))
        XCTAssertNil(Handwriting.accepted(""))
    }
    func testGuidanceNeverPulsesForLostOrStaleEvidence() {
        let box = ObjectBox(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        XCTAssertTrue(FindingPolicy.canPulse(frameAge: 1, semanticAge: 5, confidence: 0.8, box: box))
        XCTAssertFalse(FindingPolicy.canPulse(frameAge: 3, semanticAge: 5, confidence: 0.8, box: box))
        XCTAssertFalse(FindingPolicy.canPulse(frameAge: 1, semanticAge: 13, confidence: 0.8, box: box))
        XCTAssertFalse(FindingPolicy.canPulse(frameAge: 1, semanticAge: 5, confidence: 0.5, box: box))
        XCTAssertFalse(FindingPolicy.canPulse(frameAge: 1, semanticAge: 5, confidence: 0.9, box: nil))
        XCTAssertFalse(ObjectBox(x: 0.9, y: 0, width: 0.3, height: 0.1).valid)
    }
    func testRoomSamplingPreservesFirstAndLastViews() {
        let frames = (0..<30).map { RoomFrame(jpeg: Data([$0]), captured: Date()) }
        let result = FindingPolicy.samples(frames)
        XCTAssertEqual(result.count, 8)
        XCTAssertEqual(result.first, Data([0]))
        XCTAssertEqual(result.last, Data([29]))
    }
    func testVerificationRequiresRecentConfidentEvidence() throws {
        let yes = try JSONDecoder().decode(AIResult.self, from: Data("{\"text\":\"Possible keys.\",\"verdict\":\"yes\",\"confidence\":0.95}".utf8))
        XCTAssertEqual(FindingPolicy.verdict(yes, age: 2), "yes")
        XCTAssertEqual(FindingPolicy.verdict(yes, age: 10), "uncertain")
    }
    @MainActor func testOnDeviceRecognizesDrawnH() async throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("Native ink recognition needs iOS 27") }
        func line(_ a: CGPoint, _ b: CGPoint) -> [CGPoint] { (0...30).map { i in let t=Double(i)/30; return CGPoint(x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t) } }
        let strokes = [line(CGPoint(x:80,y:60),CGPoint(x:80,y:260)),line(CGPoint(x:200,y:60),CGPoint(x:200,y:260)),line(CGPoint(x:80,y:160),CGPoint(x:200,y:160))]
        let drawing = Handwriting.drawing(strokes)
        XCTAssertFalse(drawing.bounds.isEmpty)
        let image = drawing.image(from: drawing.bounds.insetBy(dx: -30, dy: -30), scale: 3)
        let attachment = XCTAttachment(image: image); attachment.name = "Synthetic-H-Ink"; attachment.lifetime = .keepAlways; add(attachment)
        let text = await Handwriting.read(strokes)
        XCTAssertEqual(text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), "h")
    }
    @MainActor func testRecognitionPipelineHandlesNarrowDrawnA() async {
        func line(_ a: CGPoint, _ b: CGPoint) -> [CGPoint] { (0...30).map { i in let t=Double(i)/30; return CGPoint(x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t) } }
        let strokes = [line(CGPoint(x:70,y:250),CGPoint(x:140,y:60)) + line(CGPoint(x:140,y:60),CGPoint(x:210,y:250)),line(CGPoint(x:98,y:175),CGPoint(x:182,y:175))]
        let text = await Handwriting.read(strokes)
        XCTAssertEqual(text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), "a")
    }

    @MainActor func testCheckWithoutFreshViewStopsFeedbackAndReturnsUncertain() {
        let finder = ObjectFinding(); var stops = 0
        finder.onStopFeedback = { stops += 1 }
        finder.check()
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(finder.mode, .uncertain)
        XCTAssertEqual(finder.lastVerdict, "uncertain")
    }

}
