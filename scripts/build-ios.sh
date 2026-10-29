#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -d .local/discord-sdk/discord_social_sdk/lib/release/discord_partner_sdk.xcframework ]]; then
  ./scripts/setup-discord-sdk.sh
fi
xcodebuild -project ios/EverysightPlayground.xcodeproj \
  -scheme EverysightPlayground \
  -destination 'generic/platform=iOS Simulator' \
  -clonedSourcePackagesDirPath .local/SourcePackages \
  -derivedDataPath .local/DerivedData \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- "$@" build
