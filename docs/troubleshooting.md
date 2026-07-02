# Troubleshooting — DataWave SQL Federation Platform

---

## System Requirements

Before raising issues, verify host resources meet these minimums:

| Resource | Minimum | Recommended |
|---|---|---|
| Docker Engine | 24.x | latest stable |
| Docker Compose | v2.20+ | latest stable |
| RAM available to Docker | 10 GB | **12 GB** |
| CPU cores | 4 | 8 |
| Free disk | 20 GB | **25 GB** |
| OS | Linux, macOS 13+, Windows WSL2 | Linux |

> **macOS / Docker Desktop:** Go to **Preferences → Resources → Memory** and set to at least **12 GB**. The stack uses ~6.5 GB at steady state — 8 GB leaves almost no headroom and init-time bursts will OOM-kill Ranger or Elasticsearch.

---

## General Diagnostic Commands

```bash
# View status of all containers
docker compose ps

# Tail logs for a specific service
docker compose logs -f <service-name>

# Check health check output
docker inspect --format='{{json .State.Health}}' datawave-<service-name> | jq

# Check resource usage
docker stats --no-stream
```

---

## Startup Issues

### Stack is slow / services stuck in `starting`

**Symptom:** `docker compose ps` shows services stuck in `starting` or `unhealthy` for more than 5 minutes.

**Cause:** Ranger (`datawave-ranger`) takes 2–5 minutes on first boot to initialise its database. All services that depend on Ranger (including Trino) wait until Ranger is healthy.

**Fix:**

```bash
docker compose logs -f ranger
# Look for: "Ranger Admin is ready"
```

Wait for Ranger before troubleshooting anything else. Trino and Superset start automatically once Ranger passes its health check.

---

### A container immediately exits or crashes

**Symptom:** A service shows `Exited` with a non-zero code in `docker compose ps`.

```bash
docker compose logs <service-name>
```

Common causes:

| Service | Common cause | Fix |
|---|---|---|
| Any | Port already in use on host | `lsof -i :<port>` then stop the conflicting process or change the host port in `docker-compose.yml` |
| `elasticsearch` | `vm.max_map_count` too low (Linux) | `sudo sysctl -w vm.max_map_count=262144` |
| `ranger` | Postgres not yet ready | Wait — `postgres` and `ranger-solr` must be healthy first |
| `trino` | Dependency not healthy | Wait for `postgres`, `mysql`, `minio`, `nessie`, `elasticsearch`, `ranger-sync` |
| `keycloak` | OpenLDAP not yet ready | Wait for `openldap` to be healthy |

---

### Port conflict

```bash
# Find what is using a port (example: 8080)
lsof -i :8080

# Change the host-side port in docker-compose.yml to avoid conflict
# e.g., change "8080:8080" to "18080:8080" then access via localhost:18080
```

---

### Out of memory / containers OOM-killed

**Symptom:** Services restart repeatedly; `docker compose logs` shows `Killed` or Java OutOfMemoryError.

**Fix:**
1. Increase Docker Desktop memory to **8 GB** minimum (**Preferences → Resources**)
2. Optionally lower Elasticsearch heap: in `docker-compose.yml` change `ES_JAVA_OPTS=-Xms512m -Xmx512m` to `ES_JAVA_OPTS=-Xms256m -Xmx256m`
3. Lower Trino memory: in `trino/etc/config.properties` change `query.max-memory-per-node` to `256MB`

---

## Superset Issues

### "Sign in with Keycloak" button missing

**Cause:** Superset started before Keycloak was healthy, or `superset_config.py` did not load correctly.

**Fix:**

```bash
docker compose restart superset
docker compose logs -f superset | grep -i "keycloak\|oidc\|error"
```

---

### SQL Lab shows "Unable to add a new tab to the backend"

**Cause:** The user is missing the `Alpha` Superset role (needed for SQL Lab access).

**Fix:** Log in as the Superset `admin` user → **Settings → List Users** → find the affected user → add the `Alpha` role.

---

### Schema dropdown in SQL Lab shows only `system` schemas

