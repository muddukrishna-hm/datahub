# secrets/

This directory holds Docker secret files mounted read-only into containers at `/run/secrets/<name>`.

All files are committed with **dev-default** values so the stack runs immediately after cloning — no setup step required.

> For production deployments, replace the values in these files before starting the stack and never push the changes back to the repository.

---

## Credentials at a glance

| File | Default value | Used by |
|---|---|---|
| `postgres_password.txt` | `datawave123` | PostgreSQL, Trino |
| `mysql_root_password.txt` | `datawave123` | MySQL |
| `mysql_password.txt` | `datawave123` | MySQL, Trino |
| `minio_root_password.txt` | `minioadmin123` | MinIO, Trino |
| `ranger_db_password.txt` | `RangerPass@1` | Ranger PostgreSQL (`ranger-db`) + Ranger internal DB users |
| `ranger_admin_password.txt` | `RangerAdmin@1` | Ranger Admin UI login (`admin`) |
| `keycloak_db_password.txt` | `keycloak123` | Keycloak DB |
| `keycloak_admin_password.txt` | `admin123` | Keycloak admin console |
| `metabase_db_password.txt` | `metabase123` | Metabase DB |
| `metabase_admin_password.txt` | `MetabaseAdmin1` | Metabase admin UI |
| `elasticsearch_password.txt` | `ElasticPass@1` | Elasticsearch (`elastic`), Kibana backend (`kibana_system`), Trino audit listener |
| `oauth2_client_secret.txt` | `datawave-secret-32chars-long-ok` | OAuth2 Proxy ↔ Keycloak |
| `oauth2_cookie_secret.txt` | `datawave-oauth2-cookie-secret-32` | OAuth2 Proxy session cookie |

> `oauth2_client_secret.txt` must match the `secret` field for client `datawave-app` in `keycloak/datawave-realm.json`. Change both together or leave as-is.
