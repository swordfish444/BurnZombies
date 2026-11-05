#!/bin/bash
# Keeps the release signing identity in 1Password, so any Mac the maintainer approves can build a
# release. Every release since v0.13.0 is signed with one self-signed certificate, and macOS ties
# Full Disk Access to it, so releases keep using that same key: a new identity
# (scripts/ensure-signing-identity.sh) would make every user allow BurnZombies again.
#
#   scripts/release-identity.sh save   On the Mac that has the identity: copies it from the login
#                                      keychain into 1Password, then reads it back. macOS asks
#                                      once to allow the export.
#   scripts/release-identity.sh load   On another Mac: installs it from 1Password into the login
#                                      keychain, trusted for code signing only (macOS asks for
#                                      the password), then signs a test file with it.
#
# Needs the 1Password CLI (op) with 1Password > Settings > Developer > Integrate with 1Password
# CLI turned on; 1Password asks for Touch ID. The identity is one Document item holding the
# certificate and private key as PEM; on disk it exists only in a private temporary folder while
# this script runs. BURNZOMBIES_OP_ACCOUNT picks the 1Password account (default
# my.1password.com) and BURNZOMBIES_OP_VAULT the vault that save uses (default: Personal or
# Private).
set -euo pipefail

name="${BURNZOMBIES_SIGNING_IDENTITY:-BurnZombies Local Signing}"
pin="${BURNZOMBIES_RELEASE_CERT_SHA256:-dbe8297fd599efa4bb942d0ebb5487e3bc27c15d7b71fadc8253da8ab1d697b9}"
keychain="${BURNZOMBIES_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
account="${BURNZOMBIES_OP_ACCOUNT:-my.1password.com}"
vault="${BURNZOMBIES_OP_VAULT:-}"
title="BurnZombies release signing identity"
ssl=/usr/bin/openssl # macOS's LibreSSL reads and writes the PKCS#12 algorithms the keychain uses.
sha1=""

die() {
  echo "$*" >&2
  exit 1
}
[[ $# -eq 1 && ("$1" == save || "$1" == load) ]] || die "Usage: $0 save|load"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

needs_op() {
  command -v op >/dev/null ||
    die "Needs the 1Password CLI: brew install 1password-cli, then turn on 1Password > Settings > Developer > Integrate with 1Password CLI."
}
op_() { op "$@" --account "$account"; }

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
  echo "Exporting \"$name\". If macOS asks to allow the export, enter your login password and choose Allow." >&2
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

# Checks that macOS accepts the identity for code signing and that a test file signed with it
# carries the release certificate.
prove_signing() {
  grep -qF "$sha1" <<<"$(security find-identity -v -p codesigning "$keychain")" ||
    die "\"$name\" is in the keychain, but macOS does not accept it for code signing."
  cp /usr/bin/true "$work/probe"
  local signed
  signed="$(codesign --force --sign "$sha1" --keychain "$keychain" "$work/probe" 2>&1)" ||
    die "codesign cannot sign with \"$name\": $signed"
  codesign -d --extract-certificates="$work/probe-cert" "$work/probe" 2>/dev/null
  [[ "$(shasum -a 256 "$work/probe-cert0" | awk '{print $1}')" == "$pin" ]] ||
    die "The test file was not signed with the release certificate."
}

# The ID of the 1Password document called $title, or nothing when there is none.
saved_document() {
  local listing
  listing="$(op_ document list --format json)" ||
    die "1Password did not answer. Unlock it, check that Settings > Developer > Integrate with 1Password CLI is on, and try again."
  python3 -c '
import json, sys
matches = [d["id"] for d in json.load(sys.stdin) if d.get("title") == sys.argv[1]]
if len(matches) > 1:
    sys.exit("1Password has %d documents called %r. Keep one and try again." % (len(matches), sys.argv[1]))
print(matches[0] if matches else "")' "$title" <<<"$listing"
}

save() {
  needs_op
  local id
  id="$(saved_document)"
  if [[ -n "$id" ]]; then
    mkdir "$work/saved"
    op_ document get "$id" --out-file "$work/saved/identity.pem" >/dev/null
    (check_bundle "$work/saved/identity.pem" "$work/saved") ||
      die "1Password already has a different \"$title\". Rename or archive it, then run save again."
    echo "1Password already has \"$title\" ($account), and it is the release identity. Nothing to do." >&2
    return
  fi
  export_bundle
  op_ document create "$work/identity.pem" --title "$title" --file-name "$name.pem" --tags burnzombies \
    ${vault:+--vault "$vault"} >/dev/null
  # Reads it back the way load finds it: by title.
  op_ document get "$title" --out-file "$work/readback.pem" >/dev/null ||
    die "1Password saved \"$title\" but cannot return it. Check the app."
  cmp -s "$work/identity.pem" "$work/readback.pem" || die "1Password returned something else for \"$title\". Check the app."
  echo "Saved \"$name\" to 1Password as \"$title\" ($account) and read it back." >&2
}

load() {
  needs_op
  op_ document get "$title" --out-file "$work/identity.pem" >/dev/null ||
    die "Cannot read \"$title\" from 1Password ($account). Run save on the Mac that has the identity first."
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
  if ! grep -qF "$sha1" <<<"$(security find-identity -v -p codesigning "$keychain")"; then
    echo "Trusting \"$name\" for code signing only. macOS asks for your password." >&2
    security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$work/cert.pem" >/dev/null
  fi
  echo "Signing a test file. If macOS asks whether codesign may use the key, choose Always Allow." >&2
  prove_signing
  echo "Ready: this Mac signs with the release certificate. scripts/build-app.sh and scripts/package-release.sh use it from now on." >&2
}

"$1"
