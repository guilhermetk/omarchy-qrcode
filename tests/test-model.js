const assert = require("assert")
const {
  MAX_MATRIX_SIZE,
  MAX_RESPONSE_LINE,
  errorMessage,
  parseQrMatrix,
  parseScanHighlight,
  parseResponse
} = require("../Model.js")

assert.deepStrictEqual(parseQrMatrix(["01", "10"]), {
  rows: ["01", "10"],
  size: 2
})
assert.deepStrictEqual(parseQrMatrix(["01", "1x"]), { rows: [], size: 0 })
assert.deepStrictEqual(parseQrMatrix(["0", "11"]), { rows: [], size: 0 })
assert.deepStrictEqual(parseQrMatrix([]), { rows: [], size: 0 })
assert.deepStrictEqual(
  parseQrMatrix(Array(MAX_MATRIX_SIZE + 1).fill("0".repeat(MAX_MATRIX_SIZE + 1))),
  { rows: [], size: 0 }
)

const highlight = {
  monitor: "DP-1",
  imageWidth: 5120,
  imageHeight: 2880,
  x: 100,
  y: 200,
  width: 300,
  height: 400
}
assert.deepStrictEqual(parseScanHighlight(highlight), highlight)
assert.strictEqual(parseScanHighlight({ ...highlight, x: -1 }), null)
assert.strictEqual(parseScanHighlight({ ...highlight, imageWidth: "5120" }), null)
assert.strictEqual(parseScanHighlight({ ...highlight, monitor: "<b>DP-1</b>" }), null)
assert.strictEqual(parseScanHighlight({ ...highlight, imageWidth: 10000, imageHeight: 10000 }), null)

const dependency = parseResponse(
  JSON.stringify({ id: 7, ok: true, qrencode: true, zbar: false }),
  7,
  "dependencies"
)
assert.deepStrictEqual(dependency, {
  valid: true,
  ok: true,
  qrencode: true,
  zbar: false
})
assert.strictEqual(parseResponse(JSON.stringify({ id: 8, ok: true, qrencode: true, zbar: true }), 7, "dependencies").valid, false)
assert.strictEqual(parseResponse('{"id":7,"ok":true}\n{"id":7}', 7, "dependencies").valid, false)
assert.strictEqual(parseResponse("x".repeat(MAX_RESPONSE_LINE + 1), 7, "scan").valid, false)

const generated = parseResponse(
  JSON.stringify({ id: 9, ok: true, matrix: ["01", "10"] }),
  9,
  "generate"
)
assert.deepStrictEqual(generated.rows, ["01", "10"])
assert.strictEqual(parseResponse(JSON.stringify({ id: 9, ok: true, matrix: ["01", "1x"] }), 9, "generate").valid, false)

const encoded = Buffer.from("decoded payload").toString("base64")
const scanned = parseResponse(
  JSON.stringify({ id: 10, ok: true, payload: encoded, highlight }),
  10,
  "scan"
)
assert.strictEqual(scanned.payload, encoded)
assert.deepStrictEqual(scanned.highlight, highlight)
assert.strictEqual(parseResponse(JSON.stringify({ id: 10, ok: true, payload: "not base64!", highlight: null }), 10, "scan").valid, false)
assert.strictEqual(parseResponse(JSON.stringify({
  id: 10,
  ok: true,
  payload: Buffer.alloc(4097).toString("base64"),
  highlight: null
}), 10, "scan").valid, false)

const basename = "qr-code-2026-09-02_12-34-56-deadbeef.png"
const digest = "a".repeat(64)
assert.deepStrictEqual(
  parseResponse(JSON.stringify({ id: 11, ok: true, basename, sha256: digest }), 11, "export"),
  { valid: true, ok: true, basename, sha256: digest }
)
assert.strictEqual(parseResponse(JSON.stringify({ id: 11, ok: true, basename: "../../bad.png", sha256: digest }), 11, "export").valid, false)
assert.strictEqual(parseResponse(JSON.stringify({ id: 11, ok: true, basename, sha256: "A".repeat(64) }), 11, "export").valid, false)

assert.deepStrictEqual(
  parseResponse(JSON.stringify({ id: 12, ok: true, ready: true }), 12, "clipboard"),
  { valid: true, ok: true, ready: true }
)
const fixedError = parseResponse(JSON.stringify({ id: 13, ok: false, error: "no_code" }), 13, "scan")
assert.strictEqual(fixedError.message, "No QR code or barcode found")
assert.strictEqual(parseResponse(JSON.stringify({ id: 13, ok: false, error: "<b>raw helper text</b>" }), 13, "scan").valid, false)
assert.strictEqual(errorMessage("unknown"), "QR Tools encountered an internal error")

console.log("Model tests passed")
