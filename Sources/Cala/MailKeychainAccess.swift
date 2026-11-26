import Foundation
import Security

/// Who a Keychain item lets read its password, as far as Cala can tell without reading it.
struct MailItemAccess: Equatable {
    var exists: Bool
    /// The access list for reading the password trusts the helper (any app, or the helper's cdhash). nil: unknown.
    var aclTrustsHelper: Bool?
    /// The item's partition list includes the helper's cdhash, or the item has none. nil: unknown.
    var partitionTrustsHelper: Bool?

    static let missing = MailItemAccess(exists: false, aclTrustsHelper: nil, partitionTrustsHelper: nil)
}

/// Reads the access list of the helper's and the old Keychain items (legacy keychain API) to predict whether reading
/// them will make macOS show a window. Only attributes and the access list are read, never the password: no
/// authorization is needed, so this never prompts (checked with Keychain UI turned off against an item another app
/// created). Uses deprecated SecKeychain/SecAccess calls on purpose: these items live in the file-based login keychain.
enum MailKeychainAccess {
    static let service = "Cala Mail"

    /// cdhashes of every slice of the bundled helper (the access list records the one that ran).
    static func helperCDHashes(at url: URL = MailKeychain.helperURL) -> [String] {
        ["arm64", "x86_64"].compactMap { arch in
            var code: SecStaticCode?
            let attributes = [kSecCodeAttributeArchitecture as String: arch] as CFDictionary
            guard SecStaticCodeCreateWithPathAndAttributes(url as CFURL, [], attributes, &code) == errSecSuccess,
                  let code else { return nil }
            var info: CFDictionary?
            guard SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
                  let unique = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { return nil }
            return unique.map { String(format: "%02x", $0) }.joined()
        }
    }

    /// nil when the item could not be inspected (then the caller cannot predict and should watch the read instead).
    /// The access list names trusted apps by path (their code requirement is not public API), so the helper is
    /// recognised by `helperPath`; the partition list by the helper's cdhashes.
    static func inspect(account: String, service: String = service, helperPath: String = MailKeychain.helperURL.path,
                        helperCDHashes: [String], searchList: [Any]? = nil) -> MailItemAccess? {
        guard !helperCDHashes.isEmpty else { return nil }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let searchList { query[kSecMatchSearchList as String] = searchList }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess, let result, CFGetTypeID(result) == SecKeychainItemGetTypeID() else { return nil }
        let path = URL(fileURLWithPath: helperPath).resolvingSymlinksInPath().path
        return access(of: result as! SecKeychainItem, helperPath: path, helperCDHashes: helperCDHashes.map { $0.lowercased() })
    }

    @available(macOS, deprecated: 10.10)
    private static func access(of item: SecKeychainItem, helperPath: String, helperCDHashes: [String]) -> MailItemAccess? {
        var access: SecAccess?
        guard SecKeychainItemCopyAccess(item, &access) == errSecSuccess, let access else { return nil }
        var list: CFArray?
        guard SecAccessCopyACLList(access, &list) == errSecSuccess, let acls = list as? [SecACL] else { return nil }
        var aclTrusts = false, sawDecrypt = false
        var partition: Bool?
        for acl in acls {
            let authorizations = SecACLCopyAuthorizations(acl) as? [String] ?? []
            var applications: CFArray?
            var description: CFString?
            var prompt = SecKeychainPromptSelector()
            guard SecACLCopyContents(acl, &applications, &description, &prompt) == errSecSuccess else { return nil }
            if authorizations.contains(kSecACLAuthorizationDecrypt as String)
                || authorizations.contains(kSecACLAuthorizationAny as String) {
                sawDecrypt = true
                guard let apps = applications as? [SecTrustedApplication] else { aclTrusts = true; continue } // any app
                for app in apps where trusts(app, helperPath) { aclTrusts = true }
            }
            if authorizations.contains(kSecACLAuthorizationPartitionID as String) {
                guard let description, let partitions = partitionIDs(description as String) else { return nil }
                partition = helperCDHashes.contains { partitions.contains("cdhash:" + $0) }
            }
        }
        // Without a partition entry macOS has nothing to check there (this is what temporary keychains look like).
        return MailItemAccess(exists: true, aclTrustsHelper: sawDecrypt ? aclTrusts : nil,
                              partitionTrustsHelper: partition ?? true)
    }

    @available(macOS, deprecated: 10.10)
    private static func trusts(_ app: SecTrustedApplication, _ helperPath: String) -> Bool {
        var data: CFData?
        guard SecTrustedApplicationCopyData(app, &data) == errSecSuccess, let data = data as Data? else { return false }
        let path = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path == helperPath
    }

    /// The partition entry's description is hex-encoded JSON, {"Partitions":["teamid:…","cdhash:…"]} (a property
    /// list is accepted too).
    static func partitionIDs(_ description: String) -> [String]? {
        var bytes = [UInt8]()
        var high: UInt8?
        for scalar in description.unicodeScalars {
            guard let nibble = UInt8(String(scalar), radix: 16) else { return nil }
            if let h = high { bytes.append(h << 4 | nibble); high = nil } else { high = nibble }
        }
        guard high == nil, !bytes.isEmpty,
              let object = (try? JSONSerialization.jsonObject(with: Data(bytes)))
                ?? (try? PropertyListSerialization.propertyList(from: Data(bytes), format: nil)),
              let partitions = (object as? [String: Any])?["Partitions"] as? [String] else { return nil }
        return partitions.map { $0.lowercased() }
    }
}
