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

// ===================================================================
// ADVANCED METRICS - Cache, Rate Limiting, Circuit Breaker
// ===================================================================

// Cache metrics
const cacheHitCounter = meter.createCounter('cache_hits_total', {
  description: 'Total number of cache hits',
});

const cacheMissCounter = meter.createCounter('cache_misses_total', {
  description: 'Total number of cache misses',
});

const cacheHitRatioGauge = meter.createObservableGauge('cache_hit_ratio', {
  description: 'Current cache hit ratio (0-1)',
});

// Rate limiting metrics
const rateLimitedRequestsCounter = meter.createCounter('rate_limited_requests_total', {
  description: 'Total number of rate-limited requests',
});

const activeConnectionsGauge = meter.createObservableGauge('active_connections', {
  description: 'Current number of active connections',
});

// Circuit breaker metrics
const circuitBreakerStateGauge = meter.createObservableGauge('circuit_breaker_state', {
  description: 'Circuit breaker state: 0=closed, 1=half-open, 2=open',
});

const circuitBreakerTripsCounter = meter.createCounter('circuit_breaker_trips_total', {
  description: 'Number of times circuit breaker has tripped',
});

// Search metrics
const searchQueryCounter = meter.createCounter('search_queries_total', {
  description: 'Total number of search queries',
});

const searchResultsHistogram = meter.createHistogram('search_results_count', {
  description: 'Distribution of search result counts',
});

// Recommendation metrics
const recommendationsServedCounter = meter.createCounter('recommendations_served_total', {
  description: 'Total number of recommendations served',
});

// ===================================================================
// Simulated Infrastructure State
// ===================================================================

// Cache simulation
let cacheHits = 0;
let cacheMisses = 0;
const productCache = new Map();
const CACHE_TTL_MS = 30000; // 30 seconds

// Rate limiting simulation
const rateLimitWindow = new Map(); // IP -> request count
const RATE_LIMIT_MAX = 100; // requests per window
const RATE_LIMIT_WINDOW_MS = 60000; // 1 minute

// Circuit breaker simulation
let circuitBreakerState = 0; // 0=closed, 1=half-open, 2=open
let consecutiveFailures = 0;
const FAILURE_THRESHOLD = 5;
let lastCircuitCheck = Date.now();

// Active connections tracking
let activeConnections = 0;

// Track recent response times for experience score calculation
let recentResponseTimes = [];
const MAX_SAMPLES = 20;

// ===================================================================
// Realistic Product Catalog with descriptions, ratings, reviews
// ===================================================================

