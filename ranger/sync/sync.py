#!/usr/bin/env python3
"""
Ranger → Trino rules.json sync.

Polls the Ranger REST API for the datawave_trino service policies every
SYNC_INTERVAL seconds and writes a fresh rules.json to OUTPUT_FILE.
Trino's file-based ACL reloads the file automatically (security.refresh-period).

Ranger access type → Trino privilege mapping:
  select → SELECT      insert → INSERT
  delete → DELETE      create → CREATE
  drop   → DROP        alter  → ALTER_TABLE
  all    → all Trino privileges
"""

import json
import os
import sys
import time

import requests
from requests.auth import HTTPBasicAuth

RANGER_URL = os.environ.get("RANGER_URL", "http://ranger:6080")
RANGER_USER = os.environ.get("RANGER_USER", "admin")
RANGER_PASS = os.environ.get("RANGER_PASS", "RangerAdmin@1")
SERVICE_NAME = os.environ.get("RANGER_SERVICE", "datawave_trino")
OUTPUT_FILE = os.environ.get("OUTPUT_FILE", "/sync/rules.json")
SYNC_INTERVAL = int(os.environ.get("SYNC_INTERVAL", "30"))

AUTH = HTTPBasicAuth(RANGER_USER, RANGER_PASS)

ALL_PRIVS = ["SELECT", "INSERT", "DELETE", "UPDATE", "OWNERSHIP"]

# Column masking rules are not yet supported in the Ranger Trino plugin's
# dataMaskPolicyItems, so we hardcode them here and always prepend them to
# the synced table rules so they survive ranger-sync overwrites.
MASKING_RULES = [
    {
        "group": "data-analyst",
        "catalog": "postgresql",
        "schema": "logistics",
        "table": "customers",
        "privileges": ["SELECT"],
        "columns": [{"name": "credit_card", "mask": "NULL"}],
    }
]

RANGER_TO_TRINO = {
    "select": "SELECT",
    "insert": "INSERT",
    "delete": "DELETE",
    "update": "UPDATE",
    "create": None,   # no CREATE in Trino file-ACL table privileges
    "drop":   None,   # no DROP in Trino file-ACL table privileges
    "alter":  None,   # no ALTER in Trino file-ACL table privileges
    "all":    None,   # handled specially → ALL_PRIVS
}


def get_policies():
    url = f"{RANGER_URL}/service/public/v2/api/policy"
    r = requests.get(url, auth=AUTH, params={"serviceName": SERVICE_NAME}, timeout=10)
    r.raise_for_status()
    return r.json()


def resource_val(resources, key):
    """Return list of values for a resource key, ['*'] if absent."""
    r = resources.get(key, {})
    vals = r.get("values", ["*"])
    return vals if vals else ["*"]


def glob_to_regex(val):
    """Ranger uses * globbing; Trino rules use Java regex .*"""
    return ".*" if val == "*" else val.replace("*", ".*")


def item_privs(accesses):
    privs = []
    for a in accesses:
        if not a.get("isAllowed", True):
            continue
        t = a.get("type", "")
        if t == "all":
            return list(ALL_PRIVS)
        mapped = RANGER_TO_TRINO.get(t)
        if mapped is not None:
            privs.append(mapped)
    return privs


def convert(policies):
    catalog_rules = []
    schema_rules = []
    table_rules = []

    for pol in policies:
        if not pol.get("isEnabled", True):
            continue
        resources = pol.get("resources", {})
        has_catalog = "catalog" in resources
        has_schema = "schema" in resources
        has_table = "table" in resources

        for item in pol.get("policyItems", []):
            groups = item.get("groups", [])
            accesses = item.get("accesses", [])
            privs = item_privs(accesses)
            if not privs:
                continue

            cats = [glob_to_regex(v) for v in resource_val(resources, "catalog")]
            schemas = [glob_to_regex(v) for v in resource_val(resources, "schema")]
            tables = [glob_to_regex(v) for v in resource_val(resources, "table")]
            cat_pat = "|".join(cats) if len(cats) > 1 else cats[0]
            sch_pat = "|".join(schemas) if len(schemas) > 1 else schemas[0]
            tbl_pat = "|".join(tables) if len(tables) > 1 else tables[0]

            for group in groups:
                if not has_schema and not has_table:
                    # Catalog-level rule
                    allow = (
                        "all"
                        if set(privs) >= set(ALL_PRIVS)
                        else "read-only" if "SELECT" in privs else "none"
                    )
                    catalog_rules.append(
                        {"group": group, "catalog": cat_pat, "allow": allow}
                    )

                elif has_schema and not has_table:
                    schema_rules.append(
                        {
                            "group": group,
                            "catalog": cat_pat,
                            "schema": sch_pat,
                            "owner": True,
                        }
                    )

                else:
                    table_rules.append(
                        {
                            "group": group,
                            "catalog": cat_pat,
                            "schema": sch_pat,
                            "table": tbl_pat,
                            "privileges": privs,
                        }
                    )

    # Default-deny at the end of each section
    catalog_rules.append({"allow": "none"})
    schema_rules.append({"owner": False})

    return {"catalogs": catalog_rules, "schemas": schema_rules,
            "tables": MASKING_RULES + table_rules}


def write_rules(rules):
    tmp = OUTPUT_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(rules, f, indent=2)
    os.replace(tmp, OUTPUT_FILE)


BUNDLED_FALLBACK = "/fallback-rules.json"


def seed_if_missing():
    """Seed from bundled fallback-rules.json so Trino has RBAC on first boot."""
    if not os.path.exists(OUTPUT_FILE):
        os.makedirs(os.path.dirname(OUTPUT_FILE), exist_ok=True)
        import shutil
        shutil.copy(BUNDLED_FALLBACK, OUTPUT_FILE)
        print(f"[ranger-sync] Seeded fallback rules → {OUTPUT_FILE}", flush=True)


def main():
    print(
        f"[ranger-sync] Starting — service={SERVICE_NAME} output={OUTPUT_FILE} interval={SYNC_INTERVAL}s",
        flush=True,
    )
    seed_if_missing()
    while True:
        try:
            policies = get_policies()
            if not policies:
                print("[ranger-sync] No policies in Ranger yet — keeping existing rules", flush=True)
            else:
                rules = convert(policies)
                write_rules(rules)
                print(
                    f"[ranger-sync] Wrote {len(policies)} policies → {OUTPUT_FILE}",
                    flush=True,
                )
        except Exception as e:
            print(f"[ranger-sync] ERROR: {e}", file=sys.stderr, flush=True)
        time.sleep(SYNC_INTERVAL)


if __name__ == "__main__":
    main()
