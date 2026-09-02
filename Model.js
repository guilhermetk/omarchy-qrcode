var MAX_MATRIX_SIZE = 185
var MAX_IMAGE_DIMENSION = 10000
var MAX_IMAGE_PIXELS = 40000000
var MAX_DECODED_BYTES = 4096
var MAX_RESPONSE_LINE = 16 * 1024
var MAX_GENERATE_RESPONSE_LINE = 96 * 1024

var ERROR_MESSAGES = {
  invalid_request: "QR Tools received an invalid request",
  input_empty: "No text available to encode",
  input_too_large: "Text is too large for this QR panel (maximum 2048 bytes)",
  qrencode_missing: "QR generation requires qrencode",
  qrencode_failed: "Could not generate QR code",
  qr_output_too_large: "QR generator output exceeded its safety limit",
  qr_matrix_invalid: "QR generator returned an invalid matrix",
  clipboard_missing: "Clipboard access requires wl-clipboard",
  clipboard_unavailable: "Could not read text from the clipboard",
  clipboard_sensitive: "Refusing to encode sensitive clipboard data",
  clipboard_payload_invalid: "Clipboard data was invalid",
  capture_missing: "QR scanning requires Omarchy's screenshot tool",
  zbarimg_missing: "QR scanning requires zbarimg (package: zbar)",
  scan_cancelled: "Screen capture cancelled",
  capture_failed: "Could not capture the screen for QR scanning",
  screenshot_invalid: "Screenshot capture returned an invalid image",
  image_dimensions_invalid: "Screenshot dimensions exceed the safety limit",
  no_code: "No QR code or barcode found",
  decode_failed: "Barcode decoder failed",
  decoded_too_large: "Decoded data exceeds the 4096-byte safety limit",
  decoded_invalid: "Barcode decoder returned invalid data",
  export_invalid_size: "Export size is invalid for this QR code",
  export_invalid_matrix: "The QR matrix is invalid",
  pictures_unavailable: "Could not securely open ~/Pictures",
  export_too_large: "Exported PNG exceeded the safety limit",
  export_failed: "Could not export QR code",
  export_published_cleanup: "QR code was saved, but final cleanup could not be confirmed",
  export_changed: "The exported QR file changed before it could be copied",
  clipboard_copy_failed: "Could not copy data to the clipboard",
  unsafe_directory: "A required private directory failed validation",
  runtime_unavailable: "Private runtime storage is unavailable",
  response_too_large: "QR Tools response exceeded its safety limit",
  internal_error: "QR Tools encountered an internal error"
}

function invalidResponse() {
  return { valid: false, ok: false, message: "QR Tools returned an invalid response" }
}

function errorMessage(code) {
  return Object.prototype.hasOwnProperty.call(ERROR_MESSAGES, code)
    ? ERROR_MESSAGES[code]
    : "QR Tools encountered an internal error"
}

function isInteger(value) {
  return typeof value === "number" && isFinite(value) && Math.floor(value) === value
}

function parseQrMatrix(value) {
  var rows = value
  if (typeof value === "string") rows = value.split("\n")
  if (!Array.isArray(rows) || rows.length < 1 || rows.length > MAX_MATRIX_SIZE)
    return { rows: [], size: 0 }

  var size = rows.length
  var copy = []
  for (var index = 0; index < size; index++) {
    if (typeof rows[index] !== "string" || rows[index].length !== size ||
        !/^[01]+$/.test(rows[index]))
      return { rows: [], size: 0 }
    copy.push(rows[index])
  }
  return { rows: copy, size: size }
}