const products = [
  {
    id: 1,
    name: 'Laptop Pro 15',
    description: 'High-performance laptop with 15.6" Retina display, M3 Pro chip, 18GB unified memory, and 512GB SSD. Perfect for developers and creative professionals.',
    price: 1299.99,
    stock: 15,
    category: 'electronics',
    brand: 'TechCorp',
    rating: 4.7,
    reviewCount: 342,
    tags: ['laptop', 'professional', 'portable', 'high-performance'],
    specs: {
      processor: 'M3 Pro',
      memory: '18GB',
      storage: '512GB SSD',
      display: '15.6" Retina',
      weight: '1.6kg'
    },
    popularity: 95
  },
  {
    id: 2,
    name: 'Wireless Mouse Pro',
    description: 'Ergonomic wireless mouse with precision tracking, customizable buttons, and 90-day battery life. Compatible with all major operating systems.',
    price: 29.99,
    stock: 50,
    category: 'electronics',
    brand: 'PeripheralCo',
    rating: 4.5,
    reviewCount: 1205,
    tags: ['mouse', 'wireless', 'ergonomic', 'office'],
    specs: {
      dpi: '16000',
      buttons: 6,
      battery: '90 days',
      connectivity: 'Bluetooth/USB'
    },
    popularity: 88
  },
  {
    id: 3,
    name: 'Mechanical Keyboard RGB',
    description: 'Premium mechanical keyboard with Cherry MX switches, full RGB backlighting, and aircraft-grade aluminum frame. N-key rollover for gaming.',
    price: 89.99,
    stock: 30,
    category: 'electronics',
    brand: 'KeyMaster',
    rating: 4.8,
    reviewCount: 567,
    tags: ['keyboard', 'mechanical', 'gaming', 'rgb'],
    specs: {
      switches: 'Cherry MX Brown',
      layout: 'Full-size',
      backlighting: 'RGB',
      connection: 'USB-C'
    },
    popularity: 92
  },
  {
    id: 4,
    name: 'USB-C Hub 7-in-1',
    description: 'Compact USB-C hub with 4K HDMI, 100W power delivery, 2x USB-A 3.0, USB-C data, SD card reader, and Ethernet port.',
    price: 49.99,
    stock: 25,
    category: 'accessories',
    brand: 'ConnectPro',
    rating: 4.3,
    reviewCount: 892,
    tags: ['hub', 'usb-c', 'dock', 'portable'],
    specs: {
      ports: 7,
      hdmi: '4K@60Hz',
      power: '100W PD',
      ethernet: '1Gbps'
    },
    popularity: 78
  },
  {
    id: 5,
    name: 'Ultra Monitor 27"',
    description: 'Professional 27-inch 4K IPS monitor with 99% DCI-P3 color accuracy, USB-C connectivity, and adjustable ergonomic stand.',
    price: 399.99,
    stock: 10,
    category: 'electronics',
    brand: 'DisplayMaster',
    rating: 4.6,
    reviewCount: 234,
    tags: ['monitor', '4k', 'professional', 'color-accurate'],
    specs: {
      resolution: '3840x2160',
      panel: 'IPS',
      refreshRate: '60Hz',
      colorGamut: '99% DCI-P3'
    },
    popularity: 85
  },
  {
    id: 6,
    name: 'HD Webcam Pro',
    description: '1080p HD webcam with auto-focus, noise-canceling dual microphones, and low-light correction. Ideal for video conferencing.',
    price: 79.99,
    stock: 20,
    category: 'electronics',
    brand: 'StreamGear',
    rating: 4.4,
    reviewCount: 1567,
    tags: ['webcam', 'streaming', 'conference', 'hd'],
    specs: {
      resolution: '1080p',
      framerate: '60fps',
      fov: '90 degrees',
      microphone: 'Dual stereo'
    },
    popularity: 82
  },
  {
    id: 7,
    name: 'LED Desk Lamp Smart',
    description: 'Adjustable LED desk lamp with smart home integration, color temperature control (2700K-6500K), and wireless charging base.',
    price: 39.99,
    stock: 35,
    category: 'accessories',
    brand: 'LightWorks',
    rating: 4.2,
    reviewCount: 445,
    tags: ['lamp', 'smart', 'led', 'wireless-charging'],
    specs: {
      brightness: '1000 lumens',
      colorTemp: '2700K-6500K',
      wireless: 'Qi charging',
      smart: 'Alexa/Google'
    },
    popularity: 65
  },
  {
    id: 8,
    name: 'Premium Notebook Set',
    description: 'Set of 3 premium hardcover notebooks with 200gsm paper, lay-flat binding, and numbered pages. Includes dot grid, lined, and blank.',
    price: 12.99,
    stock: 100,
    category: 'stationery',
    brand: 'PaperCraft',
    rating: 4.9,
    reviewCount: 2341,
    tags: ['notebook', 'premium', 'writing', 'journal'],
    specs: {
      pages: 192,
      paperWeight: '200gsm',
      binding: 'Lay-flat',
      quantity: 3
    },
    popularity: 70
  },
  {
    id: 9,
    name: 'Wireless Earbuds Pro',
    description: 'True wireless earbuds with active noise cancellation, 30-hour battery life with case, and IPX5 water resistance.',
    price: 149.99,
    stock: 40,
    category: 'electronics',
    brand: 'AudioTech',
    rating: 4.6,
    reviewCount: 3421,
    tags: ['earbuds', 'wireless', 'anc', 'audio'],
    specs: {
      battery: '8h (30h with case)',
      anc: 'Active',
      waterproof: 'IPX5',
      codec: 'aptX, AAC'
    },
    popularity: 94
  },
  {
    id: 10,
    name: 'Portable SSD 1TB',
    description: 'Ultra-fast portable SSD with 1050MB/s read speeds, hardware encryption, and shock-resistant aluminum enclosure.',
    price: 129.99,
    stock: 45,
    category: 'electronics',
    brand: 'StoragePro',
    rating: 4.7,
    reviewCount: 1876,
    tags: ['ssd', 'storage', 'portable', 'fast'],
    specs: {
      capacity: '1TB',
      readSpeed: '1050MB/s',
      writeSpeed: '1000MB/s',
      encryption: 'AES 256-bit'
    },
    popularity: 89
  },
  {
    id: 11,
    name: 'Ergonomic Office Chair',
    description: 'Fully adjustable ergonomic office chair with lumbar support, breathable mesh back, and 4D armrests. Supports up to 150kg.',
    price: 299.99,
    stock: 8,
    category: 'accessories',
    brand: 'ComfortSeating',
    rating: 4.5,
    reviewCount: 654,
    tags: ['chair', 'ergonomic', 'office', 'comfort'],
    specs: {
      maxWeight: '150kg',
      adjustments: '12-point',
      material: 'Mesh',
      warranty: '5 years'
    },
    popularity: 76
  },
  {
    id: 12,
    name: 'Standing Desk Electric',
    description: 'Electric height-adjustable standing desk with memory presets, anti-collision technology, and cable management system.',
    price: 449.99,
    stock: 5,
    category: 'accessories',
    brand: 'DeskMaster',
    rating: 4.4,
    reviewCount: 321,
    tags: ['desk', 'standing', 'electric', 'ergonomic'],
    specs: {
      heightRange: '60-125cm',
      loadCapacity: '120kg',
      presets: 4,
      surface: '140x70cm'
    },
    popularity: 72
  }
];