**Cause:** Superset queries `information_schema.schemata` in Trino's `system` catalog when listing schemas. Ensure the analyst group has `read-only` access to the `system` catalog in `trino/etc/rules.json`.

---

### Superset shows a blank page after Keycloak login

**Cause:** OIDC redirect URI mismatch or Keycloak not yet healthy.

**Fix:**

```bash
docker compose logs -f superset | grep -i "error\|redirect\|oidc"
docker compose logs -f keycloak | grep -i "error\|redirect"
```

Confirm `http://localhost:8088/oauth-authorized/keycloak` is listed as a valid redirect URI in the Keycloak `superset` client.

---

## Trino Issues

### "Access Denied" when the query should be allowed

**Cause 1:** The group provider did not load correctly.

```bash
docker logs datawave-trino 2>&1 | grep -i "group provider"
# Expected: "-- Loaded group provider file --"
```

If missing, restart Trino:

```bash
docker compose restart trino
```

**Cause 2:** The username is not listed in `trino/etc/groups.txt` under the correct group.

**Fix:** Edit `groups.txt`, add the username to the right group line, then `docker compose restart trino`.

**Cause 3:** `rules.json` has not been written yet (ranger-sync still waiting for Ranger).

```bash
docker logs datawave-ranger-sync 2>&1 | tail -10
docker exec datawave-trino cat /etc/ranger-sync/rules.json
```

---

### Trino query times out or hangs

```bash
docker compose logs -f trino
```

Check for:
- `Query exceeded memory limit` → reduce query scope or increase `query.max-memory-per-node`
- Connection errors to PostgreSQL/MySQL → check those services are healthy
- Nessie/MinIO errors on Iceberg queries → check `nessie` and `minio` health

---

### Trino Web UI shows no query history

**Cause:** The Trino Web UI only shows queries made after Trino started. Historical queries are in Elasticsearch/Kibana.

**Fix:** Go to **http://localhost:5601** (Kibana) and search the `trino-query-audit` index.

---

## Apache Ranger Issues

### Ranger takes too long to start (3–5 minutes is normal)

**Cause:** On first boot, Ranger runs database migrations against PostgreSQL. This is normal.

```bash
docker compose logs -f ranger
# Wait for "Ranger Admin is ready"
```

---

### Ranger admin login fails

**Symptom:** Cannot log in to **http://localhost:6080** with `admin` and `RANGER_ADMIN_PASSWORD` from `.env`.

**Cause:** Ranger DB initialisation may have used a different password on a previous run.

**Fix:** Reset the Ranger state (uses the shared postgres volume):

```bash
docker compose down
docker volume rm datawave-sql-federation_postgres_data
docker compose up -d
```

---

### No policies visible in Ranger UI after a fresh deploy

**Symptom:** Ranger UI shows no policies under the `datawave_trino` service after `docker compose down -v && docker compose up`.

**Cause:** Ranger policies are stored in the shared PostgreSQL volume. `down -v` wipes the volume, so policies are lost. The `ranger-init` container re-seeds them automatically on each fresh boot, but it runs once and exits — check its logs if policies are missing:

```bash
docker logs datawave-ranger-init
```

**Fix:** If `ranger-init` exited with an error, re-run it manually after Ranger is healthy:

```bash
docker compose up ranger-init
```

Then verify policies appear at **http://localhost:6080** → Service Manager → `datawave_trino` → Edit → Policies.

---

### Ranger policies not syncing to Trino

**Symptom:** Policy change in Ranger UI not reflected in query behaviour after 30 seconds.

```bash
docker logs datawave-ranger-sync 2>&1 | tail -10
docker exec datawave-trino cat /etc/ranger-sync/rules.json
```

If `rules.json` is stale, check ranger-sync can reach Ranger:

```bash
docker exec datawave-ranger-sync wget -qO- http://ranger:6080/login.jsp | grep -c "Ranger"
```

---

### Users not appearing in Ranger after LDAP change

**Cause:** `ranger-usersync` polls every 60 seconds. Wait up to 60s, then check:

```bash
docker logs datawave-ranger-usersync 2>&1 | tail -10
```

