#!/bin/sh
set -e

MB_URL="http://metabase:3000"
ADMIN_EMAIL="${MB_ADMIN_EMAIL:-admin@datawave.io}"
ADMIN_PASSWORD="${MB_ADMIN_PASSWORD}"

echo "[metabase-init] Waiting for Metabase to be ready..."
until curl -sf "$MB_URL/api/health" | grep -q '"status":"ok"'; do
  sleep 5
done

SETUP_TOKEN=$(curl -sf "$MB_URL/api/session/properties" \
  | grep -o '"setup-token":"[^"]*"' | cut -d'"' -f4)

if [ -z "$SETUP_TOKEN" ] || [ "$SETUP_TOKEN" = "null" ]; then
  echo "[metabase-init] Metabase already set up — checking Trino connection..."
  SESSION_ID=$(curl -sf -X POST "$MB_URL/api/session" \
    -H "Content-Type: application/json" \
    -d "{\"username\": \"$ADMIN_EMAIL\", \"password\": \"$ADMIN_PASSWORD\"}" \
    | grep -o '"id":"[^"]*"' | cut -d'"' -f4)

  DB_LIST=$(curl -sf "$MB_URL/api/database" -H "X-Metabase-Session: $SESSION_ID")
  echo "$DB_LIST" | grep -q 'DataWave Federation' \
    || add_trino_connection "$SESSION_ID"
  echo "[metabase-init] Done."
  exit 0
fi

echo "[metabase-init] Setting up Metabase admin..."
SESSION_ID=$(curl -sf -X POST "$MB_URL/api/setup" \
  -H "Content-Type: application/json" \
  -d "{
    \"token\": \"$SETUP_TOKEN\",
    \"user\": {
      \"email\": \"$ADMIN_EMAIL\",
      \"password\": \"$ADMIN_PASSWORD\",
      \"first_name\": \"DataWave\",
      \"last_name\": \"Admin\",
      \"site_name\": \"DataWave Industries\"
    },
    \"prefs\": {
      \"site_name\": \"DataWave Industries\",
      \"allow_tracking\": false
    }
  }" | grep -o '"id":"[^"]*"' | cut -d'"' -f4)

add_trino_connection() {
  local session_id="$1"
  echo "[metabase-init] Adding DataWave Federation (Trino) connection..."
  local i=0
  while [ $i -lt 5 ]; do
    result=$(curl -s -X POST "$MB_URL/api/database" \
      -H "X-Metabase-Session: $session_id" \
      -H "Content-Type: application/json" \
      -d '{
        "engine": "starburst",
        "name": "DataWave Federation",
        "is_on_demand": false,
        "is_full_sync": true,
        "details": {
          "host": "trino",
          "port": 8080,
          "catalog": "postgresql",
          "user": "admin",
          "ssl": false
        }
      }')
    if echo "$result" | grep -q '"id"'; then
      echo "[metabase-init] Connection added."
      return 0
    fi
    i=$((i+1))
    echo "[metabase-init] Trino not ready, retrying in 10s... ($i/5)"
    sleep 10
  done
  echo "[metabase-init] WARNING: could not add Trino connection after 5 attempts."
}

add_trino_connection "$SESSION_ID"
echo "[metabase-init] Done. Admin: $ADMIN_EMAIL"
