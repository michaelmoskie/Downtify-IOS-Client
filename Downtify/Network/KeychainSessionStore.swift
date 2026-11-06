import Foundation
import Security

struct DeviceSession: Codable, Equatable, Sendable, CustomDebugStringConvertible {
    let baseAddress: String
    let serverID: String
    let serverName: String
    let deviceID: String
    let username: String?
    let role: String?
    let token: String
    let allowsInsecureHTTP: Bool

    var debugDescription: String { "DeviceSession" }
}

protocol DeviceSessionStoring {
    func load() throws -> DeviceSession?
    func save(_ session: DeviceSession) throws
    func clear() throws
}

enum KeychainSessionError: Error, Equatable {
    case invalidRecord
    case operationFailed(OSStatus)
}

struct KeychainSessionStore: DeviceSessionStoring {
    private let service: String

    init(service: String = "app.downtify.ios.session") {
        self.service = service
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "active-device"]
    }

    func load() throws -> DeviceSession? {
        var query = self.query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainSessionError.operationFailed(status) }
        guard let data = item as? Data, let session = try? JSONDecoder().decode(DeviceSession.self, from: data) else {
            throw KeychainSessionError.invalidRecord
        }
        return session
    }

    func save(_ session: DeviceSession) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: try JSONEncoder().encode(session),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let item = query.merging(attributes) { _, new in new }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainSessionError.operationFailed(status) }
    }

    func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainSessionError.operationFailed(status)
        }
    }
}
