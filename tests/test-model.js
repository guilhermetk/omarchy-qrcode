const assert = require("assert")
const { parseQrMatrix, parseScanHighlight } = require("../Model.js")

assert.deepStrictEqual(parseQrMatrix("01\n10\n"), {
  rows: ["01", "10"],
  size: 2
})
assert.deepStrictEqual(parseQrMatrix("01\n1x\n"), { rows: [], size: 0 })
assert.deepStrictEqual(parseQrMatrix("0\n11\n"), { rows: [], size: 0 })
assert.deepStrictEqual(parseQrMatrix(""), { rows: [], size: 0 })

assert.deepStrictEqual(parseScanHighlight(JSON.stringify({
  monitor: "DP-1",
  imageWidth: 5120,
  imageHeight: 2880,
  x: 100,
  y: 200,
  width: 300,
  height: 400
})), {
  monitor: "DP-1",
  imageWidth: 5120,
  imageHeight: 2880,
  x: 100,
  y: 200,
  width: 300,
  height: 400
})
assert.deepStrictEqual(parseScanHighlight(JSON.stringify({
  imageWidth: 100,
  imageHeight: 100,
  x: -10,
  y: 80,
  width: 30,
  height: 40
})), {
  monitor: "",
  imageWidth: 100,
  imageHeight: 100,
  x: 0,
  y: 80,
  width: 20,
  height: 20
})
assert.strictEqual(parseScanHighlight("{}"), null)
assert.strictEqual(parseScanHighlight("not json"), null)
