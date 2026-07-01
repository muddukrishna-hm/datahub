# DataWave SQL Federation Platform

A production-reference SQL federation stack built with **Trino**, **Apache Ranger**, **Keycloak SSO**, and **Elasticsearch audit** — all running locally via Docker Compose.

Trino federates three data sources through a single SQL endpoint: a PostgreSQL logistics DB, a MySQL inventory DB, and an Apache Iceberg data lake on MinIO/S3. Access control is enforced via file-based RBAC with policies mirrored in Ranger. Every query is audited to Elasticsearch and visualised in Kibana. Metabase provides the BI layer, protected by Keycloak SSO via OAuth2 Proxy.

![DataWave SQL Federation Architecture](docs/datahub.png)

**Docs:** [Architecture](docs/architecture.md) · [Prod Improvements](docs/prod-improvements.md) · [Troubleshooting](docs/troubleshooting.md)

---

## Quick Start

```bash
git clone <repository-url>
cd datahub
cp .env.example .env          # fill in real values before production use
docker compose up -d
```

First boot downloads all images (~3–4 GB). Apache Ranger takes 2–3 minutes to initialise its database schema. **Total first-boot time: ~6–8 minutes.**

### Confirm everything is healthy

```bash
docker compose ps
```

All services should reach `healthy` or `running`:

```
NAME                      STATUS
datawave-trino            healthy
datawave-postgres         healthy
datawave-mysql            healthy
datawave-minio            healthy
datawave-nessie           healthy
datawave-ranger           healthy
datawave-keycloak         healthy
datawave-metabase         healthy
datawave-elasticsearch    healthy
datawave-kibana           running
datawave-nginx            running
```

If a service stays in `starting`, allow another 60 seconds and re-check. If a service shows `unhealthy` or `exited`, see [Troubleshooting](troubleshooting.md).

---

## Accessing the Services

All services sit behind **Nginx** at http://localhost/. Every path is SSO-protected: the first visit redirects to Keycloak, and a valid login grants a session cookie for the rest.

All end-user services are routed through Nginx at http://localhost/ — no ports needed.

| Service | URL | Username | Password |
|---|---|---|---|
| **Metabase** (BI + SQL) | http://localhost/ | `admin@datawave.io` | `METABASE_ADMIN_PASSWORD` in `.env` |
| **Apache Ranger** | http://localhost/ranger/ | `admin` | `RANGER_ADMIN_PASSWORD` in `.env` |
| **Trino UI** | http://localhost/trino/ | any | _(no password — see [Design Decisions](#design-decisions--limitations))_ |
| **MinIO Console** | http://localhost/minio/ | `minioadmin` | `MINIO_ROOT_PASSWORD` in `.env` |
| **Kibana** | http://localhost/kibana/ | `elastic` | `ELASTICSEARCH_PASSWORD` in `.env` |

**Keycloak Admin is the one exception** — it is accessed directly at **http://localhost:8180/** (`admin` / `KEYCLOAK_ADMIN_PASSWORD` in `.env`). Routing Keycloak behind a Nginx subpath requires changing its root path configuration (`KC_HTTP_RELATIVE_PATH`), which propagates to every OIDC discovery endpoint and breaks the oauth2-proxy SSO flow. Keeping it on port 8180 avoids that coupling. In production, Keycloak would sit behind a dedicated hostname (e.g., `auth.datawave.io`) rather than a subpath.

All credentials are in `.env` at the project root. To read one:
```bash
grep ELASTICSEARCH_PASSWORD .env
```

### Pre-configured Keycloak users

| Username | Password | Trino group |
|---|---|---|
| `analyst` | `analyst123` | `data-analyst` |
| `engineer` | `engineer123` | `data-engineer` |
| `admin` | `admin123` | `data-admin` |

---

## Design Decisions & Limitations

