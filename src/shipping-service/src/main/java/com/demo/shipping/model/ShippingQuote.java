package com.demo.shipping.model;

public class ShippingQuote {
    private String quoteId;
    private String orderId;
    private double cost;
    private String currency;
    private int estimatedDays;
    private String carrier;
    private String shippingMethod;

    public ShippingQuote() {}

    public ShippingQuote(String quoteId, String orderId, double cost, String currency,
                         int estimatedDays, String carrier, String shippingMethod) {
        this.quoteId = quoteId;
        this.orderId = orderId;
        this.cost = cost;
        this.currency = currency;
        this.estimatedDays = estimatedDays;
        this.carrier = carrier;
        this.shippingMethod = shippingMethod;
    }

    // Getters and Setters
    public String getQuoteId() { return quoteId; }
    public void setQuoteId(String quoteId) { this.quoteId = quoteId; }

    public String getOrderId() { return orderId; }
    public void setOrderId(String orderId) { this.orderId = orderId; }

    public double getCost() { return cost; }
    public void setCost(double cost) { this.cost = cost; }

    public String getCurrency() { return currency; }
    public void setCurrency(String currency) { this.currency = currency; }

    public int getEstimatedDays() { return estimatedDays; }
    public void setEstimatedDays(int estimatedDays) { this.estimatedDays = estimatedDays; }

    public String getCarrier() { return carrier; }
    public void setCarrier(String carrier) { this.carrier = carrier; }

    public String getShippingMethod() { return shippingMethod; }
    public void setShippingMethod(String shippingMethod) { this.shippingMethod = shippingMethod; }
}
