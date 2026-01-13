import os
import json
import time
import random
import uuid
from datetime import datetime
from flask import Flask, jsonify, request
import requests

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
from opentelemetry.instrumentation.requests import RequestsInstrumentor
from opentelemetry.trace.status import Status, StatusCode
import logging

# Get OTEL endpoint from environment variable or use default
otlp_endpoint = os.getenv('OTEL_EXPORTER_OTLP_ENDPOINT', 'http://localhost:4318')

# Products Service URL (internal service communication)
products_service_url = os.getenv('PRODUCTS_SERVICE_URL', 'http://otel-demo-app:8080')

# Create shared resource
resource = Resource.create({
    ResourceAttributes.SERVICE_NAME: 'orders-service',
    ResourceAttributes.SERVICE_VERSION: '1.0.0',
    ResourceAttributes.SERVICE_NAMESPACE: 'demo',
    ResourceAttributes.DEPLOYMENT_ENVIRONMENT: 'demo',
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

# ===================================================================
# RED METRICS (Rate, Error, Duration) - Infrastructure Observability
# ===================================================================

# HTTP Request Counter - tracks all incoming requests (renamed for Prometheus compatibility)
request_counter = meter.create_counter(
    'http_requests_total',
    description='Total number of HTTP requests by endpoint, method, and status code',
)

# HTTP Server Duration - tracks request latency for SLA/SLO monitoring
http_server_duration = meter.create_histogram(
    'http_server_duration',
    description='HTTP server request duration in milliseconds',
    unit='ms',
)

# Order-specific metrics
order_counter = meter.create_counter(
    'orders_created_total',
    description='Total number of orders created',
)

order_value_histogram = meter.create_histogram(
    'orders_value',
    description='Distribution of order values',
)

# ===================================================================
# BUSINESS METRICS - For Executive Dashboard
# ===================================================================

# Order Revenue - tracks actual revenue from orders in dollars
order_revenue_histogram = meter.create_histogram(
    'order_revenue_dollars',
    description='Distribution of order revenue in dollars',
    unit='USD',
)

# Failed Transaction Revenue Lost - tracks revenue lost from failed transactions
failed_transaction_revenue_counter = meter.create_counter(
    'failed_transaction_revenue_lost',
    description='Revenue lost due to failed transactions in dollars',
    unit='USD',
)

# Order Processing Time - tracks how long orders take to process (SLA metric)
order_processing_time_histogram = meter.create_histogram(
    'order_processing_time_seconds',
    description='Time taken to process orders in seconds',
    unit='seconds',
)

# SLA Violation Events - tracks when order processing exceeds SLA threshold
sla_violation_counter = meter.create_counter(
    'sla_violation_events',
    description='Count of SLA violations (order processing > 2 seconds)',
)

# Create Flask app
app = Flask(__name__)

# Instrument Flask app with OpenTelemetry
FlaskInstrumentor().instrument_app(app)

# Instrument requests library for distributed tracing across services
RequestsInstrumentor().instrument()

# In-memory orders storage
orders = {}
order_id_counter = 1

# Helper function to emit structured logs with trace context
def emit_log(severity, message, **kwargs):
    span = trace.get_current_span()
    span_context = span.get_span_context()
    
    log_data = {
        'message': message,
        'trace_id': format(span_context.trace_id, '032x') if span_context.is_valid else '',
        'span_id': format(span_context.span_id, '016x') if span_context.is_valid else '',
        'service': 'orders-service',
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

# Simulate async processing latency
def simulate_processing():
    time.sleep(0.05 + random.random() * 0.1)

# ===================================================================
# APM MIDDLEWARE - Automatic instrumentation for all endpoints
# ===================================================================
# Captures latency, status codes, and request metadata automatically
# This middleware provides RED metrics (Rate, Errors, Duration) for all HTTP endpoints

@app.before_request
def before_request():
    """Store request start time for latency calculation"""
    from flask import g
    g.start_time = time.time()

@app.after_request
def after_request(response):
    """Capture metrics after request completes"""
    from flask import g, request as flask_request

    # Calculate request duration
    if hasattr(g, 'start_time'):
        duration_ms = (time.time() - g.start_time) * 1000  # Convert to milliseconds

        # Get endpoint path (use rule if available, otherwise path)
        endpoint = flask_request.url_rule.rule if flask_request.url_rule else flask_request.path
        method = flask_request.method
        status_code = response.status_code

        # Record HTTP request counter with status code
        request_counter.add(1, {
            'endpoint': endpoint,
            'method': method,
            'http_status_code': str(status_code),
            
        })

        # Record HTTP server duration (latency) for SLO monitoring
        http_server_duration.record(duration_ms, {
            'endpoint': endpoint,
            'method': method,
            'http_status_code': str(status_code),
            
        })

    return response

@app.route('/')
def root():
    with tracer.start_as_current_span('handle-root-request') as span:
        emit_log('INFO', 'Received request on root endpoint', path='/', method='GET')

        time.sleep(0.05)
        
        return jsonify({
            'service': 'Orders Service',
            'version': '1.0.0',
            'endpoints': [
                'POST /api/orders',
                'GET /api/orders/:id',
                'GET /api/orders/user/:userId',
                'POST /api/orders/:id/cancel',
                'GET /health'
            ]
        })

@app.route('/api/orders', methods=['POST'])
def create_order():
    global order_id_counter

    # Track start time for processing time and SLA metrics
    start_time = time.time()

    with tracer.start_as_current_span('create-order') as span:
        try:
            order_data = request.get_json()
            product_id = order_data.get('product_id')
            quantity = order_data.get('quantity', 1)
            user_id = order_data.get('user_id', 'user-' + str(random.randint(1, 100)))

            span.set_attribute('order.product_id', product_id)
            span.set_attribute('order.quantity', quantity)
            span.set_attribute('order.user_id', user_id)
            
            emit_log('INFO', 'Processing order creation',
                    endpoint='/api/orders',
                    product_id=product_id,
                    quantity=quantity,
                    user_id=user_id)

            # Call Products Service to get product details
            with tracer.start_as_current_span('fetch-product-details') as product_span:
                product_span.set_attribute('http.method', 'GET')
                product_span.set_attribute('http.url', f'{products_service_url}/api/products/{product_id}')
                product_span.set_attribute('peer.service', 'products-service')
                
                emit_log('INFO', 'Calling Products Service for product details', 
                        product_id=product_id)
                
                try:
                    product_response = requests.get(
                        f'{products_service_url}/api/products/{product_id}',
                        timeout=5
                    )
                    
                    if product_response.status_code == 404:
                        product_span.set_status(Status(StatusCode.ERROR, 'Product not found'))
                        emit_log('WARNING', 'Product not found', product_id=product_id)

                        # Track processing time and check for SLA violation
                        processing_time = time.time() - start_time
                        order_processing_time_histogram.record(processing_time, {
                            
                            'status': 'failed',
                            'reason': 'product_not_found'
                        })

                        # SLA threshold: 2 seconds
                        if processing_time > 2.0:
                            sla_violation_counter.add(1, {
                                
                                'reason': 'product_not_found'
                            })

                        return jsonify({'error': 'Product not found'}), 404
                    
                    product_response.raise_for_status()
                    product_data = product_response.json()['product']
                    
                    emit_log('INFO', 'Product details retrieved', 
                            product_id=product_id,
                            product_name=product_data['name'],
                            price=product_data['price'])
                    
                except requests.RequestException as e:
                    product_span.set_status(Status(StatusCode.ERROR, str(e)))
                    emit_log('ERROR', 'Failed to fetch product details',
                            error=str(e),
                            product_id=product_id)

                    # Track processing time and check for SLA violation
                    processing_time = time.time() - start_time
                    order_processing_time_histogram.record(processing_time, {
                        
                        'status': 'failed',
                        'reason': 'service_communication_error'
                    })

                    if processing_time > 2.0:
                        sla_violation_counter.add(1, {
                            
                            'reason': 'service_communication_error'
                        })

                    return jsonify({'error': 'Failed to communicate with Products Service'}), 503
            
            # Validate inventory
            with tracer.start_as_current_span('validate-inventory') as inventory_span:
                inventory_span.set_attribute('http.method', 'GET')
                inventory_span.set_attribute('http.url', f'{products_service_url}/api/inventory/{product_id}')
                
                emit_log('INFO', 'Checking product inventory', product_id=product_id)
                
                try:
                    inventory_response = requests.get(
                        f'{products_service_url}/api/inventory/{product_id}',
                        timeout=5
                    )
                    inventory_response.raise_for_status()
                    inventory_data = inventory_response.json()
                    
                    if inventory_data['stock'] < quantity:
                        inventory_span.set_attribute('inventory.sufficient', False)

                        # Calculate lost revenue
                        lost_revenue = product_data['price'] * quantity
                        failed_transaction_revenue_counter.add(lost_revenue, {
                            
                            'reason': 'insufficient_stock',
                            'product_id': str(product_id)
                        })

                        emit_log('WARNING', 'Insufficient inventory for order',
                                product_id=product_id,
                                requested=quantity,
                                available=inventory_data['stock'],
                                lost_revenue=lost_revenue)

                        # Track processing time
                        processing_time = time.time() - start_time
                        order_processing_time_histogram.record(processing_time, {
                            
                            'status': 'failed',
                            'reason': 'insufficient_stock'
                        })

                        if processing_time > 2.0:
                            sla_violation_counter.add(1, {
                                
                                'reason': 'insufficient_stock'
                            })

                        return jsonify({
                            'error': 'Insufficient stock',
                            'requested': quantity,
                            'available': inventory_data['stock']
                        }), 400
                    
                    inventory_span.set_attribute('inventory.sufficient', True)
                    
                except requests.RequestException as e:
                    inventory_span.set_status(Status(StatusCode.ERROR, str(e)))
                    emit_log('ERROR', 'Failed to check inventory', error=str(e))

                    # Track processing time
                    processing_time = time.time() - start_time
                    order_processing_time_histogram.record(processing_time, {
                        
                        'status': 'failed',
                        'reason': 'inventory_check_failed'
                    })

                    if processing_time > 2.0:
                        sla_violation_counter.add(1, {
                            
                            'reason': 'inventory_check_failed'
                        })

                    return jsonify({'error': 'Inventory check failed'}), 503
            
            # Simulate order processing (payment, validation, etc.)
            with tracer.start_as_current_span('process-order-payment') as payment_span:
                total_amount = product_data['price'] * quantity
                payment_span.set_attribute('payment.amount', total_amount)
                
                emit_log('INFO', 'Processing payment', 
                        amount=total_amount,
                        product_id=product_id)
                
                simulate_processing()
                
                # Simulate occasional payment failures (3% chance)
                if random.random() < 0.03:
                    payment_span.set_status(Status(StatusCode.ERROR, 'Payment processing failed'))

                    # Track lost revenue from payment failure
                    failed_transaction_revenue_counter.add(total_amount, {
                        
                        'reason': 'payment_declined',
                        'product_id': str(product_id)
                    })

                    emit_log('ERROR', 'Payment processing failed',
                            amount=total_amount,
                            lost_revenue=total_amount)

                    # Track processing time
                    processing_time = time.time() - start_time
                    order_processing_time_histogram.record(processing_time, {
                        
                        'status': 'failed',
                        'reason': 'payment_declined'
                    })

                    if processing_time > 2.0:
                        sla_violation_counter.add(1, {
                            
                            'reason': 'payment_declined'
                        })

                    return jsonify({'error': 'Payment processing failed'}), 402
            
            # Call Products Service to complete purchase
            with tracer.start_as_current_span('complete-purchase') as purchase_span:
                purchase_span.set_attribute('http.method', 'POST')
                purchase_span.set_attribute('http.url', f'{products_service_url}/api/products/{product_id}/purchase')
                
                emit_log('INFO', 'Completing purchase in Products Service', 
                        product_id=product_id,
                        quantity=quantity)
                
                try:
                    purchase_response = requests.post(
                        f'{products_service_url}/api/products/{product_id}/purchase',
                        json={'quantity': quantity},
                        headers={'Content-Type': 'application/json'},
                        timeout=5
                    )
                    
                    if purchase_response.status_code != 200:
                        purchase_span.set_status(Status(StatusCode.ERROR, 'Purchase failed'))

                        # Track lost revenue from purchase failure
                        total_amount = product_data['price'] * quantity
                        failed_transaction_revenue_counter.add(total_amount, {
                            
                            'reason': 'purchase_failed',
                            'product_id': str(product_id)
                        })

                        emit_log('ERROR', 'Purchase failed in Products Service',
                                status_code=purchase_response.status_code,
                                response=purchase_response.text,
                                lost_revenue=total_amount)

                        # Track processing time
                        processing_time = time.time() - start_time
                        order_processing_time_histogram.record(processing_time, {
                            
                            'status': 'failed',
                            'reason': 'purchase_failed'
                        })

                        if processing_time > 2.0:
                            sla_violation_counter.add(1, {
                                
                                'reason': 'purchase_failed'
                            })

                        return jsonify({'error': 'Failed to complete purchase'}), 400
                    
                    purchase_result = purchase_response.json()
                    
                except requests.RequestException as e:
                    purchase_span.set_status(Status(StatusCode.ERROR, str(e)))
                    emit_log('ERROR', 'Failed to complete purchase', error=str(e))

                    # Track processing time
                    processing_time = time.time() - start_time
                    order_processing_time_histogram.record(processing_time, {
                        
                        'status': 'failed',
                        'reason': 'purchase_completion_failed'
                    })

                    if processing_time > 2.0:
                        sla_violation_counter.add(1, {
                            
                            'reason': 'purchase_completion_failed'
                        })

                    return jsonify({'error': 'Purchase completion failed'}), 503
            
            # Create order record
            order_id = f'ORD-{order_id_counter:05d}'
            order_id_counter += 1
            
            order_record = {
                'order_id': order_id,
                'user_id': user_id,
                'product_id': product_id,
                'product_name': product_data['name'],
                'quantity': quantity,
                'price_per_unit': product_data['price'],
                'total_amount': product_data['price'] * quantity,
                'status': 'confirmed',
                'created_at': datetime.utcnow().isoformat() + 'Z',
                'updated_at': datetime.utcnow().isoformat() + 'Z'
            }
            
            orders[order_id] = order_record
            
            # Record metrics
            order_counter.add(1, {
                'product_id': str(product_id),
                'user_id': user_id,
                
            })
            order_value_histogram.record(order_record['total_amount'], {
                'product_id': str(product_id),
                
            })

            # Track successful order revenue
            order_revenue_histogram.record(order_record['total_amount'], {
                
                'product_id': str(product_id),
                'user_id': user_id
            })

            # Track processing time and check for SLA compliance
            processing_time = time.time() - start_time
            order_processing_time_histogram.record(processing_time, {
                
                'status': 'success'
            })

            # SLA threshold: 2 seconds
            if processing_time > 2.0:
                sla_violation_counter.add(1, {
                    
                    'reason': 'slow_processing'
                })

            emit_log('INFO', 'Order created successfully',
                    order_id=order_id,
                    product_id=product_id,
                    total_amount=order_record['total_amount'],
                    user_id=user_id,
                    processing_time_seconds=processing_time)

            span.set_attribute('order.id', order_id)
            span.set_attribute('order.total', order_record['total_amount'])
            span.set_attribute('order.status', 'confirmed')
            span.set_attribute('order.processing_time', processing_time)

            return jsonify({'order': order_record}), 201
            
        except Exception as e:
            span.set_status(Status(StatusCode.ERROR, str(e)))
            emit_log('ERROR', 'Error creating order', error=str(e))

            # Track processing time
            processing_time = time.time() - start_time
            order_processing_time_histogram.record(processing_time, {
                
                'status': 'failed',
                'reason': 'internal_error'
            })

            if processing_time > 2.0:
                sla_violation_counter.add(1, {
                    
                    'reason': 'internal_error'
                })

            return jsonify({'error': 'Internal server error'}), 500

@app.route('/api/orders/<order_id>', methods=['GET'])
def get_order(order_id):
    with tracer.start_as_current_span('get-order') as span:
        span.set_attribute('order.id', order_id)
        
        emit_log('INFO', 'Fetching order details',
                endpoint='/api/orders/:id',
                order_id=order_id)

        simulate_processing()
        
        order = orders.get(order_id)
        
        if not order:
            span.set_status(Status(StatusCode.ERROR, 'Order not found'))
            emit_log('WARNING', 'Order not found', order_id=order_id)
            return jsonify({'error': 'Order not found'}), 404
        
        emit_log('INFO', 'Order details retrieved', 
                order_id=order_id,
                status=order['status'])
        
        return jsonify({'order': order})

@app.route('/api/orders/user/<user_id>', methods=['GET'])
def get_user_orders(user_id):
    with tracer.start_as_current_span('get-user-orders') as span:
        span.set_attribute('user.id', user_id)
        
        emit_log('INFO', 'Fetching user orders',
                endpoint='/api/orders/user/:userId',
                user_id=user_id)

        simulate_processing()
        
        user_orders = [order for order in orders.values() if order['user_id'] == user_id]
        
        emit_log('INFO', 'User orders retrieved', 
                user_id=user_id,
                count=len(user_orders))
        
        span.set_attribute('orders.count', len(user_orders))
        
        return jsonify({
            'user_id': user_id,
            'orders': user_orders,
            'total': len(user_orders)
        })

@app.route('/api/orders/<order_id>/cancel', methods=['POST'])
def cancel_order(order_id):
    with tracer.start_as_current_span('cancel-order') as span:
        span.set_attribute('order.id', order_id)
        
        emit_log('INFO', 'Processing order cancellation',
                endpoint='/api/orders/:id/cancel',
                order_id=order_id)

        order = orders.get(order_id)
        
        if not order:
            span.set_status(Status(StatusCode.ERROR, 'Order not found'))
            emit_log('WARNING', 'Cannot cancel - order not found', order_id=order_id)
            return jsonify({'error': 'Order not found'}), 404
        
        if order['status'] == 'cancelled':
            emit_log('WARNING', 'Order already cancelled', order_id=order_id)
            return jsonify({'error': 'Order already cancelled'}), 400
        
        # Simulate cancellation processing
        with tracer.start_as_current_span('process-cancellation'):
            simulate_processing()
            
            # Simulate occasional cancellation failures (2% chance)
            if random.random() < 0.02:
                span.set_status(Status(StatusCode.ERROR, 'Cancellation failed'))
                emit_log('ERROR', 'Order cancellation failed', order_id=order_id)
                return jsonify({'error': 'Cancellation processing failed'}), 500
        
        order['status'] = 'cancelled'
        order['updated_at'] = datetime.utcnow().isoformat() + 'Z'
        
        emit_log('INFO', 'Order cancelled successfully', 
                order_id=order_id)
        
        span.set_attribute('order.status', 'cancelled')
        
        return jsonify({
            'success': True,
            'order_id': order_id,
            'status': 'cancelled'
        })

@app.route('/health')
def health():
    emit_log('INFO', 'Health check', status='healthy')
    
    return jsonify({
        'status': 'healthy',
        'service': 'orders-service',
        'timestamp': datetime.utcnow().isoformat() + 'Z'
    })

@app.route('/error')
def error():
    with tracer.start_as_current_span('handle-error-request') as span:
        emit_log('ERROR', 'Simulated error endpoint', path='/error', status=500)
        
        span.set_status(Status(StatusCode.ERROR, "Simulated service error"))
        
        return jsonify({
            'status': 'error',
            'message': 'Simulated internal server error'
        }), 500

if __name__ == '__main__':
    emit_log('INFO', 'Orders Service Started', 
             port=8080,
             products_service=products_service_url,
             endpoints=[
                 'POST /api/orders',
                 'GET /api/orders/:id',
                 'GET /api/orders/user/:userId',
                 'POST /api/orders/:id/cancel',
                 'GET /health',
                 'GET /error'
             ])
    print(f'🛒 Orders Service running on port 8080')
    print(f'📦 Products Service: {products_service_url}')
    app.run(host='0.0.0.0', port=8080)