- **Double login (Keycloak + Metabase)** — OAuth2 Proxy and Metabase maintain independent sessions; Metabase OSS cannot consume the Keycloak token. → [prod-improvements.md#metabase-sso](prod-improvements.md#4-metabase-sso-single-sign-on)
- **Trino has no authentication** — Trino requires TLS before any auth method can be enabled; skipped here to avoid certificate friction on localhost. Access control rules are enforced; identity is not verified. → [prod-improvements.md#trino-auth](prod-improvements.md#1-trino-authentication)
- **Credentials committed to the repo** — Dev defaults in `.env.example` so the stack starts with one command; `.env` is gitignored and must never hold real values in production. → [prod-improvements.md#security-hardening](prod-improvements.md#security-hardening-additional)
- **No per-user RBAC through Metabase** — Metabase OSS sends all queries as the single service account (`admin`); identity passthrough to Trino requires Metabase Pro. RBAC is fully demonstrable via the [Trino CLI](#rbac--demonstrating-access-control-via-trino-cli). → [prod-improvements.md#metabase-sso](prod-improvements.md#4-metabase-sso-single-sign-on)
- **Ranger policies are not enforced at query time** — Ranger 2.8.0 doesn't publish a pre-built Trino plugin binary; building it from source adds ~15 min and 500 MB to the image build for a dev exercise. Ranger serves as the policy management UI; `rules.json` does the actual enforcement. → [prod-improvements.md#ranger](prod-improvements.md#3-ranger-policy-sync-for-trino)
- **Keycloak is not behind Nginx** — Routing Keycloak under a subpath requires `KC_HTTP_RELATIVE_PATH`, which changes all OIDC discovery endpoints and breaks OAuth2 Proxy. Kept on port `8180` as a deliberate exception.

---

## Running Queries in Metabase

> **Note:** Accessing http://localhost/ requires two logins — first Keycloak (`admin` / `admin123`), then Metabase (`admin@datawave.io` / `METABASE_ADMIN_PASSWORD` from `.env`). See [limitation 1](#1-double-login--keycloak-then-metabase) above.

1. Open **http://localhost/** and complete both logins.
2. Click **New → SQL query**.
3. In the **database selector** (top-left of the SQL editor), choose **DataWave Federation** — the pre-configured Trino connection.
4. Write a query and press **Run** (Shift+Enter).

> Metabase's SQL editor does not accept a trailing semicolon. Write `SHOW CATALOGS`, not `SHOW CATALOGS;`. Semicolons are only required in the Trino CLI.

---

## SQL Reference

### Browse the federated catalog

```sql
SHOW CATALOGS
SHOW SCHEMAS FROM postgresql
SHOW SCHEMAS FROM mysql
SHOW TABLES FROM postgresql.logistics
SHOW TABLES FROM mysql.inventory
DESCRIBE postgresql.logistics.customers
```

### Shipment tracking (PostgreSQL only)

```sql
SELECT
    s.shipment_id,
    c.company_name,
    c.country       AS customer_country,
    s.weight_kg,
    s.status,
    s.dispatched_at
FROM postgresql.logistics.shipments s
JOIN postgresql.logistics.customers c ON s.customer_id = c.customer_id
WHERE s.status = 'IN_TRANSIT'
ORDER BY s.dispatched_at DESC
```

### Items below reorder level (MySQL only)

```sql
SELECT
    w.city           AS warehouse_city,
    i.sku,
    i.product_name,
    i.quantity,
    i.reorder_level,
    s.supplier_name,
    s.lead_time_days
FROM mysql.inventory.inventory i
JOIN mysql.inventory.warehouses w ON i.warehouse_id = w.warehouse_id
JOIN mysql.inventory.suppliers  s ON i.supplier_id  = s.supplier_id
WHERE i.quantity < i.reorder_level
ORDER BY i.quantity ASC
```

### Cross-source JOIN — PostgreSQL + MySQL

This is the core federation capability: a single SQL statement joining two separate database systems.

```sql
SELECT
    s.shipment_id,
    c.company_name,
    r.origin,
    r.destination,
    s.weight_kg                      AS shipment_weight_kg,
    w.warehouse_name                 AS origin_warehouse,
    SUM(i.quantity * i.unit_weight)  AS total_stock_kg
FROM postgresql.logistics.shipments  s
JOIN postgresql.logistics.customers  c ON s.customer_id = c.customer_id
JOIN postgresql.logistics.routes     r ON s.route_id    = r.route_id
JOIN mysql.inventory.warehouses      w ON w.city         = r.origin
JOIN mysql.inventory.inventory       i ON i.warehouse_id = w.warehouse_id
WHERE s.status IN ('PENDING', 'IN_TRANSIT')
GROUP BY
    s.shipment_id, c.company_name, r.origin, r.destination,
    s.weight_kg, w.warehouse_name
ORDER BY s.shipment_id
```

### Per-country revenue estimate

```sql
SELECT
    c.country,
    COUNT(s.shipment_id)                        AS total_shipments,
    SUM(s.weight_kg)                            AS total_weight_kg,
    ROUND(SUM(s.weight_kg * r.cost_per_kg), 2) AS estimated_revenue_usd
FROM postgresql.logistics.shipments  s
JOIN postgresql.logistics.customers  c ON s.customer_id = c.customer_id
JOIN postgresql.logistics.routes     r ON s.route_id    = r.route_id
GROUP BY c.country
ORDER BY estimated_revenue_usd DESC
```

### Built-in benchmark — TPCH (no external DB required)

```sql
SELECT
    n.name            AS nation,
    COUNT(o.orderkey) AS total_orders,
    SUM(o.totalprice) AS total_revenue
FROM tpch.sf1.orders    o
JOIN tpch.sf1.customer  c ON o.custkey   = c.custkey
JOIN tpch.sf1.nation    n ON c.nationkey = n.nationkey
GROUP BY n.name
ORDER BY total_revenue DESC
LIMIT 10
```

### Write to the Iceberg data lake

```sql
CREATE SCHEMA IF NOT EXISTS iceberg.datawarehouse
WITH (location = 's3://warehouse/datawarehouse/')
```

```sql
CREATE TABLE IF NOT EXISTS iceberg.datawarehouse.shipment_events (
    event_id     BIGINT,
    shipment_id  INT,
    event_type   VARCHAR,
    event_ts     TIMESTAMP(6) WITH TIME ZONE,
    payload      VARCHAR
)
WITH (format = 'PARQUET', partitioning = ARRAY['day(event_ts)'])
```

```sql
INSERT INTO iceberg.datawarehouse.shipment_events
SELECT
    CAST(ROW_NUMBER() OVER (ORDER BY s.created_at) AS BIGINT),
    s.shipment_id,
    s.status,
    CAST(s.created_at AS TIMESTAMP(6) WITH TIME ZONE),
    CAST(s.weight_kg AS VARCHAR) || ' kg via route ' || CAST(s.route_id AS VARCHAR)
FROM postgresql.logistics.shipments s
```

---

## Connecting Directly to Trino

### Trino CLI (via Docker exec)

```bash
docker exec -it datawave-trino trino
```

### Trino CLI (external container, run as a specific user)

```bash
docker run --rm --network datawave-sql-federation_datawave-net \
  trinodb/trino:458 trino \
  --server http://trino:8080 \
  --user analyst \
  --execute "SHOW CATALOGS"
```

Replace `analyst` with `engineer` or `admin` to query as a different identity.

### Trino Web UI

Open **http://localhost/trino/** — enter any username (no password). Shows live query history, node status, and resource usage.

### JDBC (DBeaver, DataGrip, IntelliJ)

| Setting | Value |
|---|---|
| Driver | `io.trino:trino-jdbc` |
| JDBC URL | `jdbc:trino://localhost:8080` |
| Username | `analyst`, `engineer`, or `admin` |
| Password | _(leave blank)_ |

---

## RBAC — Demonstrating Access Control via Trino CLI

Trino enforces per-user access control through a file-based group provider (`groups.txt`) and access rules (`rules.json`). The same policies are mirrored in Ranger (visible at http://localhost/ranger/) via the `ranger-init` container. Pass a username with `--user` to query as that identity.

| Identity | Catalogs visible | Table access | `credit_card` column |
|---|---|---|---|
| `analyst` | postgresql, mysql, iceberg, tpch | SELECT only | **NULL (masked)** |
| `engineer` | postgresql, mysql, iceberg, tpch, system | SELECT + DML | visible |
| `admin` | ALL including system | full DML + OWNERSHIP | visible |

### Analyst — read-only, credit_card masked

```bash
docker run --rm --network datawave-sql-federation_datawave-net \
  trinodb/trino:458 trino --server http://trino:8080 --user analyst \
  --execute "SELECT company_name, credit_card FROM postgresql.logistics.customers LIMIT 3"
```

Expected: `credit_card` is `NULL` for every row.

### Analyst — write denied

```bash
docker run --rm --network datawave-sql-federation_datawave-net \
  trinodb/trino:458 trino --server http://trino:8080 --user analyst \
  --execute "INSERT INTO postgresql.logistics.customers(company_name, country, region, contact_email) VALUES ('X', 'US', 'NA', 'x@x.com')"
```

Expected: `Access Denied: Cannot insert into table postgresql.logistics.customers`

### Engineer — real data, write allowed

```bash
docker run --rm --network datawave-sql-federation_datawave-net \
  trinodb/trino:458 trino --server http://trino:8080 --user engineer \
  --execute "SELECT company_name, credit_card FROM postgresql.logistics.customers LIMIT 3"
```

Expected: `credit_card` shows real values.

### Admin — all catalogs, no restrictions

```bash
docker run --rm --network datawave-sql-federation_datawave-net \
  trinodb/trino:458 trino --server http://trino:8080 --user admin \
  --execute "SHOW CATALOGS"
```

Expected: `iceberg`, `mysql`, `postgresql`, `system`, `tpch` — including `system` which is invisible to analysts.

---

## Audit Trail (Kibana)

1. Open **http://localhost/kibana/** — sign in (`elastic` / `ELASTICSEARCH_PASSWORD` from `.env`).
2. Click **Discover** — the `Trino Query Audit` data view is created automatically on first boot.
3. Every Trino query appears with `principal` (who ran it), `query` (the SQL), `@timestamp`, and `errorCode`.

Useful KQL filters in the search bar:

```
principal: analyst
errorCode: PERMISSION_DENIED
```

Or query Elasticsearch directly:

```bash
curl -s -u "elastic:$(grep ELASTICSEARCH_PASSWORD .env | cut -d= -f2)" \
  "http://localhost:9200/trino-query-audit/_search?pretty" \
  -H 'Content-Type: application/json' \
  -d '{"query": {"match_all": {}}, "size": 5}'
```

---

## Adding a New Connector

1. Create `trino/etc/catalog/newdb.properties`:

```properties
connector.name=postgresql
connection-url=jdbc:postgresql://new-host:5432/mydb
connection-user=myuser
connection-password=${ENV:TRINO_NEWDB_PASSWORD}
```

2. Add a secret file and wire it into `docker-compose.yml` under the Trino service `secrets` block and `entrypoint` export.

3. Restart Trino — no image rebuild:

```bash
docker compose restart trino
```

The catalog appears immediately in `SHOW CATALOGS`.

---

## Managing Users

### Add a user via Keycloak UI

1. Open **http://localhost:8180** (Keycloak admin — direct port, not through Nginx) and log in.
2. Select the **datawave** realm from the dropdown.
3. **Users → Add user** — set username, email → **Create**.
4. **Credentials** tab → set a password (uncheck *Temporary*).
5. The user can immediately sign in at http://localhost/.

### Add a user via CLI

```bash
docker exec -it datawave-keycloak /opt/keycloak/bin/kcadm.sh \
  config credentials \
  --server http://localhost:8080 --realm master \
  --user admin --password "$(grep KEYCLOAK_ADMIN_PASSWORD .env | cut -d= -f2)"

docker exec -it datawave-keycloak /opt/keycloak/bin/kcadm.sh \
  create users --target-realm datawave \
  -s username=newanalyst -s email=newanalyst@datawave.io -s enabled=true
```

---

## Stopping the Environment

```bash
docker compose down          # stop containers, keep data volumes
docker compose down -v       # stop containers and delete all data
```
