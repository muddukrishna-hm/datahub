#!/bin/sh
# Sets the kibana_system user password and creates the add-timestamp ingest pipeline.
# ELASTICSEARCH_PASSWORD is injected via docker-compose environment:.
set -e

ES_URL="${ES_URL:-http://elasticsearch:9200}"
PASS="${ELASTICSEARCH_PASSWORD}"

echo "[es-init] Waiting for Elasticsearch..."
until curl -sf -u "elastic:${PASS}" "${ES_URL}/_cluster/health?wait_for_status=yellow&timeout=5s" >/dev/null; do
  sleep 5
done

echo "[es-init] Setting kibana_system password..."
curl -sf -X POST -u "elastic:${PASS}" \
  "${ES_URL}/_security/user/kibana_system/_password" \
  -H "Content-Type: application/json" \
  -d "{\"password\":\"${PASS}\"}"

echo "[es-init] Creating add-timestamp ingest pipeline..."
curl -sf -X PUT -u "elastic:${PASS}" \
  "${ES_URL}/_ingest/pipeline/add-timestamp" \
  -H "Content-Type: application/json" \
  -d '{
    "description": "Adds @timestamp to Trino audit events at ingestion time",
    "processors": [
      {
        "set": {
          "field": "@timestamp",
          "value": "{{_ingest.timestamp}}"
        }
      }
    ]
  }'

echo "[es-init] Done."
