import {
  OrkesClients,
  TaskHandler,
  getTaskContext,
  worker,
  type Task,
  type TaskResult,
} from "@io-orkes/conductor-javascript";
import { Counter, Gauge, Histogram, Registry, collectDefaultMetrics } from "prom-client";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";

import { buildYTag, computeFunc2 } from "./logic.js";
import { currentTraceFields, currentTraceparent, setupTelemetry, withTaskSpan } from "./telemetry.js";

const SERVICE_NAME = process.env.OTEL_SERVICE_NAME ?? "func2-ts";
const TASK_TYPE = "func2_ts";
const WORKER_ID = process.env.WORKER_ID ?? SERVICE_NAME;
const PORT = Number(process.env.WORKER_PORT ?? 8092);
const CONDUCTOR_SERVER_URL = process.env.CONDUCTOR_SERVER_URL ?? "http://conductor-server:8080/api";
const OTLP_ENDPOINT =
  process.env.OTEL_EXPORTER_OTLP_ENDPOINT ?? "http://otel-collector:4318/v1/metrics";
const WORKER_CONCURRENCY = Number(process.env.WORKER_CONCURRENCY ?? 8);
const IDLE_SLEEP_MS = Number(process.env.WORKER_IDLE_SLEEP_MS ?? 500);

const { meter, tracer } = setupTelemetry(SERVICE_NAME, OTLP_ENDPOINT);
const taskRuns = meter.createCounter("conductor_demo_task_runs_total", {
  description: "Total completed Conductor demo task executions",
});
const taskDuration = meter.createHistogram("conductor_demo_task_duration_ms", {
  description: "Task execution duration in milliseconds",
  unit: "ms",
});
const finalOutputs = meter.createCounter("conductor_demo_final_outputs_total", {
  description: "Final func2 outputs grouped by initial cohort and y tag",
});
const finalYValue = meter.createHistogram("conductor_demo_final_y", {
  description: "Final y values emitted by func2",
  unit: "1",
});

const promRegistry = new Registry();
collectDefaultMetrics({ register: promRegistry });

const failureCounter = new Counter({
  name: "conductor_demo_ts_failures_total",
  help: "Failures observed by the TypeScript worker",
  registers: [promRegistry],
});
const inflightGauge = new Gauge({
  name: "conductor_demo_ts_inflight",
  help: "In-flight tasks in the TypeScript worker",
  registers: [promRegistry],
});
const durationHistogram = new Histogram({
  name: "conductor_demo_ts_task_duration_seconds",
  help: "Task processing time in seconds for the TypeScript worker",
  registers: [promRegistry],
});

let handler: TaskHandler | null = null;
let isStopping = false;
let startupError: string | null = null;

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

