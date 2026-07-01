# Production Improvements

Production-grade hardening for the architecture in [`architecture.md`](architecture.md) and [`datahub.png`](datahub.png). The dev stack (`docker-compose.yml`) implements the full target topology with shortcuts acceptable for local evaluation. This document maps each diagram path to its production requirements.

---

## Target vs Dev

| Diagram path | Dev stack | Production gap |
|---|---|---|
| Employee → **Superset** → Trino (SQL) | Superset OIDC + `impersonate_user` | HTTPS, network lockdown, Trino must not trust arbitrary `X-Trino-User` |
| **OIDC** (Superset → Keycloak) | Keycloak `start-dev`, H2 DB, HTTP | Postgres DB, clustered Keycloak, TLS, strict redirect URIs |
| **ldap bind** (Keycloak → OpenLDAP) | osixia/openldap, no TLS | LDAPS, corporate AD or replicated OpenLDAP |
| **user/group sync** (OpenLDAP ↔ Ranger) | Manual `groups.txt` alignment | Ranger UserSync service pulling LDAP groups |
| **policy sync** (Ranger → Trino) | `rules.json` file-based mirror | Custom Trino image + Ranger authorizer plugin |
| **event listener** (Trino → ES → Kibana) | Single-node ES, basic auth | 3-node ES cluster, Kibana SSO, index lifecycle |
| Data sources (PG, MySQL, Iceberg/MinIO) | Single containers, Nessie in-memory | Managed DBs, S3, persistent Nessie store |

---

## Contents

