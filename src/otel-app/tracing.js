// OpenTelemetry SDK initialization
// This file configures traces, metrics, and logs exporters for Grafana Stack.
// Written against the OpenTelemetry JS SDK 2.x API (resourceFromAttributes,
// NodeSDK-managed logger provider).

const { NodeSDK } = require('@opentelemetry/sdk-node');
const { getNodeAutoInstrumentations } = require('@opentelemetry/auto-instrumentations-node');
const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-http');
const { OTLPMetricExporter } = require('@opentelemetry/exporter-metrics-otlp-http');
const { OTLPLogExporter } = require('@opentelemetry/exporter-logs-otlp-http');
const { PeriodicExportingMetricReader, AggregationType } = require('@opentelemetry/sdk-metrics');
const { BatchLogRecordProcessor } = require('@opentelemetry/sdk-logs');
const { resourceFromAttributes } = require('@opentelemetry/resources');
const {
  ATTR_SERVICE_NAME,
  ATTR_SERVICE_VERSION,
} = require('@opentelemetry/semantic-conventions');

// Emit only the stable HTTP semconv family (http.server.request.duration, s).
// Must be set before the HTTP instrumentation is created; the chart sets it too.
process.env.OTEL_SEMCONV_STABILITY_OPT_IN = process.env.OTEL_SEMCONV_STABILITY_OPT_IN || 'http';

const HTTP_DURATION_BUCKETS = [0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5, 0.75, 1, 2.5, 5, 7.5, 10];

// Get OTEL endpoint and release identity from environment variables.
const otlpEndpoint = process.env.OTEL_EXPORTER_OTLP_ENDPOINT || 'http://localhost:4318';
const serviceName = process.env.OTEL_SERVICE_NAME || 'products-service';
const serviceVersion = process.env.OTEL_SERVICE_VERSION || '2.0.0';
const serviceNamespace = process.env.OTEL_SERVICE_NAMESPACE || 'demo';
const deploymentEnvironment = process.env.OTEL_DEPLOYMENT_ENVIRONMENT || 'demo';

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

// Stable, bounded resource identity. Commit/deployment IDs deliberately stay
// out of application telemetry to avoid multiplying every metric time series.
const resource = resourceFromAttributes({
  [ATTR_SERVICE_NAME]: serviceName,
  [ATTR_SERVICE_VERSION]: serviceVersion,
  'service.namespace': serviceNamespace,
  'deployment.environment.name': deploymentEnvironment,
});

// Initialize OpenTelemetry SDK with all exporters. The NodeSDK owns the
// logger provider and registers it globally on start(), so index.js can get
// its logger through @opentelemetry/api-logs and all three signals share the
// same resource and the same shutdown path.
// NOTE on exemplars: @opentelemetry/sdk-metrics 2.12.0 ships the exemplar
// classes (Always/Never/WithTraceExemplarFilter, reservoirs) but does not export
// them from its index, has no MeterProvider/View option to select a filter or
// reservoir, and the aggregators never call them, so OTEL_METRICS_EXEMPLAR_FILTER
// is a no-op and Node histograms carry no exemplars. Until upstream wires this,
// the metric -> trace jump for Products relies on the span metrics that Tempo's
// metrics-generator writes to Prometheus with send_exemplars: true (see
// kind/values/tempo.yaml).
const sdk = new NodeSDK({
  resource,
  traceExporter,
  // Stable HTTP semconv bucket boundaries (contract C1: must include 0.25 and 1
  // for Apdex). Applied via a View in case the instrumentation advisory is not
  // honoured by the installed SDK.
  views: [
    {
      instrumentName: 'http.server.request.duration',
      aggregation: {
        type: AggregationType.EXPLICIT_BUCKET_HISTOGRAM,
        options: { boundaries: HTTP_DURATION_BUCKETS },
      },
    },
  ],
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
