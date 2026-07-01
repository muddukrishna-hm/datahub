# Troubleshooting — DataWave SQL Federation Platform

---

## System Requirements

Before raising issues, verify host resources meet these minimums:

| Resource | Minimum | Recommended |
|---|---|---|
| Docker Engine | 24.x | latest stable |
| Docker Compose | v2.20+ | latest stable |
| RAM available to Docker | 6 GB | **8 GB** |
| CPU cores | 4 | 8 |
| Free disk | 5 GB | 10 GB |
| OS | Linux, macOS 13+, Windows WSL2 | Linux |

> **macOS / Docker Desktop:** Go to **Preferences → Resources → Memory** and set to at least 8 GB. Docker Desktop defaults to 2 GB which will cause Elasticsearch, Trino, and Ranger to OOM-kill each other.

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
# Watch Ranger's startup progress
docker compose logs -f ranger

# Look for this line — it means Ranger is ready:
# "Ranger Admin is ready"
```

Wait for Ranger before troubleshooting anything else. Trino, Metabase, and Nginx will start automatically once Ranger passes its health check.

---

### A container immediately exits or crashes

**Symptom:** A service shows `Exited` status in `docker compose ps`.

**Fix:**

```bash
docker compose logs <service-name>
```

Common causes:

| Service | Common cause | Fix |
|---|---|---|
| Any | Port already in use on host | `lsof -i :<port>` then stop the conflicting process or change the host port in `docker-compose.yml` |
| `elasticsearch` | `vm.max_map_count` too low (Linux) | `sudo sysctl -w vm.max_map_count=262144` |
| `ranger` | Ranger DB not yet ready | Wait — `ranger-db` and `ranger-solr` must be healthy first |
| `trino` | Dependency not healthy | Wait for `postgres`, `mysql`, `minio`, `nessie`, `elasticsearch` |
| `keycloak` | DB not yet ready | Wait for `keycloak-db` |

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

## Metabase Issues

### "DataWave Federation" connection is missing

**Symptom:** The database selector in the Metabase SQL editor does not show a "DataWave Federation" connection.

**Cause:** The `metabase-init` container runs once after Metabase starts and creates the connection. It may not have completed successfully.

**Fix:**

```bash
docker start datawave-metabase-init
docker logs -f datawave-metabase-init
```

Look for `Done` at the end of the log. If it exits with an error, check that `datawave-metabase` is healthy first:

```bash
docker compose ps metabase
```

---

### Metabase shows a setup wizard after login

**Symptom:** After SSO login, Metabase displays a "Welcome to Metabase" setup screen.

**Cause:** The admin account was not created by `metabase-init` (it may not have run yet).

**Fix:** Click through the setup wizard, then return to http://localhost/ and log in as the Keycloak `admin` user. The three Trino connections will appear once `metabase-init` completes.

---

### Metabase returns "Cannot connect to Trino"

**Fix:**

```bash
# Check Trino is healthy
docker compose ps trino

