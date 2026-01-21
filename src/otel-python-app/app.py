import os
import json
import time
import random
import uuid
from datetime import datetime, timedelta
from flask import Flask, jsonify, request, g
import requests
from functools import wraps

from opentelemetry import trace, metrics
from opentelemetry.metrics import Observation
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
    ResourceAttributes.SERVICE_VERSION: '2.0.0',
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

# HTTP Request Counter - tracks all incoming requests
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

# ===================================================================
# ADVANCED METRICS - User Sessions, Dependencies, Retries
# ===================================================================

# Observable gauge callback (must be defined before gauge creation)
def get_active_sessions_count():
    # Clean expired sessions
    current_time = datetime.utcnow()
    expired = []
    for session_id, data in active_sessions.items():
        if current_time - data['last_activity'] > timedelta(minutes=SESSION_TIMEOUT_MINUTES):
            expired.append(session_id)
    for session_id in expired:
        del active_sessions[session_id]
    return len(active_sessions)

def observe_active_sessions(options):
    yield Observation(get_active_sessions_count(), {'service': 'orders-service'})

# Active sessions metric
active_sessions_gauge = meter.create_observable_gauge(
    'active_user_sessions',
    callbacks=[observe_active_sessions],
    description='Current number of active user sessions',
)

# Dependency health metrics
dependency_request_counter = meter.create_counter(
    'dependency_requests_total',
    description='Total requests to external dependencies',
)

dependency_error_counter = meter.create_counter(
    'dependency_errors_total',
    description='Total errors from external dependencies',
)

dependency_latency_histogram = meter.create_histogram(
    'dependency_latency_ms',
    description='Latency of external dependency calls in milliseconds',
    unit='ms',
)

# Retry metrics
retry_counter = meter.create_counter(
    'retries_total',
    description='Total number of retries performed',
)

# Order status metrics
order_status_counter = meter.create_counter(
    'order_status_changes_total',
    description='Total order status changes',
)

# User behavior metrics
user_orders_histogram = meter.create_histogram(
    'user_order_count',
    description='Distribution of orders per user',
)

returning_customer_counter = meter.create_counter(
    'returning_customers_total',
    description='Number of returning customer orders',
)

new_customer_counter = meter.create_counter(
    'new_customers_total',
    description='Number of new customer orders',
)

# Cancellation metrics
cancellation_counter = meter.create_counter(
    'order_cancellations_total',
    description='Total order cancellations',
)

cancellation_value_histogram = meter.create_histogram(
    'cancellation_value_dollars',
    description='Value of cancelled orders in dollars',
    unit='USD',
)

# Create Flask app
app = Flask(__name__)

# Instrument Flask app with OpenTelemetry
FlaskInstrumentor().instrument_app(app)

# Instrument requests library for distributed tracing across services
RequestsInstrumentor().instrument()

# ===================================================================
# In-memory Data Storage
# ===================================================================

# In-memory orders storage
orders = {}
order_id_counter = 1

# User order history tracking
user_order_history = {}

# Active sessions tracking
active_sessions = {}
SESSION_TIMEOUT_MINUTES = 30

# Known users (for returning vs new customer detection)
known_users = set()

# Circuit breaker for products service
class CircuitBreaker:
    def __init__(self, failure_threshold=5, reset_timeout=30):
        self.failure_threshold = failure_threshold
        self.reset_timeout = reset_timeout
        self.failures = 0
        self.state = 'closed'  # closed, open, half-open
        self.last_failure_time = None

    def can_execute(self):
        if self.state == 'closed':
            return True
        if self.state == 'open':
            if time.time() - self.last_failure_time > self.reset_timeout:
                self.state = 'half-open'
                return True
            return False
        return True  # half-open

    def record_success(self):
        self.failures = 0
        self.state = 'closed'

    def record_failure(self):
        self.failures += 1
        self.last_failure_time = time.time()
        if self.failures >= self.failure_threshold:
            self.state = 'open'

products_circuit_breaker = CircuitBreaker()

# ===================================================================
# Helper Functions
# ===================================================================

def emit_log(severity, message, **kwargs):
    """Helper function to emit structured logs with trace context"""
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

def simulate_processing():
    """Simulate async processing latency with load-based variation"""
    base_latency = 0.05

    # Add variation based on current load
    load_factor = 1 + (len(active_sessions) / 20)
    latency = base_latency * load_factor + random.random() * 0.1

    # Occasional slow processing (5% chance)
    if random.random() < 0.05:
        latency *= 3

    time.sleep(latency)

