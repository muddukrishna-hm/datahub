# Architecture — DataWave SQL Federation Platform

## System Diagram

![DataWave SQL Federation Architecture](datahub.png)

**Trino** is the central federation engine. Three bounded regions connect to it:

| Region | Components |
|---|---|
| **Data Sources** | PostgreSQL (logistics), MySQL (inventory), Iceberg tables on MinIO/S3 |
| **Identity & Access** | Employees → Superset → Keycloak → OpenLDAP → Apache Ranger |
| **Observability** | Trino → Elasticsearch → Kibana |

### Flow summary

| Diagram label | Path | What happens |
|---|---|---|
| *(direct arrow)* | **Query** | Employee logs into Superset via Keycloak; Superset sends SQL to Trino with the logged-in username |
| **OIDC** | **Login** | Superset redirects the browser to Keycloak; Keycloak returns an ID token |
| **ldap bind** | **Directory** | Keycloak verifies the user's password with an LDAP bind against OpenLDAP |
| **user/group sync** *(dashed)* | **Ranger sync** | OpenLDAP user/group membership is synced into Ranger so policies reference real directory groups |
| **policy sync** | **Authorization** | Ranger pushes access policies to Trino; `rules.json` mirrors these policies for enforcement |
| **event listener** | **Audit** | Trino HTTP event listener POSTs every completed query to Elasticsearch; Kibana visualises the audit trail |

MinIO/S3 stores Parquet data files; Iceberg (via Nessie REST catalog) provides table metadata that Trino queries directly.

---

## Design Philosophy

1. **Single SQL endpoint.** Analysts write standard SQL against one address (`trino:8080`) regardless of whether data lives in PostgreSQL, MySQL, or an Iceberg lakehouse on object storage. No ETL, no data movement.

2. **Open standards at every layer.** Trino (SQL), Iceberg (table format), OIDC (identity), LDAP (directory), S3 (object storage), and Elasticsearch (audit) are all vendor-neutral and swappable.

3. **Security at the infrastructure layer.** Identity (Keycloak + LDAP), authorization (Ranger), and audit (Elasticsearch) are enforced before and after queries — not inside application code.

4. **Direct service ports for local dev.** Services expose their own ports on `localhost` with no reverse-proxy layer, keeping first-time setup friction low. A single ingress (nginx / Ingress controller) is a production concern — see [`prod-improvements.md`](prod-improvements.md).

---

## Technology Selection Rationale

### Federation Engine — Trino
**Chosen over:** Apache Spark SQL, Presto, Dremio, Apache Drill

Trino is purpose-built for interactive, read-path SQL federation across heterogeneous sources. Unlike Spark (batch-first, heavy JVM overhead) or Dremio (proprietary acceleration layer), Trino's connector model pushes predicates down to each source, merges results in memory, and returns in seconds — not minutes. Its file-based ACL and `groups.txt` group provider allow zero-dependency RBAC in dev that maps directly to a production Ranger plugin swap.

### Policy Management — Apache Ranger
**Chosen over:** OPA (Open Policy Agent), Casbin, hand-rolled middleware

Ranger is the industry standard for centralised access control across data platform services (Hive, HDFS, Kafka, Trino). Its UI provides a single pane to define column masking, row filtering, and table-level grants without touching configuration files. The `datawave_trino` Ranger service type maps natively to Trino's access types (`select`, `insert`, `delete`, `all`). In production the Ranger-Trino plugin enforces policies at query time — no sync script needed.

### Identity Provider — Keycloak
**Chosen over:** Auth0, Okta, AWS Cognito, Dex

Keycloak is self-hosted, open-source, and OIDC/OAuth2 compliant out of the box. Its built-in LDAP User Federation means OpenLDAP users appear in Keycloak with zero custom code — just a JSON configuration block in the realm file. This mirrors how enterprises federate Active Directory into their SSO layer. Auth0/Okta would require paid plans or mocked LDAP binds, adding friction to a local demo.

### User Directory — OpenLDAP
**Chosen over:** Active Directory (unavailable locally), FreeIPA (heavy), static config files

OpenLDAP provides the standard LDAP protocol (`ldap://`) that every enterprise identity system speaks. Bootstrapping via LDIF files is reproducible and version-controllable. The same LDIF structure works against a production Active Directory or FreeIPA instance with only the `dc=` base DN changed.

