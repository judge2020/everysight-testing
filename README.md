# Everysight Testing

Native Swift / UIKit sensor dashboard for **Maverick AI / AI Pro**, generated from
Everysight's official starter and verified against **SDK 0.2.0** on 2026-10-29.
The glasses simulator is **0.2.0**. Both were the latest published releases checked
on that date. This uses the AI SDK, rather than the older Maverick Sport SDK.

## Start

```sh
./scripts/setup-tools.sh
./scripts/simulator.sh
open ios/EverysightPlayground.xcodeproj
```

Choose an iPhone simulator in Xcode and Run, or run:

```sh
./scripts/run-ios.sh
```

The launcher starts the desktop glasses simulator while it builds the app, then
boots/opens the iPhone simulator, installs and launches the dashboard. The SDK
initializes automatically and reconnects to the saved target. Once a simulator or
pair of glasses has been configured, there is no need to enter localhost or click
Connect on every launch. The dashboard also mirrors a compact status HUD on glasses.

For a physical iPhone, select your signing team in Xcode's Signing & Capabilities.
The minimum deployment target is iOS 16; simulator builds target Apple Silicon.
The app uses UIKit scenes, required by iOS 27. The launcher supports Xcode 27's
Device Hub and the Simulator app in earlier Xcode versions.
If Xcode has no iOS simulator runtime, install iOS in Xcode → Settings → Components,
or run `xcodebuild -downloadPlatform iOS -architectureVariant arm64`.

## Sensor dashboard

All visible readings and the glasses status HUD refresh on a **one-second timer**.
SDK callbacks update a locked latest-value store without driving UI redraws.
Each reading shows its sample count, age, and device timestamp when supplied.
Continuous streams are marked stale after three seconds without samples; unchanged
event-driven values retain their last-event age. Scrolling is preserved during updates.

The dashboard subscribes to:

- Accelerometer, gyroscope, magnetometer, fused quaternion, yaw/pitch/roll and IMU calibration.
- Ambient light, on-face/proximity, touch gestures, power-button and device-enable events.
- Battery percentage, battery power, charging and display/brightness telemetry.
- Eye-tracker state, frame rate, validity, pupil visibility, filtered pupil center,
  iris/pupil ellipses, eye corners, eyelid apexes, raw/filtered LED glint and frame metadata.
  Eye-camera coordinates are distinct from calibrated screen gaze.
- Directional and omni microphone packet counts/throughput, plus the directional
  PCM RMS/peak level for each one-second interval. No audio recordings are stored.

**The AI vision camera is never opened or read.** There are no vision-service calls
or camera permissions in the app. The dedicated eye tracker remains enabled.

Pause stops sensor collection and unregisters callbacks. Collection also stops in
the background and resumes on return when enabled. New sessions clear old samples.

Auto reconnect is enabled by default. The successful simulator host or Bluetooth
address is remembered; the SDK's existing target is also reused on the first launch
of this dashboard. Dropped connections retry with backoff (1–15 s), and attempts
that fail to become ready within 20 s are restarted. Explicit Disconnect disables
auto reconnect until Connect or the switch is used again. No credentials are stored
in connection preferences.

Simulator 0.2.0 was verified sending **synthetic eye geometry at about 15 Hz**, fused
orientation at 1 Hz, ambient events and both microphone streams. Its raw IMU streams
and proximity may be unavailable; missing samples are displayed honestly. The
public simulator guide currently understates its eye-feature support; runtime
callbacks from the pinned SDK/simulator are the evidence for the eye readouts.
Physical glasses, their raw IMU streams and real eye tracking have not been tested.

## Developer key

Developer keys are not included in this repository. If you store yours as a Document
named **Everysight Maverick SDK Key** in a 1Password **Private** vault, restore it with:

```sh
./scripts/key-from-1password.sh
```


