# QR Tools for Omarchy

Generate QR codes from text or clipboard contents, and scan QR codes or common
barcodes from the current screen. QR Tools runs as an Omarchy Quattro bar
widget and uses Omarchy's existing screenshot flow for reliable fullscreen and
region capture.

## Features

- Generate a QR code from typed text or a URL.
- Generate from the Wayland clipboard without placing its contents in process
  arguments.
- Export generated QR codes at a chosen pixel size to `~/Pictures` and the
  image clipboard.
- Scan a selected screen region.
- Scan the focused screen automatically and briefly highlight the detected
  code in place.
- Decode QR Code, EAN, UPC, Code 128, Code 93, Code 39, Codabar, DataBar, and
  Interleaved 2 of 5 symbols through ZBar.
- Copy decoded data without automatically opening URLs.
- Keep captures in private runtime storage only while they are being decoded.

## Dependencies

Install the runtime tools:

```bash
omarchy pkg add python qrencode zbar
```

Omarchy already provides `wl-clipboard` and its screenshot dependencies. QR
Tools uses only Python's standard library for supervision, filesystem safety,
and exact-size PNG rendering; it does not compile code or use ImageMagick.
If Python, QRencode, or ZBar is missing, QR Tools shows a warning and offers an
explicit **Install dependencies** action that opens the command above in a
visible terminal. It never installs packages automatically.

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
qmllint -I "$OMARCHY_PATH/shell" BarWidget.qml
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

The panel accepts up to 2,048 UTF-8 bytes. Scanned payloads are limited to 4,096
bytes. Screenshots are limited to 64 MiB, 10,000 pixels per side, and 40 million
pixels total. Exports are limited to 2,048 x 2,048 pixels and 8 MiB.

## Privacy and files

- Generation and scanning happen locally. QR Tools never uploads or
  automatically opens decoded content.
- Generated plaintext is not persisted. The validated matrix exists only in
  the shell while its panel is open.
- Temporary captures live in a random mode-`700` operation directory beneath
  the user's validated `XDG_RUNTIME_DIR`. QR Tools opens and validates the image
  by directory descriptor, copies it to a sealed in-memory file for decoding,
  and deletes the capture after scanning.
- Successful scans copy decoded bytes to the clipboard. Clipboard ownership is
  supervised in the foreground until the data is replaced, the shell exits, or
  five minutes pass.
- Export runs only when **Export PNG** is clicked. It saves the image under
  `~/Pictures` as a mode-`600` file and copies the same PNG to the clipboard.
  The home and Pictures directories are opened component-by-component without
  following symlinks. A fully written and synced hidden file is published with
  an exclusive hard link, so an existing file or symlink is never replaced.
- External commands use validated root-owned executables at fixed `/usr/bin`
  paths, bounded input/output, absolute deadlines, and supervised process
  groups. Helper errors are fixed codes; raw tool output is never rendered.

## Remove

```bash
omarchy plugin remove gtiscoski.qr-tools
```

Removal does not uninstall `qrencode` or `zbar` and does not delete PNG files
you explicitly exported to `~/Pictures`.

## Development

Run the helper, parser, and source-policy tests:

```bash
tests/test-scripts.sh
```

## License

MIT
