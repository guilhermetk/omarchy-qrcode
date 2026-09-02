#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

matrix=$(printf 'https://example.com/qr-tools' | "$repo_dir/qr-matrix.sh")
rows=$(printf '%s\n' "$matrix" | wc -l)
first_row=${matrix%%$'\n'*}
columns=${#first_row}
[[ $rows -eq $columns ]]
[[ $matrix =~ ^[01]+($'\n'[01]+)*$ ]]

mkdir -p "$tmp/bin" "$tmp/runtime"
cat >"$tmp/bin/omarchy" <<'SCRIPT'
#!/usr/bin/env bash
printf 'fake png' >"$OMARCHY_SCREENSHOT_DIR/capture.png"
printf '%s\n' "$OMARCHY_SCREENSHOT_DIR/capture.png"
SCRIPT
cat >"$tmp/bin/zbarimg" <<'SCRIPT'
#!/usr/bin/env bash
if [[ " $* " == *" --polygon "* ]]; then
  printf '%s\n' '+100,+200 +400,+200 +400,+600 +100,+600:https://example.com/decoded'
  exit 0
fi
printf 'https://example.com/decoded\n'
SCRIPT
cat >"$tmp/bin/wl-copy" <<'SCRIPT'
#!/usr/bin/env bash
cat >"$TEST_CLIPBOARD"
SCRIPT
cat >"$tmp/bin/omarchy-notification-send" <<'SCRIPT'
#!/usr/bin/env bash
exit 0
SCRIPT
cat >"$tmp/bin/hyprctl" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' '[{"name":"DP-1","focused":true}]'
SCRIPT
cat >"$tmp/bin/file" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' 'PNG image data, 5120 x 2880, 8-bit/color RGB, non-interlaced'
SCRIPT
chmod +x "$tmp/bin/"*

PATH="$tmp/bin:$PATH" XDG_RUNTIME_DIR="$tmp/runtime" \
  TEST_CLIPBOARD="$tmp/clipboard" "$repo_dir/scan-code.sh" fullscreen \
  >"$tmp/scan-output"
grep -qx 'https://example.com/decoded' "$tmp/scan-output"
grep -qx 'https://example.com/decoded' "$tmp/clipboard"

PATH="$tmp/bin:$PATH" XDG_RUNTIME_DIR="$tmp/runtime" \
  TEST_CLIPBOARD="$tmp/clipboard" "$repo_dir/scan-code.sh" fullscreen \
  --highlight-json >"$tmp/highlight-output"
jq -e '. == {
  monitor: "DP-1",
  imageWidth: 5120,
  imageHeight: 2880,
  x: 100,
  y: 200,
  width: 300,
  height: 400
}' "$tmp/highlight-output" >/dev/null

printf 'Script tests passed\n'
