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

highlight_json=false
case "${2:-}" in
  "") ;;
  --highlight-json)
    [[ $mode == fullscreen ]] || {
      printf '%s\n' '--highlight-json is only available for fullscreen scans' >&2
      exit 2
    }
    highlight_json=true
    ;;
  *)
    printf 'Usage: %s [region|fullscreen] [--highlight-json]\n' "$0" >&2
    exit 2
    ;;
esac

notify() {
  if command -v omarchy-notification-send >/dev/null 2>&1; then
    omarchy-notification-send -g '▦' --app-name 'QR Tools' "$1" -t 4500 \
      >/dev/null 2>&1 || true
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send --app-name='QR Tools' 'QR Tools' "$1" >/dev/null 2>&1 || true
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

capture_monitor=""
if [[ $highlight_json == true ]] && command -v hyprctl >/dev/null 2>&1 && \
  command -v jq >/dev/null 2>&1; then
  capture_monitor=$(hyprctl monitors -j 2>/dev/null |
    jq -r '.[] | select(.focused == true) | .name' 2>/dev/null | head -n 1 || true)
fi

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

# zbarimg terminates each decoded symbol with one newline that is not part of
# the payload. Remove only the final record separator; an encoded trailing
# newline remains as the preceding byte.
truncate -s -1 "$decoded_file"
[[ -s $decoded_file ]] || fail 'No QR code or barcode found'

if ! wl-copy --type 'text/plain;charset=utf-8' <"$decoded_file"; then
  fail 'Could not copy decoded data to the clipboard'
fi

notify 'QR/barcode data copied to the clipboard'

if [[ $highlight_json == false ]]; then
  cat "$decoded_file"
  exit 0
fi

# A second one-shot pass keeps arbitrary decoded bytes separate from the
# machine-readable geometry consumed by QML. Failure here must not turn a
# successful scan/copy into an error; it only skips the visual highlight.
polygon_file="$capture_dir/polygon.txt"
set +e
zbarimg --quiet --raw --polygon --oneshot -Stest-inverted "$image_path" \
  >"$polygon_file" 2>/dev/null
polygon_status=$?
set -e

highlight='{}'
if ((polygon_status == 0)) && command -v file >/dev/null 2>&1 && \
  command -v jq >/dev/null 2>&1; then
  polygon_line=$(head -n 1 "$polygon_file")
  polygon=${polygon_line%%:*}
  image_info=$(file -b -- "$image_path" 2>/dev/null || true)

  if [[ $polygon =~ ^[+-][0-9]+,[+-][0-9]+([[:space:]][+-][0-9]+,[+-][0-9]+)+$ ]] &&
    [[ $image_info =~ PNG[[:space:]]image[[:space:]]data,[[:space:]]([0-9]+)[[:space:]]x[[:space:]]([0-9]+), ]]; then
    image_width=${BASH_REMATCH[1]}
    image_height=${BASH_REMATCH[2]}
    first_point=true

    for point in $polygon; do
      point_x=${point%,*}
      point_y=${point#*,}
      point_x=${point_x#+}
      point_y=${point_y#+}

      if [[ $first_point == true ]]; then
        min_x=$point_x
        max_x=$point_x
        min_y=$point_y
        max_y=$point_y
        first_point=false
      else
        ((point_x < min_x)) && min_x=$point_x
        ((point_x > max_x)) && max_x=$point_x
        ((point_y < min_y)) && min_y=$point_y
        ((point_y > max_y)) && max_y=$point_y
      fi
    done

    box_width=$((max_x - min_x))
    box_height=$((max_y - min_y))
    if ((image_width > 0 && image_height > 0 && box_width > 0 && box_height > 0)); then
      highlight=$(jq -cn \
        --arg monitor "$capture_monitor" \
        --argjson imageWidth "$image_width" \
        --argjson imageHeight "$image_height" \
        --argjson x "$min_x" \
        --argjson y "$min_y" \
        --argjson width "$box_width" \
        --argjson height "$box_height" \
        '{monitor: $monitor, imageWidth: $imageWidth, imageHeight: $imageHeight,
          x: $x, y: $y, width: $width, height: $height}')
    fi
  fi
fi

printf '%s\n' "$highlight"
