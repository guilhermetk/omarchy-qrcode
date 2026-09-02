# QR Tools for Omarchy

Generate QR codes from text or clipboard contents, and scan QR codes or common
barcodes from the current screen. QR Tools runs as an Omarchy Quattro bar
widget and uses Omarchy's existing screenshot flow for reliable fullscreen and
region capture.

## Features

- Generate a QR code from typed text or a URL.
- Generate from the Wayland clipboard without placing its contents in process
  arguments.
- Scan a selected screen region.
- Scan the focused screen automatically.
- Decode QR Code, EAN, UPC, Code 128, Code 93, Code 39, Codabar, DataBar, and
  Interleaved 2 of 5 symbols through ZBar.
- Copy decoded data without automatically opening URLs.
- Keep generated and captured data in private runtime storage only; temporary
  files are deleted after each operation.

## Dependencies

Install the two additional runtime tools:

```bash
omarchy pkg add qrencode zbar
```

Omarchy already provides `wl-clipboard` and its screenshot dependencies.

## Install

```bash
omarchy plugin add https://github.com/guilhermetk/omarchy-qrcode --enable
```

`omarchy plugin add --enable` asks which bar section to use (left, center, or
right). The manifest pre-selects **right**, next to the other status icons, but
the panel always opens under the QR icon wherever you place it. Move it later
with `omarchy bar move gtiscoski.qr-tools`.

For local development, validate the repository and install it through your
preferred local Git remote:

```bash
omarchy plugin validate .
qmllint -I "$OMARCHY_PATH/shell" BarWidget.qml QrPanel.qml
```

## Use

- Left-click **QR** in the bar to open QR generation and scan actions.
- Right-click **QR** to select and scan a region immediately.
- Middle-click **QR** to scan the focused screen immediately.
- Summon the panel from a keybinding or terminal with:

```bash
omarchy-shell shell summon gtiscoski.qr-tools '{}'
omarchy-shell shell hide gtiscoski.qr-tools
```

Direct IPC on the bar widget:

```bash
omarchy-shell gtiscoski.qr-tools toggle
omarchy-shell gtiscoski.qr-tools scanRegion
omarchy-shell gtiscoski.qr-tools scanScreen
```

The panel accepts up to 2048 UTF-8 bytes. It does not upload, retain, or
automatically open QR contents.

## Development

Run the script and parser tests:

```bash
tests/test-scripts.sh
node tests/test-model.js
```

## License

MIT
