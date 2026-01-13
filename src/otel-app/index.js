const express = require('express');
const { trace, metrics, context, SpanStatusCode } = require('@opentelemetry/api');
const { logs } = require('@opentelemetry/api-logs');

const app = express();
const port = 8080;

// Middleware to parse JSON
app.use(express.json());

// Get meter for custom metrics
const meter = metrics.getMeter('products-service');

// Get logger for sending logs to OTEL collector
const logger = logs.getLogger('products-service', '1.0.0');

// ===================================================================
// RED METRICS (Rate, Error, Duration) - Infrastructure Observability
// ===================================================================

// HTTP Request Counter - tracks all incoming requests
const requestCounter = meter.createCounter('http_requests_total', {
  description: 'Total number of HTTP requests by endpoint, method, and status code',
});

// HTTP Server Duration - tracks request latency for SLA/SLO monitoring
const httpServerDuration = meter.createHistogram('http_server_duration', {
  description: 'HTTP server request duration in milliseconds',
  unit: 'ms',
});

// Product-specific metrics
const productViewCounter = meter.createCounter('products_viewed_total', {
  description: 'Total number of product views',
});

const purchaseCounter = meter.createCounter('purchases_total', {
  description: 'Total number of purchases',
});

const inventoryGauge = meter.createObservableGauge('inventory_level', {
  description: 'Current inventory level for products',
});

// ===================================================================
// BUSINESS METRICS - For Executive Dashboard
// ===================================================================

// Revenue at Risk - tracks potential revenue loss during incidents
const revenueAtRiskCounter = meter.createCounter('revenue_at_risk_dollars', {
  description: 'Potential revenue loss in dollars during failures',
  unit: 'USD',
});

// Transaction Value - tracks actual transaction amounts
const transactionValueHistogram = meter.createHistogram('transaction_value_dollars', {
  description: 'Distribution of transaction values in dollars',
  unit: 'USD',
});

// Cart Abandonment - tracks when users don't complete purchases
const cartAbandonmentCounter = meter.createCounter('cart_abandonment_total', {
  description: 'Total number of abandoned carts/failed checkouts',
});

// Checkout Success Rate - tracks successful vs failed transactions
const checkoutAttemptCounter = meter.createCounter('checkout_attempts_total', {
  description: 'Total checkout attempts (success + failures)',
});

const checkoutSuccessCounter = meter.createCounter('checkout_success_total', {
  description: 'Total successful checkouts',
});

// Customer Experience Score - gauge based on latency (0-100 scale)
const customerExperienceGauge = meter.createObservableGauge('customer_experience_score', {
  description: 'Customer experience score based on service latency (0-100)',
});

// Track recent response times for experience score calculation
let recentResponseTimes = [];
const MAX_SAMPLES = 20;

// In-memory product catalog
const products = [
  { id: 1, name: 'Laptop Pro', price: 1299.99, stock: 15, category: 'electronics' },
  { id: 2, name: 'Wireless Mouse', price: 29.99, stock: 50, category: 'electronics' },
  { id: 3, name: 'Mechanical Keyboard', price: 89.99, stock: 30, category: 'electronics' },
  { id: 4, name: 'USB-C Hub', price: 49.99, stock: 25, category: 'accessories' },
  { id: 5, name: 'Monitor 27"', price: 399.99, stock: 10, category: 'electronics' },
  { id: 6, name: 'Webcam HD', price: 79.99, stock: 20, category: 'electronics' },
  { id: 7, name: 'Desk Lamp', price: 39.99, stock: 35, category: 'accessories' },
  { id: 8, name: 'Notebook Set', price: 12.99, stock: 100, category: 'stationery' },
];

// Register inventory gauge callback
inventoryGauge.addCallback((observableResult) => {
  products.forEach(product => {
    observableResult.observe(product.stock, {
      product_id: product.id.toString(),
      product_name: product.name,
      category: product.category
    });
  });
});

// Register customer experience score callback
// Score formula: 100 - (avg_latency_ms / 10)
// < 100ms = 90-100 (excellent), 100-500ms = 50-90 (good), > 500ms = 0-50 (poor)
customerExperienceGauge.addCallback((observableResult) => {
  if (recentResponseTimes.length > 0) {
    const avgLatency = recentResponseTimes.reduce((a, b) => a + b, 0) / recentResponseTimes.length;
    // Score from 0 to 100, inversely proportional to latency
    const score = Math.max(0, Math.min(100, 100 - (avgLatency / 10)));
    observableResult.observe(score, {
      
    });
  } else {
    observableResult.observe(100, {  });
  }
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
      'service_name': 'products-service',
      ...attributes
    },
  });

  // Also log to console for local debugging
  console.log(JSON.stringify({
    severity,
    message,
    traceId: spanContext.traceId,
    spanId: spanContext.spanId,
    service: 'products-service',
    ...attributes
  }));
}

