import Foundation
import Security

/// Secretos en el Keychain del usuario. Nunca en disco ni en git.
public struct CredentialStore: Sendable {
    public static let anthropicKey = "anthropic_api_key"
    public static let openAIKey = "openai_api_key"
    let service: String

    public init(service: String = "app.frontbot.credentials") { self.service = service }

    /// Key sin espacios ni saltos de línea alrededor; nil si queda vacía.
    public static func normalizedApiKey(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func get(_ account: String) throws -> String? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw ValidationError(String(localized: "Error de Keychain \(String(status)).")) }
        return String(data: data, encoding: .utf8)
    }

    public func set(_ account: String, value: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(base(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base(account)
            add[kSecValueData as String] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw ValidationError(String(localized: "Error de Keychain \(String(addStatus)).")) }
        } else if status != errSecSuccess {
            throw ValidationError(String(localized: "Error de Keychain \(String(status))."))
        }
    }

    public func delete(_ account: String) throws {
        let status = SecItemDelete(base(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ValidationError(String(localized: "Error de Keychain \(String(status)).")) }
    }

    /// OpenAI API key scoped to a Frontbot workspace. The key is only returned to the caller when needed.
    public func openAIKey(workspaceId: String) throws -> String? {
        try get("\(workspaceId).\(Self.openAIKey)")
    }

    public func setOpenAIKey(_ rawValue: String, workspaceId: String) throws {
        guard let value = Self.normalizedApiKey(rawValue) else { throw ValidationError("La API key está vacía.") }
        try set("\(workspaceId).\(Self.openAIKey)", value: value)
    }

    public func deleteOpenAIKey(workspaceId: String) throws {
        try delete("\(workspaceId).\(Self.openAIKey)")
    }
}