// Product reviews storage
const productReviews = new Map();

// Initialize some reviews for each product
products.forEach(product => {
  const reviews = [];
  const reviewTemplates = [
    { rating: 5, text: 'Excellent product! Exceeded my expectations. Fast shipping and great packaging.' },
    { rating: 5, text: 'Best purchase I have made this year. Highly recommended for professionals.' },
    { rating: 4, text: 'Very good quality. Minor issues with setup but works great now.' },
    { rating: 4, text: 'Good value for money. Does exactly what it promises.' },
    { rating: 3, text: 'Decent product. Some features could be improved.' },
    { rating: 2, text: 'Not as expected. Had some issues but customer service helped.' },
  ];

  // Generate 3-6 reviews per product
  const numReviews = Math.floor(Math.random() * 4) + 3;
  for (let i = 0; i < numReviews; i++) {
    const template = reviewTemplates[Math.floor(Math.random() * reviewTemplates.length)];
    reviews.push({
      id: `${product.id}-review-${i + 1}`,
      userId: `user-${Math.floor(Math.random() * 500) + 1}`,
      userName: `User${Math.floor(Math.random() * 1000)}`,
      rating: template.rating,
      text: template.text,
      createdAt: new Date(Date.now() - Math.random() * 90 * 24 * 60 * 60 * 1000).toISOString(),
      helpful: Math.floor(Math.random() * 50),
      verified: Math.random() > 0.3
    });
  }
  productReviews.set(product.id, reviews);
});

// ===================================================================
// Observable Gauge Callbacks
// ===================================================================

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
customerExperienceGauge.addCallback((observableResult) => {
  if (recentResponseTimes.length > 0) {
    const avgLatency = recentResponseTimes.reduce((a, b) => a + b, 0) / recentResponseTimes.length;
    const score = Math.max(0, Math.min(100, 100 - (avgLatency / 10)));
    observableResult.observe(score, {});
  } else {
    observableResult.observe(100, {});
  }
});

// Register cache hit ratio callback
cacheHitRatioGauge.addCallback((observableResult) => {
  const total = cacheHits + cacheMisses;
  const ratio = total > 0 ? cacheHits / total : 0;
  observableResult.observe(ratio, { cache_name: 'product_cache' });
});

// Register active connections callback
activeConnectionsGauge.addCallback((observableResult) => {
  observableResult.observe(activeConnections, { service: 'products-service' });
});

// Register circuit breaker state callback
circuitBreakerStateGauge.addCallback((observableResult) => {
  observableResult.observe(circuitBreakerState, { service: 'database' });
});

// ===================================================================
// Helper Functions
// ===================================================================

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

// Simulate database latency with load-based variation
const simulateDbLatency = async (operation = 'read') => {
  // Base latency
  let baseLatency = operation === 'write' ? 80 : 50;

  // Add load-based variation (more connections = slower)
  const loadFactor = 1 + (activeConnections / 50);
  baseLatency *= loadFactor;

  // Add some randomness
  const latency = baseLatency + Math.random() * 100;

  // Simulate occasional slow queries (5% chance)
  const finalLatency = Math.random() < 0.05 ? latency * 3 : latency;

  return new Promise(resolve => setTimeout(resolve, finalLatency));
};

// Cache operations
function getCached(key) {
  const cached = productCache.get(key);
  if (cached && Date.now() - cached.timestamp < CACHE_TTL_MS) {
    cacheHits++;
    cacheHitCounter.add(1, { cache: 'product', operation: 'get' });
    return cached.data;
  }
  cacheMisses++;
  cacheMissCounter.add(1, { cache: 'product', operation: 'get' });
  return null;
}

function setCache(key, data) {
  productCache.set(key, { data, timestamp: Date.now() });
}

