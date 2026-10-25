import Foundation

struct AIResult: Codable {
    let text: String
    let found: Bool?
    let confidence: Double?
    let horizontal: String?
    let box: ObjectBox?
    let evidenceFrame: Int?
    let verdict: String?
}

enum AIClient {
    static func request(task: String, text: String, image: Data? = nil, images: [Data] = []) async throws -> AIResult {
        if DemoAccess.configured { return try await DemoBaseten.request(task:task,text:text,image:image,images:images) }
        guard let raw = UserDefaults.standard.string(forKey: "backendURL"),
              let base = URL(string: raw), base.scheme == "https", base.host != nil else {
            throw ServiceError.message("The AI connection needs companion setup. Baseten credentials stay on the server.")
        }
        var request = URLRequest(url: base.appendingPathComponent("assist"))
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard !BackendAccess.token.isEmpty else { throw ServiceError.message("The AI connection needs companion setup.") }
        request.setValue("Bearer " + BackendAccess.token, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["task": task, "text": text, "image": image?.base64EncodedString() ?? "", "images": images.map { $0.base64EncodedString() }])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: String])?["error"]
            throw ServiceError.message(message ?? "The AI service is unavailable. Your original text is unchanged.")
        }
        let result = try JSONDecoder().decode(AIResult.self, from: data)
        guard !result.text.isEmpty, result.text.count <= 4000 else { throw ServiceError.message("The AI response was empty or too long. Please retry.") }
        return result
    }
}
enum ServiceError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum BrailleInput {
    static func character(for dots: Set<Int>, numbers: Bool, capitals: Bool) -> String? {
        guard let letter = Braille.alphabet.first(where: { $0.1 == dots })?.0 else { return nil }
        if numbers {
            guard let index = Array("abcdefghij").firstIndex(of: Character(letter)) else { return nil }
            return String((index + 1) % 10)
        }
        return capitals ? letter.uppercased() : letter
    }
}