// Helper to simulate database latency
const simulateDbLatency = () => new Promise(resolve => setTimeout(resolve, 50 + Math.random() * 100));

// ===================================================================
// APM MIDDLEWARE - Automatic instrumentation for all endpoints
// ===================================================================
// Captures latency, status codes, and request metadata automatically
// This middleware provides RED metrics (Rate, Errors, Duration) for all HTTP endpoints
app.use((req, res, next) => {
  const startTime = Date.now();

  // Store original res.json and res.send to intercept responses
  const originalJson = res.json.bind(res);
  const originalSend = res.send.bind(res);

  // Intercept response to capture metrics
  const captureMetrics = (body) => {
    const duration = Date.now() - startTime;
    const endpoint = req.route?.path || req.path || 'unknown';
    const method = req.method;
    const statusCode = res.statusCode;

    // Record HTTP request counter with status code
    requestCounter.add(1, {
      endpoint,
      method,
      http_status_code: statusCode.toString(),
      
    });

    // Record HTTP server duration (latency) for SLO monitoring
    httpServerDuration.record(duration, {
      endpoint,
      method,
      http_status_code: statusCode.toString(),
      
    });

    // Track response times for customer experience score calculation
    recentResponseTimes.push(duration);
    if (recentResponseTimes.length > MAX_SAMPLES) recentResponseTimes.shift();

    return body;
  };

  // Override res.json to capture metrics
  res.json = function(body) {
    captureMetrics(body);
    return originalJson(body);
  };

  // Override res.send to capture metrics
  res.send = function(body) {
    captureMetrics(body);
    return originalSend(body);
  };

  next();
});

// ===================================================================
// ENDPOINTS
// ===================================================================

// Root endpoint
app.get('/', (req, res) => {
  const span = trace.getTracer('products-service').startSpan('handle-root-request');

  emitLog('INFO', 'Received request on root endpoint', {
    path: '/',
    method: 'GET'
  });

  setTimeout(() => {
    span.end();
    res.json({
      service: 'Products Service',
      version: '1.0.0',
      endpoints: [
        'GET /api/products',
        'GET /api/products/:id',
        'POST /api/products/:id/purchase',
        'GET /api/inventory/:productId',
        'GET /api/categories',
        'GET /health'
      ]
    });
  }, 50);
});

// Get all products
app.get('/api/products', async (req, res) => {
  const span = trace.getTracer('products-service').startSpan('get-all-products');

  try {
    const category = req.query.category;

    emitLog('INFO', 'Fetching products', {
      endpoint: '/api/products',
      category: category || 'all'
    });

    // Simulate database query
    const dbSpan = trace.getTracer('products-service').startSpan('db-query-products', {
      parent: span,
    });
    dbSpan.setAttribute('db.system', 'postgresql');
    dbSpan.setAttribute('db.operation', 'SELECT');
    dbSpan.setAttribute('db.table', 'products');

    await simulateDbLatency();

    const filteredProducts = category
      ? products.filter(p => p.category === category)
      : products;

    dbSpan.end();

    productViewCounter.add(filteredProducts.length, {
      category: category || 'all',
      
    });

    emitLog('INFO', 'Products retrieved successfully', {
      count: filteredProducts.length,
      category: category || 'all'
    });

    span.setAttribute('products.count', filteredProducts.length);
    span.end();

    res.json({
      products: filteredProducts,
      total: filteredProducts.length
    });
  } catch (error) {
    span.setStatus({ code: SpanStatusCode.ERROR, message: error.message });
    span.end();

    emitLog('ERROR', 'Error fetching products', {
      error: error.message
    });

    res.status(500).json({ error: 'Internal server error' });
  }
});

// Get product by ID
app.get('/api/products/:id', async (req, res) => {
  const span = trace.getTracer('products-service').startSpan('get-product-by-id');
  const productId = parseInt(req.params.id);

  try {
    span.setAttribute('product.id', productId);

    emitLog('INFO', 'Fetching product details', {
      endpoint: '/api/products/:id',
      product_id: productId
    });

    // Simulate database query
    await simulateDbLatency();

    const product = products.find(p => p.id === productId);

    if (!product) {
      span.setAttribute('product.found', false);
      span.setStatus({ code: SpanStatusCode.ERROR, message: 'Product not found' });

      emitLog('WARNING', 'Product not found', {
        product_id: productId
      });

      span.end();
      return res.status(404).json({ error: 'Product not found' });
    }

    span.setAttribute('product.found', true);
    span.setAttribute('product.name', product.name);
    span.setAttribute('product.price', product.price);

    productViewCounter.add(1, {
      product_id: productId.toString(),
      product_name: product.name,
      
    });

    emitLog('INFO', 'Product details retrieved', {
      product_id: productId,
      product_name: product.name,
      price: product.price
    });

    span.end();
    res.json({ product });
  } catch (error) {
    span.setStatus({ code: SpanStatusCode.ERROR, message: error.message });
    span.end();

    emitLog('ERROR', 'Error fetching product', {
      error: error.message,
      product_id: productId
    });

    res.status(500).json({ error: 'Internal server error' });
  }
});

