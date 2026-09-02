#!/usr/bin/env bash
set -euo pipefail

available() {
  if command -v "$1" >/dev/null 2>&1; then
    printf true
  else
    printf false
  fi
}

printf '{"qrencode":%s,"zbar":%s,"imagemagick":%s}\n' \
  "$(available qrencode)" "$(available zbarimg)" "$(available magick)"
