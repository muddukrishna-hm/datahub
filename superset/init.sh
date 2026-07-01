#!/bin/sh
set -e

echo "[superset-init] Upgrading metadata database..."
superset db upgrade

echo "[superset-init] Initialising roles and permissions..."
superset init

echo "[superset-init] Importing Trino data source..."
superset import-datasources -p /datasources.yaml

echo "[superset-init] Done. Users authenticate via Keycloak OIDC at http://localhost:8180"