// Purchase a product
app.post('/api/products/:id/purchase', async (req, res) => {
  const span = trace.getTracer('products-service').startSpan('purchase-product');
  const productId = parseInt(req.params.id);
  const quantity = req.body.quantity || 1;
  const startTime = Date.now();

  try {
    span.setAttribute('product.id', productId);
    span.setAttribute('purchase.quantity', quantity);

    emitLog('INFO', 'Processing purchase request', {
      endpoint: '/api/products/:id/purchase',
      product_id: productId,
      quantity
    });

    // Track checkout attempt for success rate calculation
    checkoutAttemptCounter.add(1, {
      
      product_id: productId.toString()
    });

    // Simulate inventory check
    const inventorySpan = trace.getTracer('products-service').startSpan('check-inventory', {
      parent: span,
    });

    await simulateDbLatency();

    const product = products.find(p => p.id === productId);

    if (!product) {
      inventorySpan.end();
      span.setStatus({ code: SpanStatusCode.ERROR, message: 'Product not found' });

      // Track cart abandonment and potential revenue loss
      cartAbandonmentCounter.add(1, {
        
        reason: 'product_not_found'
      });

      emitLog('WARNING', 'Purchase failed - product not found', {
        product_id: productId
      });

      // Track response time for customer experience
      const responseTime = Date.now() - startTime;
      recentResponseTimes.push(responseTime);
      if (recentResponseTimes.length > MAX_SAMPLES) recentResponseTimes.shift();

      span.end();
      return res.status(404).json({ error: 'Product not found' });
    }

    if (product.stock < quantity) {
      inventorySpan.setAttribute('inventory.sufficient', false);
      inventorySpan.end();
      span.setStatus({ code: SpanStatusCode.ERROR, message: 'Insufficient stock' });

      // Track cart abandonment and lost revenue
      const lostRevenue = product.price * quantity;
      cartAbandonmentCounter.add(1, {
        
        reason: 'insufficient_stock',
        product_id: productId.toString()
      });
      revenueAtRiskCounter.add(lostRevenue, {
        
        reason: 'insufficient_stock',
        product_name: product.name
      });

      emitLog('WARNING', 'Purchase failed - insufficient stock', {
        product_id: productId,
        product_name: product.name,
        requested: quantity,
        available: product.stock,
        lost_revenue: lostRevenue
      });

      // Track response time for customer experience
      const responseTime = Date.now() - startTime;
      recentResponseTimes.push(responseTime);
      if (recentResponseTimes.length > MAX_SAMPLES) recentResponseTimes.shift();

      span.end();
      return res.status(400).json({
        error: 'Insufficient stock',
        available: product.stock,
        requested: quantity
      });
    }

    inventorySpan.setAttribute('inventory.sufficient', true);
    inventorySpan.end();

    // Simulate payment processing
    const paymentSpan = trace.getTracer('products-service').startSpan('process-payment', {
      parent: span,
    });
    paymentSpan.setAttribute('payment.amount', product.price * quantity);

    await new Promise(resolve => setTimeout(resolve, 100 + Math.random() * 200));

    // Simulate occasional payment failures (5% chance)
    if (Math.random() < 0.05) {
      paymentSpan.setStatus({ code: SpanStatusCode.ERROR, message: 'Payment declined' });
      paymentSpan.end();
      span.setStatus({ code: SpanStatusCode.ERROR, message: 'Payment failed' });

      // Track cart abandonment and lost revenue due to payment failure
      const lostRevenue = product.price * quantity;
      cartAbandonmentCounter.add(1, {
        
        reason: 'payment_declined',
        product_id: productId.toString()
      });
      revenueAtRiskCounter.add(lostRevenue, {
        
        reason: 'payment_declined',
        product_name: product.name
      });

      emitLog('ERROR', 'Purchase failed - payment declined', {
        product_id: productId,
        amount: lostRevenue,
        lost_revenue: lostRevenue
      });

      // Track response time for customer experience
      const responseTime = Date.now() - startTime;
      recentResponseTimes.push(responseTime);
      if (recentResponseTimes.length > MAX_SAMPLES) recentResponseTimes.shift();

      span.end();
      return res.status(402).json({ error: 'Payment declined' });
    }

    paymentSpan.end();

    // Update inventory
    product.stock -= quantity;

    // Calculate transaction value
    const transactionValue = product.price * quantity;

    // Track successful purchase metrics
    purchaseCounter.add(1, {
      product_id: productId.toString(),
      product_name: product.name,
      
    });

    // Track checkout success
    checkoutSuccessCounter.add(1, {
      
      product_id: productId.toString()
    });

    // Track transaction value
    transactionValueHistogram.record(transactionValue, {
      
      product_id: productId.toString(),
      product_name: product.name
    });

    emitLog('INFO', 'Purchase completed successfully', {
      product_id: productId,
      product_name: product.name,
      quantity,
      total_amount: transactionValue,
      remaining_stock: product.stock
    });

    // Track response time for customer experience
    const responseTime = Date.now() - startTime;
    recentResponseTimes.push(responseTime);
    if (recentResponseTimes.length > MAX_SAMPLES) recentResponseTimes.shift();

    span.setAttribute('purchase.success', true);
    span.setAttribute('purchase.total', transactionValue);
    span.end();

    res.json({
      success: true,
      product: product.name,
      quantity,
      total: product.price * quantity,
      remaining_stock: product.stock
    });
  } catch (error) {
    span.setStatus({ code: SpanStatusCode.ERROR, message: error.message });

    // Track cart abandonment due to system error
    cartAbandonmentCounter.add(1, {
      
      reason: 'system_error'
    });

    emitLog('ERROR', 'Error processing purchase', {
      error: error.message,
      product_id: productId
    });

    // Track response time for customer experience
    const responseTime = Date.now() - startTime;
    recentResponseTimes.push(responseTime);
    if (recentResponseTimes.length > MAX_SAMPLES) recentResponseTimes.shift();

    span.end();
    res.status(500).json({ error: 'Internal server error' });
  }
});

