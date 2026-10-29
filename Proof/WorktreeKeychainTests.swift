import BurnCore
import CryptoKit
import Foundation
import Security

func worktreeKeychainProof() throws {
  let service = "BurnZombies.WorktreeRecovery.Proof." + UUID().uuidString
  let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service, kSecAttrAccount as String: "archive-key-v1",
    kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
  var result: CFTypeRef?
  equal(SecItemCopyMatching(query as CFDictionary, &result), errSecItemNotFound)
  let first = try WorktreeRecoveryKey.load(namespace: service)
  defer { SecItemDelete(query as CFDictionary) }
  let second = try WorktreeRecoveryKey.load(create: false, namespace: service)
  let message = Data("synthetic recovery-key integration fixture".utf8)
  let sealed = try AES.GCM.seal(message, using: first)
  equal(try AES.GCM.open(sealed, using: second), message)
  equal(SecItemDelete(query as CFDictionary), errSecSuccess)
  do { _ = try WorktreeRecoveryKey.load(create: false, namespace: service); failTest("missing recovery key was recreated during restore") } catch {}
  print("PASS native Keychain temporary recovery-key create/read/encryption/delete; no production key was read or changed")
}
