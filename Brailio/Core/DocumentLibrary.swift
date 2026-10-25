import Foundation
import PDFKit
import UIKit

struct LibraryDocument: Codable, Identifiable {
    let id: UUID
    let title: String
    let filename: String
    let pages: Int
    let source: String
    var page: Int = 0
    var cell: Int = 0
}
struct OnlineDocument: Identifiable, Decodable {
    let identifier: String
    let title: String
    var id: String { identifier }
}
struct ReadablePage {
    let text: String
    let replacements: Int
    static func prepare(_ text: String) -> Self {
        // Expand unsupported typography explicitly instead of silently dropping book text.
        let replacements = ["“":"'", "”":"'", "\"":"'", "…":"...", "ﬁ":"fi", "ﬂ":"fl", "\u{00ad}":"", "\u{00a0}":" ", "&":" and ", "%":" percent ", "/":" slash ", "(":" comma ", ")":" comma ", "$":" dollars ", "+":" plus ", "=":" equals ", "@":" at "]
        var value = text
        for (from, to) in replacements { value = value.replacingOccurrences(of: from, with: to) }
        value = value.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US"))
        var count = 0
        let cleaned = value.map { char -> String in
            if Braille.translate(String(char)).unsupported.isEmpty { return String(char) }
            count += 1; return " unsupported symbol "
        }.joined()
        return Self(text: cleaned.isEmpty ? "blank page" : cleaned, replacements: count)
    }
}

