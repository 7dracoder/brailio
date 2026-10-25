import Foundation
import Security

enum BackendAccess {
    static let service = "com.brailio.backend"
    static var token: String {
        get {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "access", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
        set {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "access"]
            SecItemDelete(query as CFDictionary)
            if !newValue.isEmpty {
                var item = query; item[kSecValueData as String] = Data(newValue.utf8); item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                SecItemAdd(item as CFDictionary, nil)
            }
        }
    }
    static func bootstrap() {
        UserDefaults.standard.register(defaults: ["backendURL": "https://brailio-api.vercel.app"])
        // Used only by the local developer's device launch. No provider key is shipped in the app.
        if let token = ProcessInfo.processInfo.environment["BRAILIO_ACCESS_TOKEN"] { self.token = token }
        if let url = ProcessInfo.processInfo.environment["BRAILIO_BACKEND_URL"] { UserDefaults.standard.set(url, forKey: "backendURL") }
    }
}
