import test from "node:test";
import assert from "node:assert/strict";

import { buildYTag, computeFunc2 } from "../src/logic.js";

test("approved path computes y", () => {
  assert.deepEqual(computeFunc2({ x: 5.5 }), {
    x: 5.5,
    y: 11,
  });
});

test("missing x throws a clear error", () => {
  assert.throws(() => computeFunc2({ x: undefined }), /x is required/);
});

test("y tag splits at 10.5", () => {
  assert.equal(buildYTag(10.49), "y_lt_10_5");
  assert.equal(buildYTag(10.5), "y_ge_10_5");
});
