import { Counter, Gauge, Histogram, Registry, collectDefaultMetrics } from "prom-client";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";

import { ConductorClient, type ConductorTask } from "./conductor.js";
import { computeFunc2 } from "./logic.js";
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

const promRegistry = new Registry();
collectDefaultMetrics({ register: promRegistry });

const pollCounter = new Counter({
  name: "conductor_demo_ts_polls_total",
  help: "Poll attempts made by the TypeScript worker",
  registers: [promRegistry],
});
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

const client = new ConductorClient(CONDUCTOR_SERVER_URL);
let isStopping = false;

function logEvent(
  level: "ERROR" | "INFO",
  message: string,
  fields: Record<string, number | string | undefined>,
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

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
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
    writeJson(response, 200, {
      ok: true,
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

function buildOutput(task: ConductorTask) {
  const input = task.inputData ?? {};
  const result = computeFunc2({ x: input.x });

  return {
    ...result,
    attempt: Number(input.attempt ?? 0),
    comment: typeof input.comment === "string" ? input.comment : "",
    correlation_id: typeof input.correlation_id === "string" ? input.correlation_id : "",
    taskId: task.taskId,
    traceparent: currentTraceparent(),
    workflowId: task.workflowInstanceId,
    ...currentTraceFields(),
  };
}

async function completeTask(task: ConductorTask): Promise<void> {
  const input = task.inputData ?? {};
  const startedAt = performance.now();

  await withTaskSpan(
    tracer,
    "func2_ts.execute",
    input.traceparent,
    {
      "conductor.task.id": task.taskId,
      "conductor.task.type": TASK_TYPE,
      "conductor.workflow.id": task.workflowInstanceId,
    },
    async () => {
      inflightGauge.inc();
      logEvent("INFO", "func2 task started", {
        attempt: String(input.attempt ?? ""),
        taskId: task.taskId,
        taskType: TASK_TYPE,
        workflowId: task.workflowInstanceId,
        x: String(input.x ?? ""),
      });

      try {
        const outputData = buildOutput(task);
        await client.updateTask({
          taskId: task.taskId,
          workflowInstanceId: task.workflowInstanceId,
          status: "COMPLETED",
          outputData,
        });

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
        durationHistogram.observe(durationMs / 1000);
        logEvent("INFO", "func2 task completed", {
          duration_ms: durationMs.toString(),
          taskId: task.taskId,
          taskType: TASK_TYPE,
          workflowId: task.workflowInstanceId,
          y: String(outputData.y),
        });
      } catch (error) {
        failureCounter.inc();
        const reason = error instanceof Error ? error.message : String(error);
        await client.updateTask({
          taskId: task.taskId,
          workflowInstanceId: task.workflowInstanceId,
          status: "FAILED",
          reasonForIncompletion: reason,
          outputData: {
            taskId: task.taskId,
            workflowId: task.workflowInstanceId,
            ...currentTraceFields(),
          },
        });
        logEvent("ERROR", "func2 task failed", {
          error: reason,
          taskId: task.taskId,
          taskType: TASK_TYPE,
          workflowId: task.workflowInstanceId,
        });
      } finally {
        inflightGauge.dec();
      }
    },
  );
}

async function pollLoop(): Promise<void> {
  while (!isStopping) {
    try {
      pollCounter.inc();
      const task = await client.pollTask(TASK_TYPE, WORKER_ID);
      if (!task?.taskId) {
        await sleep(IDLE_SLEEP_MS);
        continue;
      }
      await completeTask(task);
    } catch (error) {
      failureCounter.inc();
      logEvent("ERROR", "poll loop error", {
        error: error instanceof Error ? error.message : String(error),
        taskType: TASK_TYPE,
      });
      await sleep(IDLE_SLEEP_MS);
    }
  }
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
  logEvent("INFO", "func2-ts worker started", {
    conductor_url: CONDUCTOR_SERVER_URL,
    port: String(PORT),
    workerId: WORKER_ID,
  });
});

for (let index = 0; index < WORKER_CONCURRENCY; index += 1) {
  void pollLoop();
}

function shutdown(): void {
  isStopping = true;
  server.close(() => {
    logEvent("INFO", "func2-ts worker stopped", { workerId: WORKER_ID });
    process.exit(0);
  });
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
