#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements-tools.txt
if ! command -v optipng >/dev/null; then
  brew install optipng
fi
if ! command -v magick >/dev/null; then
  brew install imagemagick
fi