### BI Interface — Apache Superset
**Chosen over:** Grafana, Metabase, Redash, Tableau

Superset has native Trino/Presto SQLAlchemy support and the `impersonate_user=True` connection flag — the only off-the-shelf BI tool that transparently forwards the logged-in user's identity to Trino, enabling per-user RBAC enforcement without a proxy layer. Its Flask-AppBuilder security layer integrates directly with Keycloak OIDC via `AUTH_OAUTH`.

### Audit Store — Elasticsearch + Kibana
**Chosen over:** PostgreSQL logs, Loki, Splunk, Datadog

Trino's HTTP Event Listener POSTs completed-query JSON directly to Elasticsearch with no intermediate agent. Elasticsearch's inverted index makes `principal: analyst AND errorCode: PERMISSION_DENIED` queries sub-second even at high query volumes. Kibana provides ad-hoc search and dashboard visualisation over the same data. The stack is S3-snapshotable in production for long-term retention.

### Object Storage — MinIO
**Chosen over:** Local filesystem mounts, AWS S3 (requires account)

MinIO implements the S3 API exactly — Trino's Iceberg connector uses the same `s3://` URI scheme and AWS SDK code paths it would use in production. Switching from MinIO to AWS S3 requires only two environment variable changes (`s3.endpoint` and credentials). This makes MinIO the ideal S3 stand-in for local development.

### Iceberg Table Format + Nessie Catalog
**Chosen over:** Hive Metastore + ORC, Delta Lake, Apache Hudi

Apache Iceberg is the emerging open standard for lakehouse tables (ACID, schema evolution, time travel, partition pruning). Nessie provides an Iceberg REST catalog with Git-like branch semantics — enabling reproducible data states — without the ZooKeeper + JVM overhead of a Hive Metastore. In production, Nessie can be backed by a persistent store (RocksDB, DynamoDB) with a one-line config change.

### Heterogeneous Sources — PostgreSQL + MySQL
**Chosen for contrast:** Two different RDBMS vendors in the same federated query

Using both PostgreSQL (logistics) and MySQL (inventory) demonstrates Trino's core value proposition: a cross-source JOIN that would otherwise require an ETL pipeline. PostgreSQL is used for its advanced analytics features (window functions, JSONB, partitioning); MySQL represents the common operational database found in enterprise SaaS products.

### Orchestration — Docker Compose
**Chosen over:** Kubernetes, Nomad, bare-metal scripts

Docker Compose gives a reproducible, single-command local environment with `depends_on` health-check ordering and named volumes — no cluster, no cloud account, no Helm charts required. The same container images and environment variables are production-ready; the only change is the orchestrator (see [`prod-improvements.md`](prod-improvements.md)).

---

## Implementation Status

The diagram above is the **target** architecture. The table below maps each component to its state in the current `docker-compose.yml`.

| Component | Diagram role | Status | Notes |
|---|---|---|---|
| PostgreSQL | Logistics OLTP source | **Running** | `postgres:5432` |
| MySQL | Inventory OLTP source | **Running** | `mysql:3306` |
| MinIO | S3-compatible storage | **Running** | `minio:9000` / console `:9001` |
| Iceberg (Nessie) | Lakehouse catalog | **Running** | Nessie REST catalog, in-memory store |
| OpenLDAP | User directory | **Running** | `openldap:389`; osixia/openldap 1.5.0; LDIF-bootstrapped |
| Keycloak | OIDC identity provider | **Running** | `keycloak:8180`; H2 embedded DB; `datawave` realm imported on first boot |
| Trino | Federation engine | **Running** | `trino:8080`; `groups.txt` RBAC; HTTP event listener to ES |
| Apache Ranger | Policy management | **Running** | `ranger:6080`; shares Postgres `ranger` DB |
| Apache Superset | BI + SQL interface | **Running** | `superset:8088`; Keycloak OIDC; `impersonate_user=True` |
| Elasticsearch | Query audit store | **Running** | `elasticsearch:9200` |
| Kibana | Audit dashboards | **Running** | `kibana:5601`; `kibana_system` password set by `es-init` |
| Ranger → Trino policy sync | Live enforcement | **Partial** | Ranger UI + `rules.json` mirror; Ranger-Trino plugin not wired |

---

## Network Map

