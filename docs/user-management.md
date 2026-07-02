# DataWave SQL Federation — User & Access Management Guide

## RBAC Architecture

Every query follows this chain:

```
Browser login (Keycloak OIDC)
    → Superset passes username to Trino (impersonate_user=true)
        → Trino looks up groups.txt → resolves group membership
            → Trino enforces rules.json (synced from Ranger every 30s)
                → Query allowed / denied / columns masked
```

Background sync processes keep the systems aligned automatically:

```
OpenLDAP ──(ranger-usersync, 60s)──► Ranger Admin (users & groups)
Ranger   ──(ranger-sync, 30s)──────► Trino rules.json (policies)
```

Four systems must be in sync for a user to work:

| System | What it controls | How it's kept in sync |
|---|---|---|
| **OpenLDAP** | Authentication — who can log in and what password | Manual (phpLDAPadmin or CLI) |
| **Keycloak** | SSO — federates LDAP users into the DataWave realm | Auto-syncs from LDAP every 5 min |
| **Trino `groups.txt`** | Authorization — which Trino RBAC group the user belongs to | Manual edit + `docker compose restart trino` |
| **Ranger** | Policy — what each group is allowed to do | Users/groups auto-synced from LDAP every 60s via `ranger-usersync` |

---

## Current Users

| Username | Password | LDAP Group | Trino Group | Role |
|---|---|---|---|---|
| `analyst` | `analyst123` | `data-analyst` | `data-analyst` | Read-only analyst |
| `engineer` | `engineer123` | `data-engineer` | `data-engineer` | Read-write engineer |
| `admin` | `admin123` | `data-admin` | `data-admin` | Full admin |

> **Local development only.** These are demo credentials. See [prod-improvements.md](prod-improvements.md) for production user provisioning.

---

## Current Ranger Policies (What Each Role Can Do)

Ranger policies are stored in the `datawave_trino` service at **http://localhost:6080**.  
The `ranger-sync` container converts them to Trino's `rules.json` every 30 seconds.

