import Foundation
import Security

/// The three keychain calls the app makes, behind one set of functions: a
/// generic-password item is read, written (updated if present, else added) or
/// deleted. Compiled into the Top Shelf extension too.
enum Keychain {
    /// `household`: on an Apple TV, the keychain everyone who uses the TV
    /// shares, rather than the person's own. The app runs as whoever is using
    /// the TV, each with their own keychain, settings and files; what's here
    /// is what they share (see `hasHousehold`).
    static func query(service: String, account: String, group: String? = nil, household: Bool = false) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        if let group { query[kSecAttrAccessGroup as String] = group }
        #if os(macOS)
        // The iPhone's kind of keychain, not the Mac's older one: kept for the app by its
        // signature, with nothing ever asked of the person (the older one asks whether
        // a rebuilt or updated app may read what an earlier one saved).
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        #if os(tvOS)
        if household, hasHousehold { query[kSecUseUserIndependentKeychain as String] = true }
        #endif
        return query
    }

    /// Whether there's a keychain shared by everyone on the device, apart from
    /// each person's own: on an Apple TV, where the app runs as the person
    /// using it. Elsewhere (an iPhone, an iPad, a build without the
    /// entitlement) the household is the device's one keychain.
    static let hasHousehold: Bool = {
        #if os(tvOS)
        let probe: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "app.jellygoose.household-probe",
                                    kSecAttrAccount as String: "probe",
                                    kSecUseUserIndependentKeychain as String: true]
        let status = SecItemCopyMatching(probe as CFDictionary, nil)
        return status == errSecItemNotFound || status == errSecSuccess
        #else
        return false
        #endif
    }()

    /// Every item of a service, by account: what's kept for each of several
    /// accounts under one name.
    static func readAll(_ query: [String: Any]) -> [(account: String, data: Data)] {
        var query = query
        query[kSecAttrAccount as String] = nil
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data else { return nil }
            return (account, data)
        }
    }

    static func read(_ query: [String: Any]) -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Reachable only after the device has been unlocked once, and never
    /// synced off it.
    @discardableResult
    static func write(_ data: Data, _ query: [String: Any]) -> Bool {
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess {
            return true
        }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ query: [String: Any]) {
        SecItemDelete(query as CFDictionary)
    }
}
