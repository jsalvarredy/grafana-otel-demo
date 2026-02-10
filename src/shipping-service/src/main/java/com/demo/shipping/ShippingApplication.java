package com.demo.shipping;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * Shipping Service - A simple microservice WITHOUT OpenTelemetry instrumentation.
 *
 * This service demonstrates Beyla's eBPF-based auto-instrumentation capability.
 * Beyla will automatically capture:
 * - HTTP request traces
 * - RED metrics (Rate, Errors, Duration)
 *
 * No code changes or SDK dependencies are required!
 */
@SpringBootApplication
public class ShippingApplication {
    public static void main(String[] args) {
        SpringApplication.run(ShippingApplication.class, args);
    }
}
