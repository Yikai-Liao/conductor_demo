import { context, metrics, propagation, trace, type Attributes } from "@opentelemetry/api";
import { W3CTraceContextPropagator } from "@opentelemetry/core";
import { OTLPMetricExporter } from "@opentelemetry/exporter-metrics-otlp-http";
import { resourceFromAttributes } from "@opentelemetry/resources";
import { MeterProvider, PeriodicExportingMetricReader } from "@opentelemetry/sdk-metrics";
import { NodeTracerProvider } from "@opentelemetry/sdk-trace-node";

export interface TraceFields {
  span_id?: string;
  trace_flags?: string;
  trace_id?: string;
}

export function setupTelemetry(serviceName: string, otlpEndpoint: string) {
  const resource = resourceFromAttributes({ "service.name": serviceName });
  const exporter = new OTLPMetricExporter({ url: otlpEndpoint });
  const reader = new PeriodicExportingMetricReader({
    exporter,
    exportIntervalMillis: 5000,
  });
  const meterProvider = new MeterProvider({
    resource,
    readers: [reader],
  });

  metrics.setGlobalMeterProvider(meterProvider);

  const tracerProvider = new NodeTracerProvider({ resource });
  tracerProvider.register({
    propagator: new W3CTraceContextPropagator(),
  });

  return {
    meter: metrics.getMeter(serviceName),
    tracer: trace.getTracer(serviceName),
  };
}

export function extractParentContext(traceparent?: unknown) {
  if (typeof traceparent !== "string" || traceparent.trim() === "") {
    return context.active();
  }

  return propagation.extract(context.active(), { traceparent });
}

export function currentTraceFields(): TraceFields {
  const span = trace.getSpan(context.active());
  const spanContext = span?.spanContext();

  if (!spanContext) {
    return {};
  }

  return {
    span_id: spanContext.spanId,
    trace_flags: spanContext.traceFlags.toString(16).padStart(2, "0"),
    trace_id: spanContext.traceId,
  };
}

export function currentTraceparent(): string | undefined {
  const carrier: Record<string, string> = {};
  propagation.inject(context.active(), carrier);
  return carrier.traceparent;
}

export async function withTaskSpan<T>(
  tracer: ReturnType<typeof trace.getTracer>,
  name: string,
  traceparent: unknown,
  attributes: Attributes,
  fn: () => Promise<T>,
): Promise<T> {
  const parentContext = extractParentContext(traceparent);

  return context.with(parentContext, () =>
    tracer.startActiveSpan(name, { attributes }, async (span) => {
      try {
        return await fn();
      } catch (error) {
        span.recordException(error as Error);
        throw error;
      } finally {
        span.end();
      }
    }),
  );
}