def update_session(user_id):
    """Update or create user session"""
    session_id = f"session-{user_id}"
    current_time = datetime.utcnow()

    if session_id in active_sessions:
        active_sessions[session_id]['last_activity'] = current_time
        active_sessions[session_id]['request_count'] += 1
    else:
        active_sessions[session_id] = {
            'user_id': user_id,
            'started_at': current_time,
            'last_activity': current_time,
            'request_count': 1
        }

def call_products_service(method, path, json_data=None, timeout=5):
    """Call Products Service with circuit breaker and metrics"""
    if not products_circuit_breaker.can_execute():
        emit_log('WARNING', 'Circuit breaker open for products service')
        raise Exception('Products service circuit breaker is open')

    start_time = time.time()
    url = f'{products_service_url}{path}'

    dependency_request_counter.add(1, {
        'dependency': 'products-service',
        'method': method
    })

    try:
        if method == 'GET':
            response = requests.get(url, timeout=timeout)
        elif method == 'POST':
            response = requests.post(url, json=json_data, timeout=timeout)
        else:
            raise ValueError(f'Unsupported method: {method}')

        latency = (time.time() - start_time) * 1000
        dependency_latency_histogram.record(latency, {
            'dependency': 'products-service',
            'method': method
        })

        products_circuit_breaker.record_success()
        return response

    except Exception as e:
        products_circuit_breaker.record_failure()
        dependency_error_counter.add(1, {
            'dependency': 'products-service',
            'error_type': type(e).__name__
        })
        raise

def call_with_retry(func, max_retries=3, backoff_factor=1.5):
    """Execute function with retry logic"""
    last_exception = None
    for attempt in range(max_retries):
        try:
            return func()
        except Exception as e:
            last_exception = e
            if attempt < max_retries - 1:
                retry_counter.add(1, {'service': 'products-service', 'attempt': str(attempt + 1)})
                wait_time = backoff_factor ** attempt
                emit_log('WARNING', f'Retry attempt {attempt + 1} after {wait_time}s', error=str(e))
                time.sleep(wait_time)
    raise last_exception

# ===================================================================
# APM MIDDLEWARE - Automatic instrumentation for all endpoints
# ===================================================================

@app.before_request
def before_request():
    """Store request start time and update session"""
    g.start_time = time.time()

    # Update session if user_id in request
    if request.is_json and request.json:
        user_id = request.json.get('user_id')
        if user_id:
            update_session(user_id)

@app.after_request
def after_request(response):
    """Capture metrics after request completes"""
    if hasattr(g, 'start_time'):
        duration_ms = (time.time() - g.start_time) * 1000

        # Get endpoint path
        endpoint = request.url_rule.rule if request.url_rule else request.path
        method = request.method
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

# ===================================================================
# API ENDPOINTS
# ===================================================================

