import { Counter, Gauge, Histogram, Registry, collectDefaultMetrics } from "prom-client";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";

import { ConductorClient, type ConductorTask, type ConductorWorkflow } from "./conductor.js";
import {
  REVIEW_REVIEWING,
  buildReviewDecision,
  extractPendingReviewTasks,
  randomDelay,
} from "./review.js";
import { currentTraceFields, currentTraceparent, setupTelemetry, withTaskSpan } from "./telemetry.js";

const SERVICE_NAME = process.env.OTEL_SERVICE_NAME ?? "review-service";
const PORT = Number(process.env.REVIEW_SERVICE_PORT ?? 8090);
const CONDUCTOR_SERVER_URL = process.env.CONDUCTOR_SERVER_URL ?? "http://conductor-server:8080/api";
const OTLP_ENDPOINT =
  process.env.OTEL_EXPORTER_OTLP_ENDPOINT ?? "http://otel-collector:4318/v1/metrics";
const APPROVAL_THRESHOLD = Number(process.env.REVIEW_APPROVAL_THRESHOLD ?? 5);
const MAX_DELAY_MS = Number(process.env.REVIEW_MAX_DELAY_MS ?? 5000);
const REJECT_INCREMENT_MIN = Number(process.env.REVIEW_REJECT_INCREMENT_MIN ?? 0.1);
const REJECT_INCREMENT_MAX = Number(process.env.REVIEW_REJECT_INCREMENT_MAX ?? 1.0);
const REVIEW_API_TOKEN = process.env.REVIEW_API_TOKEN?.trim() ?? "";

const { meter, tracer } = setupTelemetry(SERVICE_NAME, OTLP_ENDPOINT);
const reviewCounter = meter.createCounter("conductor_demo_review_decisions_total", {
  description: "Total review decisions emitted by the review service",
});
const reviewDuration = meter.createHistogram("conductor_demo_review_duration_ms", {
  description: "Review decision duration in milliseconds",
  unit: "ms",
});

const promRegistry = new Registry();
collectDefaultMetrics({ register: promRegistry });

const requestCounter = new Counter({
  name: "conductor_demo_review_http_requests_total",
  help: "HTTP requests handled by the review service",
  labelNames: ["route", "status_code"] as const,
  registers: [promRegistry],
});
const failureCounter = new Counter({
  name: "conductor_demo_review_failures_total",
  help: "Review failures observed by the review service",
  registers: [promRegistry],
});
const pendingGauge = new Gauge({
  name: "conductor_demo_review_pending_total",
  help: "Pending review tasks observed by the review service",
  registers: [promRegistry],
});
const durationHistogram = new Histogram({
  name: "conductor_demo_review_duration_seconds",
  help: "Review decision duration in seconds",
  registers: [promRegistry],
});

const client = new ConductorClient(CONDUCTOR_SERVER_URL);

function logEvent(
  level: "ERROR" | "INFO",
  message: string,
  fields: Record<string, unknown>,
): void {
  process.stdout.write(
    `${JSON.stringify({
      ts: new Date().toISOString(),
      level,
      service: SERVICE_NAME,
      message,
      ...currentTraceFields(),
      ...fields,
    })}\n`,
  );
}

function toOptionalNumber(value: unknown): number | undefined {
  if (value === null || value === undefined || value === "") {
    return undefined;
  }

  const numeric = Number(value);
  return Number.isNaN(numeric) ? undefined : Number(numeric.toFixed(2));
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}

function writeJson(
  route: string,
  response: ServerResponse,
  statusCode: number,
  payload: Record<string, unknown>,
): void {
  const body = JSON.stringify(payload);
  requestCounter.inc({
    route,
    status_code: String(statusCode),
  });
  response.writeHead(statusCode, {
    "Content-Type": "application/json",
    "Content-Length": Buffer.byteLength(body),
  });
  response.end(body);
}

async function readJsonBody(request: IncomingMessage): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = [];

  for await (const chunk of request) {
    chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
  }

  if (chunks.length === 0) {
    return {};
  }

  return JSON.parse(Buffer.concat(chunks).toString("utf8")) as Record<string, unknown>;
}