All containers share a single Docker bridge network `datawave-net` (`172.20.0.0/16`). Services reach each other by container name via Docker DNS.

```
┌──────────────────────────── datawave-net  172.20.0.0/16 ────────────────────────────┐
│                                                                                     │
│  IDENTITY & ACCESS                                                                  │
│  ─────────────────                                                                  │
│  Employees ──► superset:8088 ──OIDC──► keycloak:8080 ──LDAP──► openldap:389       │
│  openldap:1389 ─ ─ ─user/group sync─ ─ ─► ranger:6080                             │
│  ranger:6080 ──policy sync──► trino:8080                                           │
│  superset:8088 ──SQL + impersonation──► trino:8080                                 │
│                                                                                     │
│  DATA SOURCES                                                                       │
│  ────────────                                                                       │
│  trino:8080 ──────► postgres:5432       (postgresql catalog)                        │
│              ──────► mysql:3306          (mysql catalog)                            │
│              ──────► nessie:19120        (iceberg catalog metadata)                 │
│              ──────► minio:9000          (iceberg Parquet files)                    │
│                                                                                     │
│  AUTHORIZATION BACKEND                                                              │
│  ─────────────────────                                                              │
│  ranger:6080 ──────► postgres:5432       (ranger DB on shared instance)             │
│              ──────► ranger-solr:8983    (Ranger audit index)                       │
│                                                                                     │
│  OBSERVABILITY                                                                      │
│  ─────────────                                                                      │
│  trino:8080 ─ ─event listener─ ─► elasticsearch:9200 ──► kibana:5601               │
│                                                                                     │
│  OBJECT STORAGE                                                                     │
│  ──────────────                                                                     │
│  nessie:19120 ─────► minio:9000          (warehouse bucket via Trino S3 layer)      │
│                                                                                     │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

### Port Reference

| Host Port | Service | Purpose |
|---|---|---|
| **389** | openldap | LDAP directory (osixia/openldap, standard port) |
| **3306** | mysql | Inventory DB |
| **5432** | postgres | Logistics DB (+ Ranger policy store) |
| **5601** | kibana | Audit dashboards |
| **6080** | ranger | Ranger Admin UI |
| **8080** | trino | Web UI + JDBC/HTTP API |
| **8088** | superset | BI portal + SQL Lab |
| **8180** | keycloak | OIDC issuer + Admin Console |
| **8983** | ranger-solr | Ranger audit index (dev) |
| **9000** | minio | S3 API |
| **9001** | minio | Console UI |
| **9200** | elasticsearch | Audit REST API |
| **19120** | nessie | Iceberg REST catalog |

---

## Layer 1 — Data Federation

### Trino (SQL Federation Engine)

Trino is the hub. It receives SQL from Superset (or any JDBC/CLI client), applies access-control rules, pushes predicates down to each source, and merges results in memory.

| Property | Value |
|---|---|
| Image | `trinodb/trino:458` |
| Container | `datawave-trino` |
| Port | `8080` |
| Catalogs | `postgresql`, `mysql`, `iceberg`, `tpch` (built-in) |
| Access control | File-based — `rules.json` + `groups.txt` |
| Audit | HTTP Event Listener → `elasticsearch:9200/trino-query-audit/_doc` |

**Catalog connectors:**

| Catalog | Connector | Backend |
|---|---|---|
| `postgresql` | `postgresql` | `postgres:5432/logistics` |
| `mysql` | `mysql` | `mysql:3306/inventory` |
| `iceberg` | `iceberg` (Nessie REST) | `nessie:19120` + `minio:9000/warehouse` |

**RBAC groups (`trino/etc/groups.txt`):**

```
data-analyst:analyst
data-engineer:engineer
data-admin:admin,krishna,trino
```

Each entry maps a Trino group name to its members. Users authenticate via Keycloak OIDC; Superset passes the `preferred_username` to Trino as the query principal; Trino looks up the username here to resolve group membership before applying `rules.json`.

**RBAC rules (`trino/etc/rules.json`) — summary:**

| Group | Catalogs | Privileges |
|---|---|---|
| `data-admin` | all | ALL + OWNERSHIP |
| `data-engineer` | `postgresql`, `mysql`, `iceberg` | SELECT + DML + DDL |
| `data-analyst` | `postgresql`, `mysql`, `iceberg`, `tpch` | SELECT only; `credit_card` masked |
| (default) | all | NONE (implicit deny) |

### PostgreSQL — Logistics

| Property | Value |
|---|---|
| Database | `logistics` |
| User | `datawave` |
| Schema | `customers`, `routes`, `shipments` |
| Also hosts | `ranger` database for Apache Ranger policy store |

### MySQL — Inventory

| Property | Value |
|---|---|
| Database | `inventory` |
| User | `datawave` |
| Schema | `warehouses`, `suppliers`, `inventory` |

### MinIO + Nessie — Iceberg Lakehouse

```
MinIO (S3 API)  ──►  Parquet data files in warehouse/
Nessie (REST)   ──►  Iceberg table metadata (git-like branches)
Trino iceberg connector ──► Nessie for catalog, MinIO for I/O
```

| Bucket | Purpose |
|---|---|
| `warehouse` | Iceberg table data (Nessie-managed) |
| `raw-data` | Landing zone for ingestion |
| `archive` | Historical snapshots |

---

## Layer 2 — Analytics Interface

### Apache Superset

Superset is the employee-facing BI and SQL interface. It authenticates via Keycloak OIDC and passes the logged-in username to Trino so RBAC is enforced per user.

| Property | Value |
|---|---|
| Image | Custom build (`superset/Dockerfile`) |
| Container | `datawave-superset` |
| Port | `8088` |
| URL | http://localhost:8088 |
| Auth | Keycloak OIDC (`AUTH_TYPE = AUTH_OAUTH`, `KeycloakSecurityManager`) |
| Trino identity | `impersonate_user=True` on the DataWave Federation DB connection |

The `KeycloakSecurityManager` maps `preferred_username` from the Keycloak JWT to the Superset/Trino username. The `admin` user is automatically promoted to the Superset Admin role via `AUTH_ROLES_MAPPING`.

### Keycloak + OpenLDAP

```
Employees → Superset ──OIDC──► Keycloak ──LDAP──► OpenLDAP
```

Keycloak issues OIDC tokens after validating credentials against OpenLDAP. Superset is the OIDC relying party; its custom security manager extracts `preferred_username` from the userinfo endpoint and uses it as the Trino query principal.

| Property | Value |
|---|---|
| Keycloak image | `quay.io/keycloak/keycloak:24.0` |
| Keycloak DB | H2 embedded (`start-dev`) — no separate DB container |
| Realm | `datawave` (imported from `keycloak/datawave-realm.json` at first boot) |
| Client | `superset` — confidential OIDC client |
| OpenLDAP image | `osixia/openldap:1.5.0` |
| Base DN | `dc=datawave,dc=io` (auto-created from `LDAP_DOMAIN=datawave.io`) |
| Bootstrap LDIF | `openldap/init/01-init.ldif` (loaded via `--copy-service` at first boot) |
| Users | `analyst`, `engineer`, `admin` |
| Groups | `data-analyst`, `data-engineer`, `data-admin` |

> **Split URL constraint:** Superset uses `http://keycloak:8080` for server-side token exchange and `http://localhost:8180` for browser-facing redirects. Keycloak realm JSON `bindCredential` and Superset client `secret` are hardcoded dev values — if changed, also update `keycloak/datawave-realm.json` and delete the `keycloak_data` volume.

