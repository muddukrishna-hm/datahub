import os
from flask_appbuilder.security.manager import AUTH_OAUTH
from superset.security import SupersetSecurityManager

# ── Core ───────────────────────────────────────────────────────────────────────
SECRET_KEY = os.environ.get("SUPERSET_SECRET_KEY", "change-me-in-production")
SQLALCHEMY_DATABASE_URI = "sqlite:////app/superset_home/superset.db"
TALISMAN_ENABLED = False
WTF_CSRF_ENABLED = True

# ── Deployment ────────────────────────────────────────────────────────────────
# Set PUBLIC_HOSTNAME in .env to the EC2 IP / public hostname for remote deploys.
_host = os.environ.get("PUBLIC_HOSTNAME", "localhost")
_KC_PUBLIC  = f"http://{_host}:8180"   # browser-facing Keycloak URL
_SUPERSET   = f"http://{_host}:8088"   # browser-facing Superset URL

# ── Keycloak OIDC ─────────────────────────────────────────────────────────────
AUTH_TYPE = AUTH_OAUTH
AUTH_USER_REGISTRATION = True
AUTH_USER_REGISTRATION_ROLE = "Alpha"
AUTH_ROLES_SYNC_AT_LOGIN = True
AUTH_ROLES_MAPPING = {"Admin": ["Admin"], "Alpha": ["Alpha"]}

OAUTH_PROVIDERS = [
    {
        "name": "keycloak",
        "token_key": "access_token",
        "icon": "fa-key",
        "remote_app": {
            "client_id": "superset",
            "client_secret": os.environ.get("SUPERSET_OIDC_SECRET", "superset-client-secret"),
            # server-side: container-to-container token exchange
            "access_token_url": "http://keycloak:8080/realms/datawave/protocol/openid-connect/token",
            "api_base_url": "http://keycloak:8080/realms/datawave/protocol/openid-connect/",
            "jwks_uri": "http://keycloak:8080/realms/datawave/protocol/openid-connect/certs",
            # browser-facing: what the user's browser is redirected to
            "authorize_url": f"{_KC_PUBLIC}/realms/datawave/protocol/openid-connect/auth",
            "client_kwargs": {
                "scope": "openid email profile",
            },
            "redirect_uri": f"{_SUPERSET}/oauth-authorized/keycloak",
        },
    }
]


class KeycloakSecurityManager(SupersetSecurityManager):
    def oauth_user_info(self, provider, response=None):
        if provider == "keycloak":
            me = self.oauth.keycloak.get("userinfo", token=response)
            data = me.json()
            username = data.get("preferred_username", "")
            return {
                "username": username,
                "email": data.get("email", ""),
                "first_name": data.get("given_name", ""),
                "last_name": data.get("family_name", ""),
                # admin → Superset Admin; everyone else → Alpha (enables SQL Lab)
                "role_keys": ["Admin"] if username == "admin" else ["Alpha"],
            }
        return super().oauth_user_info(provider, response)


CUSTOM_SECURITY_MANAGER = KeycloakSecurityManager
