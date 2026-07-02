// OpenTelemetry SDK initialization
// This file configures traces, metrics, and logs exporters for Grafana Stack

const { NodeSDK } = require('@opentelemetry/sdk-node');
const { getNodeAutoInstrumentations } = require('@opentelemetry/auto-instrumentations-node');
const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-http');
const { OTLPMetricExporter } = require('@opentelemetry/exporter-metrics-otlp-http');
const { OTLPLogExporter } = require('@opentelemetry/exporter-logs-otlp-http');
const { PeriodicExportingMetricReader } = require('@opentelemetry/sdk-metrics');
const { LoggerProvider, BatchLogRecordProcessor } = require('@opentelemetry/sdk-logs');
const { logs } = require('@opentelemetry/api-logs');
const { Resource } = require('@opentelemetry/resources');
const {
  ATTR_SERVICE_NAME,
  ATTR_SERVICE_VERSION,
} = require('@opentelemetry/semantic-conventions');

// Get OTEL endpoint from environment variable or use default
const otlpEndpoint = process.env.OTEL_EXPORTER_OTLP_ENDPOINT || 'http://localhost:4318';

// Configure trace exporter
const traceExporter = new OTLPTraceExporter({
  url: `${otlpEndpoint}/v1/traces`,
});

// Configure metrics exporter
const metricExporter = new OTLPMetricExporter({
  url: `${otlpEndpoint}/v1/metrics`,
});

// Configure logs exporter
const logExporter = new OTLPLogExporter({
  url: `${otlpEndpoint}/v1/logs`,
});

// Create shared resource.
// service.namespace / deployment.environment use stable string keys; the
// dedicated semconv constants for these moved across versions, so plain keys
// keep this forward-compatible.
const resource = new Resource({
  [ATTR_SERVICE_NAME]: 'products-service',
  [ATTR_SERVICE_VERSION]: '2.0.0',
  'service.namespace': 'demo',
  'deployment.environment': 'demo',
});

// Initialize Logger Provider for logs
const loggerProvider = new LoggerProvider({ resource });
loggerProvider.addLogRecordProcessor(new BatchLogRecordProcessor(logExporter));
logs.setGlobalLoggerProvider(loggerProvider);

// Initialize OpenTelemetry SDK with all exporters.
// NOTE: exemplars are enabled via OTEL_METRICS_EXEMPLAR_FILTER=trace_based
// (set in the Helm chart env). With exemplars on, every histogram sample can
// carry the trace_id of an in-flight request, which is what powers the
// "jump from a latency spike straight to the trace" experience in Grafana.
const sdk = new NodeSDK({
  resource,
  traceExporter,
  metricReader: new PeriodicExportingMetricReader({
    exporter: metricExporter,
    exportIntervalMillis: 10000, // Export metrics every 10 seconds
  }),
  logRecordProcessor: new BatchLogRecordProcessor(logExporter),
  instrumentations: [
    getNodeAutoInstrumentations({
      // Express/HTTP auto-instrumentation creates the active server span that
      // our manual child spans nest under. Keep noisy fs instrumentation off.
      '@opentelemetry/instrumentation-fs': { enabled: false },
    }),
  ],
});

sdk.start();

console.log(JSON.stringify({
  message: 'OpenTelemetry SDK initialized',
  service: 'products-service',
  endpoint: otlpEndpoint,
  exporters: ['traces', 'metrics', 'logs'],
  exemplars: process.env.OTEL_METRICS_EXEMPLAR_FILTER || 'default',
}));

// ---------------------------------------------------------------------------
// Continuous profiling (Pyroscope). Pushes CPU/heap profiles so Grafana can
// render flame graphs - the open-source counterpart to Datadog Continuous
// Profiler. Wrapped in try/catch so a missing module or unreachable server
// never takes the app down (the demo still works without profiling).
// ---------------------------------------------------------------------------
const pyroscopeServer = process.env.PYROSCOPE_SERVER_ADDRESS;
if (pyroscopeServer) {
  try {
    const Pyroscope = require('@pyroscope/nodejs');
    Pyroscope.init({
      serverAddress: pyroscopeServer,
      appName: process.env.PYROSCOPE_APPLICATION_NAME || 'products-service',
      tags: { service_namespace: 'demo' },
    });
    Pyroscope.start();
    console.log(JSON.stringify({
      message: 'Pyroscope profiling started',
      service: 'products-service',
      server: pyroscopeServer,
    }));
  } catch (err) {
    console.log(JSON.stringify({
      message: 'Pyroscope profiling not started (continuing without it)',
      error: err.message,
    }));
  }
}

// Graceful shutdown
process.on('SIGTERM', () => {
  sdk.shutdown()
    .then(() => {
      loggerProvider.shutdown();
      console.log(JSON.stringify({ message: 'OpenTelemetry SDK terminated' }));
    })
    .catch((error) => console.log(JSON.stringify({ message: 'Error terminating SDK', error: error.message })))
    .finally(() => process.exit(0));
});
