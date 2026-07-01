#!/bin/sh
set -e

BASE="http://kibana:5601"
AUTH="elastic:${ELASTICSEARCH_PASSWORD}"

echo "[kibana-init] Waiting for Kibana to be ready..."
until curl -sf -u "${AUTH}" "${BASE}/api/status" | grep -q '"level":"available"' > /dev/null 2>&1; do
  echo "[kibana-init] Not ready yet, retrying in 5s..."
  sleep 5
done

echo "[kibana-init] Creating trino-query-audit data view..."
curl -sf -X POST -u "${AUTH}" "${BASE}/api/data_views/data_view" \
  -H "Content-Type: application/json" \
  -H "kbn-xsrf: true" \
  -d '{
    "data_view": {
      "title": "trino-query-audit*",
      "name": "Trino Query Audit",
      "timeFieldName": "@timestamp"
    }
  }' && echo || echo "[kibana-init] Data view may already exist, skipping."

echo "[kibana-init] Done."