> Note: `ranger-usersync` only upserts — it does not remove users deleted from LDAP. Remove manually in Ranger UI under **Settings → Users/Groups**.

---

## Elasticsearch / Kibana Issues

### Kibana shows no data / "No available fields"

**Cause 1:** No queries have been run through Trino yet — the `trino-query-audit` index is empty.

**Fix:** Run any query in Superset SQL Lab, then refresh Kibana Discover.

**Cause 2:** Kibana time range filter excludes the data.

**Fix:** In Kibana Discover, click the time picker and select **Last 24 hours** or **Last 7 days**.

---

### `trino-query-audit` data view missing in Kibana

**Cause:** `kibana-init` may not have completed successfully.

```bash
docker logs datawave-kibana-init 2>&1
```

Re-run it:

```bash
docker compose up kibana-init
```

---

### Elasticsearch returns 503

**Cause:** Elasticsearch is still starting (it has a 60-second start period).

```bash
docker compose logs -f elasticsearch
# Wait for: "cluster status changed from [RED] to [GREEN]"
```

If it never becomes healthy, check memory — Elasticsearch needs at least 1 GB of JVM heap.

---

## MinIO / Iceberg Issues

### MinIO bucket init fails

**Symptom:** MinIO Console shows no buckets, or Iceberg queries fail with "bucket not found".

```bash
docker compose restart minio-init
docker compose logs -f minio-init
```

---

### Iceberg queries return "table not found"

**Cause:** Iceberg tables are not pre-seeded — they must be created explicitly.

**Fix:** In Superset SQL Lab as `admin` or `engineer`:

```sql
CREATE SCHEMA IF NOT EXISTS iceberg.datawarehouse
WITH (location = 's3://warehouse/datawarehouse/');

CREATE TABLE iceberg.datawarehouse.my_table (...)
WITH (format = 'PARQUET');
```

---

### Nessie is unreachable

```bash
docker compose logs -f nessie
curl http://localhost:19120/api/v2/config
```

If Nessie is not responding:

```bash
docker compose restart nessie
docker compose restart trino
```

---

## Keycloak / SSO Issues

### Login redirects loop back to the login page

**Cause:** Stale browser cookies or OIDC session mismatch.

**Fix:** Clear browser cookies for `localhost` and log in again.

---

### Keycloak realm is missing after restart

**Cause:** Keycloak uses an embedded H2 database (`start-dev` mode). If the `keycloak_data` volume was deleted, the realm is re-imported automatically on next boot.

If the realm is genuinely missing:

```bash
docker compose down
docker volume rm datawave-sql-federation_keycloak_data
docker compose up -d keycloak
```

This wipes all manual Keycloak UI changes. Export the realm first if needed (see [`prod-improvements.md`](prod-improvements.md#8-keycloak-realm-export)).

---

### LDAP users not appearing in Keycloak

**Cause:** Keycloak syncs from OpenLDAP every 5 minutes by default.

**Fix:** Force an immediate sync in Keycloak Admin → **User Federation → ldap → Synchronize all users**.

---

## Full Reset

Destroys all data volumes and starts completely fresh:

```bash
docker compose down -v
docker compose up --build -d
```

Allow 7–10 minutes on first boot — Ranger re-initialises its database from scratch.

---

## Checking Version Pins

| Software | Pinned version | Notes |
|---|---|---|
| Trino | `458` | Pinned — catalog API changes between minor versions |
| PostgreSQL | `15` | Major version only |
| MySQL | `8.0` | Major version only |
| Keycloak | `24.0` | Pinned — realm JSON format changes between majors |
| Elasticsearch | `8.13.0` | Pinned — must match Kibana exactly |
| Kibana | `8.13.0` | Pinned — must match Elasticsearch exactly |
| Apache Ranger | `2.8.0` | Pinned |
| Apache Ranger Solr | `2.8.0` | Pinned — must match Ranger |
| Apache Superset | `3.1.0` | Pinned — `superset_config.py` API changes between versions |
| Nessie | `latest` | REST catalog API is stable |
| MinIO / mc | `latest` | S3-compatible API is stable |
