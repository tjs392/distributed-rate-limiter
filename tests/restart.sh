#!/bin/bash
# tests/restart.sh
# Tear down and restart the full stack (rate limiter cluster + envoy + backend)

set -e

echo "Tearing down..."
docker compose -f envoy/docker-compose.yml down --timeout 2 2>/dev/null || true
docker compose down --timeout 2 2>/dev/null || true

echo "Starting rate limiter cluster..."
docker compose up -d --build
echo "Waiting for cluster to form..."
sleep 5

echo "Starting envoy + backend..."
docker compose -f envoy/docker-compose.yml up -d --build
sleep 2

echo ""
echo "Ready. Run tests with:"
echo "  ./tests/rules.sh"
echo "  ./tests/envoy_e2e.sh"
echo "  ./tests/stress.sh"