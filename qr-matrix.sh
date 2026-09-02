#!/usr/bin/env bash
set -euo pipefail

if ! command -v qrencode >/dev/null 2>&1; then
  printf 'QR generation requires qrencode\n' >&2
  exit 1
fi

runtime_root="${XDG_RUNTIME_DIR:-/tmp}/omarchy-qr-tools"
mkdir -p "$runtime_root"
chmod 700 "$runtime_root"
payload_file=$(mktemp "$runtime_root/payload.XXXXXX")
trap 'rm -f "$payload_file"' EXIT

case "${1:-}" in
  "")
    IFS= read -r payload || true
    printf '%s' "${payload:-}" >"$payload_file"
    ;;
  --clipboard)
    if ! command -v wl-paste >/dev/null 2>&1; then
      printf 'Clipboard generation requires wl-paste\n' >&2
      exit 1
    fi
    if ! wl-paste --no-newline >"$payload_file"; then
      printf 'Could not read text from the clipboard\n' >&2
      exit 1
    fi
    ;;
  *)
    printf 'Usage: %s [--clipboard]\n' "$0" >&2
    exit 2
    ;;
esac

payload_size=$(wc -c <"$payload_file")
if ((payload_size == 0)); then
  printf 'No text available to encode\n' >&2
  exit 1
fi
if ((payload_size > 2048)); then
  printf 'Text is too large for this QR panel (maximum 2048 bytes)\n' >&2
  exit 1
fi

ascii=$(qrencode --8bit --level M --type ASCII --margin 4 \
  --read-from "$payload_file" --output -)
while IFS= read -r line; do
  row=""
  for ((column = 0; column < ${#line}; column += 2)); do
    if [[ ${line:column:2} == *#* ]]; then
      row+=1
    else
      row+=0
    fi
  done
  printf '%s\n' "$row"
done <<<"$ascii"
