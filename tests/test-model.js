const assert = require("assert")
const { parseQrMatrix } = require("../Model.js")

assert.deepStrictEqual(parseQrMatrix("01\n10\n"), {
  rows: ["01", "10"],
  size: 2
})
assert.deepStrictEqual(parseQrMatrix("01\n1x\n"), { rows: [], size: 0 })
assert.deepStrictEqual(parseQrMatrix("0\n11\n"), { rows: [], size: 0 })
assert.deepStrictEqual(parseQrMatrix(""), { rows: [], size: 0 })
