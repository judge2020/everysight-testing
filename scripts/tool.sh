#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -x .venv/bin/python ]]; then
  echo 'Run ./scripts/setup-tools.sh first.' >&2
  exit 1
fi
case "${1:-}" in
  image) tool=tools/everysight/image_convert/evsimgconvert.py ;;
  font) tool=tools/everysight/font2sif/font2sif2.py ;;
  sprite) tool=tools/everysight/sprite/sprite_png.py ;;
  *) echo "Usage: $0 {image|font|sprite} [arguments...]" >&2; exit 1 ;;
esac
shift
if [[ "$tool" == *evsimgconvert.py ]] && command -v magick >/dev/null; then
  exec .venv/bin/python "$tool" --imageMagick "$(command -v magick)" "$@"
fi
exec .venv/bin/python "$tool" "$@"
