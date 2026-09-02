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

# The shell always invokes the helper as `python3 -I`, but the helper must not
# offer a non-isolated entry point of its own if it is run some other way.
if [[ -x $repo_dir/qr-tools-helper.py ]]; then
  printf 'qr-tools-helper.py must not be executable\n' >&2
  exit 1
fi

if ! head -n 1 "$repo_dir/qr-tools-helper.py" | grep -qx -- '#!/usr/bin/python3 -I'; then
  printf 'qr-tools-helper.py shebang must request isolated mode\n' >&2
  exit 1
fi

printf 'Helper, model, and source-policy tests passed\n'
