#!/usr/bin/env python3
"""
LDAP → Ranger user/group sync.

Reads users and groups from OpenLDAP and upserts them into Ranger Admin
via the xusers REST API. This replicates what the Ranger UserSync daemon
does in a production installation.

Runs every SYNC_INTERVAL seconds so Ranger group membership stays in sync
with LDAP without requiring a full Ranger UserSync installation.
"""

import os
import sys
import time

import requests
from ldap3 import ALL, SUBTREE, Connection, Server
from requests.auth import HTTPBasicAuth

RANGER_URL   = os.environ.get("RANGER_URL",   "http://ranger:6080")
RANGER_USER  = os.environ.get("RANGER_USER",  "admin")
RANGER_PASS  = os.environ.get("RANGER_PASS",  "RangerAdmin@1")

LDAP_URL        = os.environ.get("LDAP_URL",        "ldap://openldap:389")
LDAP_BIND_DN    = os.environ.get("LDAP_BIND_DN",    "cn=admin,dc=datawave,dc=io")
LDAP_BIND_PASS  = os.environ.get("LDAP_BIND_PASS",  "adminpassword")
LDAP_USER_BASE  = os.environ.get("LDAP_USER_BASE",  "ou=users,dc=datawave,dc=io")
LDAP_GROUP_BASE = os.environ.get("LDAP_GROUP_BASE", "ou=groups,dc=datawave,dc=io")

SYNC_INTERVAL = int(os.environ.get("SYNC_INTERVAL", "60"))

AUTH = HTTPBasicAuth(RANGER_USER, RANGER_PASS)
HEADERS = {"Content-Type": "application/json", "Accept": "application/json"}


# ── LDAP ──────────────────────────────────────────────────────────────────────

def ldap_connect():
    server = Server(LDAP_URL, get_info=ALL)
    return Connection(server, LDAP_BIND_DN, LDAP_BIND_PASS, auto_bind=True)


def get_ldap_users():
    conn = ldap_connect()
    conn.search(LDAP_USER_BASE, "(objectClass=inetOrgPerson)",
                attributes=["uid", "cn", "mail"])
    users = []
    for e in conn.entries:
        uid  = str(e.uid)
        cn   = str(e.cn)
        mail = str(e.mail) if e.mail else f"{uid}@datawave.io"
        users.append({"uid": uid, "cn": cn, "mail": mail})
    conn.unbind()
    return users


def get_ldap_groups():
    conn = ldap_connect()
    conn.search(LDAP_GROUP_BASE, "(objectClass=groupOfNames)",
                attributes=["cn", "member"])
    groups = []
    for e in conn.entries:
        members = [str(m).split(",")[0].replace("uid=", "") for m in e.member]
        groups.append({"name": str(e.cn), "members": members})
    conn.unbind()
    return groups


# ── Ranger REST ───────────────────────────────────────────────────────────────

def ranger_get(path, params=None):
    r = requests.get(f"{RANGER_URL}{path}", auth=AUTH, headers=HEADERS,
                     params=params, timeout=10)
    r.raise_for_status()
    return r.json()


def ranger_post(path, payload):
    r = requests.post(f"{RANGER_URL}{path}", auth=AUTH, headers=HEADERS,
                      json=payload, timeout=10)
    r.raise_for_status()
    return r.json()


def find_user(name):
    data = ranger_get("/service/xusers/users", {"name": name})
    for u in data.get("vXUsers", []):
        if u["name"] == name:
            return u
    return None


def upsert_user(uid, cn, mail):
    existing = find_user(uid)
    if existing:
        return existing["id"]
    payload = {
        "name": uid,
        "firstName": cn,
        "emailAddress": mail,
        "password": "Ldap@Managed1!",  # placeholder — auth is via LDAP/Keycloak, not Ranger
        "userRoleList": ["ROLE_USER"],
        "userSource": 1,   # 1 = external (LDAP)
        "status": 1,
        "isVisible": 1,
    }
    return ranger_post("/service/xusers/secure/users", payload)["id"]


def find_group(name):
    data = ranger_get("/service/xusers/groups", {"name": name})
    for g in data.get("vXGroups", []):
        if g["name"] == name:
            return g
    return None


def upsert_group(name):
    existing = find_group(name)
    if existing:
        return existing["id"]
    payload = {
        "name": name,
        "description": f"Synced from LDAP: {name}",
        "groupType": 0,
        "groupSource": 1,  # 1 = external (LDAP)
        "isVisible": 1,
    }
    return ranger_post("/service/xusers/secure/groups", payload)["id"]


def add_user_to_group(group_id, user_id, group_name):
    try:
        ranger_post("/service/xusers/groupusers", {
            "name": group_name,
            "userId": user_id,
            "parentGroupId": group_id,
        })
    except requests.HTTPError as e:
        if e.response.status_code == 400:
            pass  # already a member
        else:
            raise


# ── Sync ──────────────────────────────────────────────────────────────────────

def sync():
    users  = get_ldap_users()
    groups = get_ldap_groups()

    user_id_map = {}
    for u in users:
        uid = upsert_user(u["uid"], u["cn"], u["mail"])
        user_id_map[u["uid"]] = uid
        print(f"[usersync] user  {u['uid']} → ranger id={uid}", flush=True)

    for g in groups:
        gid = upsert_group(g["name"])
        print(f"[usersync] group {g['name']} → ranger id={gid}", flush=True)
        for member in g["members"]:
            if member in user_id_map:
                add_user_to_group(gid, user_id_map[member], g["name"])
                print(f"[usersync]   {member} ∈ {g['name']}", flush=True)


def main():
    print(f"[usersync] Starting — ldap={LDAP_URL} ranger={RANGER_URL} interval={SYNC_INTERVAL}s",
          flush=True)
    while True:
        try:
            sync()
            print("[usersync] Sync complete", flush=True)
        except Exception as e:
            print(f"[usersync] ERROR: {e}", file=sys.stderr, flush=True)
        time.sleep(SYNC_INTERVAL)


if __name__ == "__main__":
    main()
