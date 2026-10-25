import XCTest
import PDFKit
import simd
@testable import Brailio

final class DocumentsAndPinsTests: XCTestCase {
    private func directory() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }
    @MainActor func testFullLengthTextAndReadingBookmarkSurviveRelaunch() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Long book.txt")
        try String(repeating: "hello book ", count: 3000).write(to: file, atomically: true, encoding: .utf8)
        let library = DocumentLibrary(directory: root.appendingPathComponent("library"))
        try await library.importFile(file)
        XCTAssertGreaterThan(library.current!.pages, 10)
        library.setPage(7); library.bookmark(19)
        let restored = DocumentLibrary(directory: root.appendingPathComponent("library"))
        restored.select(library.active!)
        XCTAssertEqual(restored.page, 7); XCTAssertEqual(restored.cell, 19)
        let text = try await restored.pageText()
        XCTAssertFalse(text.text.isEmpty); XCTAssertTrue(Braille.translate(text.text).unsupported.isEmpty)
        XCTAssertEqual(restored.matching("LONG").count, 1)
        restored.deleteAll(); XCTAssertTrue(restored.documents.isEmpty)
    }
    @MainActor func testBookmarkOffsetsDoNotCrossTactileModes() async throws {
        let defaults = UserDefaults.standard, old = defaults.object(forKey: "tactileMode")
        defer { if let old { defaults.set(old, forKey: "tactileMode") } else { defaults.removeObject(forKey: "tactileMode") } }
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("book.txt")
        try String(repeating: "hello ", count: 1000).write(to: file, atomically: true, encoding: .utf8)
        defaults.set("braille", forKey: "tactileMode")
        let library = DocumentLibrary(directory: root.appendingPathComponent("library")); try await library.importFile(file)
        let id = try XCTUnwrap(library.active)
        library.setPage(1); library.bookmark(8)
        defaults.set("morse", forKey: "tactileMode")
        library.select(id)
        XCTAssertEqual(library.page, 1); XCTAssertEqual(library.cell, 0)
        library.bookmark(3)
        let restored = DocumentLibrary(directory: root.appendingPathComponent("library")); restored.select(id)
        XCTAssertEqual(restored.page, 1); XCTAssertEqual(restored.cell, 3)
        defaults.set("braille", forKey: "tactileMode"); restored.select(id)
        XCTAssertEqual(restored.cell, 0)
    }
    @MainActor func testPDFExtractsEachPageWithoutConcatenatingWholeBook() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Book.pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x:0,y:0,width:600,height:800))
        let data = renderer.pdfData { context in
            for text in ["First page", "Second page"] { context.beginPage(); (text as NSString).draw(at: CGPoint(x:40,y:40), withAttributes: [.font:UIFont.systemFont(ofSize:24)]) }
        }
        try data.write(to: file)
        let library = DocumentLibrary(directory: root.appendingPathComponent("library")); try await library.importFile(file)
        XCTAssertEqual(library.current?.pages, 2)
        let first = try await library.pageText(); XCTAssertTrue(first.text.contains("First page")); XCTAssertFalse(first.text.contains("Second"))
        library.setPage(1); let second = try await library.pageText(); XCTAssertTrue(second.text.contains("Second page"))
    }
    @MainActor func testImageOnlyPDFUsesOnDeviceOCR() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 1000)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x:0,y:0,width:800,height:1000))
            ("HELLO BOOK" as NSString).draw(at: CGPoint(x:60,y:100), withAttributes: [.font:UIFont.systemFont(ofSize:60), .foregroundColor:UIColor.black])
        }
        let pdf = PDFDocument(); pdf.insert(try XCTUnwrap(PDFPage(image: image)), at:0)
        let url = root.appendingPathComponent("Scanned.pdf"); XCTAssertTrue(pdf.write(to:url))
        let library = DocumentLibrary(directory:root.appendingPathComponent("library")); try await library.importFile(url)
        let text = try await library.pageText(); XCTAssertTrue(text.text.uppercased().contains("HELLO BOOK"))
    }
    func testUnsupportedDocumentSymbolsAreAnnouncedInsteadOfDropped() {
        let result = ReadablePage.prepare("Café ﬁ 50% 🙂")
        XCTAssertTrue(result.text.contains("Cafe fi 50 percent")); XCTAssertTrue(result.text.contains("unsupported symbol"))
        XCTAssertEqual(result.replacements, 1); XCTAssertTrue(Braille.translate(result.text).unsupported.isEmpty)
    }
    func testSavedPinDirectionsUsePhonePoseAndHandleBehind() {
        let camera = matrix_identity_float4x4
        XCTAssertEqual(PinGuidance.cue(camera: camera, target: SIMD3(-2,0,-2)), "left")
        XCTAssertEqual(PinGuidance.cue(camera: camera, target: SIMD3(2,0,-2)), "right")
        XCTAssertEqual(PinGuidance.cue(camera: camera, target: SIMD3(0,0,-2)), "ahead")
        XCTAssertEqual(PinGuidance.cue(camera: camera, target: SIMD3(0,0,2)), "behind")
        XCTAssertEqual(PinGuidance.cue(camera: camera, target: SIMD3(0.1,0,-0.3)), "near saved position")
        XCTAssertNil(PinGuidance.cue(camera: camera, target: SIMD3(.nan,0,0)))
    }
    func testSpatialPlacementRequiresFeaturesInsideObjectBox() {
        let frame = RoomFrame(jpeg:Data(),captured:Date())
        let box = ObjectBox(x:0.4,y:0.4,width:0.2,height:0.2)
        XCTAssertNil(SpatialSnapshot(frame:frame,features:[]).position(in:box))
        let features = (0..<4).map { i in SpatialFeature(point: SIMD3(Float(i) * 0.02,0,-2), image:CGPoint(x:0.5 + Double(i) * 0.01,y:0.5)) }
        XCTAssertNotNil(SpatialSnapshot(frame:frame,features:features).position(in:box))
        XCTAssertNil(SpatialSnapshot(frame:frame,features:features).position(in:ObjectBox(x:0,y:0,width:0.1,height:0.1)))
    }
    @MainActor func testPositionCheckWithoutLocalizedMapIsUncertain() {
        let room = RoomCamera(); var verdict = ""; room.onVerdict = { verdict = $0 }; room.check()
        XCTAssertEqual(verdict, "uncertain"); XCTAssertFalse(room.guiding)
    }
    func testTrackingGateRejectsStaleUnlocalizedAndLimitedFrames() {
        XCTAssertTrue(PinGuidance.available(age: 0.1, normal: true, localized: true))
        XCTAssertFalse(PinGuidance.available(age: 3, normal: true, localized: true))
        XCTAssertFalse(PinGuidance.available(age: 0.1, normal: false, localized: true))
        XCTAssertFalse(PinGuidance.available(age: 0.1, normal: true, localized: false))
        XCTAssertFalse(PinGuidance.available(age: -1, normal: true, localized: true))
    }
    @MainActor func testReaderFinishesNaturallyForBookPageChaining() async {
        let old = UserDefaults.standard.object(forKey: "slotDuration")
        UserDefaults.standard.set(0.001, forKey: "slotDuration")
        defer { if let old { UserDefaults.standard.set(old, forKey: "slotDuration") } else { UserDefaults.standard.removeObject(forKey: "slotDuration") } }
        let reader = HapticReader(); let finished = expectation(description: "Natural page completion")
        reader.onFinished = { finished.fulfill() }; reader.load(Braille.translate("ab").cells); reader.play()
        await fulfillment(of: [finished], timeout: 4)
        XCTAssertFalse(reader.isPlaying); XCTAssertEqual(reader.index, 1)
    }

}
