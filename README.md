# Discord Glasses

Native Swift / UIKit iOS app showing Discord Social SDK direct messages on
Everysight Maverick AI / AI Pro glasses. The Swift app calls the official Discord standalone C++
SDK through a small Objective-C++ bridge; Maverick AI stays pinned to **0.2.0**.
Application identifiers are supplied through ignored local configuration.

## Start

1. Download **DiscordSocialSdk-1.10.19337.zip** from your app's
   [Social SDK Downloads](https://discord.com/developers/applications/select/social-sdk/downloads).
2. Run `./scripts/setup-discord-sdk.sh /path/to/DiscordSocialSdk-1.10.19337.zip`.
   The script checks the recorded SHA-256 and installs the official iOS XCFramework
   under ignored `.local/discord-sdk/`. The SDK archive/binaries are not committed.
   The optional Krisp voice framework is not needed.
3. In the app's [OAuth2 settings](https://discord.com/developers/applications/select/oauth2),
   enable **Public Client** and add this exact redirect:
   `discord-YOUR_APPLICATION_ID:/authorize/callback`.
4. Create **`ios/Local.xcconfig`** (ignored by Git) with your own identifiers:

   ```xcconfig
   DISCORD_APPLICATION_ID = YOUR_APPLICATION_ID
   PRODUCT_BUNDLE_IDENTIFIER = YOUR_BUNDLE_IDENTIFIER
   ```

   Use the bundle ID covered by your Everysight key. The checked-in
   `ios/App.xcconfig` supplies a generic example bundle ID and no Discord app ID;
   a fresh clone compiles, but Discord sign-in stays disabled until configured.
   Never commit `Local.xcconfig`, signing team IDs, or real application identifiers.
5. Restore the Everysight key as described below, then run `./scripts/run-ios.sh`.
   Sign in with Discord on the phone and authorize its communication scopes.
   Configure glasses once; successful targets reconnect on subsequent launches.

```sh
./scripts/build-ios.sh       # ARM64 iOS simulator build
./scripts/test-discord.sh    # Parsing, Unicode, wrapping and pagination checks
open ios/EverysightPlayground.xcodeproj
```

Xcode 27 and an iOS 27 simulator runtime are installed on the development Mac.
The app supports iOS 16+. For a physical iPhone, select your signing team in Xcode.
Simulator builds use ad hoc signing so Xcode embeds the application identifier
needed for Keychain access. No device signing certificate is required for simulator
builds. The required Compose resources copy phase and ARM64 simulator setting are retained.

## Reading messages

- New incoming DMs appear on glasses for 30 seconds while the app is active and
  **Show incoming DMs on glasses** is enabled. Tap a message on the phone to show it again.
- At startup and when returning to the app, the most recent conversation (or the
  current selection) loads automatically, with up to 200 messages from the SDK
  history window. Its latest message previews on glasses for 30 seconds when
  automatic display is enabled. Choose another conversation to load its history. Pull down to refresh the
  conversation list. New/edited/deleted messages update through SDK callbacks;
  history is fetched on selection rather than repeatedly polled.
- The glasses HUD has a scrolling DM selector on the left and the selected
  conversation's message on the right. The green heading marks the active pane.
  Up/down moves through DMs in the left pane, or newer/older messages in the right.
  Tap or swipe forward opens the highlighted DM; tap in the message pane cycles
  its pages. Swipe backward returns to the DM selector. Hold hides message text.
  The phone also has Previous, Next and Hide controls. Six conversations fit at
  once; the list scrolls to keep the selection visible.
- Attachments, embeds and other non-text content show their type, count and optional
  poll/thread title. The Social SDK exposes no attachment URLs, filenames, MIME
  types or file sizes. Select a message
  and use **Open selected message in Discord** to see the full content.
- Glasses previews hide and the app switcher snapshot is covered when the app
  becomes inactive. iOS may suspend the app in the background: continuous delivery
  with the phone locked is not implemented. No background audio workaround is used.
- This is a read-only client: it never automatically sends messages or publishes presence.

**Discord's Social SDK does not expose an unrestricted Discord inbox.** DM history
requires both people to have used this application and has a maximum of 200 messages
and 72 hours. Delivery also depends on users' Discord Connected Games DM settings.
Empty history is not evidence that the user has no Discord DMs. Group DMs and lobby
messages are not shown. See the [official DM guide](https://docs.discord.com/developers/discord-social-sdk/development-guides/sending-direct-messages).

## Authentication and privacy

Uses the SDK's `Authorize`, PKCE verifier/challenge, `GetToken`, `UpdateToken`,
`Connect`, and `RefreshToken` flow with default communication scopes. No client
secret, bot token, or Discord user token is entered in the app or repository.
Only the refresh token is persisted, in Keychain with
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Access tokens and message content
stay in memory; application file logging is disabled. Token refresh occurs before
expiry and refresh tokens rotate atomically in Keychain.

**Sign out** removes this device's refresh token and clears the app's message cache;
it does not revoke other devices' grants. Use Discord's Authorized Apps settings
for account-wide revocation. Do not commit keys or tokens.

The public client flow needs no server or hosted message relay. If a confidential OAuth client becomes necessary,
a TypeScript Worker could perform token exchanges, but that would require a server
secret and a separate authenticated session design.

Discord's official [native iOS integration](https://docs.discord.com/developers/discord-social-sdk/development-guides/account-linking-on-mobile#ios-setup)
uses `discord_partner_sdk.xcframework`, Objective-C++ and C++20. Its C++ implementation
is compiled exactly once, in `DiscordBridge.mm`. The pinned SDK was downloaded from
the application portal and checked against its [release notes](https://discord.com/developers/docs/social-sdk/release_notes.html).

## Developer key

Developer keys are not included in this repository. If you store yours as a
1Password Document, supply its document and vault names locally:

```sh
./scripts/key-from-1password.sh "YOUR_SDK_KEY_DOCUMENT" "YOUR_VAULT"
```


Request an Everysight developer key for your bundle ID using the
[official key instructions](https://everysight.github.io/maverick-ai-docs/getting-started/api-key/).
Set `PRODUCT_BUNDLE_IDENTIFIER` in `ios/Local.xcconfig` to the namespace covered
by your key. Put the actual file at:

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
the Discord waiting HUD appears automatically. Camera capture is disabled in this app.
This app does not open microphones, cameras, eye tracking, or motion streams. Test final behavior on actual glasses.

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

## Official references

- [Developer portal](https://everysight.github.io/maverick-ai-docs/)
- [iOS integration](https://everysight.github.io/maverick-ai-docs/libraries-api/ios/)
- [Simulator setup](https://everysight.github.io/maverick-ai-docs/guides/simulator/)
- [SDK releases and samples](https://github.com/everysight-maverick-AI/sdk)
- [iOS Swift package](https://github.com/everysight-maverick-AI/mav-ai-ios-spm)
- [AI development tools](https://everysight.github.io/maverick-ai-docs/getting-started/vibe-coding/)

## Validation

Simulator build and launch are verified locally, with the glasses simulator reaching
Ready. A local preview verified the split HUD, scrolling through seven DMs,
switching conversations, browsing older messages, multiline pagination and
long-tap hiding on the glasses simulator. The Release device build also passed with signing disabled. Parsing/pagination tests include long messages, exact word boundaries,
newlines, composed Unicode characters and large Discord IDs.

For a local rendering test without Discord authentication, Debug builds accept
`--discord-hud-preview` as an Xcode launch argument. The phone and HUD label this
**TEST PREVIEW**; it uses seven in-memory test conversations, does not authenticate to Discord and is disabled
in Release builds. This verifies layout and gestures, not real message delivery.

The SDK authorization flow, Discord account login, password/TOTP verification,
mobile OAuth callback and SDK Ready state were verified in the iPhone simulator.
The consent screen explicitly lists sending and receiving messages. A real incoming
DM was verified on both the phone and the glasses HUD. The session restored from
Keychain after relaunch, conversation summaries loaded, and recent message history
was retrieved successfully. Physical glasses and locked-phone delivery have not been verified.
Build and diagnostic artifacts are under ignored `.local/`.
