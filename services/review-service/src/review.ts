import type { ConductorTask, ConductorWorkflow } from "./conductor.js";

export const REVIEW_PENDING = "PENDING_REVIEW";
export const REVIEW_REVIEWING = "REVIEWING";
export const REVIEW_APPROVED = "APPROVED";
export const REVIEW_REJECTED = "REJECTED_WITH_COMMENT";

export interface PendingReviewItem {
  attempt: number;
  candidate_x: number;
  correlation_id?: string;
  created_at: string;
  initial_x?: number;
  initial_x_tag?: string;
  taskId: string;
  taskRefName: string;
  trace_id?: string;
  traceparent?: string;
  workflowId: string;
}

export interface ReviewDecisionInput {
  comment?: string;
  delayMs: number;
  incrementRange: { max: number; min: number };
  mode: "approve" | "auto" | "reject";
  task: ConductorTask;
  threshold: number;
}

export interface ReviewDecisionResult {
  attempt: number;
  candidate_x: number;
  comment: string;
  decision: typeof REVIEW_APPROVED | typeof REVIEW_REJECTED;
  delay_ms: number;
  next_x: number;
}

function toNumber(value: unknown, fieldName: string): number {
  const numeric = Number(value);
  if (Number.isNaN(numeric)) {
    throw new Error(`${fieldName} must be numeric`);
  }
  return numeric;
}

function toOptionalNumber(value: unknown): number | undefined {
  const numeric = Number(value);
  return Number.isNaN(numeric) ? undefined : Number(numeric.toFixed(2));
}

function toIsoDate(epochMillis: number | undefined): string {
  if (!epochMillis) {
    return new Date(0).toISOString();
  }
  return new Date(epochMillis).toISOString();
}

function normalizeReviewTask(task: ConductorTask): PendingReviewItem | null {
  if (task.status !== "IN_PROGRESS") {
    return null;
  }

  const taskRefName = task.referenceTaskName ?? "";
  if (taskRefName !== "review_gate" && task.taskType !== "HUMAN") {
    return null;
  }

  const input = task.inputData ?? {};
  const candidateX = Number(input.candidate_x);
  const attempt = Number(input.attempt);
  if (Number.isNaN(candidateX) || Number.isNaN(attempt)) {
    return null;
  }

  return {
    attempt,
    candidate_x: Number(candidateX.toFixed(2)),
    correlation_id: typeof input.correlation_id === "string" ? input.correlation_id : undefined,
    created_at: toIsoDate(task.startTime ?? task.updateTime),
    initial_x: toOptionalNumber(input.initial_x),
    initial_x_tag: typeof input.initial_x_tag === "string" ? input.initial_x_tag : undefined,
    taskId: task.taskId,
    taskRefName: task.referenceTaskName ?? "review_gate",
    trace_id: typeof input.trace_id === "string" ? input.trace_id : undefined,
    traceparent: typeof input.traceparent === "string" ? input.traceparent : undefined,
    workflowId: task.workflowInstanceId,
  };
}

export function extractPendingReviewTasks(workflows: ConductorWorkflow[]): PendingReviewItem[] {
  return workflows
    .flatMap((workflow) => workflow.tasks ?? [])
    .map((task) => normalizeReviewTask(task))
    .filter((item): item is PendingReviewItem => item !== null)
    .sort((left, right) => left.created_at.localeCompare(right.created_at));
}

export function buildReviewDecision(input: ReviewDecisionInput): ReviewDecisionResult {
  const taskInput = input.task.inputData ?? {};
  const candidateX = toNumber(taskInput.candidate_x, "candidate_x");
  const attempt = toNumber(taskInput.attempt ?? 1, "attempt");

  if (input.mode === "approve") {
    return {
      attempt,
      candidate_x: Number(candidateX.toFixed(2)),
      comment: input.comment?.trim() || "人工审批通过",
      decision: REVIEW_APPROVED,
      delay_ms: input.delayMs,
      next_x: Number(candidateX.toFixed(2)),
    };
  }

  if (input.mode === "reject") {
    const increment = randomBetween(input.incrementRange.min, input.incrementRange.max);
    return {
      attempt,
      candidate_x: Number(candidateX.toFixed(2)),
      comment: input.comment?.trim() || `数值不符合，打回 (candidate_x=${candidateX.toFixed(2)})`,
      decision: REVIEW_REJECTED,
      delay_ms: input.delayMs,
      next_x: Number((candidateX + increment).toFixed(2)),
    };
  }

  if (candidateX > input.threshold) {
    return {
      attempt,
      candidate_x: Number(candidateX.toFixed(2)),
      comment: input.comment?.trim() || `自动审批通过，candidate_x=${candidateX.toFixed(2)}`,
      decision: REVIEW_APPROVED,
      delay_ms: input.delayMs,
      next_x: Number(candidateX.toFixed(2)),
    };
  }

  const increment = randomBetween(input.incrementRange.min, input.incrementRange.max);
  return {
    attempt,
    candidate_x: Number(candidateX.toFixed(2)),
    comment: input.comment?.trim() || `自动审批打回，candidate_x=${candidateX.toFixed(2)}`,
    decision: REVIEW_REJECTED,
    delay_ms: input.delayMs,
    next_x: Number((candidateX + increment).toFixed(2)),
  };
}

export function randomDelay(maxDelayMs: number): number {
  return Math.floor(Math.random() * (maxDelayMs + 1));
}

export function randomBetween(min: number, max: number): number {
  if (min > max) {
    throw new Error("incrementRange.min must be <= incrementRange.max");
  }

  return Number((Math.random() * (max - min) + min).toFixed(2));
}
