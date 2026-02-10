package com.demo.shipping.service;

import com.demo.shipping.model.ShipmentStatus;
import com.demo.shipping.model.ShippingQuote;
import com.demo.shipping.model.ShippingRequest;
import org.springframework.stereotype.Service;

import java.time.LocalDateTime;
import java.util.Map;
import java.util.Random;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

@Service
public class ShippingService {

    private final Random random = new Random();
    private final Map<String, ShipmentStatus> shipments = new ConcurrentHashMap<>();

    private static final String[] CARRIERS = {"FedEx", "UPS", "DHL", "USPS"};
    private static final String[] LOCATIONS = {
        "Distribution Center - New York",
        "Sorting Facility - Chicago",
        "Regional Hub - Los Angeles",
        "Local Delivery Center",
        "In Transit - Highway I-95"
    };
    private static final String[] STATUSES = {
        "pending", "picked_up", "in_transit", "out_for_delivery", "delivered"
    };

    public ShippingQuote calculateShipping(ShippingRequest request) {
        // Simulate processing time (Beyla will capture this latency)
        simulateProcessing(50, 200);

        String carrier = selectCarrier(request);
        double baseCost = calculateBaseCost(request);
        int estimatedDays = calculateDeliveryDays(request);

        String quoteId = "QT-" + UUID.randomUUID().toString().substring(0, 8).toUpperCase();

        return new ShippingQuote(
            quoteId,
            request.getOrderId(),
            baseCost,
            "USD",
            estimatedDays,
            carrier,
            request.getShippingMethod() != null ? request.getShippingMethod() : "standard"
        );
    }

    public ShipmentStatus createShipment(ShippingRequest request) {
        // Simulate shipment creation
        simulateProcessing(100, 300);

        String trackingId = "TRK-" + UUID.randomUUID().toString().substring(0, 12).toUpperCase();
        String carrier = selectCarrier(request);
        int deliveryDays = calculateDeliveryDays(request);

        ShipmentStatus status = new ShipmentStatus(
            trackingId,
            request.getOrderId(),
            "pending",
            "Awaiting pickup",
            LocalDateTime.now(),
            LocalDateTime.now().plusDays(deliveryDays),
            carrier
        );

        shipments.put(trackingId, status);
        return status;
    }

    public ShipmentStatus getShipmentStatus(String trackingId) {
        // Simulate database lookup
        simulateProcessing(20, 100);

        ShipmentStatus status = shipments.get(trackingId);
        if (status != null) {
            // Simulate status progression
            status = simulateStatusProgression(status);
            shipments.put(trackingId, status);
        }
        return status;
    }

    public ShipmentStatus getShipmentByOrderId(String orderId) {
        simulateProcessing(30, 150);

        return shipments.values().stream()
            .filter(s -> orderId.equals(s.getOrderId()))
            .findFirst()
            .map(this::simulateStatusProgression)
            .orElse(null);
    }

    private String selectCarrier(ShippingRequest request) {
        // Simple carrier selection logic
        if ("overnight".equals(request.getShippingMethod())) {
            return "FedEx";
        } else if ("express".equals(request.getShippingMethod())) {
            return random.nextBoolean() ? "UPS" : "DHL";
        }
        return CARRIERS[random.nextInt(CARRIERS.length)];
    }

    private double calculateBaseCost(ShippingRequest request) {
        double weight = request.getTotalWeight() > 0 ? request.getTotalWeight() : 1.0;
        double baseCost = 5.99 + (weight * 0.50);

        String method = request.getShippingMethod();
        if ("express".equals(method)) {
            baseCost *= 1.5;
        } else if ("overnight".equals(method)) {
            baseCost *= 2.5;
        }

        // International shipping
        if (request.getDestinationCountry() != null &&
            !request.getDestinationCountry().equalsIgnoreCase("US") &&
            !request.getDestinationCountry().equalsIgnoreCase("USA")) {
            baseCost += 15.00;
        }

        return Math.round(baseCost * 100.0) / 100.0;
    }

    private int calculateDeliveryDays(ShippingRequest request) {
        String method = request.getShippingMethod();
        if ("overnight".equals(method)) {
            return 1;
        } else if ("express".equals(method)) {
            return 2 + random.nextInt(2);
        }
        return 5 + random.nextInt(3); // Standard: 5-7 days
    }

    private ShipmentStatus simulateStatusProgression(ShipmentStatus status) {
        // Randomly progress the shipment status
        int currentIndex = java.util.Arrays.asList(STATUSES).indexOf(status.getStatus());
        if (currentIndex < STATUSES.length - 1 && random.nextInt(3) == 0) {
            currentIndex++;
            status.setStatus(STATUSES[currentIndex]);
            status.setCurrentLocation(LOCATIONS[Math.min(currentIndex, LOCATIONS.length - 1)]);
            status.setLastUpdate(LocalDateTime.now());
        }
        return status;
    }

    private void simulateProcessing(int minMs, int maxMs) {
        try {
            Thread.sleep(minMs + random.nextInt(maxMs - minMs));
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }
}