@app.route('/')
def root():
    with tracer.start_as_current_span('handle-root-request') as span:
        emit_log('INFO', 'Received request on root endpoint', path='/', method='GET')

        time.sleep(0.05)

        return jsonify({
            'service': 'Orders Service',
            'version': '2.0.0',
            'description': 'Order management API with advanced observability',
            'endpoints': [
                'POST /api/orders - Create new order',
                'GET /api/orders/:id - Get order details',
                'GET /api/orders/user/:userId - Get user order history',
                'POST /api/orders/:id/cancel - Cancel order',
                'GET /api/orders/:id/track - Track order status',
                'GET /api/stats - Service statistics',
                'GET /health - Health check'
            ],
            'total_orders': len(orders),
            'active_sessions': get_active_sessions_count()
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

            # Add span event for order creation start
            span.add_event('order_creation_started', {
                'product_id': product_id,
                'quantity': quantity,
                'user_id': user_id
            })

            span.set_attribute('order.product_id', product_id)
            span.set_attribute('order.quantity', quantity)
            span.set_attribute('order.user_id', user_id)

            # Track returning vs new customer
            if user_id in known_users:
                returning_customer_counter.add(1, {'service': 'orders-service'})
                span.set_attribute('customer.type', 'returning')
            else:
                new_customer_counter.add(1, {'service': 'orders-service'})
                known_users.add(user_id)
                span.set_attribute('customer.type', 'new')

            emit_log('INFO', 'Processing order creation',
                    endpoint='/api/orders',
                    product_id=product_id,
                    quantity=quantity,
                    user_id=user_id)

            # Call Products Service to get product details with retry
            with tracer.start_as_current_span('fetch-product-details') as product_span:
                product_span.set_attribute('http.method', 'GET')
                product_span.set_attribute('http.url', f'{products_service_url}/api/products/{product_id}')
                product_span.set_attribute('peer.service', 'products-service')

                emit_log('INFO', 'Calling Products Service for product details',
                        product_id=product_id)

                try:
                    def fetch_product():
                        return call_products_service('GET', f'/api/products/{product_id}')

                    product_response = call_with_retry(fetch_product)

                    if product_response.status_code == 404:
                        product_span.set_status(Status(StatusCode.ERROR, 'Product not found'))
                        product_span.add_event('product_not_found', {'product_id': product_id})
                        emit_log('WARNING', 'Product not found', product_id=product_id)

                        # Track processing time and check for SLA violation
                        processing_time = time.time() - start_time
                        order_processing_time_histogram.record(processing_time, {
                            'status': 'failed',
                            'reason': 'product_not_found'
                        })

                        if processing_time > 2.0:
                            sla_violation_counter.add(1, {'reason': 'product_not_found'})

                        return jsonify({'error': 'Product not found'}), 404

                    product_response.raise_for_status()
                    product_data = product_response.json()['product']

                    product_span.add_event('product_details_retrieved', {
                        'product_name': product_data['name'],
                        'price': product_data['price']
                    })

                    emit_log('INFO', 'Product details retrieved',
                            product_id=product_id,
                            product_name=product_data['name'],
                            price=product_data['price'])

                except requests.RequestException as e:
                    product_span.set_status(Status(StatusCode.ERROR, str(e)))
                    product_span.add_event('service_communication_error', {'error': str(e)})
                    emit_log('ERROR', 'Failed to fetch product details',
                            error=str(e),
                            product_id=product_id)

                    processing_time = time.time() - start_time
                    order_processing_time_histogram.record(processing_time, {
                        'status': 'failed',
                        'reason': 'service_communication_error'
                    })

                    if processing_time > 2.0:
                        sla_violation_counter.add(1, {'reason': 'service_communication_error'})

                    return jsonify({'error': 'Failed to communicate with Products Service'}), 503

            # Validate inventory
            with tracer.start_as_current_span('validate-inventory') as inventory_span:
                inventory_span.set_attribute('http.method', 'GET')
                inventory_span.set_attribute('http.url', f'{products_service_url}/api/inventory/{product_id}')

                emit_log('INFO', 'Checking product inventory', product_id=product_id)

                try:
                    def check_inventory():
                        return call_products_service('GET', f'/api/inventory/{product_id}')

                    inventory_response = call_with_retry(check_inventory)
                    inventory_response.raise_for_status()
                    inventory_data = inventory_response.json()

                    if inventory_data['stock'] < quantity:
                        inventory_span.set_attribute('inventory.sufficient', False)
                        inventory_span.add_event('insufficient_inventory', {
                            'requested': quantity,
                            'available': inventory_data['stock']
                        })

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

                        processing_time = time.time() - start_time
                        order_processing_time_histogram.record(processing_time, {
                            'status': 'failed',
                            'reason': 'insufficient_stock'
                        })

                        if processing_time > 2.0:
                            sla_violation_counter.add(1, {'reason': 'insufficient_stock'})

                        return jsonify({
                            'error': 'Insufficient stock',
                            'requested': quantity,
                            'available': inventory_data['stock']
                        }), 400

                    inventory_span.set_attribute('inventory.sufficient', True)
                    inventory_span.set_attribute('inventory.stock_status', inventory_data.get('status', 'unknown'))

                except requests.RequestException as e:
                    inventory_span.set_status(Status(StatusCode.ERROR, str(e)))
                    emit_log('ERROR', 'Failed to check inventory', error=str(e))

                    processing_time = time.time() - start_time
                    order_processing_time_histogram.record(processing_time, {
                        'status': 'failed',
                        'reason': 'inventory_check_failed'
                    })

                    if processing_time > 2.0:
                        sla_violation_counter.add(1, {'reason': 'inventory_check_failed'})

                    return jsonify({'error': 'Inventory check failed'}), 503

            # Simulate order processing (payment, validation, etc.)
            with tracer.start_as_current_span('process-order-payment') as payment_span:
                total_amount = product_data['price'] * quantity
                payment_span.set_attribute('payment.amount', total_amount)
                payment_span.set_attribute('payment.currency', 'USD')

                payment_span.add_event('payment_processing_started')

                emit_log('INFO', 'Processing payment',
                        amount=total_amount,
                        product_id=product_id)

                simulate_processing()

                # Simulate occasional payment failures (3% chance)
                if random.random() < 0.03:
                    payment_span.set_status(Status(StatusCode.ERROR, 'Payment processing failed'))
                    payment_span.add_event('payment_declined', {'reason': 'card_declined'})

                    failed_transaction_revenue_counter.add(total_amount, {
                        'reason': 'payment_declined',
                        'product_id': str(product_id)
                    })

                    emit_log('ERROR', 'Payment processing failed',
                            amount=total_amount,
                            lost_revenue=total_amount)

                    processing_time = time.time() - start_time
                    order_processing_time_histogram.record(processing_time, {
                        'status': 'failed',
                        'reason': 'payment_declined'
                    })

                    if processing_time > 2.0:
                        sla_violation_counter.add(1, {'reason': 'payment_declined'})

                    return jsonify({'error': 'Payment processing failed'}), 402

                payment_span.add_event('payment_successful')

            # Call Products Service to complete purchase
            with tracer.start_as_current_span('complete-purchase') as purchase_span:
                purchase_span.set_attribute('http.method', 'POST')
                purchase_span.set_attribute('http.url', f'{products_service_url}/api/products/{product_id}/purchase')

                emit_log('INFO', 'Completing purchase in Products Service',
                        product_id=product_id,
                        quantity=quantity)

                try:
                    def complete_purchase():
                        return call_products_service('POST', f'/api/products/{product_id}/purchase',
                                                   {'quantity': quantity})

                    purchase_response = call_with_retry(complete_purchase)

                    if purchase_response.status_code != 200:
                        purchase_span.set_status(Status(StatusCode.ERROR, 'Purchase failed'))
                        purchase_span.add_event('purchase_failed', {
                            'status_code': purchase_response.status_code
                        })

                        total_amount = product_data['price'] * quantity
                        failed_transaction_revenue_counter.add(total_amount, {
                            'reason': 'purchase_failed',
                            'product_id': str(product_id)
                        })

                        emit_log('ERROR', 'Purchase failed in Products Service',
                                status_code=purchase_response.status_code,
                                response=purchase_response.text,
                                lost_revenue=total_amount)

                        processing_time = time.time() - start_time
                        order_processing_time_histogram.record(processing_time, {
                            'status': 'failed',
                            'reason': 'purchase_failed'
                        })

                        if processing_time > 2.0:
                            sla_violation_counter.add(1, {'reason': 'purchase_failed'})

                        return jsonify({'error': 'Failed to complete purchase'}), 400

                    purchase_result = purchase_response.json()
                    purchase_span.add_event('purchase_completed', {
                        'order_id_from_products': purchase_result.get('orderId', 'unknown')
                    })

                except requests.RequestException as e:
                    purchase_span.set_status(Status(StatusCode.ERROR, str(e)))
                    emit_log('ERROR', 'Failed to complete purchase', error=str(e))

                    processing_time = time.time() - start_time
                    order_processing_time_histogram.record(processing_time, {
                        'status': 'failed',
                        'reason': 'purchase_completion_failed'
                    })

                    if processing_time > 2.0:
                        sla_violation_counter.add(1, {'reason': 'purchase_completion_failed'})

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
                'status_history': [
                    {'status': 'created', 'timestamp': datetime.utcnow().isoformat() + 'Z'},
                    {'status': 'confirmed', 'timestamp': datetime.utcnow().isoformat() + 'Z'}
                ],
                'created_at': datetime.utcnow().isoformat() + 'Z',
                'updated_at': datetime.utcnow().isoformat() + 'Z',
                'estimated_delivery': (datetime.utcnow() + timedelta(days=random.randint(3, 7))).isoformat() + 'Z'
            }

            orders[order_id] = order_record

            # Update user order history
            if user_id not in user_order_history:
                user_order_history[user_id] = []
            user_order_history[user_id].append(order_id)

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

            # Track user order count
            user_orders_histogram.record(len(user_order_history[user_id]), {
                'user_id': user_id
            })

            # Track order status change
            order_status_counter.add(1, {
                'from_status': 'none',
                'to_status': 'confirmed'
            })

            # Track processing time and check for SLA compliance
            processing_time = time.time() - start_time
            order_processing_time_histogram.record(processing_time, {
                'status': 'success'
            })

            # SLA threshold: 2 seconds
            if processing_time > 2.0:
                sla_violation_counter.add(1, {'reason': 'slow_processing'})

            span.add_event('order_created', {
                'order_id': order_id,
                'total_amount': order_record['total_amount'],
                'processing_time_ms': processing_time * 1000
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
            span.add_event('order_creation_error', {'error': str(e)})
            emit_log('ERROR', 'Error creating order', error=str(e))

            processing_time = time.time() - start_time
            order_processing_time_histogram.record(processing_time, {
                'status': 'failed',
                'reason': 'internal_error'
            })

            if processing_time > 2.0:
                sla_violation_counter.add(1, {'reason': 'internal_error'})

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
            span.add_event('order_not_found', {'order_id': order_id})
            emit_log('WARNING', 'Order not found', order_id=order_id)
            return jsonify({'error': 'Order not found'}), 404

        span.set_attribute('order.status', order['status'])
        span.set_attribute('order.total', order['total_amount'])

        emit_log('INFO', 'Order details retrieved',
                order_id=order_id,
                status=order['status'])

        return jsonify({'order': order})

@app.route('/api/orders/<order_id>/track', methods=['GET'])
def track_order(order_id):
    with tracer.start_as_current_span('track-order') as span:
        span.set_attribute('order.id', order_id)

        emit_log('INFO', 'Tracking order',
                endpoint='/api/orders/:id/track',
                order_id=order_id)

        simulate_processing()

        order = orders.get(order_id)

        if not order:
            span.set_status(Status(StatusCode.ERROR, 'Order not found'))
            emit_log('WARNING', 'Order not found for tracking', order_id=order_id)
            return jsonify({'error': 'Order not found'}), 404

        # Generate tracking info
        tracking_info = {
            'order_id': order_id,
            'current_status': order['status'],
            'status_history': order.get('status_history', []),
            'estimated_delivery': order.get('estimated_delivery'),
            'tracking_number': f'TRK-{order_id[4:]}',
            'carrier': 'FastShip Express',
            'last_update': datetime.utcnow().isoformat() + 'Z'
        }

        emit_log('INFO', 'Order tracking info retrieved',
                order_id=order_id,
                status=order['status'])

        return jsonify({'tracking': tracking_info})

@app.route('/api/orders/user/<user_id>', methods=['GET'])
def get_user_orders(user_id):
    with tracer.start_as_current_span('get-user-orders') as span:
        span.set_attribute('user.id', user_id)

        emit_log('INFO', 'Fetching user orders',
                endpoint='/api/orders/user/:userId',
                user_id=user_id)

        simulate_processing()

        # Update session
        update_session(user_id)

        user_orders = [orders[oid] for oid in user_order_history.get(user_id, []) if oid in orders]

        # Calculate user stats
        total_spent = sum(o['total_amount'] for o in user_orders)

        emit_log('INFO', 'User orders retrieved',
                user_id=user_id,
                count=len(user_orders),
                total_spent=total_spent)

        span.set_attribute('orders.count', len(user_orders))
        span.set_attribute('user.total_spent', total_spent)

        return jsonify({
            'user_id': user_id,
            'orders': user_orders,
            'total': len(user_orders),
            'total_spent': total_spent,
            'average_order_value': total_spent / len(user_orders) if user_orders else 0
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
            span.add_event('cancellation_failed', {'reason': 'order_not_found'})
            emit_log('WARNING', 'Cannot cancel - order not found', order_id=order_id)
            return jsonify({'error': 'Order not found'}), 404

        if order['status'] == 'cancelled':
            span.add_event('cancellation_failed', {'reason': 'already_cancelled'})
            emit_log('WARNING', 'Order already cancelled', order_id=order_id)
            return jsonify({'error': 'Order already cancelled'}), 400

        if order['status'] == 'shipped':
            span.add_event('cancellation_failed', {'reason': 'already_shipped'})
            emit_log('WARNING', 'Cannot cancel shipped order', order_id=order_id)
            return jsonify({'error': 'Cannot cancel shipped order'}), 400

        # Simulate cancellation processing
        with tracer.start_as_current_span('process-cancellation') as cancel_span:
            simulate_processing()

            # Simulate occasional cancellation failures (2% chance)
            if random.random() < 0.02:
                span.set_status(Status(StatusCode.ERROR, 'Cancellation failed'))
                cancel_span.add_event('cancellation_processing_failed')
                emit_log('ERROR', 'Order cancellation failed', order_id=order_id)
                return jsonify({'error': 'Cancellation processing failed'}), 500

        previous_status = order['status']
        order['status'] = 'cancelled'
        order['updated_at'] = datetime.utcnow().isoformat() + 'Z'
        order['status_history'].append({
            'status': 'cancelled',
            'timestamp': datetime.utcnow().isoformat() + 'Z'
        })

        # Record metrics
        cancellation_counter.add(1, {
            'product_id': str(order['product_id']),
            'previous_status': previous_status
        })

        cancellation_value_histogram.record(order['total_amount'], {
            'product_id': str(order['product_id'])
        })

        order_status_counter.add(1, {
            'from_status': previous_status,
            'to_status': 'cancelled'
        })

        span.add_event('order_cancelled', {
            'previous_status': previous_status,
            'cancelled_value': order['total_amount']
        })

        emit_log('INFO', 'Order cancelled successfully',
                order_id=order_id,
                cancelled_value=order['total_amount'])

        span.set_attribute('order.status', 'cancelled')

        return jsonify({
            'success': True,
            'order_id': order_id,
            'status': 'cancelled',
            'refund_amount': order['total_amount']
        })

@app.route('/api/stats')
def get_stats():
    with tracer.start_as_current_span('get-stats') as span:
        # Calculate various stats
        total_orders = len(orders)
        total_revenue = sum(o['total_amount'] for o in orders.values() if o['status'] != 'cancelled')
        cancelled_orders = sum(1 for o in orders.values() if o['status'] == 'cancelled')

        stats = {
            'service': 'orders-service',
            'version': '2.0.0',
            'orders': {
                'total': total_orders,
                'confirmed': sum(1 for o in orders.values() if o['status'] == 'confirmed'),
                'cancelled': cancelled_orders,
                'cancellation_rate': f'{(cancelled_orders / total_orders * 100):.1f}%' if total_orders > 0 else '0%'
            },
            'revenue': {
                'total': total_revenue,
                'average_order_value': total_revenue / (total_orders - cancelled_orders) if total_orders - cancelled_orders > 0 else 0
            },
            'users': {
                'total': len(known_users),
                'with_orders': len(user_order_history),
                'active_sessions': get_active_sessions_count()
            },
            'dependencies': {
                'products_service': {
                    'circuit_breaker_state': products_circuit_breaker.state,
                    'failures': products_circuit_breaker.failures
                }
            }
        }

        span.end()
        return jsonify(stats)

@app.route('/health')
def health():
    is_healthy = products_circuit_breaker.state != 'open'

    emit_log('INFO', 'Health check',
             status='healthy' if is_healthy else 'degraded',
             circuit_breaker=products_circuit_breaker.state)

    return jsonify({
        'status': 'healthy' if is_healthy else 'degraded',
        'service': 'orders-service',
        'version': '2.0.0',
        'timestamp': datetime.utcnow().isoformat() + 'Z',
        'checks': {
            'products_service': products_circuit_breaker.state,
            'database': 'healthy'
        },
        'active_sessions': get_active_sessions_count()
    }), 200 if is_healthy else 503

@app.route('/error')
def error():
    with tracer.start_as_current_span('handle-error-request') as span:
        emit_log('ERROR', 'Simulated error endpoint', path='/error', status=500)

        span.add_event('simulated_error_triggered')
        span.set_status(Status(StatusCode.ERROR, "Simulated service error"))

        return jsonify({
            'status': 'error',
            'message': 'Simulated internal server error',
            'error_id': f'ERR-{int(time.time())}'
        }), 500

@app.route('/api/slow')
def slow_endpoint():
    with tracer.start_as_current_span('slow-endpoint') as span:
        delay = int(request.args.get('delay', 3000)) / 1000

        emit_log('INFO', 'Slow endpoint called', delay_seconds=delay)

        time.sleep(delay)

        span.set_attribute('artificial_delay_seconds', delay)

        return jsonify({
            'message': 'Slow response completed',
            'delay_seconds': delay
        })

if __name__ == '__main__':
    emit_log('INFO', 'Orders Service Started',
             port=8080,
             version='2.0.0',
             products_service=products_service_url,
             features=['circuit_breaker', 'retry', 'session_tracking', 'order_tracking'])
    print(f'Orders Service v2.0.0 running on port 8080')
    print(f'Products Service: {products_service_url}')
    app.run(host='0.0.0.0', port=8080)
