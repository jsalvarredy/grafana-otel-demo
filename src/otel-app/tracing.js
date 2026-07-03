// OpenTelemetry SDK initialization
// This file configures traces, metrics, and logs exporters for Grafana Stack.
// Written against the OpenTelemetry JS SDK 2.x API (resourceFromAttributes,
// NodeSDK-managed logger provider).

const { NodeSDK } = require('@opentelemetry/sdk-node');
const { getNodeAutoInstrumentations } = require('@opentelemetry/auto-instrumentations-node');
const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-http');
const { OTLPMetricExporter } = require('@opentelemetry/exporter-metrics-otlp-http');
const { OTLPLogExporter } = require('@opentelemetry/exporter-logs-otlp-http');
const { PeriodicExportingMetricReader } = require('@opentelemetry/sdk-metrics');
const { BatchLogRecordProcessor } = require('@opentelemetry/sdk-logs');
const { resourceFromAttributes } = require('@opentelemetry/resources');
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
const resource = resourceFromAttributes({
  [ATTR_SERVICE_NAME]: 'products-service',
  [ATTR_SERVICE_VERSION]: '2.0.0',
  'service.namespace': 'demo',
  'deployment.environment': 'demo',
});

// Initialize OpenTelemetry SDK with all exporters. The NodeSDK owns the
// logger provider and registers it globally on start(), so index.js can get
// its logger through @opentelemetry/api-logs and all three signals share the
// same resource and the same shutdown path.
// NOTE on exemplars: the JS SDK ships the exemplar classes but (unlike
// Java/Python) does NOT wire OTEL_METRICS_EXEMPLAR_FILTER yet, so this app's
// own histograms carry no exemplars. The metric -> trace "jump to the exact
// trace" experience in Grafana is powered by the span metrics that Tempo's
// metrics-generator writes to Prometheus with send_exemplars: true (see
// kind/values/tempo.yaml) - that path is verified end to end.
const sdk = new NodeSDK({
  resource,
  traceExporter,
  metricReaders: [
    new PeriodicExportingMetricReader({
      exporter: metricExporter,
      exportIntervalMillis: 10000, // Export metrics every 10 seconds
    }),
  ],
  // sdk-logs 0.2xx: processors take an options object ({ exporter }), not the
  // exporter positionally.
  logRecordProcessors: [new BatchLogRecordProcessor({ exporter: logExporter })],
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

// Graceful shutdown. sdk.shutdown() flushes traces, metrics AND logs (the
// NodeSDK owns the logger provider since the SDK 2.x migration).
process.on('SIGTERM', () => {
  sdk.shutdown()
    .then(() => console.log(JSON.stringify({ message: 'OpenTelemetry SDK terminated' })))
    .catch((error) => console.log(JSON.stringify({ message: 'Error terminating SDK', error: error.message })))
    .finally(() => process.exit(0));
});
