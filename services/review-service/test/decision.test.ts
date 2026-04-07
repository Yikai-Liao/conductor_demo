import test from "node:test";
import assert from "node:assert/strict";

import { REVIEW_APPROVED, REVIEW_REJECTED, buildReviewDecision } from "../src/review.js";

const baseTask = {
  taskId: "task-1",
  workflowInstanceId: "wf-1",
  inputData: {
    attempt: 2,
    candidate_x: 4.2,
  },
};

test("approve decision keeps next_x unchanged", () => {
  const result = buildReviewDecision({
    delayMs: 12,
    incrementRange: { min: 0.1, max: 1 },
    mode: "approve",
    task: baseTask,
    threshold: 5,
  });

  assert.equal(result.decision, REVIEW_APPROVED);
  assert.equal(result.next_x, 4.2);
});

test("reject decision returns rejection with comment", () => {
  const result = buildReviewDecision({
    delayMs: 12,
    incrementRange: { min: 0.1, max: 0.1 },
    mode: "reject",
    task: baseTask,
    threshold: 5,
  });

  assert.equal(result.decision, REVIEW_REJECTED);
  assert.equal(result.next_x, 4.3);
  assert.match(result.comment, /打回/);
});