### data-analyst
- **Catalogs**: read-only access to all catalogs (can list schemas and tables)
- **Tables**: `SELECT` only — no INSERT, UPDATE, DELETE, DROP
- **Column masking**: `credit_card` column in `postgresql.logistics.customers` → masked to `NULL` (hardcoded in `ranger/sync/sync.py` as `MASKING_RULES`; survives every ranger-sync cycle automatically — Ranger's `dataMaskPolicyItems` are not yet read by sync.py)

### data-engineer
- **Catalogs**: full access to all catalogs
- **Tables**: `SELECT`, `INSERT`, `DELETE` — no OWNERSHIP/DROP

### data-admin
- **Catalogs**: full access to all catalogs
- **Tables**: `SELECT`, `INSERT`, `DELETE`, `UPDATE`, `OWNERSHIP` — unrestricted

---

## Adding a New User

### Step 1 — Add to OpenLDAP

**Option A — Web UI (phpLDAPadmin)**

1. Open **http://localhost:8085** and log in with DN `cn=admin,dc=datawave,dc=io` and `LDAP_ADMIN_PASSWORD`.
2. Expand the tree: `dc=datawave,dc=io` → `ou=users` → click **Create a child entry** → choose `inetOrgPerson`.
3. Fill in `uid`, `cn`, `sn`, `mail`, `userPassword` → **Commit**.
4. Navigate to `ou=groups` → click the target group (e.g. `cn=data-analyst`) → **Add new attribute** → `member` → enter the user's full DN (e.g. `uid=alice,ou=users,dc=datawave,dc=io`) → **Update Object**.

**Option B — CLI**

```bash
docker exec datawave-openldap ldapadd \
  -x -H ldap://localhost:389 \
  -D "cn=admin,dc=datawave,dc=io" \
  -w <LDAP_ADMIN_PASSWORD> << 'EOF'
dn: uid=alice,ou=users,dc=datawave,dc=io
objectClass: inetOrgPerson
objectClass: organizationalPerson
objectClass: person
uid: alice
cn: Alice Smith
sn: Smith
mail: alice@datawave.io
userPassword: alice123
EOF
```

Then add her to the appropriate LDAP group:

```bash
docker exec datawave-openldap ldapmodify \
  -x -H ldap://localhost:389 \
  -D "cn=admin,dc=datawave,dc=io" \
  -w <LDAP_ADMIN_PASSWORD> << 'EOF'
dn: cn=data-analyst,ou=groups,dc=datawave,dc=io
changetype: modify
add: member
member: uid=alice,ou=users,dc=datawave,dc=io
EOF
```

### Step 2 — Add to Trino groups.txt

Edit `trino/etc/groups.txt` and add the username to the appropriate group line:

```
data-analyst:analyst,alice
data-engineer:engineer
data-admin:admin,trino
```

Restart Trino to pick up the change:

```bash
docker compose restart trino
```

### Step 3 — Ranger sync (automatic)

`ranger-usersync` polls LDAP every 60 seconds — the new user and their group membership appear in Ranger automatically. No manual Ranger action needed.

### Step 4 — First Login

The user logs in at **http://localhost:8088** via Keycloak SSO. Keycloak auto-syncs from LDAP (sync interval: 5 min), so the new user appears automatically. On first login Superset creates their account with the `Alpha` role.

---

## Removing a User

### Step 1 — Remove from OpenLDAP

```bash
docker exec datawave-openldap ldapdelete \
  -x -H ldap://localhost:389 \
  -D "cn=admin,dc=datawave,dc=io" \
  -w <LDAP_ADMIN_PASSWORD> \
  "uid=alice,ou=users,dc=datawave,dc=io"
```

### Step 2 — Remove from groups.txt

Edit `trino/etc/groups.txt` and remove the username, then `docker compose restart trino`.

> **Note:** `ranger-usersync` only upserts — it does not delete users from Ranger when they are removed from LDAP. Remove the user manually in the Ranger UI under **Settings → Users/Groups** if needed.

---

## Changing a User's Role

Move the username from one group to another in both places:

1. **LDAP** — remove from old group, add to new group (`ldapmodify`)
2. **`trino/etc/groups.txt`** — move username to the new group line, restart Trino

The Ranger policy is group-based and `ranger-usersync` will update the group membership in Ranger within 60 seconds.

---

## Modifying Permissions via Ranger

Open Ranger at **http://localhost:6080** — log in as `admin` with the `RANGER_ADMIN_PASSWORD` value from `.env`.

Navigate to **Access Manager → datawave_trino** to view and edit policies.

Changes sync to Trino automatically within **30 seconds** via the `ranger-sync` container.

### Ranger Policy Types (Trino service)

| Ranger resource level | Controls |
|---|---|
| Catalog | Whether the group can see the catalog at all |
| Catalog + Schema | Schema-level DDL ownership |
| Catalog + Schema + Table | Row access — SELECT / INSERT / DELETE / CREATE / DROP / ALTER |
| Data Masking policy | Column-level masking (e.g. NULL, HASH, partial mask) |

### Valid Trino access types in Ranger

`select`, `insert`, `delete`, `create`, `drop`, `alter`, `all`

> Note: `update` is not a standalone Ranger access type for Trino — use `all` or individual types.

---

## Access Control Files

| File | Purpose | Reload mechanism |
|---|---|---|
| `openldap/init/01-init.ldif` | Seed users and groups at first boot | Volume delete + recreate |
| `trino/etc/groups.txt` | Maps usernames → Trino groups | `docker compose restart trino` |
| `trino/etc/rules.json` | Seed ACL rules (used before ranger-sync first run) | Overwritten by ranger-sync within 30s |
| Ranger UI policies | Source of truth for all access rules | ranger-sync polls every 30s → Trino hot-reloads |

---

## Verifying Access

**Test as a specific user in Trino CLI:**

```bash
docker exec -it datawave-trino trino \
  --user analyst \
  --execute "SELECT * FROM postgresql.logistics.customers LIMIT 3"
```

**Verify impersonation in Superset:**  
Log in as the user → SQL Lab → run a query → check Trino logs:

```bash
docker logs datawave-trino 2>&1 | grep "principal" | tail -5
```

**Check what rules are currently active:**

```bash
docker exec datawave-trino cat /etc/ranger-sync/rules.json
```

**Check ranger-sync is running:**

```bash
docker logs datawave-ranger-sync 2>&1 | tail -5
```

**Check ranger-usersync is running:**

```bash
docker logs datawave-ranger-usersync 2>&1 | tail -10
```
