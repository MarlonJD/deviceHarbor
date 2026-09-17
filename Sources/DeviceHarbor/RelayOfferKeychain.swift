import DeviceHarborTransport
import Foundation
import Security

enum MacRelayOfferKeychain {
    private static let service = "dev.deviceharbor.mac"
    private static let account = "temporary-relay-offer"

    static func load() -> DeviceHarborRelayOffer? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(DeviceHarborRelayOffer.self, from: data)
    }

    static func save(_ offer: DeviceHarborRelayOffer) {
        guard let data = try? JSONEncoder().encode(offer) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item.merge(attributes) { _, newValue in newValue }
            _ = SecItemAdd(item as CFDictionary, nil)
        }
    }
}
