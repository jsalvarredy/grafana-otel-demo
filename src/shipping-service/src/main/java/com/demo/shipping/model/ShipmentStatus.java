package com.demo.shipping.model;

import java.time.LocalDateTime;

public class ShipmentStatus {
    private String trackingId;
    private String orderId;
    private String status; // "pending", "picked_up", "in_transit", "out_for_delivery", "delivered"
    private String currentLocation;
    private LocalDateTime lastUpdate;
    private LocalDateTime estimatedDelivery;
    private String carrier;

    public ShipmentStatus() {}

    public ShipmentStatus(String trackingId, String orderId, String status,
                          String currentLocation, LocalDateTime lastUpdate,
                          LocalDateTime estimatedDelivery, String carrier) {
        this.trackingId = trackingId;
        this.orderId = orderId;
        this.status = status;
        this.currentLocation = currentLocation;
        this.lastUpdate = lastUpdate;
        this.estimatedDelivery = estimatedDelivery;
        this.carrier = carrier;
    }

    // Getters and Setters
    public String getTrackingId() { return trackingId; }
    public void setTrackingId(String trackingId) { this.trackingId = trackingId; }

    public String getOrderId() { return orderId; }
    public void setOrderId(String orderId) { this.orderId = orderId; }

    public String getStatus() { return status; }
    public void setStatus(String status) { this.status = status; }

    public String getCurrentLocation() { return currentLocation; }
    public void setCurrentLocation(String currentLocation) { this.currentLocation = currentLocation; }

    public LocalDateTime getLastUpdate() { return lastUpdate; }
    public void setLastUpdate(LocalDateTime lastUpdate) { this.lastUpdate = lastUpdate; }

    public LocalDateTime getEstimatedDelivery() { return estimatedDelivery; }
    public void setEstimatedDelivery(LocalDateTime estimatedDelivery) { this.estimatedDelivery = estimatedDelivery; }

    public String getCarrier() { return carrier; }
    public void setCarrier(String carrier) { this.carrier = carrier; }
}
