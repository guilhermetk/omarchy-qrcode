#!/usr/bin/env bash
set -euo pipefail

runtime_root="${XDG_RUNTIME_DIR:-/tmp}/omarchy-qr-tools"
payload_file="$runtime_root/generated-payload"

if [[ ${1:-} == --discard ]]; then
  rm -f "$payload_file"
  exit 0
fi

pixel_size=${1:-}
if [[ ! $pixel_size =~ ^[0-9]+$ ]] || ((pixel_size < 256 || pixel_size > 2048)); then
  printf 'Export size is invalid\n' >&2
  exit 2
fi

command -v qrencode >/dev/null 2>&1 || {
  printf 'QR export requires qrencode\n' >&2
  exit 1
}
command -v wl-copy >/dev/null 2>&1 || {
  printf 'QR export requires wl-copy\n' >&2
  exit 1
}
command -v magick >/dev/null 2>&1 || {
  printf 'QR export requires ImageMagick\n' >&2
  exit 1
}
[[ -s $payload_file ]] || {
  printf 'Generate a QR code before exporting\n' >&2
  exit 1
}

snapshot_path=$(mktemp "$runtime_root/export-payload.XXXXXX")
source_path=$(mktemp "$runtime_root/export-source.XXXXXX.png")
render_path=$(mktemp "$runtime_root/export-render.XXXXXX.png")
final_path=$(mktemp "$runtime_root/export-final.XXXXXX.png")
trap 'rm -f "$snapshot_path" "$source_path" "$render_path" "$final_path"' EXIT
install -m 600 "$payload_file" "$snapshot_path"

pictures_dir="$HOME/Pictures"
mkdir -p "$pictures_dir"

base_name="qr-code-$(date +'%Y-%m-%d_%H-%M-%S')"
output_path="$pictures_dir/$base_name.png"
suffix=2
while [[ -e $output_path ]]; do
  output_path="$pictures_dir/$base_name-$suffix.png"
  ((suffix++))
done

umask 077
qrencode --8bit --level M --type PNG --margin 4 --size 1 \
  --output "$source_path" --read-from "$snapshot_path"
base_size=$(magick identify -format '%w' "$source_path")
if [[ ! $base_size =~ ^[0-9]+$ ]] || ((base_size < 1 || base_size > pixel_size)); then
  printf 'Could not determine a valid QR export size\n' >&2
  exit 1
fi
module_size=$((pixel_size / base_size))
if ((module_size < 2)); then
  printf 'Export size must be at least %d px for this QR code\n' "$((base_size * 2))" >&2
  exit 1
fi
qrencode --8bit --level M --type PNG --margin 4 --size "$module_size" \
  --output "$render_path" --read-from "$snapshot_path"
magick "$render_path" -background white -gravity center \
  -extent "${pixel_size}x${pixel_size}" "$final_path"
install -m 600 "$final_path" "$output_path"

if ! wl-copy --type image/png <"$output_path"; then
  printf 'QR saved to %s, but could not copy it to the clipboard\n' "$output_path" >&2
  exit 1
fi

if command -v omarchy-notification-send >/dev/null 2>&1; then
  omarchy-notification-send -g '󰐲' --app-name 'QR Tools' \
    "QR code saved to $output_path and copied to the clipboard" \
    --image "$output_path" -t 4500 \
    >/dev/null 2>&1 || true
elif command -v notify-send >/dev/null 2>&1; then
  notify-send --app-name='QR Tools' 'QR Tools' \
    "QR code saved to $output_path and copied to the clipboard" \
    >/dev/null 2>&1 || true
fi

printf '%s\n' "$output_path"
