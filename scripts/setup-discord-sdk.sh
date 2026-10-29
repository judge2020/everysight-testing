#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
archive="${1:-$HOME/Downloads/DiscordSocialSdk-1.10.19337.zip}"
if [[ ! -f "$archive" ]]; then
  echo 'Download DiscordSocialSdk-1.10.19337.zip from your Discord Developer Portal → Games → Social SDK → Downloads.' >&2
  echo 'Then run ./scripts/setup-discord-sdk.sh /path/to/DiscordSocialSdk-1.10.19337.zip' >&2
  exit 1
fi
expected=d784097504685953849cc2842561d8a8013326fe0b8df65a1de63ddefde62045
actual=$(shasum -a 256 "$archive" | cut -d ' ' -f 1)
[[ "$actual" == "$expected" ]] || { echo 'Discord SDK archive checksum mismatch' >&2; exit 1; }
mkdir -p .local/discord-sdk
unzip -oq "$archive" 'discord_social_sdk/lib/release/discord_partner_sdk.xcframework/*' -d .local/discord-sdk
# This text-only app does not use the optional Krisp voice framework.
chmod +x .local/discord-sdk/discord_social_sdk/lib/release/discord_partner_sdk.xcframework/*/discord_partner_sdk.framework/discord_partner_sdk
echo 'Discord Social SDK 1.10.19337 ready.'
