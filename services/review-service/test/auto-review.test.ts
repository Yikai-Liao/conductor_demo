import test from "node:test";
import assert from "node:assert/strict";

import { REVIEW_APPROVED, REVIEW_REJECTED, buildReviewDecision } from "../src/review.js";

test("auto review approves when candidate_x is above threshold", () => {
  const result = buildReviewDecision({
    delayMs: 10,
    incrementRange: { min: 0.1, max: 1 },
    mode: "auto",
    task: {
      taskId: "task-approve",
      workflowInstanceId: "wf-approve",
      inputData: {
        attempt: 3,
        candidate_x: 5.1,
      },
    },
    threshold: 5,
  });

  assert.equal(result.decision, REVIEW_APPROVED);
  assert.match(result.comment, /auto-approved/);
});

test("auto review rejects when candidate_x is not above threshold", () => {
  const result = buildReviewDecision({
    delayMs: 10,
    incrementRange: { min: 0.1, max: 0.1 },
    mode: "auto",
    task: {
      taskId: "task-reject",
      workflowInstanceId: "wf-reject",
      inputData: {
        attempt: 3,
        candidate_x: 5.0,
      },
    },
    threshold: 5,
  });

  assert.equal(result.decision, REVIEW_REJECTED);
  assert.equal(result.next_x, 5.1);
  assert.match(result.comment, /auto-rejected/);
});