@MainActor final class DocumentLibrary: ObservableObject {
    @Published private(set) var documents: [LibraryDocument] = []
    @Published var results: [OnlineDocument] = []
    @Published var busy = false
    @Published var status = "Search your library or import from Files"
    @Published var active: UUID?
    @Published var page = 0
    private(set) var cell = 0
    private var operation: Task<Void, Never>?
    private let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Documents", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: self.directory.appendingPathComponent("library.json")), let values = try? JSONDecoder().decode([LibraryDocument].self, from: data) { documents = values }
        #if DEBUG
        if ProcessInfo.processInfo.environment["BRAILIO_UI_TEST_LIBRARY"] == "1" {
            documents.removeAll { $0.filename == "test-book.pdf" }
            let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 600, height: 800))
            let data = renderer.pdfData { context in
                for text in ["First page.", "Second page."] { context.beginPage(); (text as NSString).draw(at: CGPoint(x: 40, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 24)]) }
            }
            try? data.write(to: self.directory.appendingPathComponent("test-book.pdf"), options: [.atomic, .completeFileProtection])
            documents.insert(LibraryDocument(id: UUID(), title: "Test book", filename: "test-book.pdf", pages: 2, source: "UI fixture"), at: 0); save()
        }
        #endif
    }
    var current: LibraryDocument? { documents.first { $0.id == active } }
    func matching(_ query: String) -> [LibraryDocument] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? documents : documents.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }
    private func save() {
        if let data = try? JSONEncoder().encode(documents) { try? data.write(to: directory.appendingPathComponent("library.json"), options: [.atomic, .completeFileProtection]) }
    }
    func bookmark(_ cell: Int) {
        guard let index = documents.firstIndex(where: { $0.id == active }) else { return }
        self.cell = max(0, cell); documents[index].page = page; documents[index].cell = self.cell; save()
    }
    func close() { active = nil; page = 0; cell = 0 }
    func select(_ id: UUID) { guard let item = documents.first(where: { $0.id == id }) else { return }; active = id; page = item.page; cell = item.cell }
    func setPage(_ value: Int) { guard let item = current else { return }; page = max(0, min(item.pages - 1, value)); cell = 0; bookmark(0) }
    func importFile(_ url: URL, title: String? = nil, source: String = "Files") async throws {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let directory = self.directory
        let item = try await Task.detached(priority: .userInitiated) {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 40_000_000 else { throw ServiceError.message("Choose a file smaller than 40 MB.") }
            let data = try Data(contentsOf: url)
            let pdf = data.starts(with: Data("%PDF-".utf8))
            let count: Int
            if pdf {
                guard let document = PDFDocument(data: data), !document.isLocked, document.pageCount > 0 else { throw ServiceError.message("This PDF is locked or unreadable.") }
                count = document.pageCount
            } else {
                guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { throw ServiceError.message("Choose a PDF or UTF-8 text document.") }
                count = max(1, Int(ceil(Double(text.count) / 2400)))
            }
            let id = UUID(); let filename = "\(id.uuidString).\(pdf ? "pdf" : "txt")"
            try data.write(to: directory.appendingPathComponent(filename), options: [.atomic, .completeFileProtection])
            return LibraryDocument(id: id, title: title ?? url.deletingPathExtension().lastPathComponent, filename: filename, pages: count, source: source)
        }.value
        documents.insert(item, at: 0); save(); select(item.id); status = "Document ready. \(item.pages) pages."
    }
    func pageText() async throws -> ReadablePage {
        guard let item = current else { throw ServiceError.message("Choose a document first.") }
        let url = directory.appendingPathComponent(item.filename); let index = page
        return try await Task.detached(priority: .userInitiated) {
            if item.filename.hasSuffix("pdf") {
                guard let document = PDFDocument(url: url), let page = document.page(at: index) else { throw ImportFailure.unreadable }
                if let text = page.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return ReadablePage.prepare(text) }
                let image = page.thumbnail(of: CGSize(width: 1600, height: 2200), for: .mediaBox)
                guard let data = image.jpegData(compressionQuality: 0.9) else { throw ImportFailure.unreadable }
                return ReadablePage.prepare(try await TextImport.recognize(data))
            }
            let text = try String(contentsOf: url, encoding: .utf8)
            let start = text.index(text.startIndex, offsetBy: min(index * 2400, text.count))
            let end = text.index(start, offsetBy: min(2400, text.distance(from: start, to: text.endIndex)))
            return ReadablePage.prepare(String(text[start..<end]))
        }.value
    }
    func searchOnline(_ query: String, completion: @escaping () -> Void) {
        operation?.cancel(); busy = true; results = []; status = "Searching Internet Archive PDFs"
        operation = Task {
            defer { busy = false }
            do {
                let words = query.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(16).map { "\"\($0)\"" }.joined(separator: " AND ")
                guard !words.isEmpty else { throw ServiceError.message("Write a document title first.") }
                var parts = URLComponents(string: "https://archive.org/advancedsearch.php")!
                parts.queryItems = [URLQueryItem(name: "q", value: "title:(\(words)) AND mediatype:texts AND format:\"Text PDF\" AND NOT access-restricted-item:true"), URLQueryItem(name: "fl[]", value: "identifier"), URLQueryItem(name: "fl[]", value: "title"), URLQueryItem(name: "rows", value: "24"), URLQueryItem(name: "output", value: "json")]
                let (data, response) = try await URLSession.shared.data(from: parts.url!)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ServiceError.message("Online search is unavailable.") }
                struct Search: Decodable { struct Response: Decodable { let docs: [OnlineDocument] }; let response: Response }
                let values = try JSONDecoder().decode(Search.self, from: data).response.docs
                try Task.checkCancellation(); results = values; status = values.isEmpty ? "No public PDFs found. Try another title or import a link." : "\(values.count) public document results"
            } catch is CancellationError { return } catch { status = error.localizedDescription }
            completion()
        }
    }
    func download(_ item: OnlineDocument) async throws {
        let encoded = item.identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
        let (data, _) = try await URLSession.shared.data(from: URL(string: "https://archive.org/metadata/\(encoded)")!)
        struct Metadata: Decodable { struct File: Decodable { let name: String; let format: String?; let size: String?; let `private`: String? }; let files: [File] }
        let metadata = try JSONDecoder().decode(Metadata.self, from: data)
        guard let file = metadata.files.first(where: { $0.format == "Text PDF" && $0.private != "true" && (Int($0.size ?? "0") ?? 0) <= 40_000_000 }) else { throw ServiceError.message("No downloadable public PDF under 40 MB. Try another result.") }
        var url = URL(string: "https://archive.org/download")!; url.appendPathComponent(item.identifier); url.appendPathComponent(file.name)
        try await downloadURL(url, title: item.title)
    }
    func downloadURL(_ url: URL, title: String? = nil) async throws {
        guard url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else { throw ServiceError.message("Use a public HTTPS PDF or text link.") }
        let downloaded = try await Self.fetchDocument(url)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        try await importFile(downloaded, title: title ?? url.deletingPathExtension().lastPathComponent, source: url.absoluteString)
    }
    nonisolated private static func fetchDocument(_ url: URL) async throws -> URL {
        // Byte parsing and file I/O run off the UI actor with a hard download ceiling.
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.timeoutInterval = 45
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServiceError.message("No document response was received.") }
        guard http.statusCode == 200 else { throw ServiceError.message("The document host returned HTTP \(http.statusCode). Try another public download.") }
        guard response.expectedContentLength <= 40_000_000 else { throw ServiceError.message("Download exceeds 40 MB.") }
        guard http.url?.scheme == "https" else { throw ServiceError.message("The download redirected to an insecure link.") }
        let mime = response.mimeType ?? ""
        guard mime == "application/pdf" || mime.hasPrefix("text/plain") || mime == "application/octet-stream" else { throw ServiceError.message("This link opens a webpage. Use a direct PDF or text download link.") }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var keep = false
        defer { if !keep { try? FileManager.default.removeItem(at: temporary) } }
        _ = FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete])
        let handle = try FileHandle(forWritingTo: temporary); defer { try? handle.close() }
        var buffer = Data(); var total = 0
        for try await byte in bytes {
            try Task.checkCancellation(); total += 1
            guard total <= 40_000_000 else { throw ServiceError.message("Download exceeds 40 MB.") }
            buffer.append(byte)
            if buffer.count == 65_536 { try handle.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true) }
        }
        try handle.write(contentsOf: buffer); try handle.synchronize(); keep = true
        return temporary
    }
    func deleteAll() { close(); documents = []; results = []; try? FileManager.default.removeItem(at: directory); try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
}
