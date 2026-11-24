#!/bin/bash
# Checks and guides one-time setup of Apple Developer ID Application signing & notarization
# for BurnZombies on a local Mac (Apple account: riptidez55@hotmail.com).
set -euo pipefail
cd "$(dirname "$0")/.."

notary_profile="${BURNZOMBIES_NOTARY_PROFILE:-burnzombies-notary}"
echo "==> Checking local code-signing identities..."
identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
echo "$identities"

dev_id="$(printf '%s\n' "$identities" | sed -n 's/.*"\(Developer ID Application: [^"]* (7K3GR5QJRH)\)".*/\1/p' | head -n 1 || true)"
if [[ -z "$dev_id" ]]; then
  cat <<'EOF'

NEXT STEP 1 — Install your Apple "Developer ID Application" certificate on this Mac:
  1. Open Xcode → Settings → Accounts → Sign in with riptidez55@hotmail.com.
  2. Select your Apple Developer Team → Manage Certificates… → click "+" → choose "Developer ID Application".
  3. Verify it appears by re-running: scripts/setup-apple-signing.sh

EOF
  exit 1
fi

team_id="$(printf '%s\n' "$dev_id" | sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p')"
echo "OK: Found Developer ID: $dev_id (Team ID: ${team_id:-unknown})"

echo "==> Checking notarytool keychain profile ($notary_profile)..."
if xcrun notarytool history --keychain-profile "$notary_profile" >/dev/null 2>&1; then
  echo "OK: notarytool profile '$notary_profile' is authenticated and working."
else
  cat <<EOF

NEXT STEP 2 — Store your Apple Notarization credentials once in Keychain:
  Option A (recommended — App Store Connect API Key from https://appstoreconnect.apple.com/access/integrations/api):
    xcrun notarytool store-credentials "$notary_profile" \\
      --key /path/to/AuthKey_KEYID.p8 --key-id KEYID --issuer ISSUER_UUID

  Option B (Apple ID + App-Specific Password from https://account.apple.com):
    xcrun notarytool store-credentials "$notary_profile" \\
      --apple-id riptidez55@hotmail.com --team-id "${team_id:-YOUR_TEAM_ID}"

Then re-run: scripts/setup-apple-signing.sh
EOF
  exit 1
fi

echo "==> All Apple Developer ID signing and notarization prerequisites are ready!"
echo "    Team ID: $team_id"
echo "    Run: scripts/release-all.sh --publish"
