from __future__ import annotations

from opentelemetry import metrics, trace
from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator


def setup_telemetry(service_name: str, otlp_endpoint: str) -> tuple:
    resource = Resource.create({"service.name": service_name})

    metric_exporter = OTLPMetricExporter(endpoint=otlp_endpoint)
    metric_reader = PeriodicExportingMetricReader(metric_exporter, export_interval_millis=5000)
    meter_provider = MeterProvider(resource=resource, metric_readers=[metric_reader])
    metrics.set_meter_provider(meter_provider)

    tracer_provider = TracerProvider(resource=resource)
    trace.set_tracer_provider(tracer_provider)

    return (
        metrics.get_meter(service_name),
        trace.get_tracer(service_name),
        TraceContextTextMapPropagator(),
    )
