const { test } = require("node:test");
const assert = require("node:assert/strict");

test("deliberate testbed failure", () => { assert.equal(1, 2); });
