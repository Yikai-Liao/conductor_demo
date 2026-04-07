import test from "node:test";
import assert from "node:assert/strict";

import { computeFunc2 } from "../src/logic.js";

test("approved path computes y", () => {
  assert.deepEqual(computeFunc2({ x: 5.5 }), {
    x: 5.5,
    y: 11,
  });
});

test("missing x throws a clear error", () => {
  assert.throws(() => computeFunc2({ x: undefined }), /x is required/);
});
