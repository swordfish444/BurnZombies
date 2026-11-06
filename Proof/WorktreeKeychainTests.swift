import BurnCore
import CryptoKit
import Foundation
import Security

private func keyBytes(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

private func keychainQuery(_ service: String) -> [String: Any] {
  [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service, kSecAttrAccount as String: "archive-key-v1",
  ]
}

/// The recovery key lives in a private file, so an update never asks for the login password: it
/// is made once, reused, kept out of the Keychain and Time Machine, and an unsafe file is refused,
/// never replaced. Touches no Keychain item.
func recoveryKeyFileProof() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "bz-recovery-key-" + UUID().uuidString, isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let namespace = "BurnZombies.WorktreeRecovery.Proof." + UUID().uuidString
  let first = try WorktreeRecoveryKey.load(namespace: namespace, root: root)
  let again = try WorktreeRecoveryKey.load(create: false, namespace: namespace, root: root)
  equal(keyBytes(first), keyBytes(again), "the same key comes back")
  let sealed = try AES.GCM.seal(Data("recovery fixture".utf8), using: first)
  equal(try AES.GCM.open(sealed, using: again), Data("recovery fixture".utf8))

  let folder = root.appendingPathComponent("recovery-key", isDirectory: true)
  let file = folder.appendingPathComponent(namespace + ".key")
  var s = stat()
  check(
    lstat(file.path, &s) == 0 && s.st_mode & 0o777 == 0o600 && s.st_size == 32
      && s.st_uid == getuid(), "the key is a private 32-byte file")
  check(lstat(folder.path, &s) == 0 && s.st_mode & 0o777 == 0o700, "in a private folder")
  check(
    (try? folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) == true,
    "left out of Time Machine")
  var query = keychainQuery(namespace)
  query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
  var result: CFTypeRef?
  equal(SecItemCopyMatching(query as CFDictionary, &result), errSecItemNotFound, "nothing in the Keychain")

  do {
    _ = try WorktreeRecoveryKey.load(create: false, namespace: namespace + "-missing", root: root)
    failTest("a restore made up a missing recovery key")
  } catch {}
  check(
    !FileManager.default.fileExists(
      atPath: folder.appendingPathComponent(namespace + "-missing.key").path),
    "and wrote no key for it")

  let saved = try Data(contentsOf: file)
  chmod(file.path, 0o644)
  do {
    _ = try WorktreeRecoveryKey.load(namespace: namespace, root: root)
    failTest("a key others can read was used")
  } catch {}
  equal(try Data(contentsOf: file), saved, "an unsafe key file is refused, not replaced")
  chmod(file.path, 0o600)
  let linked = namespace + "-link"
  symlink(file.path, folder.appendingPathComponent(linked + ".key").path)
  do {
    _ = try WorktreeRecoveryKey.load(namespace: linked, root: root)
    failTest("a key file that is a link was followed")
  } catch {}
  let short = namespace + "-short"
  FileManager.default.createFile(
    atPath: folder.appendingPathComponent(short + ".key").path, contents: Data(repeating: 1, count: 16),
    attributes: [.posixPermissions: 0o600])
  do {
    _ = try WorktreeRecoveryKey.load(namespace: short, root: root)
    failTest("a truncated key file was used")
  } catch {}
  do {
    _ = try WorktreeRecoveryKey.load(namespace: "BurnZombies.WorktreeRecovery/../escape", root: root)
    failTest("a namespace left the key folder")
  } catch {}

  final class Keys: @unchecked Sendable {
    let lock = NSLock()
    var all: [Data] = []
  }
  let keys = Keys()
  let raced = namespace + "-race"
  DispatchQueue.concurrentPerform(iterations: 8) { _ in
    guard let key = try? WorktreeRecoveryKey.load(namespace: raced, root: root) else { return }
    keys.lock.lock()
    keys.all.append(keyBytes(key))
    keys.lock.unlock()
  }
  equal(keys.all.count, 8, "every racing first load got a key")
  equal(Set(keys.all).count, 1, "and they all got the same one")
}

/// A key that an earlier build kept in the Keychain moves to the file unchanged, so existing
/// recovery copies still open; from then on the file is used. Creates, reads and deletes one
/// temporary Keychain item; no production key is read or changed.
func worktreeKeychainProof() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "bz-recovery-key-" + UUID().uuidString, isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let service = "BurnZombies.WorktreeRecovery.Proof." + UUID().uuidString
  let query = keychainQuery(service)
  defer { SecItemDelete(query as CFDictionary) }
  let legacy = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
  var item = query
  item[kSecValueData as String] = legacy
  equal(SecItemAdd(item as CFDictionary, nil), errSecSuccess)

  // A test or sandbox folder never reads the user's Keychain item: it makes a key of its own.
  let sandbox = root.appendingPathComponent("sandbox", isDirectory: true)
  let own = try WorktreeRecoveryKey.load(namespace: service, root: sandbox)
  check(keyBytes(own) != legacy, "a sandbox folder ignores the Keychain item")
  do {
    _ = try WorktreeRecoveryKey.load(
      create: false, namespace: service, root: root.appendingPathComponent("restore-sandbox"))
    failTest("a sandbox restore read the Keychain item")
  } catch {}

  let moved = try WorktreeRecoveryKey.load(
    create: false, namespace: service, root: root, keychain: true)
  equal(keyBytes(moved), legacy, "the Keychain key moves unchanged")
  let file = root.appendingPathComponent("recovery-key/" + service + ".key")
  equal(try Data(contentsOf: file), legacy, "into the private file")
  equal(SecItemDelete(query as CFDictionary), errSecSuccess)
  let later = try WorktreeRecoveryKey.load(create: false, namespace: service, root: root)
  equal(keyBytes(later), legacy, "and the file is used from then on")
  print(
    "PASS recovery key moves from a temporary Keychain item to its private file unchanged, and a sandbox folder never reads it; no production key was read or changed"
  )
}
