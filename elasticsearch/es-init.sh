#!/bin/sh
set -e

BASE="http://elasticsearch:9200"
AUTH="elastic:${ELASTICSEARCH_PASSWORD}"

echo "[es-init] Waiting for Elasticsearch to be ready..."
until curl -sf -u "${AUTH}" "${BASE}/_cluster/health" > /dev/null 2>&1; do
  echo "[es-init] Not ready yet, retrying in 5s..."
  sleep 5
done

echo "[es-init] Setting kibana_system password..."
curl -sf -X POST -u "${AUTH}" "${BASE}/_security/user/kibana_system/_password" \
  -H "Content-Type: application/json" \
  -d "{\"password\": \"${ELASTICSEARCH_PASSWORD}\"}"
echo

echo "[es-init] Creating Trino audit ingest pipeline..."
curl -sf -X PUT -u "${AUTH}" "${BASE}/_ingest/pipeline/add-timestamp" \
  -H "Content-Type: application/json" \
  -d '{
    "description": "Adds @timestamp to Trino query audit documents",
    "processors": [{"set": {"field": "@timestamp", "value": "{{_ingest.timestamp}}"}}]
  }'
echo

echo "[es-init] Done."
