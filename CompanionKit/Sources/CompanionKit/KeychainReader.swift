import Foundation
import Security

/// Reads (read-only) the OAuth token Claude Code already stores in the macOS Keychain
/// (generic password, service "Claude Code-credentials"; value is JSON with claudeAiOauth.*).
/// We never write/refresh credentials. First read from a differently-signed app may prompt the
/// user to allow keychain access ("Always Allow").
public enum KeychainReader {
    public struct Token: Sendable {
        public let accessToken: String
        public let expiresAt: Date?
    }

    public static func claudeOAuth() -> Token? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else { return nil }

        // expiresAt is epoch millis in Claude Code's stored JSON.
        var expires: Date?
        if let ms = oauth["expiresAt"] as? Double { expires = Date(timeIntervalSince1970: ms / 1000) }
        return Token(accessToken: token, expiresAt: expires)
    }
}
