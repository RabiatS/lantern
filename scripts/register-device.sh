#!/bin/zsh
# Build once for a connected iPhone so Xcode registers it on the team. The
# archive needs at least one registered device; this is the only reason to
# build for a device from the command line.
#
# Usage: scripts/register-device.sh <device-udid>
set -euo pipefail

cd "$(dirname "$0")/.."
UDID="${1:?device udid}"

xcodebuild build \
  -project Lantern.xcodeproj -scheme Lantern \
  -destination "id=$UDID" \
  -derivedDataPath DerivedData \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  -skipPackagePluginValidation -skipMacroValidation \
  -quiet

echo "==> Device $UDID registered and the app built for it."
