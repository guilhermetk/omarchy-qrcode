#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

/usr/bin/python3 -m unittest discover -s "$repo_dir/tests" -p 'test_helper.py'
node "$repo_dir/tests/test-model.js"

if grep -Eq 'StdioCollector|Quickshell\.execDetached|\.(sh)"' "$repo_dir/BarWidget.qml"; then
  printf 'BarWidget.qml contains a forbidden process pattern\n' >&2
  exit 1
fi

for process_id in dependency qr scan export clipboard notification; do
  grep -q "id: ${process_id}Proc" "$repo_dir/BarWidget.qml"
  grep -q "id: ${process_id}Deadline" "$repo_dir/BarWidget.qml"
done

grep -q 'Component.onDestruction' "$repo_dir/BarWidget.qml"
grep -q 'textFormat: Text.PlainText' "$repo_dir/BarWidget.qml"
grep -q '\["/usr/bin/python3", "-I"' "$repo_dir/BarWidget.qml"

printf 'Helper, model, and source-policy tests passed\n'
