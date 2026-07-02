#!/bin/bash
# Substitute PUBLIC_HOSTNAME in the realm template and import it into Keycloak.
# Writing to /tmp avoids volume permission issues (keycloak user can't write
# to the root of a fresh keycloak_data volume owned by root).

# Step 1 — substitute
sed "s/localhost/${PUBLIC_HOSTNAME:-localhost}/g" \
    /tmp/datawave-realm.json.tpl \
    > /tmp/datawave-realm-resolved.json

# Step 2 — import (offline, into H2). --override false skips if realm exists.
/opt/keycloak/bin/kc.sh import \
    --file /tmp/datawave-realm-resolved.json \
    --override false || true

# Step 3 — start
exec /opt/keycloak/bin/kc.sh start-dev
