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
const { SemanticResourceAttributes } = require('@opentelemetry/semantic-conventions');

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

// Create shared resource
const resource = new Resource({
  [SemanticResourceAttributes.SERVICE_NAME]: 'otel-demo-app',
  [SemanticResourceAttributes.SERVICE_VERSION]: '1.0.0',
});

// Initialize Logger Provider for logs
const loggerProvider = new LoggerProvider({ resource });
loggerProvider.addLogRecordProcessor(new BatchLogRecordProcessor(logExporter));
logs.setGlobalLoggerProvider(loggerProvider);

// Initialize OpenTelemetry SDK with all exporters
const sdk = new NodeSDK({
  resource,
  traceExporter,
  metricReader: new PeriodicExportingMetricReader({
    exporter: metricExporter,
    exportIntervalMillis: 10000, // Export metrics every 10 seconds
  }),
  logRecordProcessor: new BatchLogRecordProcessor(logExporter),
  instrumentations: [getNodeAutoInstrumentations()],
});

sdk.start();

console.log(JSON.stringify({
  message: 'OpenTelemetry SDK initialized',
  service: 'otel-demo-app',
  endpoint: otlpEndpoint,
  exporters: ['traces', 'metrics', 'logs']
}));

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

