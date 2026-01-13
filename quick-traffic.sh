#!/bin/bash
echo "🚀 Generating continuous traffic..."
echo "   Press Ctrl+C to stop"
echo ""
while true; do
  # Mix of requests
  curl -s -H "Host: otel-example.localhost" http://otel-example.localhost/api/products > /dev/null 2>&1 &
  curl -s -H "Host: otel-example.localhost" http://otel-example.localhost/api/products/$((RANDOM % 8 + 1)) > /dev/null 2>&1 &
  
  # Order every 3 iterations
  if (( RANDOM % 3 == 0 )); then
    curl -s -H "Host: python-otel-example.localhost" -X POST \
      -H "Content-Type: application/json" \
      -d "{\"product_id\": $((RANDOM % 8 + 1)), \"quantity\": 1, \"user_id\": \"user-$((RANDOM % 50 + 1))\"}" \
      http://python-otel-example.localhost/api/orders > /dev/null 2>&1 &
  fi
  
  echo -n "."
  sleep 2
done
