import test from "node:test";
import assert from "node:assert/strict";

import { extractPendingReviewTasks } from "../src/review.js";

test("extractPendingReviewTasks returns empty when no pending tasks exist", () => {
  const items = extractPendingReviewTasks([
    {
      workflowId: "wf-1",
      tasks: [],
    },
  ]);

  assert.deepEqual(items, []);
});

test("extractPendingReviewTasks keeps required fields", () => {
  const items = extractPendingReviewTasks([
    {
      workflowId: "wf-1",
      tasks: [
        {
          taskId: "task-1",
          taskType: "HUMAN",
          referenceTaskName: "review_gate",
          workflowInstanceId: "wf-1",
          status: "IN_PROGRESS",
          startTime: Date.parse("2026-04-07T00:00:00Z"),
          inputData: {
            attempt: 2,
            candidate_x: 4.2,
            traceparent: "00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01",
          },
        },
      ],
    },
  ]);

  assert.equal(items.length, 1);
  assert.equal(items[0]?.workflowId, "wf-1");
  assert.equal(items[0]?.taskId, "task-1");
  assert.equal(items[0]?.attempt, 2);
  assert.equal(items[0]?.candidate_x, 4.2);
});
