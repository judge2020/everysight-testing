#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
document="${1:?Usage: key-from-1password.sh DOCUMENT VAULT}"
vault="${2:?Usage: key-from-1password.sh DOCUMENT VAULT}"
mkdir -p .local
umask 077
key_temp="$(mktemp .local/sdk-key.XXXXXX)"
trap 'rm -f "$key_temp"' EXIT
op document get "$document" --vault "$vault" --out-file "$key_temp" --force
if [[ ! -s "$key_temp" ]]; then
  echo 'The 1Password document is empty; app key was not changed.' >&2
  exit 1
fi
mv "$key_temp" ios/EverysightPlayground/sdk.key
chmod 600 ios/EverysightPlayground/sdk.key
echo 'Installed sdk.key from 1Password. Rebuild the app to bundle it.'
