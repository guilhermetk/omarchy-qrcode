function parseQrMatrix(raw) {
  var lines = String(raw || "").trim().split(/\r?\n/).filter(function(line) {
    return line !== ""
  })
  if (lines.length === 0) return { rows: [], size: 0 }

  var size = lines[0].length
  if (size !== lines.length) return { rows: [], size: 0 }
  for (var index = 0; index < lines.length; index++) {
    if (lines[index].length !== size || !/^[01]+$/.test(lines[index]))
      return { rows: [], size: 0 }
  }
  return { rows: lines, size: size }
}

function parseScanHighlight(raw) {
  var data
  try {
    data = JSON.parse(String(raw || ""))
  } catch (error) {
    return null
  }
  if (!data || typeof data !== "object") return null

  var imageWidth = Number(data.imageWidth)
  var imageHeight = Number(data.imageHeight)
  var x = Number(data.x)
  var y = Number(data.y)
  var width = Number(data.width)
  var height = Number(data.height)
  if (!isFinite(imageWidth) || !isFinite(imageHeight) ||
      !isFinite(x) || !isFinite(y) || !isFinite(width) || !isFinite(height) ||
      imageWidth <= 0 || imageHeight <= 0 || width <= 0 || height <= 0)
    return null

  var left = Math.max(0, Math.min(imageWidth, x))
  var top = Math.max(0, Math.min(imageHeight, y))
  var right = Math.max(left, Math.min(imageWidth, x + width))
  var bottom = Math.max(top, Math.min(imageHeight, y + height))
  if (right <= left || bottom <= top) return null

  return {
    monitor: typeof data.monitor === "string" ? data.monitor : "",
    imageWidth: imageWidth,
    imageHeight: imageHeight,
    x: left,
    y: top,
    width: right - left,
    height: bottom - top
  }
}

if (typeof module !== "undefined") module.exports = {
  parseQrMatrix: parseQrMatrix,
  parseScanHighlight: parseScanHighlight
}
