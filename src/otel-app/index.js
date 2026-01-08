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

// Create custom metrics
const requestCounter = meter.createCounter('http_requests_total', {
  description: 'Total number of HTTP requests',
});

const productViewCounter = meter.createCounter('products_viewed_total', {
  description: 'Total number of product views',
});

const purchaseCounter = meter.createCounter('purchases_total', {
  description: 'Total number of purchases',
});

const inventoryGauge = meter.createObservableGauge('inventory_level', {
  description: 'Current inventory level for products',
});

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
      'service.name': 'products-service',
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

// Root endpoint
app.get('/', (req, res) => {
  const span = trace.getTracer('products-service').startSpan('handle-root-request');

  emitLog('INFO', 'Received request on root endpoint', {
    path: '/',
    method: 'GET'
  });

  requestCounter.add(1, { endpoint: '/', method: 'GET', service_name: 'products-service' });

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

    requestCounter.add(1, { endpoint: '/api/products', method: 'GET', service_name: 'products-service' });

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
      service_name: 'products-service'
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

    requestCounter.add(1, { endpoint: '/api/products/:id', method: 'GET', service_name: 'products-service' });

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
      service_name: 'products-service'
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

  try {
    span.setAttribute('product.id', productId);
    span.setAttribute('purchase.quantity', quantity);

    emitLog('INFO', 'Processing purchase request', {
      endpoint: '/api/products/:id/purchase',
      product_id: productId,
      quantity
    });

    requestCounter.add(1, { endpoint: '/api/products/:id/purchase', method: 'POST', service_name: 'products-service' });

    // Simulate inventory check
    const inventorySpan = trace.getTracer('products-service').startSpan('check-inventory', {
      parent: span,
    });

    await simulateDbLatency();

    const product = products.find(p => p.id === productId);

    if (!product) {
      inventorySpan.end();
      span.setStatus({ code: SpanStatusCode.ERROR, message: 'Product not found' });

      emitLog('WARNING', 'Purchase failed - product not found', {
        product_id: productId
      });

      span.end();
      return res.status(404).json({ error: 'Product not found' });
    }

    if (product.stock < quantity) {
      inventorySpan.setAttribute('inventory.sufficient', false);
      inventorySpan.end();
      span.setStatus({ code: SpanStatusCode.ERROR, message: 'Insufficient stock' });

      emitLog('WARNING', 'Purchase failed - insufficient stock', {
        product_id: productId,
        product_name: product.name,
        requested: quantity,
        available: product.stock
      });

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

      emitLog('ERROR', 'Purchase failed - payment declined', {
        product_id: productId,
        amount: product.price * quantity
      });

      span.end();
      return res.status(402).json({ error: 'Payment declined' });
    }

    paymentSpan.end();

    // Update inventory
    product.stock -= quantity;

    purchaseCounter.add(1, {
      product_id: productId.toString(),
      product_name: product.name,
      service_name: 'products-service'
    });

    emitLog('INFO', 'Purchase completed successfully', {
      product_id: productId,
      product_name: product.name,
      quantity,
      total_amount: product.price * quantity,
      remaining_stock: product.stock
    });

    span.setAttribute('purchase.success', true);
    span.setAttribute('purchase.total', product.price * quantity);
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
    span.end();

    emitLog('ERROR', 'Error processing purchase', {
      error: error.message,
      product_id: productId
    });

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

    requestCounter.add(1, { endpoint: '/api/inventory/:productId', method: 'GET', service_name: 'products-service' });

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

    requestCounter.add(1, { endpoint: '/api/categories', method: 'GET', service_name: 'products-service' });

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
  requestCounter.add(1, { endpoint: '/health', method: 'GET', service_name: 'products-service' });
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