async function mapWithConcurrency<T, R>(
  items: T[],
  concurrency: number,
  fn: (item: T) => Promise<R>,
): Promise<Array<{ error?: string; item: T; result?: R }>> {
  const results: Array<{ error?: string; item: T; result?: R }> = [];
  const queue = [...items];
  const workerCount = Math.max(1, concurrency);

  await Promise.all(
    Array.from({ length: workerCount }, async () => {
      while (queue.length > 0) {
        const item = queue.shift();
        if (!item) {
          return;
        }

        try {
          const result = await fn(item);
          results.push({ item, result });
        } catch (error) {
          results.push({
            item,
            error: error instanceof Error ? error.message : String(error),
          });
        }
      }
    }),
  );

  return results;
}

function parseLimit(url: URL, fallback: number): number {
  return Number(url.searchParams.get("limit") ?? fallback);
}

function isAuthorized(request: IncomingMessage): boolean {
  if (!REVIEW_API_TOKEN) {
    return true;
  }

  return request.headers.authorization === `Bearer ${REVIEW_API_TOKEN}`;
}

async function listPendingReviews(workflowId: string | null, limit: number): Promise<ReturnType<typeof extractPendingReviewTasks>> {
  const workflows: ConductorWorkflow[] = [];

  if (workflowId) {
    workflows.push(await client.getWorkflow(workflowId));
  } else {
    const search = await client.searchWorkflows("workflowType = 'human_review_demo' AND status = 'RUNNING'", limit);
    const workflowIds = (search.results ?? [])
      .map((item) => item.workflowId)
      .filter((value): value is string => Boolean(value));

    const details = await mapWithConcurrency(workflowIds, 8, async (id) => client.getWorkflow(id));
    for (const detail of details) {
      if (detail.result) {
        workflows.push(detail.result);
      }
    }
  }

  const items = extractPendingReviewTasks(workflows).slice(0, limit);
  pendingGauge.set(items.length);
  return items;
}

function validateHumanTask(task: ConductorTask): void {
  if (task.status !== "IN_PROGRESS") {
    throw new Error(`task ${task.taskId} is not pending review`);
  }

  if (task.referenceTaskName !== "review_gate" && task.taskType !== "HUMAN") {
    throw new Error(`task ${task.taskId} is not a HUMAN review task`);
  }
}

async function processDecision(
  task: ConductorTask,
  mode: "approve" | "auto" | "reject",
  comment?: string,
): Promise<Record<string, unknown>> {
  validateHumanTask(task);
  const taskInput = task.inputData ?? {};
  const delayMs = randomDelay(MAX_DELAY_MS);

  return withTaskSpan(
    tracer,
    "review_service.process",
    taskInput.traceparent,
    {
      "conductor.task.id": task.taskId,
      "conductor.task.type": task.taskType ?? "HUMAN",
      "conductor.workflow.id": task.workflowInstanceId,
      "review.mode": mode,
    },
    async () => {
      const correlationId =
        typeof taskInput.correlation_id === "string" ? taskInput.correlation_id : undefined;
      const initialX = toOptionalNumber(taskInput.initial_x);
      const initialXTag =
        typeof taskInput.initial_x_tag === "string" ? taskInput.initial_x_tag : undefined;

      logEvent("INFO", "review started", {
        candidate_x: toOptionalNumber(taskInput.candidate_x),
        correlation_id: correlationId,
        initial_x: initialX,
        initial_x_tag: initialXTag,
        review_state: REVIEW_REVIEWING,
        taskId: task.taskId,
        workflowId: task.workflowInstanceId,
      });

      const startedAt = performance.now();
      await sleep(delayMs);
      const decision = buildReviewDecision({
        comment,
        delayMs,
        incrementRange: {
          max: REJECT_INCREMENT_MAX,
          min: REJECT_INCREMENT_MIN,
        },
        mode,
        task,
        threshold: APPROVAL_THRESHOLD,
      });
      const processedAt = new Date().toISOString();
      const outputData = {
        ...decision,
        correlation_id: correlationId ?? "",
        initial_x: initialX,
        initial_x_tag: initialXTag ?? "",
        processed_at: processedAt,
        traceparent: currentTraceparent(),
        workflowId: task.workflowInstanceId,
        ...currentTraceFields(),
      };

      await client.updateTask({
        taskId: task.taskId,
        workflowInstanceId: task.workflowInstanceId,
        status: "COMPLETED",
        outputData,
      });

      const durationMs = Number((performance.now() - startedAt).toFixed(2));
      reviewCounter.add(1, {
        decision: decision.decision,
        service: SERVICE_NAME,
      });
      reviewDuration.record(durationMs, {
        decision: decision.decision,
        service: SERVICE_NAME,
      });
      durationHistogram.observe(durationMs / 1000);
      logEvent("INFO", "review completed", {
        decision: decision.decision,
        delay_ms: delayMs,
        initial_x: initialX,
        initial_x_tag: initialXTag,
        next_x: decision.next_x,
        correlation_id: correlationId,
        taskId: task.taskId,
        workflowId: task.workflowInstanceId,
      });

      return {
        comment: decision.comment,
        correlation_id: correlationId ?? "",
        decision: decision.decision,
        delay_ms: delayMs,
        initial_x: initialX,
        initial_x_tag: initialXTag ?? "",
        next_x: decision.next_x,
        processed_at: processedAt,
        taskId: task.taskId,
        trace_id: outputData.trace_id,
        workflowId: task.workflowInstanceId,
      };
    },
  );
}