function toOptionalString(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function requireTaskIdentity(task: Task): { taskId: string; workflowId: string } {
  if (!task.taskId) {
    throw new Error("taskId is required");
  }

  if (!task.workflowInstanceId) {
    throw new Error("workflowInstanceId is required");
  }

  return {
    taskId: task.taskId,
    workflowId: task.workflowInstanceId,
  };
}

function writeJson(response: ServerResponse, statusCode: number, payload: Record<string, unknown>): void {
  const body = JSON.stringify(payload);
  response.writeHead(statusCode, {
    "Content-Type": "application/json",
    "Content-Length": Buffer.byteLength(body),
  });
  response.end(body);
}

async function handleRequest(request: IncomingMessage, response: ServerResponse): Promise<void> {
  const path = request.url ?? "/";
  if (request.method !== "GET") {
    writeJson(response, 405, { ok: false, service: SERVICE_NAME, path });
    return;
  }

  if (path === "/healthz") {
    const running = handler?.running ?? false;
    const runningWorkers = handler?.runningWorkerCount ?? 0;
    const healthy = startupError === null && running && runningWorkers > 0;
    writeJson(response, healthy ? 200 : 503, {
      error: startupError,
      ok: healthy,
      running,
      runningWorkers,
      service: SERVICE_NAME,
      taskType: TASK_TYPE,
      workerId: WORKER_ID,
    });
    return;
  }

  if (path === "/metrics") {
    const body = await promRegistry.metrics();
    response.writeHead(200, {
      "Content-Type": promRegistry.contentType,
      "Content-Length": Buffer.byteLength(body),
    });
    response.end(body);
    return;
  }

  writeJson(response, 404, { ok: false, service: SERVICE_NAME, path });
}

function buildOutput(task: Task) {
  const input = task.inputData ?? {};
  const result = computeFunc2({ x: input.x });
  const { taskId, workflowId } = requireTaskIdentity(task);
  const cnCaseTitle = toOptionalString(input.cn_case_title);
  const cnCaseBody = toOptionalString(input.cn_case_body);
  const cnKeywords = toOptionalString(input.cn_keywords);
  const cnReviewComment = toOptionalString(input.cn_review_comment);
  const comment = typeof input.comment === "string" ? input.comment : "";

  return {
    ...result,
    attempt: Number(input.attempt ?? 0),
    cn_case_body: cnCaseBody,
    cn_case_title: cnCaseTitle,
    cn_final_summary: `${cnCaseTitle} 已完成，关键词=${cnKeywords}，review=${cnReviewComment || comment}，final_y=${result.y.toFixed(2)} / searchable summary`,
    cn_keywords: cnKeywords,
    cn_review_comment: cnReviewComment,
    comment,
    correlation_id: typeof input.correlation_id === "string" ? input.correlation_id : "",
    initial_x: toOptionalNumber(input.initial_x),
    initial_x_tag: typeof input.initial_x_tag === "string" ? input.initial_x_tag : "",
    taskId,
    traceparent: currentTraceparent(),
    workflowId,
    y_tag: buildYTag(result.y),
    ...currentTraceFields(),
  };
}

async function completeTask(task: Task): Promise<TaskResult> {
  const input = task.inputData ?? {};
  const startedAt = performance.now();
  const ctx = getTaskContext();
  const { taskId, workflowId } = requireTaskIdentity(task);

  return withTaskSpan(
    tracer,
    "func2_ts.execute",
    input.traceparent,
    {
      "conductor.task.id": taskId,
      "conductor.task.type": TASK_TYPE,
      "conductor.workflow.id": workflowId,
    },
    async () => {
      inflightGauge.inc();
      ctx?.addLog(`func2 task started: taskId=${taskId}`);
      logEvent("INFO", "func2 task started", {
        attempt: Number(input.attempt ?? 0),
        cn_case_title: toOptionalString(input.cn_case_title) || undefined,
        correlation_id: typeof input.correlation_id === "string" ? input.correlation_id : undefined,
        initial_x: toOptionalNumber(input.initial_x),
        initial_x_tag: typeof input.initial_x_tag === "string" ? input.initial_x_tag : undefined,
        taskId,
        taskType: TASK_TYPE,
        workflowId,
        x: toOptionalNumber(input.x),
      });

      try {
        const outputData = buildOutput(task);
        const durationMs = Number((performance.now() - startedAt).toFixed(2));

        taskRuns.add(1, {
          result: "completed",
          service: SERVICE_NAME,
          task_type: TASK_TYPE,
        });
        taskDuration.record(durationMs, {
          result: "completed",
          service: SERVICE_NAME,
          task_type: TASK_TYPE,
        });
        finalOutputs.add(1, {
          initial_x_tag: outputData.initial_x_tag || "initial_x_unknown",
          service: SERVICE_NAME,
          y_tag: outputData.y_tag,
        });
        finalYValue.record(outputData.y, {
          initial_x_tag: outputData.initial_x_tag || "initial_x_unknown",
          service: SERVICE_NAME,
          y_tag: outputData.y_tag,
        });
        durationHistogram.observe(durationMs / 1000);
        ctx?.addLog(`func2 completed: y=${outputData.y}`);
        logEvent("INFO", "func2 task completed", {
          cn_case_title: outputData.cn_case_title,
          correlation_id: outputData.correlation_id,
          duration_ms: durationMs,
          initial_x: outputData.initial_x,
          initial_x_tag: outputData.initial_x_tag,
          taskId,
          taskType: TASK_TYPE,
          workflowId,
          y: outputData.y,
          y_tag: outputData.y_tag,
        });

        return {
          outputData,
          taskId,
          status: "COMPLETED",
          workflowInstanceId: workflowId,
        };
      } catch (error) {
        failureCounter.inc();
        const reason = error instanceof Error ? error.message : String(error);
        ctx?.addLog(`func2 failed: ${reason}`);
        logEvent("ERROR", "func2 task failed", {
          cn_case_title: toOptionalString(input.cn_case_title) || undefined,
          correlation_id: typeof input.correlation_id === "string" ? input.correlation_id : undefined,
          error: reason,
          initial_x: toOptionalNumber(input.initial_x),
          initial_x_tag: typeof input.initial_x_tag === "string" ? input.initial_x_tag : undefined,
          taskId,
          taskType: TASK_TYPE,
          workflowId,
        });

        return {
          outputData: {
            cn_case_body: toOptionalString(input.cn_case_body),
            cn_case_title: toOptionalString(input.cn_case_title),
            cn_keywords: toOptionalString(input.cn_keywords),
            cn_review_comment: toOptionalString(input.cn_review_comment),
            correlation_id: typeof input.correlation_id === "string" ? input.correlation_id : "",
            initial_x: toOptionalNumber(input.initial_x),
            initial_x_tag: typeof input.initial_x_tag === "string" ? input.initial_x_tag : "",
            taskId,
            workflowId,
            ...currentTraceFields(),
          },
          reasonForIncompletion: reason,
          taskId,
          status: "FAILED",
          workflowInstanceId: workflowId,
        };
      } finally {
        inflightGauge.dec();
      }
    },
  );
}

class Func2Workers {
  @worker({
    concurrency: WORKER_CONCURRENCY,
    pollInterval: IDLE_SLEEP_MS,
    taskDefName: TASK_TYPE,
    workerId: WORKER_ID,
  })
  async execute(task: Task): Promise<TaskResult> {
    return completeTask(task);
  }
}

void new Func2Workers();

async function startWorkerHandler(): Promise<void> {
  const clients = await OrkesClients.from({ serverUrl: CONDUCTOR_SERVER_URL });
  handler = new TaskHandler({
    client: clients.getClient(),
    scanForDecorated: true,
  });
  await handler.startWorkers();
  startupError = null;
  logEvent("INFO", "func2-ts worker started", {
    conductor_url: CONDUCTOR_SERVER_URL,
    port: PORT,
    running_workers: handler.runningWorkerCount,
    workerId: WORKER_ID,
  });
}

const server = createServer((request, response) => {
  handleRequest(request, response).catch((error) => {
    writeJson(response, 500, {
      ok: false,
      error: error instanceof Error ? error.message : String(error),
      service: SERVICE_NAME,
    });
  });
});

server.listen(PORT, "0.0.0.0", () => {
  void startWorkerHandler().catch((error) => {
    startupError = error instanceof Error ? error.message : String(error);
    failureCounter.inc();
    logEvent("ERROR", "func2-ts worker failed to start", {
      error: startupError,
      workerId: WORKER_ID,
    });
  });
});

async function shutdown(): Promise<void> {
  if (isStopping) {
    return;
  }

  isStopping = true;
  try {
    await handler?.stopWorkers();
  } catch (error) {
    logEvent("ERROR", "func2-ts worker stop failed", {
      error: error instanceof Error ? error.message : String(error),
      workerId: WORKER_ID,
    });
  }

  server.close(() => {
    logEvent("INFO", "func2-ts worker stopped", { workerId: WORKER_ID });
    process.exit(0);
  });
}

process.on("SIGINT", () => {
  void shutdown();
});
process.on("SIGTERM", () => {
  void shutdown();
});
