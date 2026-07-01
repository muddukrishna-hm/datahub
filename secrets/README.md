# secrets/

This directory holds credential files read by `docker-compose.yml` via environment variable references in `.env`.

All files are committed with **dev-default** values so the stack runs immediately after cloning — no setup step required.

> For production deployments, replace the values in `.env` before starting the stack and never push real credentials to the repository.

---

## Credentials at a glance

| File | Default value | Used by |
|---|---|---|
| `postgres_password.txt` | `datawave123` | PostgreSQL superuser, Trino connectors, Ranger DB |
| `mysql_root_password.txt` | `datawave123` | MySQL root |
| `mysql_password.txt` | `datawave123` | MySQL `datawave` user, Trino MySQL connector |
| `minio_root_password.txt` | `minioadmin123` | MinIO, Trino Iceberg connector |
| `ranger_db_password.txt` | `RangerPass@1` | Ranger's own DB user (`rangeradmin`) in PostgreSQL |
| `ranger_admin_password.txt` | `RangerAdmin@1` | Ranger Admin UI login (`admin`) |
| `keycloak_admin_password.txt` | `KeycloakAdmin@1` | Keycloak master realm admin console |
| `elasticsearch_password.txt` | `ElasticPass@1` | Elasticsearch (`elastic`), Kibana backend (`kibana_system`), Trino audit event listener |
