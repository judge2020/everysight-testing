#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo 'This launcher needs Apple Silicon macOS. See the simulator docs for other platforms.' >&2
  exit 1
fi
archive=.local/GlassesSimulator-0.2.0-arm64-mac.zip
app=.local/simulator/GlassesSimulator.app
if [[ ! -d "$app" ]]; then
  mkdir -p .local/simulator
  if [[ ! -f "$archive" ]]; then
    curl -fL --retry 3 -o "$archive.part" 'https://storage.googleapis.com/evs-pub/maverickai/simulator/v0.2.0/GlassesSimulator-0.2.0-arm64-mac.zip'
    mv "$archive.part" "$archive"
  fi
  echo "05baf84d93671d6d0361d6644b190f96fc3d5cb8a0437ec55a2618797b584242  $archive" | shasum -a 256 -c -
  ditto -xk "$archive" .local/simulator
fi
open "$app"
echo 'Glasses simulator dashboard: http://127.0.0.1:8765/'
echo 'In the iOS app: Init SDK → Configure glasses → Simulator.'
echo 'Host: 127.0.0.1 from an iOS Simulator; use this Mac’s LAN IP from a physical iPhone.'
