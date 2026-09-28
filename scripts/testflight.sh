#!/bin/zsh
# Tests, archive, export and upload to TestFlight in one go.
#
# Needs: the app record in App Store Connect for the bundle id, one device
# registered (scripts/register-device.sh), and either the App Store Connect
# API key at ~/.private_keys (used when present, the reliable path) or a
# signed-in Xcode account session. The export signs manually with the local
# Apple Distribution certificate and the "Lantern App Store" profile, because
# an App Manager key cannot do cloud signing.
#
# Usage: scripts/testflight.sh [build-number] [ios|mac]
# The build number defaults to the number of commits on the current branch.
# The platform defaults to ios. The Mac build uploads the same code as a Mac
# App Store package, signed with the "Lantern Mac App Store" profile and the
# Mac Installer Distribution certificate; build numbers count per platform.
set -euo pipefail

cd "$(dirname "$0")/.."
PROJECT=Lantern.xcodeproj
SCHEME=Lantern
BUILD_NUMBER="${1:-$(git rev-list --count HEAD)}"
PLATFORM="${2:-ios}"
case "$PLATFORM" in
  ios) DESTINATION='generic/platform=iOS'; PROFILE="Lantern App Store"; INSTALLER="" ;;
  mac) DESTINATION='generic/platform=macOS'; PROFILE="Lantern Mac App Store"
       INSTALLER="<key>installerSigningCertificate</key><string>3rd Party Mac Developer Installer</string>" ;;
  *) echo "platform must be ios or mac"; exit 2 ;;
esac
OUT="build/testflight-$PLATFORM"
ARCHIVE="$OUT/Lantern.xcarchive"
EXPORT="$OUT/export"
# Tests run on a plain simulator, never on the developer's own phone.
TEST_SIM="platform=iOS Simulator,name=iPhone 17"
ASC_KEY_ID="${ASC_KEY_ID:-QLJD26FTGP}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-83314295-c12b-4e10-a39d-35bee3e8ffc7}"
ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.private_keys/AuthKey_$ASC_KEY_ID.p8}"
AUTH=()
if [[ -f "$ASC_KEY_PATH" ]]; then
  AUTH=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

mkdir -p "$OUT"
rm -rf "$ARCHIVE" "$EXPORT"

echo "==> Tests on $TEST_SIM"
xcodebuild test \
  -project "$PROJECT" -scheme "$SCHEME" \
  -destination "$TEST_SIM" \
  -derivedDataPath DerivedData \
  -skipPackagePluginValidation -skipMacroValidation \
  -quiet

echo "==> Archive $PLATFORM, build $BUILD_NUMBER"
xcodebuild archive \
  -project "$PROJECT" -scheme "$SCHEME" \
  -configuration Release \
  -destination "$DESTINATION" \
  -archivePath "$ARCHIVE" \
  -derivedDataPath DerivedData \
  -allowProvisioningUpdates "${AUTH[@]}" \
  -skipPackagePluginValidation -skipMacroValidation \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -quiet

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>upload</string>
	<key>signingStyle</key>
	<string>manual</string>
	<key>signingCertificate</key>
	<string>Apple Distribution</string>
	<key>provisioningProfiles</key>
	<dict>
		<key>com.rabiats.lanternapp</key>
		<string>$PROFILE</string>
	</dict>
	$INSTALLER
	<key>teamID</key>
	<string>T27289T9P3</string>
	<key>uploadSymbols</key>
	<true/>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
</dict>
</plist>
PLIST

echo "==> Install the App Store profile if the key is available"
if [[ -f "$ASC_KEY_PATH" ]]; then
  python3 scripts/asc.py install-profile "$PROFILE"
fi

echo "==> Export and upload"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -exportPath "$EXPORT" \
  -allowProvisioningUpdates "${AUTH[@]}"

echo "==> Uploaded $PLATFORM build $BUILD_NUMBER. It appears in App Store Connect, TestFlight, after processing."