| Section | What it covers |
|---|---|
| [Production Readiness Checklist](#production-readiness-checklist) | Prioritised work items |
| [1. Trino Trust Boundary](#1-trino-trust-boundary) | Stop username spoofing from direct Trino access |
| [2. TLS and Ingress](#2-tls-and-ingress) | HTTPS for all user-facing services |
| [3. Ranger Policy Sync](#3-ranger-policy-sync) | Live policy enforcement via Ranger plugin |
| [4. OpenLDAP → Ranger UserSync](#4-openldap--ranger-usersync) | Directory groups drive Ranger policies |
| [5. Keycloak Production](#5-keycloak-production) | Postgres, clustering, realm hygiene |
| [6. Superset Production](#6-superset-production) | OIDC URLs, secrets, roles |
| [7. Observability Production](#7-observability-production) | Elasticsearch HA, Kibana access |
| [8. Keycloak Realm Export](#8-keycloak-realm-export) | Keep committed realm JSON in sync |
| [Security Hardening](#security-hardening) | Passwords, network, resource limits |
| [Limitations and Fixes](#limitations-and-fixes) | Known dev constraints |
| [Scalability](#scalability) | Workers, S3, ES cluster |
| [High Availability and Kubernetes](#high-availability-and-kubernetes) | HA topology and Helm |

---

## Production Readiness Checklist

| # | Item | Priority | Effort |
|---|---|---|---|
| 1 | [Trino trust boundary](#1-trino-trust-boundary) | Critical | Medium |
| 2 | [TLS and Ingress](#2-tls-and-ingress) | Critical | Medium |
| 3 | [Ranger policy sync](#3-ranger-policy-sync) | High | High |
| 4 | [OpenLDAP → Ranger UserSync](#4-openldap--ranger-usersync) | High | Medium |
| 5 | [Keycloak production](#5-keycloak-production) | High | Medium |
| 6 | [Superset production](#6-superset-production) | Medium | Low |
| 7 | [Observability production](#7-observability-production) | Medium | Medium |
| 8 | [Keycloak realm export](#8-keycloak-realm-export) | Low | Low |

---

## 1. Trino Trust Boundary

**Current state:** Trino has no authenticator. Superset sends the logged-in username via `impersonate_user: true` (`X-Trino-User`), and `rules.json` + `groups.txt` enforce RBAC on that principal. Any client that can reach `trino:8080` can claim any username (`--user admin`) and bypass Superset entirely.

**Why deferred:** Trino `PASSWORD` and `OAUTH2` authenticators require HTTPS. The dev stack exposes direct ports and prioritises fast first boot over identity verification at the Trino layer.

**Production goal:** Only Superset (and approved automation) may set the query principal. Direct Trino access requires its own credential.

### Option A — Trusted header + network lockdown (minimum)

Restrict Trino port 8080 to the internal Docker/K8s network. Block host-level exposure. Combine with a header authenticator so only Superset's service account can impersonate:

```properties
# trino/etc/config.properties (requires HTTPS in production)
http-server.authentication.type=HEADER
```

```properties
# trino/etc/header-authenticator.properties
header-authenticator.name=default
```

Superset continues `impersonate_user: true`. All other clients must authenticate via Option B.

> Header authentication alone is insufficient if Trino is reachable from untrusted networks — any client can forge `X-Trino-User`.

### Option B — Keycloak OAUTH2 on Trino (preferred for CLI / Web UI)

Enable Trino's built-in OIDC flow so the Trino Web UI and CLI authenticate directly against Keycloak. Superset still impersonates via its service connection; analysts using SQL Lab inherit the OIDC identity chain.

```properties
# trino/etc/config.properties
http-server.https.enabled=true
http-server.https.port=8443
http-server.https.keystore.path=/run/secrets/trino-keystore.p12
http-server.https.keystore.key=changeit
http-server.authentication.type=OAUTH2
oauth2.issuer=https://auth.datawave.io/realms/datawave
oauth2.jwks-url=http://keycloak:8080/realms/datawave/protocol/openid-connect/certs
oauth2.auth-url=https://auth.datawave.io/realms/datawave/protocol/openid-connect/auth
oauth2.token-url=http://keycloak:8080/realms/datawave/protocol/openid-connect/token
oauth2.client-id=trino-cli
oauth2.principal-field=preferred_username
```

Register a `trino-cli` public client in the Keycloak `datawave` realm. The CLI uses `--external-authentication`.

### Option C — PASSWORD authenticator (internal automation)

For batch jobs and CI pipelines that cannot do browser OIDC:

```properties
http-server.authentication.type=PASSWORD
```

```properties
# trino/etc/password-authenticator.properties
password-authenticator.name=file
file.password-file=/etc/trino/password.db
```

```bash
htpasswd -nbBC 10 etl-bot "$(openssl rand -base64 24)" >> trino/etc/password.db
```

### Certificate generation

Trino requires a PKCS12 keystore for HTTPS. Choose by environment:

| Environment | Approach |
|---|---|
| Local / demo | `mkcert` — browser-trusted, not for production |
| Internal VPN | OpenSSL self-signed CA — distribute `ca.crt` to clients |
| Public / K8s | Let's Encrypt via certbot or cert-manager |
| Enterprise | Corporate PKI or HashiCorp Vault PKI |

**mkcert (dev only):**

```bash
brew install mkcert && mkcert -install
mkcert -pkcs12 -p12-file secrets/trino-keystore.p12 localhost 127.0.0.1 trino.datawave.io
```

**Let's Encrypt (production):**

```bash
sudo certbot certonly --standalone -d trino.datawave.io --agree-tos --email ops@datawave.io
openssl pkcs12 -export \
  -in /etc/letsencrypt/live/trino.datawave.io/fullchain.pem \
  -inkey /etc/letsencrypt/live/trino.datawave.io/privkey.pem \
  -out secrets/trino-keystore.p12 \
  -passout pass:changeit -name trino
```

Mount `secrets/trino-keystore.p12` into the Trino container and set `internal-communication.shared-secret` for multi-node deployments.

### Group provider

The file-based group provider (`trino/etc/group-provider.properties` → `groups.txt`) maps usernames to Trino groups. In production, replace with Ranger's group provider once UserSync is active, or keep `groups.txt` aligned with LDAP group membership via automation.

---

## 2. TLS and Ingress

**Current state:** Every service exposes plain HTTP on `localhost` ports (8080 Trino, 8088 Superset, 8180 Keycloak, 6080 Ranger, 5601 Kibana, etc.). Session cookies and LDAP binds traverse the network unencrypted.

**Production goal:** A single TLS-terminated ingress fronts all user-facing services. Internal service-to-service traffic stays on the cluster network.

### Recommended hostnames

| Host | Backend | Purpose |
|---|---|---|
| `analytics.datawave.io` | Superset `:8088` | Employee BI portal (diagram entry point) |
| `auth.datawave.io` | Keycloak `:8080` | OIDC issuer |
| `trino.datawave.io` | Trino `:8443` | Web UI + JDBC (optional external) |
| `ranger.datawave.io` | Ranger `:6080` | Policy admin |
| `audit.datawave.io` | Kibana `:5601` | Query audit dashboards |

### Docker Compose — add nginx ingress

For on-prem Compose deployments, add an `nginx` reverse proxy as the only service with published ports:

```nginx
# nginx/conf.d/datawave.conf
server {
    listen 443 ssl;
    server_name analytics.datawave.io;

    ssl_certificate     /etc/nginx/ssl/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;

    location / {
        proxy_pass         http://superset:8088;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Forwarded-Proto https;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
    }
}

server {
    listen 443 ssl;
    server_name auth.datawave.io;
    # ... proxy_pass http://keycloak:8080;
}

server {
    listen 443 ssl;
    server_name ranger.datawave.io;
    # ... proxy_pass http://ranger:6080;
}

server {
    listen 443 ssl;
    server_name audit.datawave.io;
    # ... proxy_pass http://kibana:5601;
}
```

Remove all other `ports:` mappings from `docker-compose.yml` except `nginx:443`. Use `docker-compose.dev.yml` to re-expose ports for local debugging.

### Service URL updates after TLS

| Service | Change |
|---|---|
| **Superset** | `WEBDRIVER_BASEURL`, OIDC redirect URIs → `https://analytics.datawave.io/...` |
| **Keycloak** | `KC_HOSTNAME=auth.datawave.io`, remove `KC_HTTP_ENABLED`, set `KC_PROXY=edge` |
| **Kibana** | `SERVER_PUBLICBASEURL=https://audit.datawave.io` |
| **Keycloak realm JSON** | Update `redirectUris` and `webOrigins` for Superset client |

### Kubernetes — cert-manager + Ingress

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
        - analytics.datawave.io
        - auth.datawave.io
        - ranger.datawave.io
        - audit.datawave.io
      secretName: datawave-tls
  rules:
    - host: analytics.datawave.io
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: superset-svc
                port:
                  number: 8088
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
    - host: ranger.datawave.io
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ranger-svc
                port:
                  number: 6080
    - host: audit.datawave.io
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: kibana-svc
                port:
                  number: 5601
```

Trino is typically **not** exposed publicly — analysts reach it through Superset SQL Lab. Expose `trino.datawave.io` only if direct CLI/Web UI access is required.

---

## 3. Ranger Policy Sync

**Current state:** Ranger runs with a policy UI and Solr audit index. Trino enforces access via `trino/etc/rules.json` (file-based). Policy changes in Ranger do not affect live queries.

**Production goal:** Diagram path **policy sync** — Ranger pushes policies to the Trino Ranger plugin at query time.

### Step 1 — Build a custom Trino image

The `trino-ranger` plugin is not in the stock `trinodb/trino` image.

```dockerfile
# trino/Dockerfile
FROM trinodb/trino:458
COPY trino-ranger-plugin-2.8.0.jar /usr/lib/trino/plugin/ranger/
```

Download the JAR from the Apache Ranger `2.8.0` release artifacts (match the `apache/ranger:2.8.0` image version).

### Step 2 — Register the Trino service in Ranger

```bash
curl -u "admin:${RANGER_ADMIN_PASSWORD}" \
  -X POST http://localhost:6080/service/public/v2/api/servicedef \
  -H 'Content-Type: application/json' \
  -d @ranger/scripts/trino-servicedef.json
```

Create a `datawave_trino` service instance in the Ranger UI and define policies per LDAP/Ranger group.

### Step 3 — Switch Trino access control

```properties
# trino/etc/access-control.properties
access-control.name=ranger
ranger.service-name=datawave_trino
ranger.rest-address=http://ranger:6080
ranger.rest-user=admin
ranger.rest-password=${ENV:TRINO_RANGER_PASSWORD}
ranger.policy-cache-dir=/data/trino/ranger-cache
ranger.policy-refresh-interval=30s
```

Pass `TRINO_RANGER_PASSWORD` via environment in `docker-compose.yml` (same value as `RANGER_ADMIN_PASSWORD` or a dedicated Ranger API user).

### Step 4 — Retire `rules.json`

Once Ranger enforcement is verified, remove `security.config-file` from `access-control.properties` and delete `rules.json`. Keep a copy in git as documentation until policies are fully migrated to Ranger.

### Step 5 — Validate

```sql
-- As analyst (via Superset SQL Lab)
SELECT * FROM postgresql.logistics.shipments;  -- allowed

-- As analyst, attempt admin catalog
SHOW SCHEMAS FROM system;  -- denied per Ranger policy
```

Policies propagate within `ranger.policy-refresh-interval` (default 30s).

---

## 4. OpenLDAP → Ranger UserSync

**Current state:** OpenLDAP holds users (`analyst`, `engineer`, `admin`) and groups (`data-analyst`, `data-engineer`, `data-admin`). Trino `groups.txt` maps group names to members manually. Ranger policies reference group names but UserSync is not configured.

**Production goal:** Diagram path **user/group sync** (dashed arrow) — Ranger UserSync pulls LDAP users and groups so policies attach to real directory principals.

### Step 1 — Deploy Ranger UserSync

Add a `ranger-usersync` service (not in the current compose):

```yaml
ranger-usersync:
  image: apache/ranger:2.8.0
  command: ["/opt/ranger/usersync/ranger-usersync-services.sh"]
  environment:
    POLICY_MGR_URL: http://ranger:6080
    SYNC_LDAP_URL: ldap://openldap:389
    SYNC_LDAP_BIND_DN: cn=admin,dc=datawave,dc=io
    SYNC_LDAP_BIND_PASSWORD: ${LDAP_ADMIN_PASSWORD}
    SYNC_LDAP_USER_SEARCH_BASE: ou=users,dc=datawave,dc=io
    SYNC_LDAP_USER_SEARCH_FILTER: "(uid={0})"
    SYNC_LDAP_GROUP_SEARCH_BASE: ou=groups,dc=datawave,dc=io
    SYNC_LDAP_GROUP_SEARCH_FILTER: "(member=uid={0},ou=users,dc=datawave,dc=io)"
    SYNC_LDAP_GROUP_NAME_ATTRIBUTE: cn
  depends_on:
    ranger:
      condition: service_healthy
    openldap:
      condition: service_healthy
```

Tune `ranger-usersync-site.xml` for your LDAP schema. For corporate Active Directory, point `SYNC_LDAP_URL` at `ldaps://ad.corp.example:636`.

### Step 2 — Align Ranger policies with LDAP groups

Define Ranger policies on `data-analyst`, `data-engineer`, `data-admin` — the same names provisioned in `openldap/init/01-init.ldif`. UserSync creates matching Ranger principals automatically.

### Step 3 — Retire manual `groups.txt` (optional)

With Ranger UserSync + Ranger authorizer plugin, Trino resolves group membership from Ranger rather than `groups.txt`. Remove the file-based group provider or keep it as fallback during migration.

### OpenLDAP production

| Dev | Production |
|---|---|
| `osixia/openldap:1.5.0`, port 389 | LDAPS (636), replicated pair or corporate AD |
| Bootstrap LDIF | HR-driven provisioning or AD federation |
| `LDAP_TLS=false` | `LDAP_TLS=true` + valid cert |

Keycloak continues **ldap bind** against the directory; only the transport and availability model change.

---

## 5. Keycloak Production

**Current state:** Keycloak runs `start-dev` with an embedded H2 database. Realm `datawave` is imported from `keycloak/datawave-realm.json` on first boot. LDAP user federation points at OpenLDAP.

**Production changes:**

### Move to PostgreSQL

```yaml
keycloak:
  image: quay.io/keycloak/keycloak:24.0
  command: start --import-realm   # remove start-dev
  environment:
    KC_DB: postgres
    KC_DB_URL: jdbc:postgresql://postgres:5432/keycloak
    KC_DB_USERNAME: keycloak
    KC_DB_PASSWORD: ${KEYCLOAK_DB_PASSWORD}
    KC_HOSTNAME: auth.datawave.io
    KC_PROXY: edge
    KC_HTTP_ENABLED: "false"
    KC_HTTPS_CERTIFICATE_FILE: /opt/keycloak/certs/tls.crt
    KC_HTTPS_CERTIFICATE_KEY_FILE: /opt/keycloak/certs/tls.key
```

Add a `keycloak` database to PostgreSQL init or use a dedicated RDS instance.

### Clustering (HA)

```yaml
command: start --cache=ispn --cache-stack=kubernetes
environment:
  JGROUPS_DISCOVERY_PROTOCOL: dns.DNS_PING
  JGROUPS_DISCOVERY_PROPERTIES: "dns_query=keycloak-headless.datawave.svc.cluster.local"
```

Run 2+ replicas behind the ingress. All nodes share the same Postgres database.

### Security hygiene

- Restrict **Valid Redirect URIs** on the `superset` client to `https://analytics.datawave.io/*`
- Enable **Brute Force Detection** (Realm Settings → Security Defenses)
- Rotate `SUPERSET_OIDC_SECRET` and update both `.env` and `keycloak/datawave-realm.json`
- Ensure `LDAP_ADMIN_PASSWORD` in `.env` matches Keycloak federation `bindCredential`
- Remove `KC_HOSTNAME_STRICT: false` in production

---

## 6. Superset Production

**Current state:** Superset authenticates via Keycloak OIDC (`KeycloakSecurityManager` in `superset/superset_config.py`). The Trino connection uses `impersonate_user: true` so the OIDC `preferred_username` becomes the Trino principal. This matches the diagram's direct Superset → Trino SQL arrow.

**Production changes:**

### HTTPS and OIDC URLs

Update `superset_config.py` so server-side token exchange and browser redirects both use production hostnames:

```python
KEYCLOAK_INTERNAL = "https://auth.datawave.io"          # or http://keycloak:8080 behind ingress
KEYCLOAK_PUBLIC     = "https://auth.datawave.io"

OAUTH_PROVIDERS = [{
    "name": "keycloak",
    "token_key": "access_token",
    "icon": "fa-key",
    "remote_app": {
        "client_id": "superset",
        "client_secret": os.environ["SUPERSET_OIDC_SECRET"],
        "api_base_url": f"{KEYCLOAK_INTERNAL}/realms/datawave/protocol/openid-connect",
        "access_token_url": f"{KEYCLOAK_INTERNAL}/realms/datawave/protocol/openid-connect/token",
        "authorize_url": f"{KEYCLOAK_PUBLIC}/realms/datawave/protocol/openid-connect/auth",
        "client_kwargs": {"scope": "openid email profile"},
    },
}]
```

### Secrets

```bash
# Generate before any non-local deployment
openssl rand -hex 32  # SUPERSET_SECRET_KEY
openssl rand -base64 32  # SUPERSET_OIDC_SECRET — also update Keycloak client secret
```

Never commit `.env` with production values. Use a secrets manager or K8s Secrets.

### Role mapping

`AUTH_ROLES_MAPPING` promotes Keycloak groups to Superset roles. Ensure Keycloak issues `groups` claim (add a group mapper in the realm) and map:

| Keycloak / LDAP group | Superset role |
|---|---|
| `data-admin` | Admin |
| `data-engineer` | Alpha |
| `data-analyst` | Gamma |

### Caching

Enable Superset result caching (Redis or Metacache DB) for dashboard queries against Trino — reduces repeated federation load:

```python
RESULTS_BACKEND = RedisCache(host='redis', port=6379, key_prefix='superset_')
```

---

## 7. Observability Production

**Current state:** Trino HTTP event listener POSTs completed queries to `elasticsearch:9200/trino-query-audit/_doc`. Kibana visualises the `trino-query-audit` index. Elasticsearch is single-node; `es-init` sets `kibana_system` password and the `add-timestamp` ingest pipeline.

### Elasticsearch HA

Replace `discovery.type=single-node` with a 3-node cluster:

```yaml
environment:
  - cluster.name=datawave-audit
  - discovery.seed_hosts=elasticsearch-2,elasticsearch-3
  - cluster.initial_master_nodes=es-1,es-2,es-3
  - xpack.security.enabled=true
```

On AWS/GCP use **Amazon OpenSearch Service** or **Elastic Cloud** — update `http-event-listener.connect-ingest-uri` in `trino/start.sh`.

### Index lifecycle

Add an ILM policy to roll over `trino-query-audit` daily and delete indices older than 90 days:

```bash
curl -u elastic:${ELASTICSEARCH_PASSWORD} -X PUT \
  "http://elasticsearch:9200/_ilm/policy/trino-audit-policy" \
  -H 'Content-Type: application/json' \
  -d '{"policy":{"phases":{"hot":{"actions":{"rollover":{"max_age":"1d"}}},"delete":{"min_age":"90d","actions":{"delete":{}}}}}}'
```

### Kibana access

- Set `SERVER_PUBLICBASEURL=https://audit.datawave.io`
- Restrict Kibana to admin/security teams — not general analysts
- Optionally integrate Kibana with Keycloak OIDC (Elastic Stack 8.x supports SAML/OIDC)
- Enable audit index encryption at rest (cloud provider or ES encryption)

### Ranger audit

Ranger writes its own audit trail to `ranger-solr:8983`. In production, use SolrCloud with replication factor ≥ 2, or forward Ranger audits to the same Elasticsearch cluster for unified search.

---

## 8. Keycloak Realm Export

**Current state:** `keycloak/datawave-realm.json` is imported on first boot. UI changes are not written back to the file.

```bash
docker exec datawave-keycloak /opt/keycloak/bin/kc.sh export \
  --realm datawave \
  --users realm_file \
  --file /tmp/realm-export.json

docker cp datawave-keycloak:/tmp/realm-export.json keycloak/datawave-realm.json
```

Run after any manual realm change. Consider a `make export-realm` target or pre-commit hook when Keycloak is running locally.

---

## Security Hardening

### Rotate all `.env` defaults

`.env.example` contains dev passwords. Before any shared deployment:

```bash
cp .env.example .env
# Replace every value — example:
POSTGRES_PASSWORD=$(openssl rand -base64 32)
MYSQL_PASSWORD=$(openssl rand -base64 32)
MINIO_ROOT_PASSWORD=$(openssl rand -base64 32)
ELASTICSEARCH_PASSWORD=$(openssl rand -base64 32)
RANGER_ADMIN_PASSWORD=$(openssl rand -base64 32)
LDAP_ADMIN_PASSWORD=$(openssl rand -base64 32)
KEYCLOAK_ADMIN_PASSWORD=$(openssl rand -base64 32)
SUPERSET_SECRET_KEY=$(openssl rand -hex 32)
SUPERSET_OIDC_SECRET=$(openssl rand -base64 32)
```

Add `.env` to `.gitignore`. In CI/CD inject secrets from Vault, AWS Secrets Manager, or K8s External Secrets.

### Disable direct port exposure

Remove all `ports:` from `docker-compose.yml` except the ingress (nginx `:443` or `:80` redirect). Internal services communicate on `datawave-net` only.

### Resource limits

```yaml
deploy:
  resources:
    limits:
      memory: 4g
      cpus: '2'
```

Apply to Trino, Elasticsearch, Ranger, and Keycloak — all JVM-heavy.

### Trino query guardrails

```properties
query.max-run-time=30m
query.max-execution-time=25m
query.client.timeout=30m
```

Prevent runaway federation queries from exhausting coordinator memory.

---

## Limitations and Fixes

### L1 — Trino accepts spoofed usernames

**Limitation:** No authenticator; any client can pass `--user admin`.

**Fix:** [Trino trust boundary](#1-trino-trust-boundary) — network lockdown + OAUTH2 or trusted-header with ingress-only access.

---

### L2 — Ranger does not enforce at query time

**Limitation:** `rules.json` is the live enforcement layer; Ranger UI is documentation only.

**Fix:** [Ranger policy sync](#3-ranger-policy-sync).

---

### L3 — LDAP groups not synced to Ranger

**Limitation:** `groups.txt` is manually aligned with OpenLDAP. Ranger policies may reference groups that do not exist in Ranger.

**Fix:** [OpenLDAP → Ranger UserSync](#4-openldap--ranger-usersync).

---

### L4 — Single node for every service

**Limitation:** No fault tolerance. Trino OOM kills all in-flight queries.

**Fix:** [High Availability and Kubernetes](#high-availability-and-kubernetes).

---

### L5 — Nessie in-memory store

**Limitation:** `NESSIE_VERSION_STORE_TYPE=IN_MEMORY` — Iceberg metadata lost on restart.

**Fix:**

```yaml
environment:
  NESSIE_VERSION_STORE_TYPE: ROCKSDB
  NESSIE_VERSION_STORE_PERSIST_ROCKSDB_DATABASE_PATH: /var/nessie/data
volumes:
  - nessie_data:/var/nessie/data
```

For production HA use `DYNAMODB` or a replicated JDBC backend.

---

### L6 — Keycloak H2 embedded database

**Limitation:** `start-dev` mode; data loss risk; not clusterable.

**Fix:** [Keycloak production](#5-keycloak-production) — Postgres + `start` command.

---

### L7 — Plain-text credentials in `.env.example`

**Limitation:** Example passwords are committed to git.

**Fix:** Generate unique secrets per environment; never commit `.env`.

---

### L8 — No query result caching

**Limitation:** Repeated dashboard queries re-scan source databases and MinIO Parquet files.

**Fix:** Superset Redis cache + Trino spill/cache volume for Iceberg scans.

---

## Scalability

### Trino — horizontal workers

Add worker containers; coordinator sets `node-scheduler.include-coordinator=false`:

```properties
# worker config.properties
coordinator=false
discovery.uri=http://trino:8080
```

| Workload | Workers | Memory per worker |
|---|---|---|
| < 10 analysts | 1 coordinator only | 4 GB |
| 10–50 analysts | 2–4 workers | 8 GB each |
| 50+ analysts, heavy Iceberg | 4–8 workers + HPA | 16 GB each |

### MinIO — distributed mode or S3

Replace single-node MinIO with a 4-node erasure-coded cluster, or point `iceberg.properties` at AWS S3 (change only `s3.endpoint` and credentials).

### Elasticsearch — multi-node

See [Observability production](#7-observability-production).

### Ranger

Ranger Admin is single-primary. Scale Solr audit index replication; increase `ranger.policy-refresh-interval` to 60s under heavy policy churn.

---

## High Availability and Kubernetes

### Production topology

```
                         ┌─────────────────────────────────────────┐
                         │           Kubernetes Cluster           │
  Employees ────────────►│  Ingress (nginx-ingress + cert-manager) │
                         │         analytics.datawave.io            │
                         └──────────────────┬──────────────────────┘
                                            │
              ┌─────────────────────────────┼─────────────────────────────┐
              │                             │                             │
         Superset (×2)                  Keycloak (×2)                 Ranger (×1)
         Deployment                   StatefulSet                   Deployment
              │                             │                             │
              │ OIDC                        │ ldap bind                   │ user/group sync
              │                             ▼                             ▼
              │                        OpenLDAP / AD ◄────────────── Ranger UserSync
              │ SQL + impersonation           │
              └──────────────► Trino Coordinator (×1) ◄──── policy sync ──┘
                                    │
                         Workers (×2–16, HPA)
                                    │
              ┌─────────────────────┼─────────────────────┐
              ▼                     ▼                     ▼
         PostgreSQL              MySQL            Iceberg (Nessie + S3)
         (operator)            (RDS)              MinIO distributed / S3
                                    │
                         Elasticsearch (×3) ──► Kibana
                         ▲
                         │ event listener
                       Trino
```

### Helm charts

| Component | Chart |
|---|---|
| Trino | `helm install trino trino/trino` |
| Keycloak | `bitnami/keycloak` |
| Superset | `apache/superset` or custom Deployment |
| MinIO | `minio/minio` (or native S3) |
| Elasticsearch | `elastic/elasticsearch` |
| Ingress | `ingress-nginx/ingress-nginx` |
| Ranger | Manual Deployment (no official chart) |
| Nessie | Custom Deployment + persistent volume |

### Trino Helm values (excerpt)

```yaml
coordinator:
  resources:
    requests: { memory: "4Gi", cpu: "2" }
    limits:   { memory: "8Gi", cpu: "4" }

worker:
  replicas: 4
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
    connection-password=${ENV:POSTGRES_PASSWORD}
  iceberg: |
    connector.name=iceberg
    iceberg.catalog.type=nessie
    iceberg.nessie-catalog.uri=http://nessie-svc:19120/api/v1
    iceberg.nessie-catalog.default-warehouse-dir=s3://warehouse/
    s3.endpoint=https://s3.amazonaws.com
```

### Secrets on Kubernetes

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: datawave-secrets
  namespace: datawave
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: datawave-secrets
  data:
    - secretKey: postgres-password
      remoteRef: { key: datawave/postgres, property: password }
    - secretKey: superset-oidc-secret
      remoteRef: { key: datawave/superset, property: oidc-secret }
```

### Database HA

| Database | Dev | Production |
|---|---|---|
| PostgreSQL (logistics + ranger) | 1 container | CloudNativePG 3-node cluster or RDS Multi-AZ |
| PostgreSQL (keycloak) | H2 embedded | Dedicated RDS / operator cluster |
| MySQL (inventory) | 1 container | RDS Multi-AZ or Percona operator |

### HA component summary

| Component | Docker Compose (dev) | Production HA |
|---|---|---|
| Trino | 1 coordinator | 1 coordinator + 2–16 workers (HPA) |
| Superset | 1 container | 2-replica Deployment + Redis |
| Keycloak | 1 container, H2 | 2-replica StatefulSet + Postgres |
| OpenLDAP | 1 container | Corporate AD or replicated LDAP |
| Ranger | 1 container | 1 primary + SolrCloud |
| Ranger UserSync | Not deployed | 1 Deployment (sidecar or separate) |
| Elasticsearch | 1 container | 3-node cluster / OpenSearch Service |
| Kibana | 1 container | 2-replica Deployment |
| Nessie | 1 container, in-memory | 2 replicas + RocksDB/DynamoDB |
| MinIO | 1 container | 4-node distributed / AWS S3 |
| Ingress | Direct ports | nginx-ingress + cert-manager |

---

## Related Documentation

| Document | Contents |
|---|---|
| [architecture.md](architecture.md) | Current system diagram and implementation status |
| [README](../README.md) | Quick start and service URLs |
| [HLD](../.claude/HLD.md) | Identity and Ranger flow notes |
| [troubleshooting.md](troubleshooting.md) | Common failures |
