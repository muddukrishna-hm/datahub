#!/bin/sh
# RANGER_DB_PASSWORD, POSTGRES_PASSWORD, and RANGER_ADMIN_PASSWORD are injected
# via docker-compose environment:. Patch ranger.sh so the admin UI password
# uses RANGER_ADMIN_PASSWORD instead of the DB password.
set -e

sed 's/rangerAdmin_password=${RANGER_DB_PASSWORD}/rangerAdmin_password=${RANGER_ADMIN_PASSWORD}/' \
  /home/ranger/scripts/ranger.sh > /tmp/ranger-entrypoint.sh
chmod +x /tmp/ranger-entrypoint.sh
exec /tmp/ranger-entrypoint.sh
