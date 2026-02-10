package com.demo.shipping.controller;

import com.demo.shipping.model.ShipmentStatus;
import com.demo.shipping.model.ShippingQuote;
import com.demo.shipping.model.ShippingRequest;
import com.demo.shipping.service.ShippingService;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.HashMap;
import java.util.Map;
import java.util.Random;

@RestController
@RequestMapping("/api")
public class ShippingController {

    private static final Logger logger = LoggerFactory.getLogger(ShippingController.class);
    private final ShippingService shippingService;
    private final Random random = new Random();

    public ShippingController(ShippingService shippingService) {
        this.shippingService = shippingService;
    }

    @GetMapping("/")
    public Map<String, Object> getServiceInfo() {
        logger.info("Service info requested");
        Map<String, Object> info = new HashMap<>();
        info.put("service", "shipping-service");
        info.put("version", "1.0.0");
        info.put("instrumentation", "Beyla eBPF (no SDK)");
        info.put("description", "Shipping service auto-instrumented by Beyla without any code changes");
        info.put("endpoints", new String[]{
            "POST /api/shipping/quote - Get shipping quote",
            "POST /api/shipping/create - Create shipment",
            "GET /api/shipping/track/{trackingId} - Track shipment",
            "GET /api/shipping/order/{orderId} - Get shipment by order ID"
        });
        return info;
    }

    @PostMapping("/shipping/quote")
    public ResponseEntity<ShippingQuote> getShippingQuote(@RequestBody ShippingRequest request) {
        logger.info("Calculating shipping quote for order: {}", request.getOrderId());

        // Simulate occasional errors (Beyla will capture these as error metrics)
        if (random.nextInt(20) == 0) {
            logger.error("Failed to calculate shipping quote - external service unavailable");
            return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE).build();
        }

        ShippingQuote quote = shippingService.calculateShipping(request);
        logger.info("Quote generated: {} for order {} - ${}", quote.getQuoteId(), request.getOrderId(), quote.getCost());

        return ResponseEntity.ok(quote);
    }

    @PostMapping("/shipping/create")
    public ResponseEntity<ShipmentStatus> createShipment(@RequestBody ShippingRequest request) {
        logger.info("Creating shipment for order: {}", request.getOrderId());

        // Validate request
        if (request.getOrderId() == null || request.getOrderId().isEmpty()) {
            logger.warn("Invalid shipment request - missing orderId");
            return ResponseEntity.badRequest().build();
        }

        // Simulate occasional errors
        if (random.nextInt(25) == 0) {
            logger.error("Failed to create shipment - carrier API error");
            return ResponseEntity.status(HttpStatus.INTERNAL_SERVER_ERROR).build();
        }

        ShipmentStatus shipment = shippingService.createShipment(request);
        logger.info("Shipment created: {} for order {}", shipment.getTrackingId(), request.getOrderId());

        return ResponseEntity.status(HttpStatus.CREATED).body(shipment);
    }

    @GetMapping("/shipping/track/{trackingId}")
    public ResponseEntity<ShipmentStatus> trackShipment(@PathVariable String trackingId) {
        logger.info("Tracking shipment: {}", trackingId);

        ShipmentStatus status = shippingService.getShipmentStatus(trackingId);
        if (status == null) {
            logger.warn("Shipment not found: {}", trackingId);
            return ResponseEntity.notFound().build();
        }

        logger.info("Shipment {} status: {}", trackingId, status.getStatus());
        return ResponseEntity.ok(status);
    }

    @GetMapping("/shipping/order/{orderId}")
    public ResponseEntity<ShipmentStatus> getShipmentByOrder(@PathVariable String orderId) {
        logger.info("Looking up shipment for order: {}", orderId);

        ShipmentStatus status = shippingService.getShipmentByOrderId(orderId);
        if (status == null) {
            logger.warn("No shipment found for order: {}", orderId);
            return ResponseEntity.notFound().build();
        }

        return ResponseEntity.ok(status);
    }

    @GetMapping("/health")
    public Map<String, String> healthCheck() {
        Map<String, String> health = new HashMap<>();
        health.put("status", "healthy");
        health.put("service", "shipping-service");
        return health;
    }

    // Endpoint to simulate slow responses (for testing Beyla latency metrics)
    @GetMapping("/slow")
    public Map<String, Object> slowEndpoint() throws InterruptedException {
        int delay = 1000 + random.nextInt(2000);
        logger.info("Slow endpoint called, sleeping for {}ms", delay);
        Thread.sleep(delay);

        Map<String, Object> response = new HashMap<>();
        response.put("message", "This was a slow response");
        response.put("delayMs", delay);
        return response;
    }

    // Endpoint to simulate errors (for testing Beyla error metrics)
    @GetMapping("/error")
    public ResponseEntity<Map<String, String>> errorEndpoint() {
        logger.error("Intentional error endpoint called");
        Map<String, String> error = new HashMap<>();
        error.put("error", "Intentional error for testing");
        error.put("message", "This endpoint always returns 500 to test Beyla error tracking");
        return ResponseEntity.status(HttpStatus.INTERNAL_SERVER_ERROR).body(error);
    }
}
