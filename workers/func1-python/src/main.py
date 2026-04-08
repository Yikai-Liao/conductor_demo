from __future__ import annotations

import json
import os
import signal
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from conductor.client.configuration.configuration import Configuration
from conductor.client.http.models.task import Task
from conductor.client.http.models.task_result import TaskResult
from conductor.client.orkes_clients import OrkesClients
from conductor.client.task_client import TaskClient
from opentelemetry.trace import SpanKind, Status, StatusCode, get_current_span
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, Histogram, REGISTRY, generate_latest

from .logic import compute_candidate_x
from .telemetry import setup_telemetry

SERVICE_NAME = os.getenv("OTEL_SERVICE_NAME", "func1-python")
TASK_TYPE = "func1_python"
WORKER_ID = os.getenv("WORKER_ID", SERVICE_NAME)
PORT = int(os.getenv("WORKER_PORT", "8091"))
CONDUCTOR_SERVER_URL = os.getenv("CONDUCTOR_SERVER_URL", "http://conductor-server:8080/api")
OTLP_ENDPOINT = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4318/v1/metrics")
WORKER_CONCURRENCY = int(os.getenv("WORKER_CONCURRENCY", "8"))
IDLE_SLEEP_SECONDS = float(os.getenv("WORKER_IDLE_SLEEP_SECONDS", "0.5"))

meter, tracer, propagator = setup_telemetry(SERVICE_NAME, OTLP_ENDPOINT)

task_runs = meter.create_counter(
    name="conductor_demo_task_runs_total",
    description="Total completed Conductor demo task executions",
)
task_duration = meter.create_histogram(
    name="conductor_demo_task_duration_ms",
    description="Task execution duration in milliseconds",
    unit="ms",
)

poll_counter = Counter("conductor_demo_python_polls_total", "Poll attempts made by the Python worker")
failure_counter = Counter("conductor_demo_python_failures_total", "Failures observed by the Python worker")
inflight_gauge = Gauge("conductor_demo_python_inflight", "In-flight tasks in the Python worker")
duration_histogram = Histogram(
    "conductor_demo_python_task_duration_seconds",
    "Task processing time in seconds for the Python worker",
)

stop_event = threading.Event()
client: TaskClient = OrkesClients(
    configuration=Configuration(server_api_url=CONDUCTOR_SERVER_URL),
).get_task_client()


def utc_timestamp() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def current_trace_fields() -> dict[str, str]:
    span_context = get_current_span().get_span_context()
    if not span_context.is_valid:
        return {}

    return {
        "trace_id": format(span_context.trace_id, "032x"),
        "span_id": format(span_context.span_id, "016x"),
        "trace_flags": format(int(span_context.trace_flags), "02x"),
    }


def current_traceparent() -> str | None:
    carrier: dict[str, str] = {}
    propagator.inject(carrier)
    return carrier.get("traceparent")


def log_event(level: str, message: str, **fields: object) -> None:
    entry = {
        "ts": utc_timestamp(),
        "level": level,
        "service": SERVICE_NAME,
        "message": message,
        **current_trace_fields(),
        **fields,
    }
    print(json.dumps(entry, ensure_ascii=False), flush=True)


def as_string(value: object) -> str:
    return value if isinstance(value, str) else ""


def build_task_result(
    task: Task,
    status: str,
    output_data: dict[str, object],
    reason: str | None = None,
) -> TaskResult:
    result = TaskResult()
    result.task_id = task.task_id
    result.workflow_instance_id = task.workflow_instance_id
    result.worker_id = WORKER_ID
    result.status = status
    result.output_data = output_data
    if reason is not None:
        result.reason_for_incompletion = reason
    return result


class Handler(BaseHTTPRequestHandler):
    def _write_json(self, status_code: int, payload: dict[str, object]) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if self.path == "/healthz":
            self._write_json(
                200,
                {
                    "ok": True,
                    "service": SERVICE_NAME,
                    "taskType": TASK_TYPE,
                    "workerId": WORKER_ID,
                },
            )
            return

        if self.path == "/metrics":
            body = generate_latest(REGISTRY)
            self.send_response(200)
            self.send_header("Content-Type", CONTENT_TYPE_LATEST)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        self._write_json(404, {"ok": False, "service": SERVICE_NAME, "path": self.path})

    def log_message(self, format: str, *args: object) -> None:  # noqa: A003
        return


def build_completion_output(task: Task) -> dict[str, object]:
    workflow_id = task.workflow_instance_id
    task_id = task.task_id
    input_data = task.input_data or {}

    result = compute_candidate_x(
        current_x=input_data.get("current_x"),
        comments=input_data.get("comments"),
        attempt=input_data.get("attempt"),
    )

    return {
        **result,
        **current_trace_fields(),
        "correlation_id": as_string(input_data.get("correlation_id")),
        "initial_x": input_data.get("initial_x"),
        "initial_x_tag": as_string(input_data.get("initial_x_tag")),
        "taskId": task_id,
        "traceparent": current_traceparent(),
        "workflowId": workflow_id,
    }