# Check Trino can reach its dependencies
docker compose logs trino | tail -50
```

If Trino is healthy, check that the connection in Metabase uses `trino` (the container hostname) not `localhost`.

---

## Trino Issues

### "Access Denied" when the query should be allowed

**Symptom:** A query returns `Access Denied` but the user's role should permit it.

**Cause 1:** The group provider did not load correctly.

**Fix:**

```bash
docker logs datawave-trino 2>&1 | grep -i "group provider"
# Expected: "-- Loaded group provider file --"
```

If missing, restart Trino:

```bash
docker compose restart trino
```

**Cause 2:** The username in the query does not match any group in `trino/etc/groups.txt`.

**Fix:** Check `trino/etc/groups.txt` and ensure the username is listed under the correct group.

---

### Trino query times out or hangs

**Fix:**

```bash
docker compose logs -f trino
```

Check for:
- `Query exceeded memory limit` → reduce query scope or increase `query.max-memory-per-node`
- Connection errors to PostgreSQL/MySQL → check those services are healthy
- Nessie/MinIO errors on Iceberg queries → check `nessie` and `minio` health

---

### Trino Web UI shows no query history

**Cause:** The Trino Web UI only shows queries made after Trino started. Historic queries are in Elasticsearch.

**Fix:** Go to http://localhost/kibana/ and search the `trino-query-audit` index for historical queries.

---

## Apache Ranger Issues

### Ranger takes too long to start (3–5 minutes is normal)

**Cause:** On first boot, Ranger downloads the PostgreSQL JDBC driver and runs database migrations. This is normal.

```bash
docker compose logs -f ranger
# Wait for "Ranger Admin is ready"
```

---

### Ranger admin login fails

**Symptom:** Cannot log in to http://localhost/ranger/ with `admin` and the password from `RANGER_ADMIN_PASSWORD` in `.env`.

**Cause:** Ranger DB initialisation may have used a different password on a previous run, or the volume is in an inconsistent state.

**Fix:** Reset the Ranger database volume:

```bash
docker compose down
docker volume rm datawave-sql-federation_ranger_db_data
docker compose up -d ranger-db ranger-solr ranger
# Wait 3–5 minutes for Ranger to reinitialise
```

---

### Ranger policies not taking effect

**Note:** In the current implementation, Trino uses file-based access control (`trino/etc/rules.json`), not the Ranger plugin. Ranger policies are visible in the UI and logged to the audit trail but do not enforce per-query at the Trino level. See [`prod-improvements.md`](prod-improvements.md#3-ranger-policy-sync) for the full Ranger-Trino plugin implementation.

---

## Elasticsearch / Kibana Issues

### Kibana shows 502 / blank login page

**Fix:**

```bash
docker compose up -d es-init kibana
docker exec datawave-nginx nginx -s reload
```

If Kibana is still not accessible:

```bash
docker compose logs -f kibana
# Check it is connecting to elasticsearch:9200
```

---

### No data in `trino-query-audit` index

**Cause 1:** No queries have been run through Trino yet.

**Cause 2:** The event listener failed to authenticate to Elasticsearch.

**Fix:**

```bash
docker compose logs trino | grep -i "event listener\|elasticsearch\|error"
```

If the listener cannot reach Elasticsearch, restart Trino after confirming Elasticsearch is healthy:

```bash
docker compose ps elasticsearch
docker compose restart trino
```

---

### Elasticsearch returns 503

**Cause:** Elasticsearch is still starting (it has a 60-second start period).

**Fix:**

```bash
docker compose logs -f elasticsearch
# Wait for: "cluster status changed from [RED] to [GREEN]"
```

If it never becomes healthy, check memory — Elasticsearch needs at least 1 GB of JVM heap.

---

## MinIO / Iceberg Issues

### MinIO bucket init fails

**Symptom:** Iceberg queries fail with "bucket not found" or "no such object".

**Fix:**

```bash
docker compose restart minio-init
docker compose logs -f minio-init
```

---

### Iceberg queries return "table not found"

**Cause:** The Iceberg table has not been created yet (Iceberg tables are created on demand by engineers, not pre-seeded).

**Fix:** Use the engineer connection in Metabase to run:

```sql
CREATE SCHEMA IF NOT EXISTS iceberg.datawarehouse
WITH (location = 's3://warehouse/datawarehouse/')
```

Then create the table. See the RBAC walkthrough in [`user-guide.md`](user-guide.md#2d-write-to-the-iceberg-data-lake).

---

### Nessie is unreachable

```bash
docker compose logs -f nessie
# Check for: "Quarkus ... started in"
curl http://localhost:19120/api/v2/config
```

If Nessie is not responding, restart it:

```bash
docker compose restart nessie
docker compose restart trino   # Trino needs to reconnect
```

---

## Keycloak / SSO Issues

### Login redirects loop back to the login page

**Cause 1:** The oauth2-proxy cookie secret changed (e.g., after a restart with a different `secrets/oauth2_cookie_secret.txt`). Old cookies are invalid.

**Fix:** Clear browser cookies for `localhost` and log in again.

**Cause 2:** `KC_HOSTNAME` or redirect URI mismatch.

**Fix:**

```bash
docker compose logs -f oauth2-proxy
# Look for: "error redeeming code" or "invalid redirect URI"
```

Confirm the redirect URI in the `datawave-app` Keycloak client matches `http://localhost/oauth2/callback`.

---

### Keycloak realm is missing after restart

**Cause:** The `keycloak_db_data` volume exists from a previous run but the realm JSON was already imported. Keycloak skips re-import if the realm exists.

If the realm is missing (shouldn't happen normally):

```bash
docker compose down
docker volume rm datawave-sql-federation_keycloak_db_data
docker compose up -d keycloak-db keycloak
```

This wipes all manual Keycloak UI changes. Export the realm first if needed (see [`prod-improvements.md`](prod-improvements.md#8-keycloak-realm-export)).

---

## Full Reset

Destroys all data volumes and starts completely fresh:

```bash
docker compose down -v
docker compose up -d
```

This takes the full 6–8 minutes on first boot because Ranger re-initialises its database from scratch.

---

## Checking Version Pins

| Software | Pinned version | Notes |
|---|---|---|
| Trino | `458` | Pinned — catalog API changes between minor versions |
| PostgreSQL | `15` | Major version only |
| MySQL | `8.0` | Major version only |
| Keycloak | `24.0` | Pinned — realm JSON format changes between majors |
| OAuth2 Proxy | `v7.6.0-alpine` | Pinned — flag names changed in v7 |
| Elasticsearch | `8.13.0` | Pinned — must match Kibana exactly |
| Kibana | `8.13.0` | Pinned — must match Elasticsearch exactly |
| Apache Ranger | `2.8.0` | Pinned |
| Apache Ranger Solr | `2.8.0` | Pinned — paired with Ranger |
| Nessie | `latest` | REST catalog API is stable |
| MinIO / mc | `latest` | S3-compatible API is stable |
| Metabase | `latest` | Internal DB schema migrates automatically |
| Nginx | `latest` | Config syntax is stable |
