#!/bin/sh

RANGER_URL="${RANGER_URL:-http://ranger:6080}"
AUTH="admin:${RANGER_ADMIN_PASSWORD}"

echo "[ranger-init] Waiting for Ranger Admin API..."
until curl -sf -u "${AUTH}" "${RANGER_URL}/service/plugins/definitions" >/dev/null 2>&1; do
  sleep 5
done
echo "[ranger-init] Ranger ready."

# ── Register Trino service definition (built-in in 2.8.0, skip if present) ───
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -u "${AUTH}" \
  "${RANGER_URL}/service/plugins/definitions/name/trino")
if [ "${STATUS}" = "200" ]; then
  echo "[ranger-init] Trino service definition already registered."
else
  echo "[ranger-init] Registering Trino service definition..."
  curl -sf -X POST -u "${AUTH}" "${RANGER_URL}/service/plugins/definitions" \
    -H "Content-Type: application/json" --data-binary @/scripts/trino-servicedef.json \
    && echo "[ranger-init] Done." || echo "[ranger-init] WARN: registration failed."
fi

# ── Create the datawave_trino service instance ────────────────────────────────
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -u "${AUTH}" \
  "${RANGER_URL}/service/plugins/services/name/datawave_trino")
if [ "${STATUS}" = "200" ]; then
  echo "[ranger-init] Service 'datawave_trino' already exists."
else
  echo "[ranger-init] Creating service 'datawave_trino'..."
  curl -sf -X POST -u "${AUTH}" "${RANGER_URL}/service/plugins/services" \
    -H "Content-Type: application/json" \
    -d '{
      "name": "datawave_trino",
      "type": "trino",
      "description": "DataWave Trino SQL Federation",
      "isEnabled": true,
      "configs": {
        "username": "trino",
        "password": "trino",
        "jdbc.driverClassName": "io.trino.jdbc.TrinoDriver",
        "jdbc.url": "jdbc:trino://trino:8080"
      }
    }' \
    && echo "[ranger-init] Service created." || echo "[ranger-init] WARN: service creation failed."
fi

echo "[ranger-init] Done. Configure group policies via the Ranger UI at http://localhost/ranger/"
