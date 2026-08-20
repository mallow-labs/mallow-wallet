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

    private func baseDeleteQuery(key: String) -> [CFString: Any] {
        return [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: key,
        ]
    }

    private func vaultWrite(key: String, value: String, result: @escaping FlutterResult) {
        guard let data = value.data(using: .utf8) else {
            result(FlutterError(code: "write_failed", message: "Failed to encode value", details: nil))
            return
        }
        // Remove any existing item first (avoids errSecDuplicateItem).
        SecItemDelete(baseDeleteQuery(key: key) as CFDictionary)

        var addQuery = baseDeleteQuery(key: key)
        // Device-unlock-bound (matches the DB encryption key tier): no access
        // control means no OS prompt on read and no passcode precondition on
        // write. The app-lock is the user gate.
        addQuery[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        addQuery[kSecValueData] = data

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecSuccess {
            result(nil)
        } else {
            result(FlutterError(
                code: "write_failed",
                message: "SecItemAdd returned \(status)",
                details: nil
            ))
        }
    }

    private func vaultRead(key: String, prompt: String, result: @escaping FlutterResult) {
        // Device-unlock-bound: a plain lookup, no auth context. The item is
        // readable whenever the device is unlocked; the app-lock is the gate.
        var query = baseDeleteQuery(key: key)
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

    private func vaultDelete(key: String, result: @escaping FlutterResult) {
        SecItemDelete(baseDeleteQuery(key: key) as CFDictionary)
        result(nil)
    }
}
