import Flutter
import Foundation
import Security

/// Native Keychain handler for mnemonic/private-key storage.
///
/// Each item is stored under kSecAttrAccessibleWhenUnlockedThisDeviceOnly — the
/// same tier as the database encryption key: readable whenever the device is
/// unlocked, with NO OS-level biometric/passcode prompt and no device-passcode
/// precondition for writes. The app's own dual-lock (PIN and/or biometric
/// app-lock) is the user-facing gate over this data; see AppLockBloc.
///
/// Writes are update-or-add, never delete-then-add: a failed `SecItemAdd`
/// after a `SecItemDelete` would destroy the stored secret, and an
/// `errSecInteractionNotAllowed` (device locked) is exactly the kind of
/// failure that can land mid-write. A failed update leaves the old value.
class MnemonicVaultChannel: NSObject, FlutterPlugin {
    static let channelName = "art.mallow.wallet/mnemonic_vault"
    /// Distinct service tag so vault items don't collide with flutter_secure_storage items.
    static let service = "art.mallow.vault"

    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: channelName,
            binaryMessenger: registrar.messenger()
        )
        let instance = MnemonicVaultChannel()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        // Enumeration takes no key: it lists every account under the service.
        if call.method == "listKeys" {
            vaultListKeys(result: result)
            return
        }
        guard let args = call.arguments as? [String: Any],
              let key = args["key"] as? String else {
            result(FlutterError(code: "invalid_args", message: "Missing key", details: nil))
            return
        }
        switch call.method {
        case "write":
            guard let value = args["value"] as? String else {
                result(FlutterError(code: "invalid_args", message: "Missing value", details: nil))
                return
            }
            vaultWrite(key: key, value: value, result: result)
        case "read":
            let prompt = args["prompt"] as? String ?? "Authenticate to access your wallet"
            vaultRead(key: key, prompt: prompt, result: result)
        case "delete":
            vaultDelete(key: key, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: – Private

    private func baseQuery(key: String) -> [CFString: Any] {
        return [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: key,
        ]
    }

    /// Update-or-add. The existing item's attributes (accessibility) are left
    /// as they are; only the data changes. A duplicate-item race on add falls
    /// through to update so the caller never sees errSecDuplicateItem.
    private func vaultWrite(key: String, value: String, result: @escaping FlutterResult) {
        guard let data = value.data(using: .utf8) else {
            result(FlutterError(code: "write_failed", message: "Failed to encode value", details: nil))
            return
        }

        let query = baseQuery(key: key)
        let update: [CFString: Any] = [kSecValueData: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)

        if status == errSecItemNotFound {
            var addQuery = baseQuery(key: key)
            // Device-unlock-bound (matches the DB encryption key tier): no access
            // control means no OS prompt on read and no passcode precondition on
            // write. The app-lock is the user gate.
            addQuery[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            addQuery[kSecValueData] = data
            status = SecItemAdd(addQuery as CFDictionary, nil)
            if status == errSecDuplicateItem {
                // Lost a race with a concurrent add; the item now exists.
                status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            }
        }

        if status == errSecSuccess {
            result(nil)
        } else {
            result(FlutterError(
                code: "write_failed",
                message: "Keychain write returned \(status)",
                details: nil
            ))
        }
    }

    private func vaultRead(key: String, prompt: String, result: @escaping FlutterResult) {
        // Device-unlock-bound: a plain lookup, no auth context. The item is
        // readable whenever the device is unlocked; the app-lock is the gate.
        var query = baseQuery(key: key)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var ref: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &ref)

        switch status {
        case errSecSuccess:
            guard let data = ref as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                result(FlutterError(code: "read_failed", message: "Failed to decode keychain data", details: nil))
                return
            }
            result(value)
        case errSecItemNotFound:
            result(nil)
        default:
            result(FlutterError(
                code: "read_failed",
                message: "SecItemCopyMatching returned \(status)",
                details: nil
            ))
        }
    }

    /// Delete one item. A status other than success or not-found is reported:
    /// the explicit wipe records a failure per step, and a swallowed status
    /// would let a wipe report "clean" with a mnemonic still in the Keychain.
    private func vaultDelete(key: String, result: @escaping FlutterResult) {
        let status = SecItemDelete(baseQuery(key: key) as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            result(nil)
        } else {
            result(FlutterError(
                code: "delete_failed",
                message: "SecItemDelete returned \(status)",
                details: nil
            ))
        }
    }

    /// Every account stored under the vault service. Lets the Dart side sweep
    /// the store on an explicit wipe; without it, items whose ids the app has
    /// lost (e.g. after the account graph is deleted) stay in the Keychain
    /// forever.
    private func vaultListKeys(result: @escaping FlutterResult) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ]
        var ref: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &ref)

        switch status {
        case errSecSuccess:
            let items = ref as? [[CFString: Any]] ?? []
            let keys = items.compactMap { $0[kSecAttrAccount] as? String }
            result(keys)
        case errSecItemNotFound:
            result([String]())
        default:
            result(FlutterError(
                code: "list_failed",
                message: "SecItemCopyMatching returned \(status)",
                details: nil
            ))
        }
    }
}
