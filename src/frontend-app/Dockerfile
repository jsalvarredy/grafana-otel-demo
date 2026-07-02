# Faro Shop frontend - nginx serving a tiny instrumented SPA.
#
# The Grafana Faro Web SDK + web tracing bundles are vendored INTO the image at
# a pinned version and served same-origin from /vendor, so the presenter's
# browser needs NO egress to a public CDN (unpkg). This makes the RUM demo
# reproducible and fully offline-capable. index.html and the nginx config are
# still provided by the Helm ConfigMap (mounted via subPath, which does not
# hide the /vendor directory baked in here).

ARG FARO_SDK_VERSION=1.19.0
ARG FARO_TRACING_VERSION=1.19.0

# Stage 1: fetch the pinned Faro bundles (build-time egress to unpkg only).
FROM alpine:3.20 AS fetch
ARG FARO_SDK_VERSION
ARG FARO_TRACING_VERSION
RUN apk add --no-cache curl && \
    mkdir -p /vendor && \
    curl -fsSL -o /vendor/faro-web-sdk.iife.js \
      "https://unpkg.com/@grafana/faro-web-sdk@${FARO_SDK_VERSION}/dist/bundle/faro-web-sdk.iife.js" && \
    curl -fsSL -o /vendor/faro-web-tracing.iife.js \
      "https://unpkg.com/@grafana/faro-web-tracing@${FARO_TRACING_VERSION}/dist/bundle/faro-web-tracing.iife.js"

# Stage 2: nginx serving the vendored assets same-origin.
FROM nginx:1.27-alpine
COPY --from=fetch /vendor/ /usr/share/nginx/html/vendor/
EXPOSE 80