// Rate limiting check
function checkRateLimit(ip) {
  const now = Date.now();
  const windowStart = now - RATE_LIMIT_WINDOW_MS;

  // Clean old entries
  for (const [key, data] of rateLimitWindow.entries()) {
    if (data.timestamp < windowStart) {
      rateLimitWindow.delete(key);
    }
  }

  const current = rateLimitWindow.get(ip) || { count: 0, timestamp: now };

  if (current.timestamp < windowStart) {
    current.count = 0;
    current.timestamp = now;
  }

  current.count++;
  rateLimitWindow.set(ip, current);

  if (current.count > RATE_LIMIT_MAX) {
    rateLimitedRequestsCounter.add(1, { service: 'products-service' });
    return false;
  }
  return true;
}

// Circuit breaker check
function checkCircuitBreaker() {
  const now = Date.now();

  // Reset circuit after 30 seconds in open state
  if (circuitBreakerState === 2 && now - lastCircuitCheck > 30000) {
    circuitBreakerState = 1; // Half-open
    lastCircuitCheck = now;
    emitLog('INFO', 'Circuit breaker entering half-open state');
  }

  return circuitBreakerState !== 2;
}

function recordCircuitBreakerSuccess() {
  if (circuitBreakerState === 1) {
    circuitBreakerState = 0; // Closed
    consecutiveFailures = 0;
    emitLog('INFO', 'Circuit breaker closed after successful request');
  }
}

function recordCircuitBreakerFailure() {
  consecutiveFailures++;
  if (consecutiveFailures >= FAILURE_THRESHOLD && circuitBreakerState === 0) {
    circuitBreakerState = 2; // Open
    lastCircuitCheck = Date.now();
    circuitBreakerTripsCounter.add(1, { service: 'database' });
    emitLog('WARNING', 'Circuit breaker opened due to consecutive failures', {
      failures: consecutiveFailures
    });
  }
}

// ===================================================================
// APM MIDDLEWARE - Automatic instrumentation for all endpoints
// ===================================================================

// Connection tracking middleware
app.use((req, res, next) => {
  activeConnections++;

  res.on('finish', () => {
    activeConnections--;
  });

  next();
});

// Rate limiting middleware
app.use((req, res, next) => {
  const clientIp = req.ip || req.connection.remoteAddress || 'unknown';

  if (!checkRateLimit(clientIp)) {
    emitLog('WARNING', 'Rate limit exceeded', { client_ip: clientIp });
    return res.status(429).json({
      error: 'Too Many Requests',
      retryAfter: 60
    });
  }

  next();
});

// Metrics capture middleware
app.use((req, res, next) => {
  const startTime = Date.now();

  const originalJson = res.json.bind(res);
  const originalSend = res.send.bind(res);

  const captureMetrics = (body) => {
    const duration = Date.now() - startTime;
    const endpoint = req.route?.path || req.path || 'unknown';
    const method = req.method;
    const statusCode = res.statusCode;

    requestCounter.add(1, {
      endpoint,
      method,
      http_status_code: statusCode.toString(),
    });

    httpServerDuration.record(duration, {
      endpoint,
      method,
      http_status_code: statusCode.toString(),
    });

    recentResponseTimes.push(duration);
    if (recentResponseTimes.length > MAX_SAMPLES) recentResponseTimes.shift();

    return body;
  };

  res.json = function (body) {
    captureMetrics(body);
    return originalJson(body);
  };

  res.send = function (body) {
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
      version: '2.0.0',
      description: 'E-commerce product catalog API with advanced observability',
      endpoints: [
        'GET /api/products - List all products with optional filtering',
        'GET /api/products/search?q=query - Search products',
        'GET /api/products/:id - Get product details',
        'GET /api/products/:id/reviews - Get product reviews',
        'GET /api/products/:id/recommendations - Get similar products',
        'POST /api/products/:id/purchase - Process purchase',
        'GET /api/inventory/:productId - Check inventory',
        'GET /api/categories - List categories',
        'GET /api/stats - Service statistics',
        'GET /health - Health check'
      ],
      totalProducts: products.length,
      categories: [...new Set(products.map(p => p.category))]
    });
  }, 50);
});

