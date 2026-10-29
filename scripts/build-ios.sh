#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project ios/EverysightPlayground.xcodeproj \
  -scheme EverysightPlayground \
  -destination 'generic/platform=iOS Simulator' \
  -clonedSourcePackagesDirPath .local/SourcePackages \
  -derivedDataPath .local/DerivedData \
  CODE_SIGNING_ALLOWED=NO "$@" build
