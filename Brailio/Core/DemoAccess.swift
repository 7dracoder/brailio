import Foundation
import Security

/// Private-device demo credential. Never bundled, placed in UserDefaults, or synced to iCloud.
enum AIProvider: String, CaseIterable { case baseten, gemini
    var title: String { self == .baseten ? "Baseten" : "Gemini" }
}
enum DemoAccess {
    static var provider: AIProvider { AIProvider(rawValue: UserDefaults.standard.string(forKey: "aiProvider") ?? "") ?? .baseten }
    static var key: String { key(for: provider) }
    static func key(for provider: AIProvider) -> String {
        let service = "com.brailio.demo." + provider.rawValue
            let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"key",kSecReturnData as String:true]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary,&item) == errSecSuccess, let data = item as? Data else { return "" }
            return String(data:data,encoding:.utf8) ?? ""
    }
    static var configured: Bool { !key.isEmpty }
    static func save(_ value: String, provider: AIProvider = DemoAccess.provider) throws {
        let service = "com.brailio.demo." + provider.rawValue
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"key"]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var item=query; item[kSecValueData as String]=Data(value.utf8); item[kSecAttrAccessible as String]=kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary,nil) == errSecSuccess else { throw ServiceError.message("The demo key could not be saved securely.") }
    }
    static func bootstrap() {
        for (name, provider) in [("BRAILIO_DEMO_BASETEN_KEY", AIProvider.baseten), ("BRAILIO_DEMO_GEMINI_KEY", AIProvider.gemini)] {
            if let value=ProcessInfo.processInfo.environment[name], !value.isEmpty { try? save(value, provider: provider) }
        }
    }
}
@MainActor final class ConnectionStatus: ObservableObject {
    @Published var state = "Not checked"
    @Published var checking = false
    func check() async {
        checking=true; defer { checking=false }
        do { _ = try await AIClient.request(task:"correct",text:"hello"); state="Connected to " + DemoAccess.provider.title }
        catch { state=error.localizedDescription }
    }
}
