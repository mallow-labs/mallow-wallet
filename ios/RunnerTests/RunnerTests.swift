import Flutter
import Security
import UIKit
import XCTest

@testable import Runner

/// Keychain-backed tests for `MnemonicVaultChannel`. They run inside the
/// hosted Runner app (simulator or device), so the real Keychain is used.
///
/// What they guard: a write over an existing key must *update* the item, not
/// delete-then-add it. With delete-then-add a failed `SecItemAdd` — e.g.
/// `errSecInteractionNotAllowed` while the device is locked — destroys the
/// stored secret; with update-or-add a failed write leaves the old value.
///
/// No CI job runs these — they need a Mac with Xcode and a booted simulator,
/// so they are a pre-release / local check, not a gate.
///
/// Run (Mac with Xcode and a booted simulator):
///   xcodebuild test -workspace ios/Runner.xcworkspace -scheme Runner \
///     -destination 'platform=iOS Simulator,name=iPhone 16' \
///     -only-testing:RunnerTests
final class MnemonicVaultChannelTests: XCTestCase {
  private let channel = MnemonicVaultChannel()
  private let service = MnemonicVaultChannel.service
  /// Every test key carries this prefix so cleanup never touches real items.
  private let prefix = "xctest_vault_"

  override func setUp() {
    super.setUp()
    cleanupTestItems()
  }

  override func tearDown() {
    cleanupTestItems()
    super.tearDown()
  }

  // MARK: - Helpers

  private func call(_ method: String, _ args: [String: Any]? = nil) -> Any? {
    var captured: Any? = "unset"
    let done = expectation(description: method)
    channel.handle(FlutterMethodCall(methodName: method, arguments: args)) { value in
      captured = value
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
    return captured
  }

  private func write(_ key: String, _ value: String) -> Any? {
    call("write", ["key": prefix + key, "value": value])
  }

  private func read(_ key: String) -> Any? {
    call("read", ["key": prefix + key])
  }

  private func delete(_ key: String) -> Any? {
    call("delete", ["key": prefix + key])
  }

  private func listKeys() -> [String] {
    let raw = call("listKeys")
    XCTAssertFalse(raw is FlutterError, "listKeys failed: \(String(describing: raw))")
    return (raw as? [String] ?? []).filter { $0.hasPrefix(prefix) }
  }

  /// Raw Keychain attributes for one account under the vault service.
  private func attributes(_ key: String) -> [CFString: Any]? {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: prefix + key,
      kSecReturnAttributes: true,
      kSecMatchLimit: kSecMatchLimitOne,
    ]
    var ref: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &ref)
    if status != errSecSuccess { return nil }
    return ref as? [CFString: Any]
  }

  /// Raw Keychain count for one account under the vault service.
  private func itemCount(_ key: String) -> Int {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: prefix + key,
      kSecReturnAttributes: true,
      kSecMatchLimit: kSecMatchLimitAll,
    ]
    var ref: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &ref)
    if status == errSecItemNotFound { return 0 }
    XCTAssertEqual(status, errSecSuccess)
    return (ref as? [[CFString: Any]])?.count ?? 0
  }

  private func cleanupTestItems() {
    for key in listKeys() {
      SecItemDelete([
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: key,
      ] as CFDictionary)
    }
  }

  // MARK: - Tests

  func testWriteThenReadRoundTrips() {
    XCTAssertNil(write("a", "first"))
    XCTAssertEqual(read("a") as? String, "first")
  }

  func testReadMissingKeyReturnsNil() {
    XCTAssertNil(read("missing"))
  }

  func testSecondWriteUpdatesInPlace() {
    // Regression guard for the delete-then-add hazard: after two writes the
    // account holds exactly one item and it carries the latest value.
    XCTAssertNil(write("b", "first"))
    XCTAssertNil(write("b", "second"))
    XCTAssertEqual(read("b") as? String, "second")
    XCTAssertEqual(itemCount("b"), 1)
  }

  func testUpdatePreservesAccessibilityAttribute() {
    XCTAssertNil(write("c", "first"))
    XCTAssertNil(write("c", "second"))
    let attrs = attributes("c")
    XCTAssertNotNil(attrs)
    XCTAssertEqual(
      attrs?[kSecAttrAccessible] as? String,
      kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
    )
  }

  /// The item count and the value cannot tell update-in-place from
  /// delete-then-add — both end with one item holding the new value. The
  /// creation date can: `SecItemUpdate` keeps it, `SecItemAdd` after a
  /// `SecItemDelete` stamps a new one. This is the only assertion in the file
  /// that would actually fail if the write regressed to delete-then-add.
  ///
  /// Creation date has one-second resolution, so the two writes must land in
  /// different seconds for the check to mean anything — hence the sleep.
  func testSecondWritePreservesCreationDate() {
    XCTAssertNil(write("cd", "first"))
    let created = attributes("cd")?[kSecAttrCreationDate] as? Date
    XCTAssertNotNil(created)

    Thread.sleep(forTimeInterval: 1.1)
    XCTAssertNil(write("cd", "second"))

    let after = attributes("cd")?[kSecAttrCreationDate] as? Date
    XCTAssertNotNil(after)
    XCTAssertEqual(created, after, "the second write replaced the item instead of updating it")
    XCTAssertEqual(read("cd") as? String, "second")
  }

  /// A delete must report a real Keychain failure and stay silent about
  /// not-found: the explicit wipe records one failure per step, so a
  /// swallowed status would let a wipe report "clean" with a secret still
  /// stored, while a not-found error would report a failure that never was.
  func testDeleteReportsNoErrorWhenPresentOrAbsent() {
    XCTAssertNil(write("del", "v"))
    let first = delete("del")
    XCTAssertFalse(first is FlutterError, "delete of an existing item failed: \(String(describing: first))")
    XCTAssertNil(first)

    let second = delete("del")
    XCTAssertFalse(second is FlutterError, "delete of a missing item reported an error")
    XCTAssertNil(second)
  }

  func testListKeysEnumeratesEveryAccountUnderTheService() {
    XCTAssertNil(write("k1", "v1"))
    XCTAssertNil(write("k2", "v2"))
    XCTAssertEqual(Set(listKeys()), Set([prefix + "k1", prefix + "k2"]))
  }

  func testListKeysIgnoresOtherServices() {
    // An item under the flutter_secure_storage service must not be listed —
    // the sweep is scoped to the vault so it can never reach another store.
    let foreign: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: "mallow_wallet",
      kSecAttrAccount: prefix + "foreign",
      kSecValueData: "x".data(using: .utf8)!,
    ]
    SecItemDelete(foreign as CFDictionary)
    XCTAssertEqual(SecItemAdd(foreign as CFDictionary, nil), errSecSuccess)
    defer { SecItemDelete(foreign as CFDictionary) }

    XCTAssertNil(write("own", "v"))
    XCTAssertEqual(listKeys(), [prefix + "own"])
  }

  func testDeleteRemovesKeyAndListReflectsIt() {
    XCTAssertNil(write("d", "v"))
    XCTAssertNil(delete("d"))
    XCTAssertNil(read("d"))
    XCTAssertTrue(listKeys().isEmpty)
    // Deleting again is a no-op, not an error.
    XCTAssertNil(delete("d"))
  }

  func testMissingKeyArgumentIsRejected() {
    let result = call("write", ["value": "v"])
    XCTAssertEqual((result as? FlutterError)?.code, "invalid_args")
  }
}
