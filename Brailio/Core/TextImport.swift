import Foundation
import Vision

enum ImportFailure: LocalizedError {
    case unreadable, noText, tooLong
    var errorDescription: String? {
        switch self {
        case .unreadable: return "This image could not be opened. Try another photo."
        case .noText: return "No readable text was found on this page. Try a clearer scan."
        case .tooLong: return "Please choose a shorter document, up to 20,000 characters."
        }
    }
}
enum TextImport {
    static func recognize(_ data: Data) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(data: data).perform([request])
            let value = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            guard !value.isEmpty else { throw ImportFailure.noText }
            guard value.count <= 20_000 else { throw ImportFailure.tooLong }
            return value
        }.value
    }
}
