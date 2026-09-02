#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

payload='https://example.com/qr-tools'
matrix=$(printf '%s' "$payload" | XDG_RUNTIME_DIR="$tmp/runtime" \
  "$repo_dir/qr-matrix.sh" --persist)
rows=$(printf '%s\n' "$matrix" | wc -l)
first_row=${matrix%%$'\n'*}
columns=${#first_row}
[[ $rows -eq $columns ]]
[[ $matrix =~ ^[01]+($'\n'[01]+)*$ ]]
printf '%s' "$payload" >"$tmp/expected-payload"
cmp -s "$tmp/expected-payload" "$tmp/runtime/omarchy-qr-tools/generated-payload"

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
if [[ ${TEST_TRAILING_NEWLINE:-false} == true ]]; then
  printf 'encoded newline\n\n'
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

export_path=$(PATH="$tmp/bin:$PATH" HOME="$tmp/home" \
  XDG_RUNTIME_DIR="$tmp/runtime" TEST_CLIPBOARD="$tmp/clipboard" \
  "$repo_dir/export-qr.sh" 513)
[[ $export_path == "$tmp/home/Pictures/"*.png ]]
[[ -f $export_path ]]
cmp -s "$export_path" "$tmp/clipboard"
export_info=$(/usr/bin/file -b -- "$export_path")
[[ $export_info == *"513 x 513"* ]]
decoded_export=$(/usr/bin/zbarimg --quiet --raw "$export_path" 2>/dev/null)
[[ $decoded_export == "$payload" ]]

printf -v dense_payload '%*s' 2048 ''
dense_payload=${dense_payload// /A}
printf '%s' "$dense_payload" | XDG_RUNTIME_DIR="$tmp/runtime" \
  "$repo_dir/qr-matrix.sh" --persist >"$tmp/dense-matrix"
dense_matrix_size=$(head -n 1 "$tmp/dense-matrix" | wc -c)
dense_matrix_size=$((dense_matrix_size - 1))
dense_pixel_size=$((dense_matrix_size * 2 + 1))
dense_export=$(PATH="$tmp/bin:$PATH" HOME="$tmp/home" \
  XDG_RUNTIME_DIR="$tmp/runtime" TEST_CLIPBOARD="$tmp/clipboard" \
  "$repo_dir/export-qr.sh" "$dense_pixel_size")
dense_info=$(/usr/bin/file -b -- "$dense_export")
[[ $dense_info == *"$dense_pixel_size x $dense_pixel_size"* ]]
decoded_dense=$(/usr/bin/zbarimg --quiet --raw "$dense_export" 2>/dev/null)
[[ $decoded_dense == "$dense_payload" ]]

PATH="$tmp/bin:$PATH" XDG_RUNTIME_DIR="$tmp/runtime" \
  TEST_CLIPBOARD="$tmp/clipboard" "$repo_dir/scan-code.sh" fullscreen \
  >"$tmp/scan-output"
grep -qx 'https://example.com/decoded' "$tmp/scan-output"
grep -qx 'https://example.com/decoded' "$tmp/clipboard"
printf 'https://example.com/decoded' >"$tmp/expected-decoded"
cmp -s "$tmp/expected-decoded" "$tmp/scan-output"
cmp -s "$tmp/expected-decoded" "$tmp/clipboard"

PATH="$tmp/bin:$PATH" XDG_RUNTIME_DIR="$tmp/runtime" \
  TEST_CLIPBOARD="$tmp/clipboard" TEST_TRAILING_NEWLINE=true \
  "$repo_dir/scan-code.sh" fullscreen >"$tmp/trailing-output"
printf 'encoded newline\n' >"$tmp/expected-trailing"
cmp -s "$tmp/expected-trailing" "$tmp/trailing-output"
cmp -s "$tmp/expected-trailing" "$tmp/clipboard"

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

XDG_RUNTIME_DIR="$tmp/runtime" "$repo_dir/export-qr.sh" --discard
[[ ! -e $tmp/runtime/omarchy-qr-tools/generated-payload ]]

mkdir -p "$tmp/dependency-bin"
ln -s /usr/bin/bash "$tmp/dependency-bin/bash"
PATH="$tmp/dependency-bin" "$repo_dir/check-dependencies.sh" \
  >"$tmp/dependencies-missing"
jq -e '. == {qrencode: false, zbar: false, imagemagick: false}' \
  "$tmp/dependencies-missing" >/dev/null
for dependency in qrencode zbarimg magick; do
  printf '#!/usr/bin/env bash\n' >"$tmp/dependency-bin/$dependency"
  chmod +x "$tmp/dependency-bin/$dependency"
done
PATH="$tmp/dependency-bin" "$repo_dir/check-dependencies.sh" \
  >"$tmp/dependencies-ready"
jq -e '. == {qrencode: true, zbar: true, imagemagick: true}' \
  "$tmp/dependencies-ready" >/dev/null

printf 'Script tests passed\n'
