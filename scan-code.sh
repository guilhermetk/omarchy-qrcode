#!/usr/bin/env bash
set -euo pipefail

mode="${1:-region}"
case "$mode" in
  region | fullscreen) ;;
  *)
    printf 'Usage: %s [region|fullscreen]\n' "$0" >&2
    exit 2
    ;;
esac

notify() {
  if command -v omarchy-notification-send >/dev/null 2>&1; then
    omarchy-notification-send -g '▦' --app-name 'QR Tools' "$1" -t 4500 || true
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send --app-name='QR Tools' 'QR Tools' "$1" || true
  fi
}

fail() {
  printf '%s\n' "$1" >&2
  notify "$1"
  exit 1
}

command -v omarchy >/dev/null 2>&1 || fail 'QR scanning requires Omarchy'
command -v zbarimg >/dev/null 2>&1 || fail 'QR scanning requires zbarimg (package: zbar)'
command -v wl-copy >/dev/null 2>&1 || fail 'QR scanning requires wl-copy'

runtime_root="${XDG_RUNTIME_DIR:-/tmp}/omarchy-qr-tools"
mkdir -p "$runtime_root"
chmod 700 "$runtime_root"
capture_dir=$(mktemp -d "$runtime_root/scan.XXXXXX")
trap 'rm -rf "$capture_dir"' EXIT

# Let the shell panel unmap before fullscreen capture freezes the desktop.
sleep 0.15

capture_output=""
if ! capture_output=$(OMARCHY_SCREENSHOT_DIR="$capture_dir" \
  omarchy capture screenshot "$mode" save); then
  fail 'Could not capture the screen for QR scanning'
fi

image_path=$(printf '%s\n' "$capture_output" | tail -n 1)
if [[ -z $image_path ]]; then
  exit 0
fi
[[ -f $image_path ]] || fail 'Screenshot capture returned no readable image'

decoded_file="$capture_dir/decoded.txt"
error_file="$capture_dir/zbar-error.txt"
set +e
zbarimg --quiet --raw -Stest-inverted "$image_path" \
  >"$decoded_file" 2>"$error_file"
scan_status=$?
set -e

if ((scan_status == 4)); then
  fail 'No QR code or barcode found'
fi
if ((scan_status != 0)); then
  detail=$(tr '\n' ' ' <"$error_file" | sed 's/[[:space:]]*$//')
  [[ -n $detail ]] || detail='Barcode decoder failed'
  fail "$detail"
fi
[[ -s $decoded_file ]] || fail 'No QR code or barcode found'

if ! wl-copy --type 'text/plain;charset=utf-8' <"$decoded_file"; then
  fail 'Could not copy decoded data to the clipboard'
fi

cat "$decoded_file"
notify 'QR/barcode data copied to the clipboard'
