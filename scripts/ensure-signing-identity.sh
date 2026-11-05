#!/bin/bash
# Creates BurnZombies' local code signing identity once, and never replaces it.
#
# macOS keys privacy grants such as Full Disk Access to the app's designated requirement. For an
# app signed with this certificate that requirement pins the certificate, so every later build
# keeps the grant; an ad-hoc build pins its own hash and loses it on each update. Regenerating
# the certificate would revoke every grant again, so this script exits untouched when the
# identity exists. Set BURNZOMBIES_SIGNING_IDENTITY to use an identity you already have; an
# Apple Developer ID Application certificate also allows notarization.
#
# Releases are signed in GitHub Actions with the release identity, never a new one: see
# scripts/release-identity.sh.
#
# Creating the identity adds a certificate to your login keychain and trusts it for code
# signing only; macOS asks for your password once.
set -euo pipefail
identity="${BURNZOMBIES_SIGNING_IDENTITY:-BurnZombies Local Signing}"

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "\"$identity\""; then
  echo "$identity"
  exit 0
fi

echo "Creating the code signing identity \"$identity\" (one time only)." >&2
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

cat > "$workdir/openssl.cnf" <<CONFIG
[ req ]
distinguished_name = dn
prompt = no
x509_extensions = v3
[ dn ]
CN = $identity
[ v3 ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CONFIG

openssl req -x509 -newkey rsa:2048 -nodes -days 7300 \
  -keyout "$workdir/key.pem" -out "$workdir/cert.pem" -config "$workdir/openssl.cnf" >/dev/null 2>&1

# macOS cannot read OpenSSL 3's default PKCS#12 algorithms, so export with the legacy set.
password="$(openssl rand -hex 16)"
openssl pkcs12 -export -inkey "$workdir/key.pem" -in "$workdir/cert.pem" \
  -out "$workdir/identity.p12" -passout "pass:$password" -name "$identity" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 >/dev/null 2>&1

keychain="$HOME/Library/Keychains/login.keychain-db"
security import "$workdir/identity.p12" -k "$keychain" -P "$password" \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$workdir/cert.pem" >/dev/null

if ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "\"$identity\""; then
  echo "\"$identity\" was imported but cannot sign code." >&2
  exit 1
fi
echo "Created \"$identity\". If macOS asks whether codesign may use it, choose Always Allow." >&2
echo "$identity"
