import XCTest
@testable import Brailio

/// Explicit opt-in because this check depends on public Internet Archive availability.
final class LiveDocumentIntegrationTests: XCTestCase {
    @MainActor func testPublicCatalogSearchAndPDFDownload() async throws {
        guard ProcessInfo.processInfo.environment["BRAILIO_LIVE_DOCUMENTS"] == "1" else { throw XCTSkip("Set BRAILIO_LIVE_DOCUMENTS=1 in the test runner to check public network services") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = DocumentLibrary(directory: root)
        let searched = expectation(description: "Public catalog search")
        library.searchOnline("Alice adventures") { searched.fulfill() }
        await fulfillment(of: [searched], timeout: 60)
        XCTAssertFalse(library.results.isEmpty, library.status)
        // Small public PDF fixture exercises archive metadata resolution and the real download path.
        let item = OnlineDocument(identifier: "gov.uscourts.ilnb.853276", title: "Public PDF integration fixture")
        try await library.download(item)
        XCTAssertNotNil(library.current); XCTAssertGreaterThan(library.current?.pages ?? 0, 0)
        let text = try await library.pageText()
        XCTAssertFalse(text.text.isEmpty); XCTAssertTrue(Braille.translate(text.text).unsupported.isEmpty)
    }
}