// Get all products with advanced filtering
app.get('/api/products', async (req, res) => {
  const span = trace.getTracer('products-service').startSpan('get-all-products');

  try {
    const { category, minPrice, maxPrice, minRating, sort, limit = 50, offset = 0 } = req.query;

    // Check cache first
    const cacheKey = `products:${JSON.stringify(req.query)}`;
    const cached = getCached(cacheKey);

    if (cached) {
      span.setAttribute('cache.hit', true);
      emitLog('INFO', 'Returning cached products', { cache_hit: true });
      span.end();
      return res.json(cached);
    }

    span.setAttribute('cache.hit', false);

    emitLog('INFO', 'Fetching products', {
      endpoint: '/api/products',
      category: category || 'all',
      filters: { minPrice, maxPrice, minRating }
    });

    // Check circuit breaker
    if (!checkCircuitBreaker()) {
      emitLog('WARNING', 'Circuit breaker is open, returning cached data');
      span.setStatus({ code: SpanStatusCode.ERROR, message: 'Circuit breaker open' });
      span.end();
      return res.status(503).json({ error: 'Service temporarily unavailable' });
    }

    // Simulate database query
    const dbSpan = trace.getTracer('products-service').startSpan('db-query-products', {
      parent: span,
    });
    dbSpan.setAttribute('db.system', 'postgresql');
    dbSpan.setAttribute('db.operation', 'SELECT');
    dbSpan.setAttribute('db.table', 'products');

    await simulateDbLatency('read');

    let filteredProducts = [...products];

    // Apply filters
    if (category) {
      filteredProducts = filteredProducts.filter(p => p.category === category);
    }
    if (minPrice) {
      filteredProducts = filteredProducts.filter(p => p.price >= parseFloat(minPrice));
    }
    if (maxPrice) {
      filteredProducts = filteredProducts.filter(p => p.price <= parseFloat(maxPrice));
    }
    if (minRating) {
      filteredProducts = filteredProducts.filter(p => p.rating >= parseFloat(minRating));
    }

    // Apply sorting
    if (sort) {
      switch (sort) {
        case 'price_asc':
          filteredProducts.sort((a, b) => a.price - b.price);
          break;
        case 'price_desc':
          filteredProducts.sort((a, b) => b.price - a.price);
          break;
        case 'rating':
          filteredProducts.sort((a, b) => b.rating - a.rating);
          break;
        case 'popularity':
          filteredProducts.sort((a, b) => b.popularity - a.popularity);
          break;
      }
    }

    // Apply pagination
    const paginatedProducts = filteredProducts.slice(
      parseInt(offset),
      parseInt(offset) + parseInt(limit)
    );

    dbSpan.end();
    recordCircuitBreakerSuccess();

    productViewCounter.add(paginatedProducts.length, {
      category: category || 'all',
    });

    const response = {
      products: paginatedProducts,
      total: filteredProducts.length,
      limit: parseInt(limit),
      offset: parseInt(offset),
      hasMore: parseInt(offset) + parseInt(limit) < filteredProducts.length
    };

    // Cache the response
    setCache(cacheKey, response);

    emitLog('INFO', 'Products retrieved successfully', {
      count: paginatedProducts.length,
      total: filteredProducts.length,
      category: category || 'all'
    });

    span.setAttribute('products.count', paginatedProducts.length);
    span.end();

    res.json(response);
  } catch (error) {
    recordCircuitBreakerFailure();
    span.setStatus({ code: SpanStatusCode.ERROR, message: error.message });
    span.end();

    emitLog('ERROR', 'Error fetching products', {
      error: error.message
    });

    res.status(500).json({ error: 'Internal server error' });
  }
});

// Search products
app.get('/api/products/search', async (req, res) => {
  const span = trace.getTracer('products-service').startSpan('search-products');

  try {
    const { q, limit = 20 } = req.query;

    if (!q) {
      span.end();
      return res.status(400).json({ error: 'Search query required' });
    }

    span.setAttribute('search.query', q);
    searchQueryCounter.add(1, { service: 'products-service' });

    emitLog('INFO', 'Searching products', {
      endpoint: '/api/products/search',
      query: q
    });

    // Simulate search latency (slightly slower than regular queries)
    await simulateDbLatency('read');
    await new Promise(resolve => setTimeout(resolve, 50));

    const searchTerm = q.toLowerCase();
    const results = products.filter(p =>
      p.name.toLowerCase().includes(searchTerm) ||
      p.description.toLowerCase().includes(searchTerm) ||
      p.tags.some(t => t.includes(searchTerm)) ||
      p.category.includes(searchTerm) ||
      p.brand.toLowerCase().includes(searchTerm)
    ).slice(0, parseInt(limit));

    // Sort by relevance (popularity for now)
    results.sort((a, b) => b.popularity - a.popularity);

    searchResultsHistogram.record(results.length, { query_type: 'text' });

    emitLog('INFO', 'Search completed', {
      query: q,
      results_count: results.length
    });

    span.setAttribute('search.results_count', results.length);
    span.end();

    res.json({
      query: q,
      results,
      total: results.length
    });
  } catch (error) {
    span.setStatus({ code: SpanStatusCode.ERROR, message: error.message });
    span.end();

    emitLog('ERROR', 'Search error', {
      error: error.message
    });

    res.status(500).json({ error: 'Search failed' });
  }
});

