#!/bin/sh
# Patch ranger-admin-install.properties so Ranger connects to the shared
# postgres container (not the default 'ranger-db') using the correct superuser,
# and patch ranger.sh so the admin UI password is RANGER_ADMIN_PASSWORD.
set -e

PROPS=/home/ranger/scripts/ranger-admin-install.properties

# DB host: the shared postgres service name
sed -i "s/^db_host=.*/db_host=${RANGER_DB_HOST:-postgres}/" "$PROPS"

# DB root user: 'datawave' is the superuser (POSTGRES_USER=datawave in compose)
sed -i "s/^db_root_user=.*/db_root_user=${POSTGRES_SUPERUSER:-datawave}/" "$PROPS"

# DB root password: the actual postgres superuser password
sed -i "s/^db_root_password=.*/db_root_password=${POSTGRES_PASSWORD}/" "$PROPS"

# Admin UI password: use RANGER_ADMIN_PASSWORD, not the DB password
sed 's/rangerAdmin_password=${RANGER_DB_PASSWORD}/rangerAdmin_password=${RANGER_ADMIN_PASSWORD}/' \
  /home/ranger/scripts/ranger.sh > /tmp/ranger-entrypoint.sh
chmod +x /tmp/ranger-entrypoint.sh
exec /tmp/ranger-entrypoint.sh
