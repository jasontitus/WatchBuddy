#!/usr/bin/env bash
#
# Build & upload WatchAI to TestFlight / App Store Connect.
# Encodes the workarounds documented in docs/RELEASE.md.
#
# Prereqs: Xcode + watchOS platform (`xcodebuild -downloadPlatform watchOS`),
# and fastlane/api_key.json (App Store Connect API key; gitignored).
#
# Remember to bump CURRENT_PROJECT_VERSION (and MARKETING_VERSION when the train
# is closed) in WatchAI.xcodeproj/project.pbxproj before running.
#
set -euo pipefail
cd "$(dirname "$0")/.."

# Gotcha 2: put system rsync ahead of Homebrew's rsync 3.4.x, which breaks
# xcodebuild's exportArchive ("rsync: syntax or usage error ... Copy failed").
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

API_KEY_JSON="fastlane/api_key.json"
[ -f "$API_KEY_JSON" ] || { echo "Missing $API_KEY_JSON (App Store Connect API key)"; exit 1; }

KEY_ID=$(python3 -c "import json;print(json.load(open('$API_KEY_JSON'))['key_id'])")
ISSUER=$(python3 -c "import json;print(json.load(open('$API_KEY_JSON'))['issuer_id'])")
P8="$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8"

# Extract the .p8 private key from api_key.json (idempotent).
if [ ! -f "$P8" ]; then
  mkdir -p "$(dirname "$P8")"
  python3 - "$API_KEY_JSON" "$P8" <<'PY'
import json, sys, os, textwrap
d = json.load(open(sys.argv[1])); key = d['key']
pem = key if '-----BEGIN' in key else \
    "-----BEGIN PRIVATE KEY-----\n" + "\n".join(textwrap.wrap(key.replace('\n','').strip(), 64)) + "\n-----END PRIVATE KEY-----\n"
if not pem.endswith('\n'): pem += '\n'
open(sys.argv[2], 'w').write(pem); os.chmod(sys.argv[2], 0o600)
PY
fi

AUTH=(-allowProvisioningUpdates \
  -authenticationKeyPath "$P8" \
  -authenticationKeyID "$KEY_ID" \
  -authenticationKeyIssuerID "$ISSUER")

rm -rf build && mkdir -p build

echo "==> Archiving (iOS + embedded watch app)..."
xcodebuild -project WatchAI.xcodeproj -scheme WatchAI -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/WatchAI.xcarchive \
  "${AUTH[@]}" clean archive

echo "==> Exporting + uploading to App Store Connect..."
xcodebuild -exportArchive -archivePath build/WatchAI.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath build/export "${AUTH[@]}"

echo "==> Done. Build is processing in App Store Connect / TestFlight."