// Get product by ID
app.get('/api/products/:id', async (req, res) => {
  const span = trace.getTracer('products-service').startSpan('get-product-by-id');
  const productId = parseInt(req.params.id);

  try {
    span.setAttribute('product.id', productId);

    // Check cache
    const cacheKey = `product:${productId}`;
    const cached = getCached(cacheKey);

    if (cached) {
      span.setAttribute('cache.hit', true);
      productViewCounter.add(1, {
        product_id: productId.toString(),
        product_name: cached.product.name,
        cache_hit: 'true'
      });
      span.end();
      return res.json(cached);
    }

    emitLog('INFO', 'Fetching product details', {
      endpoint: '/api/products/:id',
      product_id: productId
    });

    await simulateDbLatency('read');

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
    span.setAttribute('product.category', product.category);

    productViewCounter.add(1, {
      product_id: productId.toString(),
      product_name: product.name,
    });

    const response = { product };
    setCache(cacheKey, response);

    emitLog('INFO', 'Product details retrieved', {
      product_id: productId,
      product_name: product.name,
      price: product.price
    });

    span.end();
    res.json(response);
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

// Get product reviews
app.get('/api/products/:id/reviews', async (req, res) => {
  const span = trace.getTracer('products-service').startSpan('get-product-reviews');
  const productId = parseInt(req.params.id);

  try {
    span.setAttribute('product.id', productId);

    const product = products.find(p => p.id === productId);
    if (!product) {
      span.end();
      return res.status(404).json({ error: 'Product not found' });
    }

    await simulateDbLatency('read');

    const reviews = productReviews.get(productId) || [];

    emitLog('INFO', 'Reviews retrieved', {
      product_id: productId,
      review_count: reviews.length
    });

    span.setAttribute('reviews.count', reviews.length);
    span.end();

    res.json({
      productId,
      productName: product.name,
      averageRating: product.rating,
      totalReviews: product.reviewCount,
      reviews
    });
  } catch (error) {
    span.setStatus({ code: SpanStatusCode.ERROR, message: error.message });
    span.end();
    res.status(500).json({ error: 'Internal server error' });
  }
});

// Get product recommendations
app.get('/api/products/:id/recommendations', async (req, res) => {
  const span = trace.getTracer('products-service').startSpan('get-recommendations');
  const productId = parseInt(req.params.id);

  try {
    span.setAttribute('product.id', productId);

    const product = products.find(p => p.id === productId);
    if (!product) {
      span.end();
      return res.status(404).json({ error: 'Product not found' });
    }

    emitLog('INFO', 'Generating recommendations', {
      product_id: productId,
      category: product.category
    });

    // Simulate ML model latency
    await new Promise(resolve => setTimeout(resolve, 30 + Math.random() * 70));

    // Get recommendations based on category and price range
    const priceRange = product.price * 0.5;
    const recommendations = products
      .filter(p =>
        p.id !== productId &&
        (p.category === product.category ||
          p.tags.some(t => product.tags.includes(t)))
      )
      .sort((a, b) => b.popularity - a.popularity)
      .slice(0, 4);

    recommendationsServedCounter.add(recommendations.length, {
      source_product: productId.toString(),
      algorithm: 'category_similarity'
    });

    span.setAttribute('recommendations.count', recommendations.length);
    span.end();

    res.json({
      productId,
      recommendations,
      algorithm: 'category_similarity'
    });
  } catch (error) {
    span.setStatus({ code: SpanStatusCode.ERROR, message: error.message });
    span.end();
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

    // Add span event for purchase initiation
    span.addEvent('purchase_initiated', {
      product_id: productId,
      quantity: quantity
    });

    emitLog('INFO', 'Processing purchase request', {
      endpoint: '/api/products/:id/purchase',
      product_id: productId,
      quantity
    });

    checkoutAttemptCounter.add(1, {
      product_id: productId.toString()
    });

    // Inventory check span
    const inventorySpan = trace.getTracer('products-service').startSpan('check-inventory', {
      parent: span,
    });

    await simulateDbLatency('read');

    const product = products.find(p => p.id === productId);

    if (!product) {
      inventorySpan.end();
      span.addEvent('purchase_failed', { reason: 'product_not_found' });
      span.setStatus({ code: SpanStatusCode.ERROR, message: 'Product not found' });

      cartAbandonmentCounter.add(1, {
        reason: 'product_not_found'
      });

      emitLog('WARNING', 'Purchase failed - product not found', {
        product_id: productId
      });

      span.end();
      return res.status(404).json({ error: 'Product not found' });
    }

    if (product.stock < quantity) {
      inventorySpan.setAttribute('inventory.sufficient', false);
      inventorySpan.end();
      span.addEvent('purchase_failed', { reason: 'insufficient_stock' });
      span.setStatus({ code: SpanStatusCode.ERROR, message: 'Insufficient stock' });

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

      span.end();
      return res.status(400).json({
        error: 'Insufficient stock',
        available: product.stock,
        requested: quantity
      });
    }

    inventorySpan.setAttribute('inventory.sufficient', true);
    inventorySpan.end();

    // Payment processing span
    const paymentSpan = trace.getTracer('products-service').startSpan('process-payment', {
      parent: span,
    });
    const transactionAmount = product.price * quantity;
    paymentSpan.setAttribute('payment.amount', transactionAmount);
    paymentSpan.setAttribute('payment.currency', 'USD');

    // Simulate payment processing with variable latency
    await new Promise(resolve => setTimeout(resolve, 100 + Math.random() * 200));

    // Simulate payment failures (5% chance)
    if (Math.random() < 0.05) {
      paymentSpan.addEvent('payment_declined', { reason: 'card_declined' });
      paymentSpan.setStatus({ code: SpanStatusCode.ERROR, message: 'Payment declined' });
      paymentSpan.end();
      span.addEvent('purchase_failed', { reason: 'payment_declined' });
      span.setStatus({ code: SpanStatusCode.ERROR, message: 'Payment failed' });

      cartAbandonmentCounter.add(1, {
        reason: 'payment_declined',
        product_id: productId.toString()
      });
      revenueAtRiskCounter.add(transactionAmount, {
        reason: 'payment_declined',
        product_name: product.name
      });

      emitLog('ERROR', 'Purchase failed - payment declined', {
        product_id: productId,
        amount: transactionAmount,
        lost_revenue: transactionAmount
      });

      span.end();
      return res.status(402).json({ error: 'Payment declined' });
    }

    paymentSpan.addEvent('payment_successful');
    paymentSpan.end();

    // Update inventory
    product.stock -= quantity;

    // Record successful purchase metrics
    purchaseCounter.add(1, {
      product_id: productId.toString(),
      product_name: product.name,
      category: product.category
    });

    checkoutSuccessCounter.add(1, {
      product_id: productId.toString()
    });

    transactionValueHistogram.record(transactionAmount, {
      product_id: productId.toString(),
      product_name: product.name,
      category: product.category
    });

    // Invalidate cache
    productCache.delete(`product:${productId}`);

    span.addEvent('purchase_completed', {
      transaction_amount: transactionAmount,
      remaining_stock: product.stock
    });

    emitLog('INFO', 'Purchase completed successfully', {
      product_id: productId,
      product_name: product.name,
      quantity,
      total_amount: transactionAmount,
      remaining_stock: product.stock
    });

    const responseTime = Date.now() - startTime;
    recentResponseTimes.push(responseTime);
    if (recentResponseTimes.length > MAX_SAMPLES) recentResponseTimes.shift();

    span.setAttribute('purchase.success', true);
    span.setAttribute('purchase.total', transactionAmount);
    span.setAttribute('response.time_ms', responseTime);
    span.end();

    res.json({
      success: true,
      product: product.name,
      quantity,
      total: transactionAmount,
      remaining_stock: product.stock,
      orderId: `ORD-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`
    });
  } catch (error) {
    span.addEvent('purchase_error', { error: error.message });
    span.setStatus({ code: SpanStatusCode.ERROR, message: error.message });

    cartAbandonmentCounter.add(1, {
      reason: 'system_error'
    });

    emitLog('ERROR', 'Error processing purchase', {
      error: error.message,
      product_id: productId
    });

    span.end();
    res.status(500).json({ error: 'Internal server error' });
  }
});

// Get inventory for a product
app.get('/api/inventory/:productId', async (req, res) => {
  const span = trace.getTracer('products-service').startSpan('check-inventory');
  const productId = parseInt(req.params.productId);

  try {
    span.setAttribute('product.id', productId);

    emitLog('INFO', 'Checking inventory', {
      endpoint: '/api/inventory/:productId',
      product_id: productId
    });

    await simulateDbLatency('read');

    const product = products.find(p => p.id === productId);

    if (!product) {
      span.setStatus({ code: SpanStatusCode.ERROR, message: 'Product not found' });
      emitLog('WARNING', 'Inventory check - product not found', { product_id: productId });
      span.end();
      return res.status(404).json({ error: 'Product not found' });
    }

    // Determine stock status
    let stockStatus = 'in_stock';
    if (product.stock === 0) {
      stockStatus = 'out_of_stock';
    } else if (product.stock < 5) {
      stockStatus = 'low_stock';
    }

    emitLog('INFO', 'Inventory check complete', {
      product_id: productId,
      stock: product.stock,
      status: stockStatus
    });

    span.setAttribute('inventory.stock', product.stock);
    span.setAttribute('inventory.status', stockStatus);
    span.end();

    res.json({
      product_id: productId,
      product_name: product.name,
      stock: product.stock,
      available: product.stock > 0,
      status: stockStatus,
      reservable: product.stock
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

    await simulateDbLatency('read');

    const categoryStats = {};
    products.forEach(p => {
      if (!categoryStats[p.category]) {
        categoryStats[p.category] = { count: 0, avgPrice: 0, totalStock: 0 };
      }
      categoryStats[p.category].count++;
      categoryStats[p.category].avgPrice += p.price;
      categoryStats[p.category].totalStock += p.stock;
    });

    const categories = Object.entries(categoryStats).map(([name, stats]) => ({
      name,
      productCount: stats.count,
      averagePrice: (stats.avgPrice / stats.count).toFixed(2),
      totalStock: stats.totalStock
    }));

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

// Service statistics endpoint
app.get('/api/stats', async (req, res) => {
  const span = trace.getTracer('products-service').startSpan('get-stats');

  try {
    const total = cacheHits + cacheMisses;
    const cacheHitRate = total > 0 ? ((cacheHits / total) * 100).toFixed(2) : 0;

    const stats = {
      service: 'products-service',
      version: '2.0.0',
      uptime: process.uptime(),
      products: {
        total: products.length,
        categories: [...new Set(products.map(p => p.category))].length,
        totalStock: products.reduce((sum, p) => sum + p.stock, 0),
        averagePrice: (products.reduce((sum, p) => sum + p.price, 0) / products.length).toFixed(2)
      },
      cache: {
        hits: cacheHits,
        misses: cacheMisses,
        hitRate: `${cacheHitRate}%`,
        size: productCache.size
      },
      circuitBreaker: {
        state: circuitBreakerState === 0 ? 'closed' : circuitBreakerState === 1 ? 'half-open' : 'open',
        consecutiveFailures
      },
      connections: {
        active: activeConnections
      }
    };

    span.end();
    res.json(stats);
  } catch (error) {
    span.setStatus({ code: SpanStatusCode.ERROR, message: error.message });
    span.end();
    res.status(500).json({ error: 'Internal server error' });
  }
});

// Health check endpoint
app.get('/health', (req, res) => {
  const isHealthy = circuitBreakerState !== 2;

  emitLog('INFO', 'Health check', {
    status: isHealthy ? 'healthy' : 'degraded',
    circuitBreaker: circuitBreakerState
  });

  res.status(isHealthy ? 200 : 503).json({
    status: isHealthy ? 'healthy' : 'degraded',
    service: 'products-service',
    version: '2.0.0',
    timestamp: new Date().toISOString(),
    checks: {
      database: circuitBreakerState === 0 ? 'healthy' : 'degraded',
      cache: 'healthy'
    }
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
    span.addEvent('simulated_error_triggered');
    span.setStatus({ code: SpanStatusCode.ERROR, message: 'Simulated service error' });
  }

  res.status(500).json({
    status: 'error',
    message: 'Simulated internal server error',
    errorId: `ERR-${Date.now()}`
  });
});

// Slow endpoint for testing latency alerts
app.get('/api/slow', async (req, res) => {
  const span = trace.getTracer('products-service').startSpan('slow-endpoint');

  const delay = parseInt(req.query.delay) || 3000;

  emitLog('INFO', 'Slow endpoint called', { delay });

  await new Promise(resolve => setTimeout(resolve, delay));

  span.setAttribute('artificial_delay_ms', delay);
  span.end();

  res.json({
    message: 'Slow response completed',
    delay_ms: delay
  });
});

app.listen(port, () => {
  emitLog('INFO', 'Products Service Started', {
    port: port,
    version: '2.0.0',
    total_products: products.length,
    features: ['caching', 'rate_limiting', 'circuit_breaker', 'search', 'recommendations']
  });
  console.log(`Products Service v2.0.0 running on port ${port}`);
  console.log(`Total products: ${products.length}`);
  console.log(`Categories: ${[...new Set(products.map(p => p.category))].join(', ')}`);
});
