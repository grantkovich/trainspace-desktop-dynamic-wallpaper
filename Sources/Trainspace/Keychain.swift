import Foundation
import Security
import TrainspaceCore

/// API keys live in the login keychain, not in preferences.
enum KeyStore {
    private static let service = "com.grantkovich.trainspace.api-keys"

    static func load() -> [LiveFeeds.KeyKind: String] {
        var out: [LiveFeeds.KeyKind: String] = [:]
        for kind in LiveFeeds.KeyKind.allCases {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: kind.rawValue,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
               let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty {
                out[kind] = key
            }
        }
        return out
    }

    @discardableResult
    static func save(_ key: String, for kind: LiveFeeds.KeyKind) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: kind.rawValue,
        ]
        SecItemDelete(base as CFDictionary)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(trimmed.utf8)
        add[kSecAttrLabel as String] = "Trainspace \(kind.rawValue) API key"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