async function handleRequest(request: IncomingMessage, response: ServerResponse): Promise<void> {
  const url = new URL(request.url ?? "/", `http://${request.headers.host ?? "localhost"}`);
  const route = url.pathname;

  if (request.method === "GET" && route === "/healthz") {
    writeJson(route, response, 200, { ok: true, service: SERVICE_NAME });
    return;
  }

  if (request.method === "GET" && route === "/metrics") {
    const body = await promRegistry.metrics();
    response.writeHead(200, {
      "Content-Type": promRegistry.contentType,
      "Content-Length": Buffer.byteLength(body),
    });
    response.end(body);
    return;
  }

  if (route.startsWith("/reviews/") && !isAuthorized(request)) {
    writeJson(route, response, 401, {
      ok: false,
      error: "unauthorized",
      service: SERVICE_NAME,
    });
    return;
  }

  if (request.method === "GET" && route === "/reviews/pending") {
    const items = await listPendingReviews(url.searchParams.get("workflowId"), parseLimit(url, 20));
    writeJson(route, response, 200, {
      count: items.length,
      items,
    });
    return;
  }

  if (request.method === "POST" && route === "/reviews/auto-review") {
    const limit = parseLimit(url, 1000);
    const concurrency = Number(url.searchParams.get("concurrency") ?? 32);
    const items = await listPendingReviews(url.searchParams.get("workflowId"), limit);
    const startedAt = performance.now();
    const results = await mapWithConcurrency(items, concurrency, async (item) => {
      const task = await client.getTask(item.taskId);
      return processDecision(task, "auto");
    });

    const completed = results.filter((item) => item.result).map((item) => item.result);
    const failed = results.filter((item) => item.error);
    const averageDelayMs =
      completed.length === 0
        ? 0
        : Number(
            (
              completed.reduce((sum, item) => sum + Number(item?.delay_ms ?? 0), 0) /
              completed.length
            ).toFixed(2),
          );

    writeJson(route, response, 200, {
      average_delay_ms: averageDelayMs,
      completed: completed.length,
      failed: failed.length,
      in_progress: 0,
      items: completed,
      requested: items.length,
      runtime_ms: Number((performance.now() - startedAt).toFixed(2)),
    });
    return;
  }

  const reviewActionMatch = /^\/reviews\/([^/]+)\/(approve|auto-review|reject)$/.exec(route);
  if (request.method === "POST" && reviewActionMatch) {
    const [, taskId, action] = reviewActionMatch;
    const body = await readJsonBody(request);
    const task = await client.getTask(taskId);
    const mode = action === "approve" ? "approve" : action === "reject" ? "reject" : "auto";
    const result = await processDecision(
      task,
      mode,
      typeof body.comment === "string" ? body.comment : undefined,
    );
    writeJson(route, response, 200, result);
    return;
  }

  writeJson(route, response, 404, {
    ok: false,
    path: route,
    service: SERVICE_NAME,
  });
}

const server = createServer((request, response) => {
  handleRequest(request, response).catch((error) => {
    failureCounter.inc();
    logEvent("ERROR", "request failed", {
      error: error instanceof Error ? error.message : String(error),
      path: request.url ?? "/",
    });
    const route = new URL(request.url ?? "/", `http://${request.headers.host ?? "localhost"}`).pathname;
    writeJson(route, response, 500, {
      ok: false,
      error: error instanceof Error ? error.message : String(error),
      service: SERVICE_NAME,
    });
  });
});

server.listen(PORT, "0.0.0.0", () => {
  logEvent("INFO", "review-service started", {
    conductor_url: CONDUCTOR_SERVER_URL,
    port: String(PORT),
  });
});

function shutdown(): void {
  server.close(() => {
    logEvent("INFO", "review-service stopped", {});
    process.exit(0);
  });
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
