#!/bin/zsh
# Tests, archive, export and upload to TestFlight in one go.
#
# Needs: the Apple Developer account added in Xcode (Settings, Accounts), the
# app record created in App Store Connect for the bundle id, and one device
# registered (see scripts/register-device.sh). No API key: the upload goes
# through Xcode's account session with -allowProvisioningUpdates.
#
# Usage: scripts/testflight.sh [build-number]
# The build number defaults to the number of commits on the current branch.
set -euo pipefail

cd "$(dirname "$0")/.."
PROJECT=Lantern.xcodeproj
SCHEME=Lantern
BUILD_NUMBER="${1:-$(git rev-list --count HEAD)}"
OUT="build/testflight"
ARCHIVE="$OUT/Lantern.xcarchive"
EXPORT="$OUT/export"
# Tests run on a plain simulator, never on the developer's own phone.
TEST_SIM="platform=iOS Simulator,name=iPhone 17"

mkdir -p "$OUT"
rm -rf "$ARCHIVE" "$EXPORT"

echo "==> Tests on $TEST_SIM"
xcodebuild test \
  -project "$PROJECT" -scheme "$SCHEME" \
  -destination "$TEST_SIM" \
  -derivedDataPath DerivedData \
  -skipPackagePluginValidation -skipMacroValidation \
  -quiet

echo "==> Archive, build $BUILD_NUMBER"
xcodebuild archive \
  -project "$PROJECT" -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -derivedDataPath DerivedData \
  -allowProvisioningUpdates \
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
	<string>automatic</string>
	<key>teamID</key>
	<string>T27289T9P3</string>
	<key>uploadSymbols</key>
	<true/>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
</dict>
</plist>
PLIST

echo "==> Export and upload"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -exportPath "$EXPORT" \
  -allowProvisioningUpdates

echo "==> Uploaded build $BUILD_NUMBER. It appears in App Store Connect, TestFlight, after processing."
