import Foundation
import Security

/// Private-device demo credential. Never bundled, placed in UserDefaults, or synced to iCloud.
enum DemoAccess {
    private static let service = "com.brailio.demo.baseten"
    static var key: String {
        get {
            let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"key",kSecReturnData as String:true]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary,&item) == errSecSuccess, let data = item as? Data else { return "" }
            return String(data:data,encoding:.utf8) ?? ""
        }
    }
    static var configured: Bool { !key.isEmpty }
    static func save(_ value: String) throws {
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"key"]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var item=query; item[kSecValueData as String]=Data(value.utf8); item[kSecAttrAccessible as String]=kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary,nil) == errSecSuccess else { throw ServiceError.message("The demo key could not be saved securely.") }
    }
    static func bootstrap() {
        if let value=ProcessInfo.processInfo.environment["BRAILIO_DEMO_BASETEN_KEY"], !value.isEmpty { try? save(value) }
    }
}
@MainActor final class ConnectionStatus: ObservableObject {
    @Published var state = "Not checked"
    @Published var checking = false
    func check() async {
        checking=true; defer { checking=false }
        do { _ = try await AIClient.request(task:"correct",text:"hello"); state="Connected to Baseten" }
        catch { state=error.localizedDescription }
    }
}
