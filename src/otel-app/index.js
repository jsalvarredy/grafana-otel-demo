const express = require('express');
const { trace, metrics } = require('@opentelemetry/api');
const { logs } = require('@opentelemetry/api-logs');

const app = express();
const port = 8080;

// Get meter for custom metrics
const meter = metrics.getMeter('otel-demo-app');

// Get logger for sending logs to OTEL collector
const logger = logs.getLogger('otel-demo-app', '1.0.0');

// Create custom metrics
const requestCounter = meter.createCounter('http_requests_total', {
  description: 'Total number of HTTP requests',
});

const diceRollHistogram = meter.createHistogram('dice_roll_value', {
  description: 'Distribution of dice roll values',
});

// Helper function to emit logs with trace context
function emitLog(severity, message, attributes = {}) {
  const span = trace.getActiveSpan();
  const spanContext = span ? span.spanContext() : {};

  logger.emit({
    severityText: severity,
    body: JSON.stringify({ message, ...attributes }),
    attributes: {
      'trace_id': spanContext.traceId || '',
      'span_id': spanContext.spanId || '',
      ...attributes
    },
  });

  // Also log to console for local debugging
  console.log(JSON.stringify({
    severity,
    message,
    traceId: spanContext.traceId,
    spanId: spanContext.spanId,
    ...attributes
  }));
}

// Root endpoint
app.get('/', (req, res) => {
  const span = trace.getTracer('otel-demo-app').startSpan('handle-root-request');

  // Emit log with trace context
  emitLog('INFO', 'Received request on root endpoint', {
    path: '/',
    method: 'GET'
  });

  // Increment request counter
  requestCounter.add(1, { endpoint: '/', method: 'GET' });

  setTimeout(() => {
    span.end();
    res.send('Hello from OpenTelemetry Instrumented Node.js App! Try /rolldice or /work');
  }, 100);
});

// Dice roll endpoint - demonstrates traces and metrics
app.get('/rolldice', (req, res) => {
  const span = trace.getTracer('otel-demo-app').startSpan('roll-dice');
  const result = Math.floor(Math.random() * 6) + 1;

  // Add custom attributes to span
  span.setAttribute('dice.value', result);
  span.setAttribute('endpoint', '/rolldice');

  // Emit structured log
  emitLog('INFO', 'Dice rolled', {
    dice_value: result,
    endpoint: '/rolldice'
  });

  // Record metrics
  requestCounter.add(1, { endpoint: '/rolldice', method: 'GET' });
  diceRollHistogram.record(result, { endpoint: '/rolldice' });

  // Add event for special cases
  if (result === 6) {
    span.addEvent('Lucky roll!', { dice: result });
    emitLog('INFO', 'Lucky six!', {
      dice_value: result,
      special: true
    });
  }

  res.json({ result, message: `You rolled a ${result}!` });
  span.end();
});

// Simulated work endpoint - demonstrates nested spans
app.get('/work', (req, res) => {
  const parentSpan = trace.getTracer('otel-demo-app').startSpan('do-work');

  emitLog('INFO', 'Starting work simulation', {
    endpoint: '/work'
  });

  requestCounter.add(1, { endpoint: '/work', method: 'GET' });

  // Simulate database query
  const dbSpan = trace.getTracer('otel-demo-app').startSpan('database-query', {
    parent: parentSpan,
  });
  dbSpan.setAttribute('db.system', 'postgresql');
  dbSpan.setAttribute('db.operation', 'SELECT');

  setTimeout(() => {
    emitLog('INFO', 'Database query completed', {
      operation: 'SELECT',
      db: 'postgresql'
    });
    dbSpan.end();

    // Simulate API call
    const apiSpan = trace.getTracer('otel-demo-app').startSpan('external-api-call', {
      parent: parentSpan,
    });
    apiSpan.setAttribute('http.method', 'GET');
    apiSpan.setAttribute('http.url', 'https://api.example.com/data');

    setTimeout(() => {
      emitLog('INFO', 'External API call completed', {
        url: 'https://api.example.com/data',
        method: 'GET'
      });
      apiSpan.end();
      parentSpan.end();

      res.json({
        status: 'completed',
        message: 'Work simulation finished',
        operations: ['database-query', 'external-api-call']
      });
    }, 150);
  }, 200);
});

// Health check endpoint
app.get('/error', (req, res) => {
  const span = trace.getSpan(context.active());

  emitLog('ERROR', 'Simulated error on /error endpoint', {
    path: '/error',
    status: 500
  });

  // Set span status to error
  span.setStatus({ code: SpanStatusCode.ERROR, message: 'Simulated service error' });

  res.status(500).json({
    status: 'error',
    message: 'Simulated internal server error'
  });
});

app.get('/health', (req, res) => {
  requestCounter.add(1, { endpoint: '/health', method: 'GET' });
  emitLog('INFO', 'Health check', {
    status: 'healthy'
  });
  res.json({ status: 'healthy', timestamp: new Date().toISOString() });
});

app.listen(port, () => {
  emitLog('INFO', 'OTEL Demo App Started', {
    port: port,
    endpoints: ['/', '/rolldice', '/work', '/health']
  });
});
