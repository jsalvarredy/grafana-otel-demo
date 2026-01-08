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

# Create custom metrics
request_counter = meter.create_counter(
    'http.requests.total',
    description='Total number of HTTP requests',
)

order_counter = meter.create_counter(
    'orders.created.total',
    description='Total number of orders created',
)

order_value_histogram = meter.create_histogram(
    'orders.value',
    description='Distribution of order values',
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

@app.route('/')
def root():
    with tracer.start_as_current_span('handle-root-request') as span:
        emit_log('INFO', 'Received request on root endpoint', path='/', method='GET')
        
        request_counter.add(1, {'endpoint': '/', 'method': 'GET', 'service_name': 'orders-service'})
        
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
            
            request_counter.add(1, {'endpoint': '/api/orders', 'method': 'POST', 'service_name': 'orders-service'})
            
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
                        emit_log('WARNING', 'Insufficient inventory for order',
                                product_id=product_id,
                                requested=quantity,
                                available=inventory_data['stock'])
                        return jsonify({
                            'error': 'Insufficient stock',
                            'requested': quantity,
                            'available': inventory_data['stock']
                        }), 400
                    
                    inventory_span.set_attribute('inventory.sufficient', True)
                    
                except requests.RequestException as e:
                    inventory_span.set_status(Status(StatusCode.ERROR, str(e)))
                    emit_log('ERROR', 'Failed to check inventory', error=str(e))
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
                    emit_log('ERROR', 'Payment processing failed', 
                            amount=total_amount)
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
                        emit_log('ERROR', 'Purchase failed in Products Service',
                                status_code=purchase_response.status_code,
                                response=purchase_response.text)
                        return jsonify({'error': 'Failed to complete purchase'}), 400
                    
                    purchase_result = purchase_response.json()
                    
                except requests.RequestException as e:
                    purchase_span.set_status(Status(StatusCode.ERROR, str(e)))
                    emit_log('ERROR', 'Failed to complete purchase', error=str(e))
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
                'service_name': 'orders-service'
            })
            order_value_histogram.record(order_record['total_amount'], {
                'product_id': str(product_id),
                'service_name': 'orders-service'
            })
            
            emit_log('INFO', 'Order created successfully',
                    order_id=order_id,
                    product_id=product_id,
                    total_amount=order_record['total_amount'],
                    user_id=user_id)
            
            span.set_attribute('order.id', order_id)
            span.set_attribute('order.total', order_record['total_amount'])
            span.set_attribute('order.status', 'confirmed')
            
            return jsonify({'order': order_record}), 201
            
        except Exception as e:
            span.set_status(Status(StatusCode.ERROR, str(e)))
            emit_log('ERROR', 'Error creating order', error=str(e))
            return jsonify({'error': 'Internal server error'}), 500

@app.route('/api/orders/<order_id>', methods=['GET'])
def get_order(order_id):
    with tracer.start_as_current_span('get-order') as span:
        span.set_attribute('order.id', order_id)
        
        emit_log('INFO', 'Fetching order details', 
                endpoint='/api/orders/:id',
                order_id=order_id)
        
        request_counter.add(1, {'endpoint': '/api/orders/:id', 'method': 'GET', 'service_name': 'orders-service'})
        
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
        
        request_counter.add(1, {'endpoint': '/api/orders/user/:userId', 'method': 'GET', 'service_name': 'orders-service'})
        
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
        
        request_counter.add(1, {'endpoint': '/api/orders/:id/cancel', 'method': 'POST', 'service_name': 'orders-service'})
        
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
    request_counter.add(1, {'endpoint': '/health', 'method': 'GET', 'service_name': 'orders-service'})
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
