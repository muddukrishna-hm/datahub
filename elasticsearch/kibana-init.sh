#!/bin/sh
# Creates the Trino Query Audit data view in Kibana on first boot.
# ELASTICSEARCH_PASSWORD is injected via docker-compose environment:.
set -e

KIBANA_URL="${KIBANA_URL:-http://kibana:5601/kibana}"
ES_PASS="${ELASTICSEARCH_PASSWORD}"

echo "[kibana-init] Waiting for Kibana to be ready..."
until curl -sf -u "elastic:${ES_PASS}" "${KIBANA_URL}/api/status" \
  | grep -q '"level":"available"'; do
  sleep 5
done

echo "[kibana-init] Creating Trino query audit data view..."
result=$(curl -s -u "elastic:${ES_PASS}" \
  -X POST "${KIBANA_URL}/api/data_views/data_view" \
  -H "kbn-xsrf: true" \
  -H "Content-Type: application/json" \
  -d '{
    "data_view": {
      "title": "trino-query-audit*",
      "name": "Trino Query Audit",
      "timeFieldName": "@timestamp"
    }
  }')

if echo "$result" | grep -q '"id"'; then
  echo "[kibana-init] Data view created."
else
  echo "[kibana-init] Data view may already exist or failed: $result"
fi

echo "[kibana-init] Done."
