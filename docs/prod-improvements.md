# Production Improvements

Items that are architecturally sound but deferred from the initial build. Each section describes the current state, why it was deferred, and a complete implementation path.

---

## Contents

| Section | What it covers |
|---|---|
| [Production Readiness Checklist](#production-readiness-checklist) | Deferred items with priority and effort |
| [Limitations & Fixes](#limitations--fixes) | Known constraints and how to resolve each |
| [Scalability](#scalability) | Trino worker scaling, connector scaling, object storage, query routing |
| [Security Hardening](#security-hardening-additional) | Passwords, TLS, network lockdown, resource limits |
| [High Availability & Kubernetes](#high-availability--kubernetes) | HA topology, Helm charts, StatefulSets, managed services |

---

## Production Readiness Checklist

Before deploying this stack outside a local development environment, work through each item below.

| # | Item | Priority | Effort |
|---|---|---|---|
| 1 | [Trino Authentication](#1-trino-authentication) | Critical | Medium |
| 2 | [TLS / HTTPS for All Services](#2-tls--https-for-all-services) | Critical | Low–Medium |
| 3 | [Ranger Policy Sync for Trino](#3-ranger-policy-sync-for-trino) | High | High |
| 4 | [Metabase SSO (Single Sign-On)](#4-metabase-sso-single-sign-on) | Medium | Low–Medium |
| 5 | [Metabase Provisioning](#5-metabase-provisioning) | Low | Low |
| 6 | [Keycloak Realm Export Automation](#6-keycloak-realm-export-automation) | Low | Low |

---

## 1. Trino Authentication

**Current state:** Trino runs in anonymous (no-auth) mode. Any user who can reach port 8080 or http://localhost/trino/ can run queries without identifying themselves. The access-control layer (`rules.json`) and column masking are wired up but Trino trusts whatever username the client sends — there is no credential verification.

**Why deferred:** Trino's built-in `PASSWORD` and `OAUTH2` authenticators both require HTTPS. Enabling HTTPS for a single-node dev stack means generating a TLS certificate, configuring `http-server.https.*` properties, and updating the nginx upstream — significant setup friction for first-time evaluators.

**How to implement:**

### Step 1 — Generate a certificate

Trino requires a PKCS12 or JKS keystore. Choose the right certificate approach for your environment:

---

#### Option A — Local development: `mkcert` (browser-trusted, zero friction)

`mkcert` creates a local certificate authority and issues certs that your OS and browsers trust automatically. No security warnings, no manual CA import.

```bash
# Install mkcert and create a local CA (one-time setup)
brew install mkcert        # macOS
# or: sudo apt install mkcert   (Ubuntu/Debian)
mkcert -install            # installs CA into your system trust store

# Issue a cert for Trino and package it as PKCS12
mkcert -pkcs12 -p12-file secrets/trino-keystore.p12 \
  localhost 127.0.0.1 ::1

# Default PKCS12 password is "changeit" — override if needed:
# mkcert -p12-password mypassword -pkcs12 -p12-file secrets/trino-keystore.p12 localhost
```

> `mkcert` is **not suitable for production** — the root CA private key lives on your laptop and would need to be distributed to every client.

---

#### Option B — Staging / internal: OpenSSL self-signed certificate

Suitable for internal networks where you control all clients and can distribute the CA cert.

```bash
# Step 1 — Create a private CA
openssl genrsa -out secrets/ca.key 4096
openssl req -new -x509 -days 3650 -key secrets/ca.key \
  -out secrets/ca.crt \
  -subj "/C=US/ST=State/L=City/O=DataWave/CN=DataWave Internal CA"

# Step 2 — Create Trino's private key and CSR
openssl genrsa -out secrets/trino.key 2048
openssl req -new -key secrets/trino.key \
  -out secrets/trino.csr \
  -subj "/C=US/ST=State/L=City/O=DataWave/CN=trino.datawave.io"

# Step 3 — Sign the CSR with the CA (include SANs for all hostnames)
cat > /tmp/trino-ext.cnf <<EOF
[SAN]
subjectAltName=DNS:trino.datawave.io,DNS:localhost,IP:127.0.0.1
EOF

openssl x509 -req -days 825 \
  -in secrets/trino.csr \
  -CA secrets/ca.crt \
  -CAkey secrets/ca.key \
  -CAcreateserial \
  -extfile /tmp/trino-ext.cnf \
  -extensions SAN \
  -out secrets/trino.crt

# Step 4 — Bundle into PKCS12 keystore (required by Trino's JVM)
openssl pkcs12 -export \
  -in secrets/trino.crt \
  -inkey secrets/trino.key \
  -CAfile secrets/ca.crt \
  -caname "DataWave Internal CA" \
  -out secrets/trino-keystore.p12 \
  -passout pass:changeit \
  -name trino

# Step 5 — Distribute ca.crt to all clients that need to trust Trino's cert
# macOS:  sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain secrets/ca.crt
# Linux:  sudo cp secrets/ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates
# Java:   keytool -import -alias datawave-ca -file secrets/ca.crt -keystore $JAVA_HOME/lib/security/cacerts
```

> Store `ca.key` in a secrets manager (Vault, AWS Secrets Manager) — it is the root of trust for your entire stack. Never commit it to git.

---

#### Option C — Production: Let's Encrypt (public CA, auto-renewed)

Use this when Trino is behind a public or VPN-accessible hostname. Let's Encrypt issues trusted certs for free and `certbot` renews them automatically.

```bash
# Install certbot
brew install certbot      # macOS
# or: sudo apt install certbot   (Ubuntu/Debian)

# Issue a cert (standalone mode — temporarily binds port 80)
sudo certbot certonly --standalone \
  -d trino.datawave.io \
  --agree-tos --email ops@datawave.io

# Certs are written to:
#   /etc/letsencrypt/live/trino.datawave.io/fullchain.pem
#   /etc/letsencrypt/live/trino.datawave.io/privkey.pem

# Convert to PKCS12 for Trino
openssl pkcs12 -export \
  -in /etc/letsencrypt/live/trino.datawave.io/fullchain.pem \
  -inkey /etc/letsencrypt/live/trino.datawave.io/privkey.pem \
  -out secrets/trino-keystore.p12 \
  -passout pass:changeit \
  -name trino

# Auto-renew (certbot installs a cron/systemd timer automatically)
# After renewal, run the pkcs12 export again and restart Trino:
sudo certbot renew --deploy-hook \
  "openssl pkcs12 -export \
    -in /etc/letsencrypt/live/trino.datawave.io/fullchain.pem \
    -inkey /etc/letsencrypt/live/trino.datawave.io/privkey.pem \
    -out /path/to/secrets/trino-keystore.p12 \
    -passout pass:changeit -name trino && \
   docker compose restart trino"
```

> On Kubernetes, use **cert-manager** with a `Certificate` resource instead — it handles renewal and secret injection automatically. See the [HA / Kubernetes section](#high-availability--kubernetes) for details.

---

#### Option D — Enterprise: Internal PKI / corporate CA

If your organisation already operates a PKI (ADCS, HashiCorp Vault PKI engine, CFSSL):

```bash
# Example: request a cert from HashiCorp Vault PKI
vault write pki/issue/datawave-role \
  common_name=trino.datawave.io \
  alt_names="localhost" \
  ip_sans="127.0.0.1" \
  ttl=8760h \
  format=pem > /tmp/vault-cert.json

# Extract cert and key
jq -r .data.certificate /tmp/vault-cert.json > secrets/trino.crt
jq -r .data.private_key /tmp/vault-cert.json > secrets/trino.key
jq -r .data.issuing_ca  /tmp/vault-cert.json > secrets/ca.crt

# Bundle into PKCS12
openssl pkcs12 -export \
  -in secrets/trino.crt \
  -inkey secrets/trino.key \
  -CAfile secrets/ca.crt \
  -out secrets/trino-keystore.p12 \
  -passout pass:changeit -name trino
```

---

#### Certificate approach decision guide

| Environment | Recommended approach | Trust distribution |
|---|---|---|
| Local laptop / demo | mkcert (Option A) | Automatic via OS trust store |
| Internal / VPN-only | OpenSSL self-signed CA (Option B) | Distribute `ca.crt` to clients |
| Public-facing staging | Let's Encrypt (Option C) | Publicly trusted, no distribution needed |
| Production | Let's Encrypt or corporate CA (C / D) | Publicly trusted or managed PKI |
| Kubernetes | cert-manager + Let's Encrypt | Automatic via K8s secret injection |

---

### Step 2 — Enable HTTPS in `trino/etc/config.properties`

```properties
http-server.https.enabled=true
http-server.https.port=8443
http-server.https.keystore.path=/run/secrets/trino-keystore.p12
http-server.https.keystore.key=changeit
internal-communication.shared-secret=<random-32-char-string>
```

### Step 3 — Choose an authentication method

**Option A — File-based PASSWORD (simplest for internal teams):**

```properties
# trino/etc/config.properties
http-server.authentication.type=PASSWORD
```

```properties
# trino/etc/password-authenticator.properties
password-authenticator.name=file
file.password-file=/etc/trino/password.db
```

Generate bcrypt hashes:

```bash
htpasswd -nbBC 10 analyst <password> >> trino/etc/password.db
htpasswd -nbBC 10 engineer <password> >> trino/etc/password.db
htpasswd -nbBC 10 admin <password> >> trino/etc/password.db
```

**Option B — Keycloak OAUTH2 (unified SSO — preferred):**

```properties
# trino/etc/config.properties
http-server.authentication.type=OAUTH2
oauth2.issuer=http://localhost:8180/realms/datawave
oauth2.jwks-url=http://keycloak:8080/realms/datawave/protocol/openid-connect/certs
oauth2.auth-url=http://localhost:8180/realms/datawave/protocol/openid-connect/auth
oauth2.token-url=http://keycloak:8080/realms/datawave/protocol/openid-connect/token
oauth2.client-id=trino-cli
oauth2.principal-field=preferred_username
```

The Trino Web UI will redirect to Keycloak for login. The CLI uses `--external-authentication`. The `trino-cli` public Keycloak client is already configured.

### Step 4 — Update nginx upstream to use HTTPS

```nginx
upstream trino {
    server trino:8443;
}
```

### Step 5 — Confirm group provider

The file-based group provider is already wired in `trino/etc/group-provider.properties`. With real authentication, Trino will map the authenticated username to the correct group and enforce `rules.json`.

---

## 2. TLS / HTTPS for All Services

**Current state:** All traffic is plain HTTP. This is acceptable for local development but exposes credentials and session cookies on any shared or cloud network.

**Why deferred:** TLS requires certificate generation and distribution across services. On a local single-machine stack this adds friction; `mkcert` makes it feasible but adds a prerequisite step.

**How to implement:**

### Choose a certificate approach

Use the same tiered strategy described in [Step 1 of Trino Authentication](#step-1--generate-a-certificate) — the decision guide applies here too. Nginx needs PEM-format certs (`cert.pem` + `key.pem`), not PKCS12.

**Dev — `mkcert` (browser-trusted, zero config):**

```bash
brew install mkcert && mkcert -install

# Single cert covering all services on localhost
mkcert -cert-file nginx/ssl/cert.pem -key-file nginx/ssl/key.pem \
  localhost 127.0.0.1 ::1
```

**Staging / internal — OpenSSL self-signed CA:**

```bash
# Reuse the same CA from the Trino cert step, just issue a new cert for nginx
openssl genrsa -out nginx/ssl/nginx.key 2048
openssl req -new -key nginx/ssl/nginx.key -out /tmp/nginx.csr \
  -subj "/C=US/O=DataWave/CN=datawave.io"

cat > /tmp/nginx-ext.cnf <<EOF
[SAN]
subjectAltName=DNS:datawave.io,DNS:*.datawave.io,DNS:localhost,IP:127.0.0.1
EOF

openssl x509 -req -days 825 \
  -in /tmp/nginx.csr \
  -CA secrets/ca.crt -CAkey secrets/ca.key -CAcreateserial \
  -extfile /tmp/nginx-ext.cnf -extensions SAN \
  -out nginx/ssl/cert.pem

cp nginx/ssl/nginx.key nginx/ssl/key.pem
```

**Production — Let's Encrypt via certbot:**

```bash
sudo certbot certonly --standalone -d datawave.io -d *.datawave.io \
  --agree-tos --email ops@datawave.io

# Symlink or copy to nginx/ssl/
cp /etc/letsencrypt/live/datawave.io/fullchain.pem nginx/ssl/cert.pem
cp /etc/letsencrypt/live/datawave.io/privkey.pem   nginx/ssl/key.pem

# certbot auto-renew hook
sudo certbot renew --deploy-hook \
  "cp /etc/letsencrypt/live/datawave.io/fullchain.pem /path/to/nginx/ssl/cert.pem && \
   cp /etc/letsencrypt/live/datawave.io/privkey.pem   /path/to/nginx/ssl/key.pem && \
   docker compose restart nginx"
```

### Nginx TLS configuration

```nginx
server {
    listen 443 ssl;
    server_name localhost;

    ssl_certificate     /etc/nginx/ssl/cert.pem;
    ssl_certificate_key /etc/nginx/ssl/key.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    # ... existing location blocks unchanged
}

server {
    listen 80;
    return 301 https://$host$request_uri;
}
```

### Update services that need to reach Nginx over HTTPS

- **oauth2-proxy:** Add `--cookie-secure=true` and change `--redirect-url` to `https://localhost/oauth2/callback`
- **Keycloak:** Set `KC_HOSTNAME=your-domain` and remove `KC_HTTP_ENABLED=true`
- **Metabase:** Update `MB_SITE_URL=https://localhost`

### Production CA (Let's Encrypt)

For public-facing deployments, use Certbot or the nginx ACME challenge. Add a `certbot` service to `docker-compose.yml` and mount the issued certificates into nginx.

---

## 3. Ranger Policy Sync for Trino

**Current state:** Trino uses file-based access control (`trino/etc/rules.json`). Ranger is running and operational with pre-loaded demo policies, but Trino does not call Ranger at query time. The `ranger/scripts/trino-servicedef.json` file is pre-staged for this implementation.

**Why deferred:** The `trino-ranger` plugin is not bundled in the standard `trinodb/trino` image. Using it requires building a custom Trino image with the plugin JAR copied in.

**How to implement:**

### Step 1 — Build a custom Trino image

```dockerfile
FROM trinodb/trino:458

# Copy the Ranger plugin JAR into the Trino plugin directory
COPY trino-ranger-plugin.jar /usr/lib/trino/plugin/ranger/
```

Download `trino-ranger-plugin.jar` from the Apache Ranger release that matches your Ranger version (`2.8.0`).

### Step 2 — Register the Trino service in Ranger

```bash
curl -u admin:$(cat secrets/ranger_admin_password.txt) \
  -X POST http://localhost:6080/service/public/v2/api/servicedef \
  -H 'Content-Type: application/json' \
  -d @ranger/scripts/trino-servicedef.json
```

### Step 3 — Replace `access-control.properties`

```properties
# trino/etc/access-control.properties
access-control.name=ranger
ranger.service-name=trino
ranger.rest-address=http://ranger:6080
ranger.rest-user=admin
ranger.rest-password=${ENV:TRINO_RANGER_PASSWORD}
ranger.policy-cache-dir=/data/trino/ranger-cache
ranger.policy-refresh-interval=30s
```

Add `TRINO_RANGER_PASSWORD` to the Trino entrypoint wrapper:

```bash
export TRINO_RANGER_PASSWORD=$(cat /run/secrets/ranger_admin_password)
```

And add `ranger_admin_password` to the Trino `secrets:` list in `docker-compose.yml`.

### Step 4 — Delete `rules.json` (or keep for fallback)

Once Ranger enforcement is active, `trino/etc/rules.json` is no longer consulted. Remove `access-control.properties` reference to `security.config-file` and the `rules.json` file.

### Step 5 — Manage all policies from the Ranger UI

All policies are now live-editable in the Ranger Admin at http://localhost/ranger/ and propagate to Trino within 30 seconds (configurable via `ranger.policy-refresh-interval`).

---

## 4. Metabase SSO (Single Sign-On)

**Current state:** http://localhost/ is gated by oauth2-proxy + Keycloak — only authenticated users can reach the stack. However, Metabase still presents its own login page after Keycloak authentication (double login). After the first combined session the two cookies persist, so return visits go straight to Metabase without prompts.

**Why deferred:** Metabase's free Community edition has no built-in OIDC/SAML integration.

**How to implement (two options):**

### Option A — Metabase Pro / Enterprise (paid)

Upgrade to a paid Metabase plan and configure SAML or OIDC against the `datawave` Keycloak realm. Users authenticate once through Keycloak and are provisioned into Metabase automatically.

### Option B — Metabase LDAP + Keycloak LDAP federation (free)

Keycloak can expose an LDAP interface via its User Federation provider.

1. In Keycloak Admin → **datawave** realm → **User Federation** → **Add provider: LDAP**
2. Configure Keycloak to expose users via its LDAP provider
3. In Metabase Admin → **Authentication → LDAP**:
   ```
   LDAP Host: keycloak
   LDAP Port: 10389   (Keycloak LDAP port)
   LDAP Base DN: dc=datawave,dc=io
   LDAP User Filter: (uid={login})
   ```
4. Users log in to Metabase directly with their Keycloak credentials — no separate Metabase password, no double login.

---

## 5. Metabase Provisioning

**Current state:** The `metabase-init` container runs automatically after Metabase starts and creates the admin account (`admin@datawave.io`) and the "DataWave Federation" Trino connection. If it has already run, it detects this and exits without making changes.

**Why deferred:** The current `curl`-based init script is adequate for a demo stack but fragile — it relies on polling, has no retry logic for partial failures, and does not handle Metabase version changes gracefully.

**How to improve:**

1. **Use Metabase environment variables** for the initial admin setup (supported in recent versions):

   ```yaml
   environment:
     MB_ADMIN_EMAIL: admin@datawave.io
     MB_ADMIN_FIRST_NAME: Admin
     MB_ADMIN_LAST_NAME: DataWave
   ```

   Password is still set via the `/api/setup` call.

2. **Add idempotency checks** to `metabase/init.sh`:

   ```bash
   # Check if setup was already done
   STATUS=$(curl -sf http://metabase:3000/api/session/properties | jq -r .setup_token)
   if [ "$STATUS" = "null" ]; then
     echo "Setup already complete — skipping"
     exit 0
   fi
   ```

3. **Store the admin password in a Metabase-native way** — use `MB_ADMIN_PASSWORD` env var instead of the setup API call (available in Metabase v0.50+).

---

## 6. Keycloak Realm Export Automation

**Current state:** The realm JSON (`keycloak/datawave-realm.json`) is imported on first boot via `--import-realm`. On restarts, Keycloak skips the import if the realm already exists, so any changes made in the Admin UI are not persisted back to the file.

**Why deferred:** The export command requires running inside the Keycloak container and the output needs to be cleaned of environment-specific noise before committing.

**How to implement:**

Add a `make export-realm` target or a shell alias:

```bash
# Export the current realm state to the committed file
docker exec datawave-keycloak /opt/keycloak/bin/kc.sh export \
  --realm datawave \
  --users realm_file \
  --file /tmp/realm-export.json && \
docker cp datawave-keycloak:/tmp/realm-export.json keycloak/datawave-realm.json
```

Run this after any manual changes in the Keycloak Admin UI to keep the committed JSON in sync. Add to your workflow as a pre-commit step.

**Automate with a Git hook:**

```bash
# .git/hooks/pre-commit
#!/bin/sh
if docker ps --format '{{.Names}}' | grep -q datawave-keycloak; then
  echo "Exporting Keycloak realm before commit..."
  docker exec datawave-keycloak /opt/keycloak/bin/kc.sh export \
    --realm datawave --users realm_file --file /tmp/realm-export.json
  docker cp datawave-keycloak:/tmp/realm-export.json keycloak/datawave-realm.json
  git add keycloak/datawave-realm.json
fi
```

---

## Security Hardening (Additional)

These items are not deferred features but production-mandatory security controls:

### Change all default passwords

All `secrets/*.txt` files contain dev-default values committed to the repository. Before any non-local deployment:

```bash
# Generate cryptographically random secrets
openssl rand -base64 32 > secrets/postgres_password.txt
openssl rand -base64 32 > secrets/mysql_password.txt
openssl rand -base64 32 > secrets/minio_root_password.txt
openssl rand -base64 32 > secrets/elasticsearch_password.txt
openssl rand -base64 32 > secrets/ranger_admin_password.txt
openssl rand -base64 32 > secrets/keycloak_admin_password.txt
openssl rand -base64 32 > secrets/oauth2_cookie_secret.txt
# ... repeat for all secret files
```

Add `secrets/` to `.gitignore` for production deployments.

### Restrict Keycloak redirect URIs

In the Keycloak Admin UI → **datawave-app** client → **Valid Redirect URIs**: change `*` to your specific domain.

### Enable brute-force protection

Keycloak Admin → **datawave** realm → **Realm Settings → Security Defenses → Brute Force Detection** → Enable.

### Lock down OAuth2 Proxy

In production set:

```
--cookie-secure=true           (requires HTTPS)
--cookie-samesite=lax
--email-domain=datawave.io     (restrict to your org's email domain)
```

### Disable direct port exposure

In `docker-compose.yml`, remove all `ports:` mappings except `nginx:80`/`nginx:443`. Services that need external dev access can be selectively re-enabled with a `docker compose -f docker-compose.yml -f docker-compose.dev.yml up` override pattern.

### Resource limits

Add memory and CPU limits to prevent a single service from consuming all host resources:

```yaml
deploy:
  resources:
    limits:
      memory: 2g
      cpus: '2'
```

This is particularly important for Elasticsearch, Trino, and Ranger which all have large JVM heaps.

---

## Limitations & Fixes

These are known constraints in the current single-node Docker Compose setup, each with a concrete fix path.

---

### L1 — Trino is anonymous (no real identity enforcement)

**Limitation:** Trino runs without an authenticator. Any client can claim any username by passing `--user analyst` or setting the JDBC property `user=admin`. The RBAC rules fire on the claimed username, but there is nothing preventing impersonation.

**Impact:** In production, a user could trivially escalate to `admin` access by changing their client username.

**Fix:** Enable Trino OAUTH2 authentication backed by Keycloak. Full implementation steps are in [Trino Authentication](#1-trino-authentication) above. This is the highest-priority fix before any shared deployment.

---

### L2 — Ranger does not enforce at query time

**Limitation:** Apache Ranger is running and holds the authoritative policy definitions, but Trino's active enforcement uses `rules.json` (file-based), not the Ranger plugin. Policy changes in the Ranger UI have no effect on live queries.

**Impact:** The Ranger UI can be used to define and review policies but cannot dynamically revoke access — a file change + Trino restart is required to change enforcement.

**Fix:** Build a custom Trino image with the Ranger plugin JAR and register the Trino service in Ranger. Full implementation in [Ranger Policy Sync for Trino](#3-ranger-policy-sync-for-trino) above.

---

### L3 — Single node for every service

**Limitation:** Every service (Trino coordinator, Elasticsearch, Ranger, Keycloak, MinIO) runs as a single container with no replicas. A crash of any container makes that component unavailable until Docker restarts it.

**Impact:** No fault tolerance. A Trino OOM kill drops all in-flight queries. An Elasticsearch restart loses the audit buffer.

**Fix:** See [High Availability & Kubernetes](#high-availability--kubernetes) below for a full HA topology.

---

### L4 — Nessie uses in-memory version store

**Limitation:** Nessie is configured with `NESSIE_VERSION_STORE_TYPE=IN_MEMORY`. All Iceberg table metadata (commits, branches, tags) is lost when the Nessie container restarts.

**Impact:** Iceberg tables created in one session disappear after a restart. Only suitable for demos.

**Fix:** Switch to a persistent backend:

```yaml
# docker-compose.yml — nessie service
environment:
  NESSIE_VERSION_STORE_TYPE: ROCKSDB
  NESSIE_VERSION_STORE_PERSIST_ROCKSDB_DATABASE_PATH: /var/nessie/data
volumes:
  - nessie_data:/var/nessie/data
```

For production, use `DYNAMODB` or `MONGODB` for replicated metadata storage.

---

### L5 — Metabase requires a second login (double login)

**Limitation:** oauth2-proxy gates the portal with Keycloak SSO, but Metabase Community Edition does not integrate with OIDC — users see a Metabase login page after their Keycloak session is established.

**Impact:** Users authenticate twice on a fresh browser session.

**Fix:** See [Metabase SSO](#4-metabase-sso-single-sign-on) above (LDAP federation is free; OIDC requires Metabase Pro).

---

### L6 — Secrets committed in plain text

**Limitation:** `secrets/*.txt` files contain dev-default passwords and are committed to the repository. Anyone with repository access can read all credentials.

**Impact:** Acceptable for a local demo; a critical vulnerability in any shared or cloud environment.

**Fix options (in order of maturity):**

| Option | Suitable for |
|---|---|
| `.gitignore secrets/` + generate locally | Small teams, on-prem |
| [HashiCorp Vault](https://developer.hashicorp.com/vault) Agent sidecar | On-prem / self-managed |
| AWS Secrets Manager + ECS Secrets integration | AWS deployments |
| Kubernetes Secrets + [External Secrets Operator](https://external-secrets.io/) | K8s deployments |
| [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets) | GitOps K8s workflows |

---

### L7 — No query result caching

**Limitation:** Trino does not cache query results. Every repeated identical query hits the source databases and re-scans Parquet files on MinIO.

**Impact:** Slow dashboard load times for high-cardinality aggregation queries run frequently by many analysts.

**Fix:** Add a caching layer:

- **Trino native file-based cache** (available in Trino 400+): mount a fast local volume as a spill/cache dir
- **[Alluxio](https://www.alluxio.io/)** as a caching proxy between Trino and MinIO for Iceberg data
- **Metabase question caching** (Admin → Caching): cache results for N hours at the BI layer for dashboard queries

---

### L8 — No data lineage or catalog metadata

**Limitation:** There is no data catalog layer. Analysts cannot discover what tables exist, who owns them, or how data flows between systems.

**Fix:** Add [Apache Atlas](https://atlas.apache.org/) or [DataHub (LinkedIn)](https://datahubproject.io/) as a metadata layer. Both integrate with Ranger for policy-aware lineage and with Trino via JDBC for schema discovery.

---

## Scalability

The current stack runs on a single Docker host. This section describes how to scale each bottleneck independently.

---

### Trino — Horizontal Worker Scaling

**Current:** Trino runs in coordinator-only mode (`node-scheduler.include-coordinator=true`). The coordinator both plans queries and executes them, capped at one node.

**How to scale:**

Add worker containers to `docker-compose.yml`. Workers register themselves with the coordinator via discovery:

```yaml
# docker-compose.yml — add as many workers as needed
trino-worker-1:
  image: trinodb/trino:458
  container_name: datawave-trino-worker-1
  restart: unless-stopped
  entrypoint: ["/bin/sh", "-c"]
  command:
    - |
      mkdir -p /etc/trino
      cp -r /etc/trino-source/. /etc/trino/
      export TRINO_POSTGRES_PASSWORD=$(cat /run/secrets/postgres_password)
      export TRINO_MYSQL_PASSWORD=$(cat /run/secrets/mysql_password)
      export TRINO_MINIO_SECRET_KEY=$(cat /run/secrets/minio_root_password)
      exec /usr/lib/trino/bin/run-trino
  volumes:
    - ./trino/etc/worker:/etc/trino-source:ro   # separate worker config
  networks:
    - datawave-net
  secrets:
    - postgres_password
    - mysql_password
    - minio_root_password
```

**Worker-specific `trino/etc/worker/config.properties`:**

```properties
coordinator=false
http-server.http.port=8080
discovery.uri=http://trino:8080    # points at the coordinator
query.max-memory=4GB
query.max-memory-per-node=1GB
```

**Turn off coordinator self-scheduling** once workers exist:

```properties
# coordinator config.properties
node-scheduler.include-coordinator=false
```

**Scaling rules of thumb:**

| Workload | Workers | Memory per worker |
|---|---|---|
| < 10 concurrent analysts | 1 coordinator only | 4 GB |
| 10–50 analysts, mixed DML | 2–4 workers | 8 GB each |
| 50+ analysts, heavy Iceberg scans | 4–8 workers + autoscale | 16 GB each |

**On Kubernetes:** Use a `Deployment` with `replicas: N` for workers and a single-replica `StatefulSet` for the coordinator. Workers auto-register via the discovery URI.

---

### MinIO — Distributed Mode

**Current:** MinIO runs as a single server (`minio server /data`). A single disk failure loses all Iceberg data.

**How to scale:** Switch to MinIO distributed mode with erasure coding across multiple nodes:

```bash
# 4-node MinIO cluster (run on separate hosts or as 4 containers)
minio server \
  http://minio-{1...4}/data{1...4} \
  --console-address ":9001"
```

In Docker Compose for local multi-node testing:

```yaml
minio-1:
  image: minio/minio:latest
  command: server http://minio-{1...4}/data --console-address ":9001"
  volumes:
    - minio1_data:/data
  networks:
    - datawave-net

# repeat for minio-2, minio-3, minio-4
```

**On AWS:** Replace MinIO with **S3** — change only `s3.endpoint` in `trino/etc/catalog/iceberg.properties`. No other changes required.

---

### Elasticsearch — Multi-node Cluster

**Current:** Elasticsearch runs as a single node (`discovery.type=single-node`). No replication; a node restart drops the audit buffer.

**How to scale:** Switch to a 3-node cluster for production:

```yaml
# Add to docker-compose.yml
elasticsearch-2:
  image: elasticsearch:8.13.0
  environment:
    - cluster.name=datawave-audit
    - node.name=es-2
    - discovery.seed_hosts=elasticsearch,elasticsearch-3
    - cluster.initial_master_nodes=elasticsearch,elasticsearch-2,elasticsearch-3
    - xpack.security.enabled=true
  networks:
    - datawave-net

elasticsearch-3:
  image: elasticsearch:8.13.0
  environment:
    - cluster.name=datawave-audit
    - node.name=es-3
    - discovery.seed_hosts=elasticsearch,elasticsearch-2
    - cluster.initial_master_nodes=elasticsearch,elasticsearch-2,elasticsearch-3
    - xpack.security.enabled=true
  networks:
    - datawave-net
```

Update `trino`'s event listener URI to point at a load-balanced endpoint or use the cluster VIP.

**On AWS/GCP:** Replace with **Amazon OpenSearch Service** or **Elastic Cloud** — update `http-event-listener.connect-ingest-uri` in the Trino entrypoint.

---

### Keycloak — Clustered Mode

**Current:** Single Keycloak node. A restart causes a brief authentication outage (existing sessions survive via cookies, but new logins fail until Keycloak is back).

**How to scale:**

```yaml
keycloak-2:
  image: quay.io/keycloak/keycloak:24.0
  command:
    - |
      export KC_DB_PASSWORD=$(cat /run/secrets/keycloak_db_password)
      exec /opt/keycloak/bin/kc.sh start \
        --cache=ispn \
        --cache-stack=kubernetes    # or "tcp" for Docker
  environment:
    KC_DB: postgres
    KC_DB_URL: jdbc:postgresql://keycloak-db:5432/keycloak
    KC_HOSTNAME: your-domain.com
    JGROUPS_DISCOVERY_PROTOCOL: PING
  networks:
    - datawave-net
```

Both nodes share the same PostgreSQL database. Sessions are replicated via JGroups clustering (`PING` for Docker, `dns.DNS_PING` for Kubernetes).

---

### Apache Ranger — Scaling Considerations

Ranger is not horizontally scalable in its current `apache/ranger` packaging. For production scale:

- Run Ranger on a **dedicated host** with at least 4 cores / 8 GB RAM
- Increase Solr replication factor to 2+ for the `ranger_audits` collection
- Use an **external managed Solr** (SolrCloud) instead of the bundled container
- Set `ranger.policy-refresh-interval=30s` on the Trino side to reduce Ranger query load; increase to `60s` under heavy load

---

## High Availability & Kubernetes

This section describes a production-grade HA deployment on Kubernetes. All Docker images used in this stack run unchanged on Kubernetes — only the orchestration layer changes.

---

### HA Architecture Overview

```
                    ┌─────────────────────────────────────┐
                    │          Kubernetes Cluster          │
                    │                                      │
  Users ──► Ingress (nginx-ingress / Traefik + cert-manager)
                    │
          ┌─────────┴──────────┐
          │    oauth2-proxy    │  (Deployment, 2 replicas)
          │    (sidecar SSO)   │
          └─────────┬──────────┘
                    │
     ┌──────────────┼──────────────┐
     │              │              │
  Keycloak       Metabase       Ranger
  (StatefulSet)  (Deployment)   (Deployment)
  2 replicas     2 replicas     1 replica
     │              │
  keycloak-db    metabase-db
  (PostgreSQL    (PostgreSQL
   operator)      operator)
                    │
          ┌─────────┴──────────────┐
          │       Trino            │
          │  Coordinator (×1)      │
          │  Workers     (×3–8)    │
          └─────────┬──────────────┘
                    │
     ┌──────────────┼──────────────┐
     │              │              │
  PostgreSQL      MySQL          MinIO
  (operator)    (operator)    (distributed /
                               S3-compatible)
                    │
             Elasticsearch
             (3-node cluster /
              OpenSearch Service)
```

---

### Recommended Kubernetes Deployment Strategy

#### Use Helm charts where available

| Component | Helm chart |
|---|---|
| Trino | `helm install trino trino/trino` ([trino.io/docs](https://trino.io/docs/current/installation/kubernetes.html)) |
| Keycloak | `helm install keycloak bitnami/keycloak` |
| MinIO | `helm install minio minio/minio` (or use AWS S3) |
| Elasticsearch | `helm install elasticsearch elastic/elasticsearch` |
| Metabase | Community Helm chart or custom Deployment |
| Apache Ranger | Manual Deployment (no official chart) |
| nginx-ingress | `helm install ingress-nginx ingress-nginx/ingress-nginx` |

---

#### Trino on Kubernetes

**`trino-values.yaml` (Helm override):**

```yaml
coordinator:
  resources:
    requests:
      memory: "4Gi"
      cpu: "2"
    limits:
      memory: "8Gi"
      cpu: "4"
  jvm:
    maxHeapSize: "6G"

worker:
  replicas: 4
  resources:
    requests:
      memory: "8Gi"
      cpu: "4"
    limits:
      memory: "16Gi"
      cpu: "8"
  jvm:
    maxHeapSize: "12G"
  autoscaling:
    enabled: true
    minReplicas: 2
    maxReplicas: 16
    targetCPUUtilizationPercentage: 70

additionalCatalogs:
  postgresql: |
    connector.name=postgresql
    connection-url=jdbc:postgresql://postgres-svc:5432/logistics
    connection-user=datawave
    connection-password=${ENV:TRINO_POSTGRES_PASSWORD}
  mysql: |
    connector.name=mysql
    connection-url=jdbc:mysql://mysql-svc:3306
    connection-user=datawave
    connection-password=${ENV:TRINO_MYSQL_PASSWORD}
  iceberg: |
    connector.name=iceberg
    iceberg.catalog.type=nessie
    iceberg.nessie-catalog.uri=http://nessie-svc:19120/api/v1
    iceberg.nessie-catalog.default-warehouse-dir=s3://warehouse/
    s3.endpoint=http://minio-svc:9000
    s3.aws-secret-key=${ENV:TRINO_MINIO_SECRET_KEY}
```

Apply:

```bash
helm repo add trino https://trinodb.github.io/charts
helm install trino trino/trino -f trino-values.yaml -n datawave
```

**Horizontal Pod Autoscaler for workers:**

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: trino-worker-hpa
  namespace: datawave
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: trino-worker
  minReplicas: 2
  maxReplicas: 16
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: 75
```

---

#### Keycloak on Kubernetes

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: keycloak
  namespace: datawave
spec:
  replicas: 2
  serviceName: keycloak-headless
  selector:
    matchLabels:
      app: keycloak
  template:
    spec:
      containers:
        - name: keycloak
          image: quay.io/keycloak/keycloak:24.0
          args: ["start", "--cache=ispn", "--cache-stack=kubernetes"]
          env:
            - name: KC_DB
              value: postgres
            - name: KC_DB_URL
              value: jdbc:postgresql://postgres-keycloak-svc:5432/keycloak
            - name: KC_DB_USERNAME
              value: keycloak
            - name: KC_DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: keycloak-secrets
                  key: db-password
            - name: KC_HOSTNAME
              value: auth.datawave.io
            - name: JGROUPS_DISCOVERY_PROTOCOL
              value: dns.DNS_PING
            - name: JGROUPS_DISCOVERY_PROPERTIES
              value: "dns_query=keycloak-headless.datawave.svc.cluster.local"
```

---

#### Secrets Management on Kubernetes

Replace `secrets/*.txt` files with Kubernetes Secrets or an external secrets provider:

**Option A — Kubernetes native Secrets:**

```bash
kubectl create secret generic datawave-secrets \
  --from-literal=postgres-password=$(openssl rand -base64 32) \
  --from-literal=mysql-password=$(openssl rand -base64 32) \
  --from-literal=minio-secret-key=$(openssl rand -base64 32) \
  --from-literal=elasticsearch-password=$(openssl rand -base64 32) \
  -n datawave
```

Reference in a Pod:

```yaml
env:
  - name: TRINO_POSTGRES_PASSWORD
    valueFrom:
      secretKeyRef:
        name: datawave-secrets
        key: postgres-password
```

**Option B — External Secrets Operator (recommended for production):**

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: datawave-secrets
  namespace: datawave
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend      # or aws-secrets-manager, gcp-sm, etc.
    kind: ClusterSecretStore
  target:
    name: datawave-secrets
  data:
    - secretKey: postgres-password
      remoteRef:
        key: datawave/postgres
        property: password
    - secretKey: minio-secret-key
      remoteRef:
        key: datawave/minio
        property: secret-key
```

---

#### Ingress with TLS (cert-manager + Let's Encrypt)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: datawave-ingress
  namespace: datawave
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/proxy-read-timeout: "300"
    nginx.ingress.kubernetes.io/proxy-body-size: "0"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - datawave.io
        - auth.datawave.io
      secretName: datawave-tls
  rules:
    - host: datawave.io
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: oauth2-proxy-svc
                port:
                  number: 4180
          - path: /trino
            pathType: Prefix
            backend:
              service:
                name: trino-coordinator-svc
                port:
                  number: 8080
          - path: /ranger
            pathType: Prefix
            backend:
              service:
                name: ranger-svc
                port:
                  number: 6080
          - path: /kibana
            pathType: Prefix
            backend:
              service:
                name: kibana-svc
                port:
                  number: 5601
    - host: auth.datawave.io
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: keycloak-svc
                port:
                  number: 8080
```

---

#### Database HA with PostgreSQL Operator

All three internal PostgreSQL instances (Keycloak, Metabase, Ranger) should use a PostgreSQL operator for automated failover:

```yaml
# Using CloudNativePG operator
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: keycloak-postgres
  namespace: datawave
spec:
  instances: 3                   # 1 primary + 2 standbys
  storage:
    size: 20Gi
    storageClass: fast-ssd
  postgresql:
    pg_hba:
      - host keycloak keycloak all scram-sha-256
  backup:
    barmanObjectStore:
      destinationPath: s3://datawave-backups/keycloak-postgres
      serverName: keycloak-postgres
```

**Alternative operators:** [Zalando postgres-operator](https://github.com/zalando/postgres-operator), [Percona Operator for PostgreSQL](https://www.percona.com/software/percona-operator-for-postgresql).

---

### HA Component Summary

| Component | Docker Compose | Production HA |
|---|---|---|
| Trino | 1 coordinator | 1 coordinator + 2–16 workers (HPA) |
| PostgreSQL (×3) | 1 container each | CloudNativePG (3 replicas each) |
| MySQL | 1 container | PlanetScale / AWS RDS Multi-AZ |
| MinIO | 1 container | 4-node distributed / AWS S3 |
| Elasticsearch | 1 container | 3-node cluster / Amazon OpenSearch |
| Nessie | 1 container, in-memory | 2 replicas + DynamoDB/RocksDB store |
| Keycloak | 1 container | 2-replica StatefulSet + JGroups |
| Ranger | 1 container | 1 replica (primary) + SolrCloud |
| Metabase | 1 container | 2-replica Deployment |
| oauth2-proxy | 1 container | 2-replica Deployment |
| Nginx | 1 container | nginx-ingress controller (replicated) |
