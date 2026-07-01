#!/bin/sh
set -e

MINIO_ALIAS="local"
MINIO_URL="http://minio:9000"
MINIO_USER="${MINIO_ROOT_USER:-minioadmin}"
# The entrypoint wrapper sets MINIO_ROOT_PASSWORD from /run/secrets/minio_root_password
MINIO_PASS="${MINIO_ROOT_PASSWORD}"

echo "Waiting for MinIO to be ready..."
until mc alias set "$MINIO_ALIAS" "$MINIO_URL" "$MINIO_USER" "$MINIO_PASS" 2>/dev/null; do
  sleep 2
done

echo "MinIO is ready. Creating buckets..."

mc mb --ignore-existing "$MINIO_ALIAS/warehouse"
mc anonymous set none "$MINIO_ALIAS/warehouse"

mc mb --ignore-existing "$MINIO_ALIAS/raw-data"
mc anonymous set none "$MINIO_ALIAS/raw-data"

mc mb --ignore-existing "$MINIO_ALIAS/archive"
mc anonymous set none "$MINIO_ALIAS/archive"

echo "Buckets created:"
mc ls "$MINIO_ALIAS"
echo "MinIO init complete."
