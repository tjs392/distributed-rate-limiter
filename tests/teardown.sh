echo "Tearing down..."
docker compose -f envoy/docker-compose.yml down --timeout 2 2>/dev/null || true
docker compose down --timeout 2 2>/dev/null || true
