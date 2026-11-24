#!/bin/bash
# Save and restore the maintainer's Apple Developer ID identity in the personal 1Password
# vault. The historical BurnZombies Local Signing backup has a separate document title.
# Usage: scripts/release-identity.sh save | load
set -euo pipefail
umask 077

name="${BURNZOMBIES_SIGNING_IDENTITY:-Developer ID Application: skylar graika (7K3GR5QJRH)}"
pin="${BURNZOMBIES_RELEASE_CERT_SHA256:-c68cfaf7b2157bd1be74d4d6e60398f720372936bd03a1ac7dea2eb0d6beea03}"
preferred_keychain="$HOME/Library/Keychains/BurnZombies-Developer-ID.keychain-db"
[[ -f "$preferred_keychain" ]] || preferred_keychain="$HOME/Library/Keychains/login.keychain-db"
keychain="${BURNZOMBIES_KEYCHAIN:-$preferred_keychain}"
vault="${BURNZOMBIES_OP_VAULT:-skylar}"
title="BurnZombies Developer ID Application signing identity"
ssl=/usr/bin/openssl # macOS's LibreSSL reads and writes the PKCS#12 algorithms the keychain uses.
sha1=""

die() {
  echo "$*" >&2
  exit 1
}
[[ $# -eq 1 && ("$1" == load || "$1" == save) ]] || die "Usage: $0 load|save"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [[ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]]; then
  OP_SERVICE_ACCOUNT_TOKEN="$(security find-generic-password \
    -s "${BURNZOMBIES_OP_TOKEN_ITEM:-codex-1password-service-account-token}" -w 2>/dev/null || true)"
fi
if [[ -n "$OP_SERVICE_ACCOUNT_TOKEN" ]]; then export OP_SERVICE_ACCOUNT_TOKEN; else unset OP_SERVICE_ACCOUNT_TOKEN; fi

needs_op() {
  command -v op >/dev/null || die "Needs the 1Password CLI: brew install 1password-cli."
}
op_() { op "$@" --vault "$vault" ${BURNZOMBIES_OP_ACCOUNT:+--account "$BURNZOMBIES_OP_ACCOUNT"}; }

# The SHA-256 of a PEM certificate's DER bytes: the hash package-release.sh pins.
cert_sha256() { "$ssl" x509 -in "$1" -outform DER | shasum -a 256 | awk '{print $1}'; }

# Splits the PEM bundle $1 into cert.pem and key.pem in folder $2, checks that it is the release
# certificate with its own private key, and sets sha1 to the certificate's SHA-1 (codesign's ID).
check_bundle() {
  "$ssl" x509 -in "$1" -out "$2/cert.pem" 2>/dev/null || die "$1 holds no certificate."
  "$ssl" pkey -in "$1" -out "$2/key.pem" 2>/dev/null || die "$1 holds no private key."
  local actual
  actual="$(cert_sha256 "$2/cert.pem")"
  [[ "$actual" == "$pin" ]] || die "That certificate is $actual, not the release certificate $pin."
  [[ "$("$ssl" x509 -in "$2/cert.pem" -noout -pubkey)" == "$("$ssl" pkey -in "$2/key.pem" -pubout)" ]] ||
    die "That private key does not belong to the release certificate."
  sha1="$("$ssl" x509 -in "$2/cert.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')"
}

# Writes $work/identity.pem from the keychain: exactly the identity whose certificate is the
# release certificate, nothing else, exported under a passphrase that exists only while this runs.
export_bundle() {
  cat >"$work/export.swift" <<'SWIFT'
import CryptoKit
import Foundation
import Security

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
// Unattended execution must report an authorization failure without showing a system prompt.
SecKeychainSetUserInteractionAllowed(false)
let arguments = CommandLine.arguments
guard arguments.count == 4, let passphrase = ProcessInfo.processInfo.environment["BZ_P12_PASSPHRASE"] else {
    fail("usage: export.swift KEYCHAIN CERTIFICATE_SHA256 OUTPUT, with the passphrase in BZ_P12_PASSPHRASE")
}
var keychain: SecKeychain?
guard SecKeychainOpen(arguments[1], &keychain) == errSecSuccess, let keychain else {
    fail("Cannot open \(arguments[1]).")
}
let query: [String: Any] = [
    kSecClass as String: kSecClassIdentity,
    kSecMatchSearchList as String: [keychain],
    kSecMatchLimit as String: kSecMatchLimitAll,
    kSecReturnRef as String: true,
]
var found: CFTypeRef?
let status = SecItemCopyMatching(query as CFDictionary, &found)
let identities = status == errSecSuccess ? (found as? [SecIdentity] ?? []) : []
for identity in identities {
    var certificate: SecCertificate?
    guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { continue }
    let digest = SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
    guard digest.map({ String(format: "%02x", $0) }).joined() == arguments[2] else { continue }
    let secret = passphrase as CFString
    var parameters = SecItemImportExportKeyParameters()
    parameters.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
    parameters.passphrase = Unmanaged.passUnretained(secret as AnyObject)
    var exported: CFData?
    let result = withExtendedLifetime(secret) { SecItemExport(identity, .formatPKCS12, [], &parameters, &exported) }
    guard result == errSecSuccess, let exported else {
        fail("macOS did not export the identity: \((SecCopyErrorMessageString(result, nil) as String?) ?? "error \(result)").")
    }
    guard FileManager.default.createFile(atPath: arguments[3], contents: exported as Data, attributes: [.posixPermissions: 0o600]) else {
        fail("Cannot write \(arguments[3]).")
    }
    exit(0)
}
fail("No identity in \(arguments[1]) has the release certificate \(arguments[2]). Run save on the Mac that has it.")
SWIFT
  local passphrase
  passphrase="$("$ssl" rand -hex 16)"
  echo "Backing up the selected Developer ID identity." >&2
  BZ_P12_PASSPHRASE="$passphrase" swift -swift-version 5 -suppress-warnings "$work/export.swift" "$keychain" "$pin" "$work/export.p12"
  BZ_P12_PASSPHRASE="$passphrase" "$ssl" pkcs12 -in "$work/export.p12" -passin env:BZ_P12_PASSPHRASE -nodes \
    -out "$work/export.pem" 2>/dev/null || die "Cannot read the exported identity."
  rm "$work/export.p12"
  check_bundle "$work/export.pem" "$work"
  cat "$work/cert.pem" "$work/key.pem" >"$work/identity.pem"
}

# Imports $work/cert.pem and key.pem into $keychain.
install_identity() {
  local passphrase
  passphrase="$("$ssl" rand -hex 16)"
  BZ_P12_PASSPHRASE="$passphrase" "$ssl" pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" \
    -out "$work/identity.p12" -passout env:BZ_P12_PASSPHRASE -name "$name" >/dev/null 2>&1 ||
    die "Cannot package the identity for the keychain."
  security import "$work/identity.p12" -k "$keychain" -P "$passphrase" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null
}

# Signs a test file with the identity and checks that the signature carries the release
# certificate.
prove_signing() {
  grep -qF "$sha1" <<<"$(security find-identity -p codesigning "$keychain")" ||
    die "\"$name\" is not in $keychain."
  cp /usr/bin/true "$work/probe"
  local signed
  signed="$(codesign --force --sign "$sha1" --keychain "$keychain" "$work/probe" 2>&1)" ||
    die "codesign cannot sign with \"$name\": $signed"
  codesign --verify --strict -R '=anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "7K3GR5QJRH"' "$work/probe"
  codesign -d --extract-certificates="$work/probe-cert" "$work/probe" 2>/dev/null
  [[ "$(shasum -a 256 "$work/probe-cert0" | awk '{print $1}')" == "$pin" ]] ||
    die "The test file was not signed with the release certificate."
}

# The ID of the 1Password document called $title, or nothing when there is none.
saved_document() {
  local listing
  listing="$(op_ document list --format json)" ||
    die "1Password did not answer for the vault $vault. Check OP_SERVICE_ACCOUNT_TOKEN (or that the 1Password app is unlocked) and try again."
  python3 -c '
import json, sys
matches = [d["id"] for d in json.load(sys.stdin) if d.get("title") == sys.argv[1]]
if len(matches) > 1:
    sys.exit("1Password has %d documents called %r. Keep one and try again." % (len(matches), sys.argv[1]))
print(matches[0] if matches else "")' "$title" <<<"$listing"
}

load() {
  needs_op
  op_ document get "$title" --out-file "$work/identity.pem" >/dev/null ||
    die "Cannot read \"$title\" from the 1Password vault $vault. Run save on the Mac that has the identity first."
  check_bundle "$work/identity.pem" "$work"

  # codesign finds identities by name, so another identity with this name would be ambiguous.
  local listed others
  listed="$(security find-identity -p codesigning; security find-identity -p codesigning "$keychain")"
  others="$(grep -F "\"$name\"" <<<"$listed" | grep -v -F "$sha1" | awk '{print $2}' | sort -u | tr '\n' ' ')" || true
  [[ -z "$others" ]] ||
    die "This Mac already has a different \"$name\" (SHA-1 $others), probably made by scripts/ensure-signing-identity.sh. Remove it in Keychain Access (login > My Certificates), then run load again. Anything this Mac signed with it will need Full Disk Access allowed again."

  if ! grep -qF "$sha1" <<<"$(security find-identity -p codesigning "$keychain")"; then
    install_identity
  fi
  echo "Signing a test file. If macOS asks whether codesign may use the key, choose Always Allow; it asks once per Mac." >&2
  prove_signing
  echo "Ready: this Mac signs with the release certificate. scripts/build-app.sh and scripts/package-release.sh use it from now on." >&2
}

save() {
  needs_op
  local id
  id="$(saved_document)"
  if [[ -n "$id" ]]; then
    mkdir "$work/saved"
    op_ document get "$id" --out-file "$work/saved/identity.pem" >/dev/null
    (check_bundle "$work/saved/identity.pem" "$work/saved") ||
      die "The vault $vault already has a different \"$title\". Rename or archive it, then run save again."
    echo "The 1Password vault $vault already has \"$title\", and it is the release identity. Nothing to do." >&2
    return
  fi
  export_bundle
  op_ document create "$work/identity.pem" --title "$title" --file-name "$name.pem" --tags burnzombies >/dev/null
  # Reads it back the way load finds it: by title.
  op_ document get "$title" --out-file "$work/readback.pem" >/dev/null ||
    die "1Password saved \"$title\" but cannot return it. Check the vault $vault."
  cmp -s "$work/identity.pem" "$work/readback.pem" || die "1Password returned something else for \"$title\". Check the vault $vault."
  echo "Saved \"$name\" to the 1Password vault $vault as \"$title\" and read it back." >&2
}

"$1"