def complete_task(task: Task) -> None:
    task_id = task.task_id
    workflow_id = task.workflow_instance_id
    input_data = task.input_data or {}
    traceparent = input_data.get("traceparent")
    parent_context = propagator.extract({"traceparent": traceparent}) if traceparent else None
    started = time.perf_counter()

    with tracer.start_as_current_span(
        "func1_python.execute",
        context=parent_context,
        kind=SpanKind.CONSUMER,
        attributes={
            "conductor.task.id": task_id,
            "conductor.task.type": TASK_TYPE,
            "conductor.workflow.id": workflow_id,
        },
    ) as span:
        inflight_gauge.inc()
        log_event(
            "INFO",
            "func1 task started",
            attempt=input_data.get("attempt"),
            comment_in=input_data.get("comments", ""),
            correlation_id=as_string(input_data.get("correlation_id")),
            initial_x=input_data.get("initial_x"),
            initial_x_tag=as_string(input_data.get("initial_x_tag")),
            taskId=task_id,
            taskType=TASK_TYPE,
            workflowId=workflow_id,
        )

        try:
            output_data = build_completion_output(task)
            client.update_task(build_task_result(task, "COMPLETED", output_data))

            elapsed_ms = round((time.perf_counter() - started) * 1000, 2)
            task_runs.add(
                1,
                {
                    "result": "completed",
                    "service": SERVICE_NAME,
                    "task_type": TASK_TYPE,
                },
            )
            task_duration.record(
                elapsed_ms,
                {
                    "result": "completed",
                    "service": SERVICE_NAME,
                    "task_type": TASK_TYPE,
                },
            )
            duration_histogram.observe(elapsed_ms / 1000)
            log_event(
                "INFO",
                "func1 task completed",
                candidate_x=output_data["candidate_x"],
                comment_in=output_data["comment_in"],
                correlation_id=output_data["correlation_id"],
                duration_ms=elapsed_ms,
                initial_x=output_data["initial_x"],
                initial_x_tag=output_data["initial_x_tag"],
                taskId=task_id,
                taskType=TASK_TYPE,
                workflowId=workflow_id,
            )
        except Exception as exc:  # noqa: BLE001
            failure_counter.inc()
            span.record_exception(exc)
            span.set_status(Status(status_code=StatusCode.ERROR, description=str(exc)))
            client.update_task(
                build_task_result(
                    task,
                    "FAILED",
                    {
                        **current_trace_fields(),
                        "correlation_id": as_string(input_data.get("correlation_id")),
                        "initial_x": input_data.get("initial_x"),
                        "initial_x_tag": as_string(input_data.get("initial_x_tag")),
                        "taskId": task_id,
                        "workflowId": workflow_id,
                    },
                    str(exc),
                )
            )
            log_event(
                "ERROR",
                "func1 task failed",
                correlation_id=as_string(input_data.get("correlation_id")),
                error=str(exc),
                initial_x=input_data.get("initial_x"),
                initial_x_tag=as_string(input_data.get("initial_x_tag")),
                taskId=task_id,
                taskType=TASK_TYPE,
                workflowId=workflow_id,
            )
        finally:
            inflight_gauge.dec()


def poll_loop() -> None:
    while not stop_event.is_set():
        try:
            poll_counter.inc()
            task = client.poll_task(TASK_TYPE, WORKER_ID)
            if not task or not task.task_id:
                time.sleep(IDLE_SLEEP_SECONDS)
                continue
            complete_task(task)
        except Exception as exc:  # noqa: BLE001
            failure_counter.inc()
            log_event("ERROR", "poll loop error", error=str(exc), taskType=TASK_TYPE)
            time.sleep(IDLE_SLEEP_SECONDS)


def run_http_server() -> ThreadingHTTPServer:
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server


def handle_shutdown(signum: int, frame: object) -> None:  # noqa: ARG001
    stop_event.set()


if __name__ == "__main__":
    signal.signal(signal.SIGINT, handle_shutdown)
    signal.signal(signal.SIGTERM, handle_shutdown)
    server = run_http_server()
    log_event(
        "INFO",
        "func1-python worker started",
        conductor_url=CONDUCTOR_SERVER_URL,
        port=PORT,
        workerId=WORKER_ID,
    )

    threads = [threading.Thread(target=poll_loop, daemon=True) for _ in range(WORKER_CONCURRENCY)]
    for thread in threads:
        thread.start()

    while not stop_event.is_set():
        time.sleep(0.5)

    server.shutdown()
    server.server_close()
    log_event("INFO", "func1-python worker stopped", workerId=WORKER_ID)