function parseScanHighlight(value) {
  var data = value
  if (typeof value === "string") {
    try {
      data = JSON.parse(value)
    } catch (error) {
      return null
    }
  }
  if (!data || typeof data !== "object" || Array.isArray(data)) return null

  var imageWidth = data.imageWidth
  var imageHeight = data.imageHeight
  var x = data.x
  var y = data.y
  var width = data.width
  var height = data.height
  if (!isInteger(imageWidth) || !isInteger(imageHeight) ||
      !isInteger(x) || !isInteger(y) || !isInteger(width) || !isInteger(height) ||
      imageWidth < 1 || imageHeight < 1 ||
      imageWidth > MAX_IMAGE_DIMENSION || imageHeight > MAX_IMAGE_DIMENSION ||
      imageWidth * imageHeight > MAX_IMAGE_PIXELS ||
      x < 0 || y < 0 || width < 1 || height < 1 ||
      x + width > imageWidth || y + height > imageHeight)
    return null

  var monitor = data.monitor
  if (typeof monitor !== "string" ||
      (monitor !== "" && !/^[A-Za-z0-9_.:-]{1,128}$/.test(monitor)))
    return null

  return {
    monitor: monitor,
    imageWidth: imageWidth,
    imageHeight: imageHeight,
    x: x,
    y: y,
    width: width,
    height: height
  }
}

function validBase64(value) {
  if (typeof value !== "string" || value.length < 4 || value.length % 4 !== 0 ||
      !/^[A-Za-z0-9+/]*={0,2}$/.test(value))
    return false
  var padding = value.endsWith("==") ? 2 : (value.endsWith("=") ? 1 : 0)
  var decodedLength = value.length / 4 * 3 - padding
  return decodedLength > 0 && decodedLength <= MAX_DECODED_BYTES
}

function parseResponse(raw, expectedId, kind) {
  if (!isInteger(expectedId) || expectedId < 1) return invalidResponse()
  var line = String(raw === undefined || raw === null ? "" : raw)
  var maximum = kind === "generate" ? MAX_GENERATE_RESPONSE_LINE : MAX_RESPONSE_LINE
  if (line.length < 2 || line.length > maximum || /[\r\n]/.test(line))
    return invalidResponse()

  var data
  try {
    data = JSON.parse(line)
  } catch (error) {
    return invalidResponse()
  }
  if (!data || typeof data !== "object" || Array.isArray(data) ||
      data.id !== expectedId || typeof data.ok !== "boolean")
    return invalidResponse()

  if (!data.ok) {
    if (typeof data.error !== "string" || data.error.length > 64 ||
        !Object.prototype.hasOwnProperty.call(ERROR_MESSAGES, data.error))
      return invalidResponse()
    return {
      valid: true,
      ok: false,
      errorCode: data.error,
      message: errorMessage(data.error)
    }
  }

  if (kind === "dependencies") {
    if (typeof data.qrencode !== "boolean" || typeof data.zbar !== "boolean")
      return invalidResponse()
    return { valid: true, ok: true, qrencode: data.qrencode, zbar: data.zbar }
  }
  if (kind === "generate") {
    var matrix = parseQrMatrix(data.matrix)
    if (matrix.size === 0) return invalidResponse()
    return { valid: true, ok: true, rows: matrix.rows, size: matrix.size }
  }
  if (kind === "scan") {
    if (!validBase64(data.payload)) return invalidResponse()
    var highlight = data.highlight === null ? null : parseScanHighlight(data.highlight)
    if (data.highlight !== null && highlight === null) return invalidResponse()
    return { valid: true, ok: true, payload: data.payload, highlight: highlight }
  }
  if (kind === "export") {
    if (typeof data.basename !== "string" ||
        !/^qr-code-[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9a-f]{8}\.png$/.test(data.basename) ||
        typeof data.sha256 !== "string" || !/^[0-9a-f]{64}$/.test(data.sha256))
      return invalidResponse()
    return {
      valid: true,
      ok: true,
      basename: data.basename,
      sha256: data.sha256
    }
  }
  if (kind === "clipboard") {
    if (data.ready !== true) return invalidResponse()
    return { valid: true, ok: true, ready: true }
  }
  if (kind === "notify") return { valid: true, ok: true }
  return invalidResponse()
}

if (typeof module !== "undefined") module.exports = {
  MAX_MATRIX_SIZE: MAX_MATRIX_SIZE,
  MAX_RESPONSE_LINE: MAX_RESPONSE_LINE,
  MAX_GENERATE_RESPONSE_LINE: MAX_GENERATE_RESPONSE_LINE,
  errorMessage: errorMessage,
  parseQrMatrix: parseQrMatrix,
  parseScanHighlight: parseScanHighlight,
  parseResponse: parseResponse
}