Request an Everysight developer key for bundle ID
**`com.judge2020.everysightplayground`** using the
[official key instructions](https://everysight.github.io/maverick-ai-docs/getting-started/api-key/).
If you already have a key for a different namespace, change the Xcode bundle ID to
match it. Put the actual file at:

```
ios/EverysightPlayground/sdk.key
```

Rebuild. A build phase copies a nonempty key into the bundle and removes any stale
bundled key when the source is absent. Keys are ignored by Git. No placeholder key
is supplied. The app disables Connect when no key is bundled; initialization and
configuration remain available. The simulator also requires a valid key. A native
iOS app uses the public Swift package and needs no GitHub Packages token.

## Glasses simulator

`./scripts/simulator.sh` downloads the pinned official macOS ARM64 archive if needed,
checks its recorded SHA-256, extracts it into `.local/simulator/`, and opens it.
The simulator dashboard is at <http://127.0.0.1:8765/>; the SDK uses port 8765.

For the first connection to a new target, tap **Configure → Simulator**. Enter **only the host**:

- iPhone simulator on this Mac: `127.0.0.1`.
- Physical iPhone: this Mac's LAN IP, on the same network. Allow Local Network access.

The simulator must be running and disconnected from other clients. Once ready,
the sensor status HUD appears automatically. Camera capture is disabled in this app.
Microphone data uses the Mac microphone; orientation and simulated eye features
are driven by the simulator. Test final behavior on actual glasses.

## Asset tools

`./scripts/setup-tools.sh` installs pinned Python dependencies into `.venv/` and
installs ImageMagick / optipng via Homebrew if missing. Original Everysight scripts,
licenses, and provenance are in `tools/everysight/`. Pillow is pinned to 12.3.0:
Pillow 13 removed the PNG mode used by the upstream 16-bit image converter.

```sh
./scripts/tool.sh image input.png -o output.png --bpp 16 --alpha
./scripts/tool.sh font --path /path/to/font.ttf --size 24
./scripts/tool.sh sprite --help
```

The font tool writes outputs alongside its input font. The sprite tool generates
PNG sprite sheets and Kotlin source; the images can also be used by the Swift app.
See each tool's README or `--help` for options.

## SDK development tools

Three official skills are available to Codex within this repo under `.agents/skills/`:
`evs-mav2-sdk-quickstart`, `evs-mav2-sdk-assistant`, and `evs-mav2-sdk-api-guide`.
The official documentation MCP is configured for this project in
`.codex/config.toml`. Start a new trusted coding session in this folder to load it.
The setup used official web docs and upstream samples directly; the MCP endpoint
was also verified with a successful protocol initialization.

SDK package versions are pinned in the Xcode project and `Package.resolved`.
The `Copy Maverick AI Compose Resources` phase is required for the SDK's phone UI.
Local downloads, build logs, simulator files and derived data live under `.local/`
and are ignored by Git. Python dependencies are pinned in `requirements-tools.txt`.
Repository: https://github.com/judge2020/everysight-testing

## Official references

- [Developer portal](https://everysight.github.io/maverick-ai-docs/)
- [iOS integration](https://everysight.github.io/maverick-ai-docs/libraries-api/ios/)
- [Simulator setup](https://everysight.github.io/maverick-ai-docs/guides/simulator/)
- [SDK releases and samples](https://github.com/everysight-maverick-AI/sdk)
- [iOS Swift package](https://github.com/everysight-maverick-AI/mav-ai-ios-spm)
- [AI development tools](https://everysight.github.io/maverick-ai-docs/getting-started/vibe-coding/)

## Verified on this Mac

- Xcode 27.0; iOS 27.0 ARM64 simulator runtime installed.
- Debug iOS simulator build, installation, and launch succeeded.
- Release device build succeeded with code signing disabled.
- SDK initializes automatically; app relaunch reuses the saved target without input.
- One-second UI updates, stable scrolling, live eye geometry and microphone levels verified.
- Simulator shutdown/restart recovered automatically; explicit Disconnect stayed disconnected
  until Connect was pressed again.
- The simulator reported CAMERA PREVIEW OFF on the final build; app sources contain no
  vision-service calls and Info.plist contains no camera permission.
- Connected the iPhone simulator to glasses simulator 0.2.0 at `127.0.0.1`.
  The app reached **ready**, and the simulator displayed the sensor status HUD.
- Developer key restored via `op`, byte-for-byte verified, and bundled locally.
  Keys and local build artifacts are excluded from Git.
- Image conversion, font conversion, and sprite generation smoke tests passed.

Build and diagnostic logs are local under `.local/`. The app and glasses simulator
are left running, connected to each other. Physical glasses were not tested.