// Get inventory for a product (callable by other services)
app.get('/api/inventory/:productId', async (req, res) => {
  const span = trace.getTracer('products-service').startSpan('check-inventory');
  const productId = parseInt(req.params.productId);

  try {
    span.setAttribute('product.id', productId);

    emitLog('INFO', 'Checking inventory', {
      endpoint: '/api/inventory/:productId',
      product_id: productId
    });

    await simulateDbLatency();

    const product = products.find(p => p.id === productId);

    if (!product) {
      span.setStatus({ code: SpanStatusCode.ERROR, message: 'Product not found' });
      emitLog('WARNING', 'Inventory check - product not found', { product_id: productId });
      span.end();
      return res.status(404).json({ error: 'Product not found' });
    }

    emitLog('INFO', 'Inventory check complete', {
      product_id: productId,
      stock: product.stock
    });

    span.setAttribute('inventory.stock', product.stock);
    span.end();

    res.json({
      product_id: productId,
      product_name: product.name,
      stock: product.stock,
      available: product.stock > 0
    });
  } catch (error) {
    span.setStatus({ code: SpanStatusCode.ERROR, message: error.message });
    span.end();

    emitLog('ERROR', 'Error checking inventory', {
      error: error.message,
      product_id: productId
    });

    res.status(500).json({ error: 'Internal server error' });
  }
});

// Get all categories
app.get('/api/categories', async (req, res) => {
  const span = trace.getTracer('products-service').startSpan('get-categories');

  try {
    emitLog('INFO', 'Fetching categories', {
      endpoint: '/api/categories'
    });

    await simulateDbLatency();

    const categories = [...new Set(products.map(p => p.category))];

    emitLog('INFO', 'Categories retrieved', {
      count: categories.length
    });

    span.end();
    res.json({ categories });
  } catch (error) {
    span.setStatus({ code: SpanStatusCode.ERROR, message: error.message });
    span.end();

    emitLog('ERROR', 'Error fetching categories', {
      error: error.message
    });

    res.status(500).json({ error: 'Internal server error' });
  }
});

// Health check endpoint
app.get('/health', (req, res) => {
  emitLog('INFO', 'Health check', {
    status: 'healthy'
  });
  res.json({
    status: 'healthy',
    service: 'products-service',
    timestamp: new Date().toISOString()
  });
});

// Error simulation endpoint
app.get('/error', (req, res) => {
  const span = trace.getActiveSpan();

  emitLog('ERROR', 'Simulated error endpoint', {
    path: '/error',
    status: 500
  });

  if (span) {
    span.setStatus({ code: SpanStatusCode.ERROR, message: 'Simulated service error' });
  }

  res.status(500).json({
    status: 'error',
    message: 'Simulated internal server error'
  });
});

app.listen(port, () => {
  emitLog('INFO', 'Products Service Started', {
    port: port,
    endpoints: [
      'GET /',
      'GET /api/products',
      'GET /api/products/:id',
      'POST /api/products/:id/purchase',
      'GET /api/inventory/:productId',
      'GET /api/categories',
      'GET /health',
      'GET /error'
    ],
    total_products: products.length
  });
  console.log(`🛍️  Products Service running on port ${port}`);
});