---

## Layer 3 — Authorization

### Apache Ranger

Ranger is the policy management and audit UI for the federation layer.

| Property | Value |
|---|---|
| Image | `apache/ranger:2.8.0` |
| Container | `datawave-ranger` |
| Port | `6080` |
| Admin URL | http://localhost:6080 |
| Policy store | PostgreSQL (`ranger` DB on shared `postgres` instance) |
| Audit index | `ranger-solr:8983` |

**Policy sync (diagram):**

```
Apache Ranger  ──policy sync──►  Trino Ranger Plugin  ──►  per-query allow/deny
```

> **Current state:** The Ranger-Trino authorizer plugin is not installed (requires a custom Trino image build). Ranger serves as the **policy documentation UI**; `rules.json` enforces access at query time. Policies in Ranger and rules in `rules.json` are kept aligned manually. See [`prod-improvements.md`](prod-improvements.md#3-ranger-policy-sync).

**Target policy model (Ranger `datawave_trino` service):**

| Group | Catalogs | Access |
|---|---|---|
| `data-analyst` | `postgresql`, `mysql`, `iceberg`, `tpch` | SELECT |
| `data-engineer` | `postgresql`, `mysql`, `iceberg` | SELECT + DML + DDL |
| `data-admin` | all | ALL |
| `data-analyst` | `system.*` | DENY |

---

## Layer 4 — Audit & Observability

### Trino HTTP Event Listener → Elasticsearch

Every completed query is POSTed as a JSON document to Elasticsearch:

```properties
event-listener.name=http
http-event-listener.connect-ingest-uri=http://elasticsearch:9200/trino-query-audit/_doc?pipeline=add-timestamp
http-event-listener.connect-http-headers=Authorization: Basic <base64(elastic:password)>
http-event-listener.log-completed=true
http-event-listener.log-created=false
http-event-listener.log-split=false
```

`event-listener.properties` is generated at container startup by `trino/start.sh`, which base64-encodes `ELASTICSEARCH_PASSWORD` into the `Authorization` header. The file is never stored on disk in the source tree.

**Key audit fields:** `queryId`, `principal`, `query`, `@timestamp`, `errorType`, `wallTime`.

### Kibana

```
Trino ──event listener──► Elasticsearch:9200 ──► Kibana:5601
```

Kibana provides Discover and dashboards over the `trino-query-audit` index. Administrators can search by user, query text, duration, and error code.

| Property | Value |
|---|---|
| Image | `kibana:8.13.0` (matches Elasticsearch `8.13.0`) |
| Container | `datawave-kibana` |
| URL | http://localhost:5601 |
| ES user | `elastic` (UI login); `kibana_system` (backend connection) |

The `es-init` one-shot container sets the `kibana_system` password and creates the `add-timestamp` ingest pipeline before Kibana starts. Kibana `depends_on: es-init` ensures this ordering.

---

## Credentials

All credentials live in `.env` (copy from `.env.example`). Docker Compose substitutes `${VAR}` references at startup.

| Variable | Used by |
|---|---|
| `POSTGRES_PASSWORD` | `postgres`, `trino` |
| `MYSQL_ROOT_PASSWORD` / `MYSQL_PASSWORD` | `mysql`, `trino` |
| `MINIO_ROOT_PASSWORD` | `minio`, `minio-init`, `trino` |
| `RANGER_DB_PASSWORD` | `postgres` (ranger DB), `ranger` |
| `RANGER_ADMIN_PASSWORD` | Ranger Admin UI (`admin`) |
| `ELASTICSEARCH_PASSWORD` | `elasticsearch`, `es-init`, `kibana`, `trino` |
| `LDAP_ADMIN_PASSWORD` | `openldap`; **must match** `bindCredential` in `keycloak/datawave-realm.json` |
| `KEYCLOAK_ADMIN_PASSWORD` | `keycloak` bootstrap admin |
| `SUPERSET_SECRET_KEY` | `superset` Flask secret |
| `SUPERSET_ADMIN_PASSWORD` | unused (OIDC-only; kept for potential CLI use) |
| `SUPERSET_OIDC_SECRET` | `superset`; **must match** client `secret` in `keycloak/datawave-realm.json` |

---

## Service Startup Order

```
postgres (healthy ~10s) ──┬──► ranger-solr (healthy ~30s) ──► ranger (healthy ~3 min)
mysql  (healthy ~10s)  ──┤
minio  (healthy ~10s)  ──┼──► minio-init (exits 0)
nessie (healthy ~30s)  ──┤
                          │
openldap (healthy ~20s) ──┼──► keycloak (healthy ~60s)
                          │
elasticsearch (60s) ──────┼──► es-init (exits 0) ──► kibana (healthy ~60s)
                          │
                          └──► trino (healthy ~60s) ──► superset-init ──► superset
```

**Critical path:** `postgres → ranger (~3 min)` and `openldap → keycloak → superset`

**First-boot time: ~7–10 minutes.** Ranger database initialisation dominates; Keycloak realm import adds ~60s.

---

## Related Documentation

| Document | Contents |
|---|---|
| [README](../README.md) | Quick start, service URLs, SQL examples |
| [prod-improvements.md](prod-improvements.md) | Ranger plugin, TLS, K8s, production hardening |
| [troubleshooting.md](troubleshooting.md) | Common failures and fixes |
