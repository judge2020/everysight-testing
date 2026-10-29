#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Start the desktop target while Xcode builds, so the saved simulator connection is ready.
./scripts/simulator.sh
./scripts/build-ios.sh
# Supply a specific iPhone UDID as the first argument, or use the first available one.
device="${1:-$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin); phones=[x for k,v in d["devices"].items() if ".iOS-" in k for x in v if "iPhone" in x["name"]]; print(next((x["udid"] for x in phones if x["state"] == "Booted"), phones[0]["udid"] if phones else ""))')}"
if [[ -z "$device" ]]; then
  runtime="$(xcrun simctl list runtimes -j | python3 -c 'import json,sys; print(next((x["identifier"] for x in reversed(json.load(sys.stdin)["runtimes"]) if x.get("isAvailable") and ".iOS-" in x["identifier"]), ""))')"
  if [[ -z "$runtime" ]]; then
    echo 'No iOS runtime. Install iOS in Xcode → Settings → Components.' >&2
    exit 1
  fi
  device_type="$(xcrun simctl list devicetypes -j | python3 -c 'import json,sys; print(next(x["identifier"] for x in reversed(json.load(sys.stdin)["devicetypes"]) if x.get("productFamily") == "iPhone"))')"
  device="$(xcrun simctl create 'Everysight iPhone' "$device_type" "$runtime")"
fi
state="$(xcrun simctl list devices -j | python3 -c 'import json,sys; print(next((x["state"] for v in json.load(sys.stdin)["devices"].values() for x in v if x["udid"] == sys.argv[1]), ""))' "$device")"
if [[ "$state" != Booted ]]; then
  xcrun simctl boot "$device"
fi
developer_dir="$(xcode-select -p)"
if [[ -d "${developer_dir%/Developer}/Applications/DeviceHub.app" ]]; then
  open "${developer_dir%/Developer}/Applications/DeviceHub.app"
else
  open "$developer_dir/Applications/Simulator.app"
fi
xcrun simctl bootstatus "$device" -b
xcrun simctl install "$device" .local/DerivedData/Build/Products/Debug-iphonesimulator/EverysightPlayground.app
xcrun simctl launch "$device" com.judge2020.everysightplayground
