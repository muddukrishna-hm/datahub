#!/usr/bin/env python3
"""
Seed the datawave_trino Ranger service and RBAC policy items on first boot.

Ranger auto-creates default empty policies on service creation. This script
updates the three relevant ones (catalog, schema, table) to add our RBAC
group permissions. Idempotent — safe to re-run.
"""

import os
import sys
import time

import requests
from requests.auth import HTTPBasicAuth

RANGER_URL  = os.environ.get("RANGER_URL",  "http://ranger:6080")
RANGER_USER = os.environ.get("RANGER_USER", "admin")
RANGER_PASS = os.environ.get("RANGER_PASS", "RangerAdmin@1")

AUTH    = HTTPBasicAuth(RANGER_USER, RANGER_PASS)
HEADERS = {"Content-Type": "application/json", "Accept": "application/json"}

SERVICE_NAME = "datawave_trino"


# ── helpers ───────────────────────────────────────────────────────────────────

def get(path, **kw):
    r = requests.get(f"{RANGER_URL}{path}", auth=AUTH, headers=HEADERS,
                     timeout=10, **kw)
    r.raise_for_status()
    return r.json()


def post(path, payload):
    r = requests.post(f"{RANGER_URL}{path}", auth=AUTH, headers=HEADERS,
                      json=payload, timeout=10)
    r.raise_for_status()
    return r.json()


def put(path, payload):
    r = requests.put(f"{RANGER_URL}{path}", auth=AUTH, headers=HEADERS,
                     json=payload, timeout=10)
    if not r.ok:
        print(f"[ranger-init] PUT {path} → {r.status_code}: {r.text[:500]}", file=sys.stderr, flush=True)
    r.raise_for_status()
    return r.json()


def wait_for_ranger():
    print("[ranger-init] Waiting for Ranger ...", flush=True)
    for _ in range(60):
        try:
            r = requests.get(f"{RANGER_URL}/login.jsp", timeout=5)
            if r.status_code < 500:
                print("[ranger-init] Ranger is up", flush=True)
                return
        except Exception:
            pass
        time.sleep(5)
    print("[ranger-init] ERROR: Ranger not reachable after 5 min", file=sys.stderr)
    sys.exit(1)


# ── service ───────────────────────────────────────────────────────────────────

def ensure_service():
    existing = get("/service/public/v2/api/service",
                   params={"serviceName": SERVICE_NAME})
    if existing:
        sid = existing[0]["id"]
        print(f"[ranger-init] service {SERVICE_NAME} already exists (id={sid})",
              flush=True)
        return

    payload = {
        "name":        SERVICE_NAME,
        "type":        "trino",
        "description": "DataWave Trino federation service",
        "isEnabled":   True,
        "configs": {
            "username":             "trino",
            "jdbc.driverClassName": "io.trino.jdbc.TrinoDriver",
            "jdbc.url":             "jdbc:trino://trino:8080",
        },
    }
    result = post("/service/public/v2/api/service", payload)
    print(f"[ranger-init] Created service {SERVICE_NAME} (id={result['id']})",
          flush=True)


# ── policy item builders ───────────────────────────────────────────────────────

def item(groups, *access_types):
    return {
        "accesses":      [{"type": t, "isAllowed": True} for t in access_types],
        "groups":        list(groups),
        "delegateAdmin": False,
    }


# ── update helpers ────────────────────────────────────────────────────────────

def get_policy_by_name(name):
    """Return the full policy object for the named policy, or None."""
    policies = get("/service/public/v2/api/policy",
                   params={"serviceName": SERVICE_NAME, "policyName": name})
    return policies[0] if policies else None


def already_seeded(policy):
    """Return True if any of our group policy items are already present."""
    our_groups = {"data-admin", "data-engineer", "data-analyst"}
    for pi in policy.get("policyItems", []):
        if our_groups & set(pi.get("groups", [])):
            return True
    return False


def update_policy(policy, new_items):
    """Append new_items to the policy's policyItems and PUT it back."""
    policy["policyItems"] = policy.get("policyItems", []) + new_items
    put(f"/service/public/v2/api/policy/{policy['id']}", policy)
    print(f"[ranger-init] Updated policy '{policy['name']}'", flush=True)


# ── seeding ───────────────────────────────────────────────────────────────────

def seed_policies():
    # ── Catalog-level ─────────────────────────────────────────────────────────
    # Ranger default: "all - catalog" (catalog=*)
    # sync.py maps this to catalog rules in rules.json
    pol = get_policy_by_name("all - catalog")
    if pol and not already_seeded(pol):
        update_policy(pol, [
            item(["data-admin"],    "all"),
            item(["data-engineer"], "select", "insert", "delete", "create", "drop", "alter"),
            item(["data-analyst"],  "select"),
        ])
    elif pol:
        print("[ranger-init] policy 'all - catalog' already seeded — skipping",
              flush=True)

    # ── Schema-level ──────────────────────────────────────────────────────────
    # Ranger default: "all - catalog, schema" (catalog=*, schema=*)
    # sync.py maps this to schema ownership rules in rules.json
    pol = get_policy_by_name("all - catalog, schema")
    if pol and not already_seeded(pol):
        update_policy(pol, [
            item(["data-admin"],    "all"),
            item(["data-engineer"], "all"),
        ])
    elif pol:
        print("[ranger-init] policy 'all - catalog, schema' already seeded — skipping",
              flush=True)

    # ── Table-level ───────────────────────────────────────────────────────────
    # Ranger default: "all - catalog, schema, table" (catalog=*, schema=*, table=*)
    # sync.py maps this to table rules in rules.json
    pol = get_policy_by_name("all - catalog, schema, table")
    if pol and not already_seeded(pol):
        update_policy(pol, [
            item(["data-admin"],    "all"),
            item(["data-engineer"], "select", "insert", "delete"),
            item(["data-analyst"],  "select"),
        ])
    elif pol:
        print("[ranger-init] policy 'all - catalog, schema, table' already seeded — skipping",
              flush=True)


# ── main ──────────────────────────────────────────────────────────────────────

def main():
    wait_for_ranger()
    ensure_service()
    seed_policies()
    print("[ranger-init] Done.", flush=True)


if __name__ == "__main__":
    main()
