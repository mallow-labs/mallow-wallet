import Flutter
import Foundation
import Security

/// The iOS platform slot of the social vault: iCloud Keychain items, one per
/// (vault, slot), each holding that slot's random 32-byte secret.
///
/// This store is the OPPOSITE of MnemonicVaultChannel on purpose, and the two
/// must never share a service:
///
/// - MnemonicVault items are `WhenUnlockedThisDeviceOnly` and never leave the
///   device. Wallet keys and phrases live there and must stay there.
/// - Items here are `kSecAttrSynchronizable` with `WhenUnlocked`, so iCloud
///   Keychain (end-to-end encrypted) carries them to the user's other devices
///   and they survive a reinstall — when the user has iCloud Keychain on — and
///   none of them can be read while the device is locked.
///
/// A slot secret alone opens nothing. It unwraps a data key only together
/// with the vault's ciphertext, which the backend hands out only to a fresh
/// Google or Apple sign-in for the same identity.
///
/// Items are keyed `<vaultId>.<slotId>` and are never overwritten: two devices
/// syncing through one iCloud account can each add a slot for the same vault,
/// and an overwrite would destroy the secret behind the other device's slot.
/// `add` therefore fails on an existing item instead of updating it.
class SocialVaultSlotChannel: NSObject, FlutterPlugin {
    static let channelName = "art.mallow.wallet/social_vault_slot"
    /// Distinct from MnemonicVaultChannel's service, so a listing or sweep of
    /// one can never touch the other.
    static let service = "art.mallow.social-vault-slot"

    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: channelName,
            binaryMessenger: registrar.messenger()
        )
        registrar.addMethodCallDelegate(SocialVaultSlotChannel(), channel: channel)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "isAvailable":
            // The Keychain is always there. Without iCloud Keychain the item
            // stays on this device, which covers a reinstall but not a new
            // device — the app's copy says so.
            result(true)
        case "list":
            guard let args = call.arguments as? [String: Any],
                  let prefix = args["prefix"] as? String else {
                result(FlutterError(code: "invalid_args", message: "Missing prefix", details: nil))
                return
            }
            list(prefix: prefix, result: result)
        case "add":
            guard let args = call.arguments as? [String: Any],
                  let key = args["key"] as? String,
                  let value = args["value"] as? String,
                  let data = value.data(using: .utf8) else {
                result(FlutterError(code: "invalid_args", message: "Missing key or value", details: nil))
                return
            }
            add(key: key, data: data, result: result)
        case "delete":
            guard let args = call.arguments as? [String: Any],
                  let key = args["key"] as? String else {
                result(FlutterError(code: "invalid_args", message: "Missing key", details: nil))
                return
            }
            delete(key: key, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func baseQuery() -> [CFString: Any] {
        return [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrSynchronizable: kCFBooleanTrue as Any,
        ]
    }

    private func itemQuery(key: String) -> [CFString: Any] {
        var query = baseQuery()
        query[kSecAttrAccount] = key
        return query
    }

    /// Items written before this class was `WhenUnlocked` were
    /// `AfterFirstUnlock`, readable while the device is locked. Move such an
    /// item to `WhenUnlocked` where it is: an attribute update of the item
    /// itself, never a delete and an add, so its value is not at stake. A
    /// failed update leaves the item exactly as it was, and the next listing
    /// tries again.
    private func upgradeAccessibility(key: String, current: Any?) {
        if let current = current as? String,
           current == (kSecAttrAccessibleWhenUnlocked as String) {
            return
        }
        let update: [CFString: Any] = [kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked]
        _ = SecItemUpdate(itemQuery(key: key) as CFDictionary, update as CFDictionary)
    }

    /// Every item whose account starts with `prefix`, as account → value.
    private func list(prefix: String, result: @escaping FlutterResult) {
        var query = baseQuery()
        query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = kSecMatchLimitAll
        var ref: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &ref)
        if status == errSecItemNotFound {
            result([String: String]())
            return
        }
        guard status == errSecSuccess, let items = ref as? [[String: Any]] else {
            result(FlutterError(code: "read_failed", message: "SecItemCopyMatching returned \(status)", details: nil))
            return
        }
        var values = [String: String]()
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  account.hasPrefix(prefix) else { continue }
            upgradeAccessibility(key: account, current: item[kSecAttrAccessible as String])
            var read = itemQuery(key: account)
            read[kSecReturnData] = true
            read[kSecMatchLimit] = kSecMatchLimitOne
            var dataRef: AnyObject?
            let readStatus = SecItemCopyMatching(read as CFDictionary, &dataRef)
            if readStatus == errSecSuccess,
               let data = dataRef as? Data,
               let value = String(data: data, encoding: .utf8) {
                values[account] = value
            }
        }
        result(values)
    }

    /// Add-only. An existing item is an error, never replaced.
    private func add(key: String, data: Data, result: @escaping FlutterResult) {
        var add = itemQuery(key: key)
        // Synchronizable items cannot be ThisDeviceOnly, so this is the
        // strictest class they can have. Every read and write happens with
        // the app in the foreground — a sign-in, an unlocked app — so nothing
        // needs the item while the device is locked.
        add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlocked
        add[kSecValueData] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            result(nil)
        case errSecDuplicateItem:
            result(FlutterError(code: "exists", message: "Slot entry already exists", details: nil))
        default:
            result(FlutterError(code: "write_failed", message: "Keychain write returned \(status)", details: nil))
        }
    }

    /// Deletes the item everywhere iCloud Keychain carries it. The app calls
    /// this only once the slot is gone from the vault.
    private func delete(key: String, result: @escaping FlutterResult) {
        let status = SecItemDelete(itemQuery(key: key) as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            result(nil)
        } else {
            result(FlutterError(code: "delete_failed", message: "SecItemDelete returned \(status)", details: nil))
        }
    }
}
