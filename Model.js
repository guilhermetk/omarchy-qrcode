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

if (typeof module !== "undefined") module.exports = { parseQrMatrix: parseQrMatrix }
