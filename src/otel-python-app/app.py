import os
import json
import time
import random
from flask import Flask, jsonify

from opentelemetry import trace, metrics
from opentelemetry._logs import set_logger_provider
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter
from opentelemetry.exporter.otlp.proto.http._log_exporter import OTLPLogExporter
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
from opentelemetry.sdk.resources import Resource
from opentelemetry.semconv.resource import ResourceAttributes
from opentelemetry.instrumentation.flask import FlaskInstrumentor
import logging

# Get OTEL endpoint from environment variable or use default
otlp_endpoint = os.getenv('OTEL_EXPORTER_OTLP_ENDPOINT', 'http://localhost:4318')

# Create shared resource
resource = Resource.create({
    ResourceAttributes.SERVICE_NAME: 'otel-python-app',
    ResourceAttributes.SERVICE_VERSION: '1.0.0',
})

# Configure trace provider
trace_provider = TracerProvider(resource=resource)
trace_provider.add_span_processor(
    BatchSpanProcessor(
        OTLPSpanExporter(endpoint=f"{otlp_endpoint}/v1/traces")
    )
)
trace.set_tracer_provider(trace_provider)

# Configure metrics provider
metric_reader = PeriodicExportingMetricReader(
    OTLPMetricExporter(endpoint=f"{otlp_endpoint}/v1/metrics"),
    export_interval_millis=10000  # Export metrics every 10 seconds
)
meter_provider = MeterProvider(resource=resource, metric_readers=[metric_reader])
metrics.set_meter_provider(meter_provider)

# Configure logger provider
logger_provider = LoggerProvider(resource=resource)
logger_provider.add_log_record_processor(
    BatchLogRecordProcessor(
        OTLPLogExporter(endpoint=f"{otlp_endpoint}/v1/logs")
    )
)
set_logger_provider(logger_provider)

# Setup logging handler
handler = LoggingHandler(level=logging.INFO, logger_provider=logger_provider)
logging.getLogger().addHandler(handler)
logging.getLogger().setLevel(logging.INFO)

# Get tracer and meter
tracer = trace.get_tracer(__name__)
meter = metrics.get_meter(__name__)

# Create custom metrics
request_counter = meter.create_counter(
    'http.requests.total',
    description='Total number of HTTP requests',
)

dice_roll_histogram = meter.create_histogram(
    'dice.roll.value',
    description='Distribution of dice roll values',
)

# Create Flask app
app = Flask(__name__)

# Instrument Flask app with OpenTelemetry
FlaskInstrumentor().instrument_app(app)

# Helper function to emit structured logs with trace context
def emit_log(severity, message, **kwargs):
    span = trace.get_current_span()
    span_context = span.get_span_context()
    
    log_data = {
        'message': message,
        'trace_id': format(span_context.trace_id, '032x') if span_context.is_valid else '',
        'span_id': format(span_context.span_id, '016x') if span_context.is_valid else '',
        **kwargs
    }
    
    # Log to OTEL logger
    if severity == 'INFO':
        logging.info(json.dumps(log_data))
    elif severity == 'WARNING':
        logging.warning(json.dumps(log_data))
    elif severity == 'ERROR':
        logging.error(json.dumps(log_data))
    
    # Also print to console for local debugging
    print(json.dumps(log_data))

@app.route('/')
def root():
    with tracer.start_as_current_span('handle-root-request') as span:
        emit_log('INFO', 'Received request on root endpoint', path='/', method='GET')
        
        request_counter.add(1, {'endpoint': '/', 'method': 'GET'})
        
        time.sleep(0.1)  # Simulate work
        
        return 'Hello from OpenTelemetry Instrumented Python App! Try /rolldice or /work'

@app.route('/rolldice')
def rolldice():
    with tracer.start_as_current_span('roll-dice') as span:
        result = random.randint(1, 6)
        
        # Add custom attributes to span
        span.set_attribute('dice.value', result)
        span.set_attribute('endpoint', '/rolldice')
        
        # Emit structured log
        emit_log('INFO', 'Dice rolled', dice_value=result, endpoint='/rolldice')
        
        # Record metrics
        request_counter.add(1, {'endpoint': '/rolldice', 'method': 'GET'})
        dice_roll_histogram.record(result, {'endpoint': '/rolldice'})
        
        # Add event for special cases
        if result == 6:
            span.add_event('Lucky roll!', {'dice': result})
            emit_log('INFO', 'Lucky six!', dice_value=result, special=True)
        
        return jsonify({'result': result, 'message': f'You rolled a {result}!'})

@app.route('/work')
def work():
    with tracer.start_as_current_span('do-work') as parent_span:
        emit_log('INFO', 'Starting work simulation', endpoint='/work')
        
        request_counter.add(1, {'endpoint': '/work', 'method': 'GET'})
        
        # Simulate database query
        with tracer.start_as_current_span('database-query') as db_span:
            db_span.set_attribute('db.system', 'postgresql')
            db_span.set_attribute('db.operation', 'SELECT')
            
            time.sleep(0.2)  # Simulate DB work
            
            emit_log('INFO', 'Database query completed', operation='SELECT', db='postgresql')
        
        # Simulate API call
        with tracer.start_as_current_span('external-api-call') as api_span:
            api_span.set_attribute('http.method', 'GET')
            api_span.set_attribute('http.url', 'https://api.example.com/data')
            
            time.sleep(0.15)  # Simulate API work
            
            emit_log('INFO', 'External API call completed', url='https://api.example.com/data', method='GET')
        
        return jsonify({
            'status': 'completed',
            'message': 'Work simulation finished',
            'operations': ['database-query', 'external-api-call']
        })

@app.route('/error')
def error():
    with tracer.start_as_current_span('handle-error-request') as span:
        emit_log('ERROR', 'Simulated error on /error endpoint', path='/error', status=500)
        
        # Set OTEL status to error
        span.set_status(trace.Status(trace.StatusCode.ERROR, "Simulated service error"))
        
        return jsonify({
            'status': 'error',
            'message': 'Simulated internal server error'
        }), 500

@app.route('/health')
def health():
    request_counter.add(1, {'endpoint': '/health', 'method': 'GET'})
    emit_log('INFO', 'Health check', status='healthy')
    
    from datetime import datetime
    return jsonify({
        'status': 'healthy',
        'timestamp': datetime.utcnow().isoformat() + 'Z'
    })

if __name__ == '__main__':
    emit_log('INFO', 'OTEL Python Demo App Started', 
             port=8080, 
             endpoints=['/', '/rolldice', '/work', '/health'])
    app.run(host='0.0.0.0', port=8080)
