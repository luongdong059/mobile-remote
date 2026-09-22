#!/bin/bash
# Builds WebDriverAgent (the XCUITest runner that gives iPhone control) and
# installs it on a cabled iPhone. Run once per phone and again when the
# signing profile expires (7 days on a free Apple ID).
#   TEAM=PCACWK2ZD7 scripts/install-wda.sh [UDID]
set -euo pipefail

TEAM="${TEAM:?set TEAM to your Apple Development team id (see: security find-identity -v -p codesigning)}"
BUNDLE_ID="com.nldong.WebDriverAgentRunner"
WORK="${WDA_DIR:-$HOME/Library/Caches/mobile-remote/wda}"
mkdir -p "$WORK"

UDID="${1:-}"
if [ -z "$UDID" ]; then
    UDID="$(xcrun xctrace list devices 2>/dev/null | grep -E '^\S.*\(\S+\) \([0-9A-F]{8}-[0-9A-F]{16}\)$' | head -1 | sed -E 's/.*\(([0-9A-F-]+)\)$/\1/')"
    [ -n "$UDID" ] || { echo "no cabled iPhone found; pass its UDID" >&2; exit 1; }
fi
echo "device: $UDID   team: $TEAM"

if [ ! -d "$WORK/WebDriverAgent" ]; then
    git clone --depth 1 https://github.com/appium/WebDriverAgent.git "$WORK/WebDriverAgent"
fi
cd "$WORK/WebDriverAgent"
xcodebuild build-for-testing -quiet -project WebDriverAgent.xcodeproj -scheme WebDriverAgentRunner \
    -destination "id=$UDID" -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM" \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" CODE_SIGN_STYLE=Automatic -derivedDataPath "$WORK/build"

RUNNER="$(find "$WORK/build/Build/Products" -name 'WebDriverAgentRunner-Runner.app' -path '*iphoneos*' | head -1)"
[ -n "$RUNNER" ] || { echo "runner app not found after build" >&2; exit 1; }
# The app runs it through xcodebuild (which also installs it), so the build
# products must stay here: Mobile Remote looks for the .xctestrun in this folder.
xcrun devicectl device install app --device "$UDID" "$RUNNER"
echo "installed $BUNDLE_ID.xctrunner on $UDID"
echo "xctestrun: $(ls "$WORK"/build/Build/Products/*.xctestrun | head -1)"
echo "On the phone, trust the developer once: Settings › General › VPN & Device Management."
