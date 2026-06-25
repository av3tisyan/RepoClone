#!/usr/bin/env python3
"""ldap_auth — auth backend for nginx `auth_request` (local users + LDAPS).

nginx has no native LDAP auth. This daemon answers nginx's internal `auth_request`
subrequest: it reads the HTTP Basic `Authorization` header and returns 200 (allow)
or 401 (deny). It validates credentials against, in order:

  1. a local **htpasswd** file (managed from the dashboard via `htpasswd -B`), then
  2. an **LDAP/AD** directory over LDAPS (when enabled).

So a username present in the htpasswd file is always checked locally (a break-glass
admin that works even if the directory is down); everyone else is checked against LDAP.

It also serves two helper routes used by the dashboard daemon (which is stdlib-only
and has no LDAP client):
  POST /test   — try a candidate LDAP config (+ optional test user) and report the result
  GET  /group  — list the members of the configured required group

Config precedence: a JSON file (LDAP_CONF, default /opt/apt/manager/ldap.json, written
by the dashboard) overrides the environment defaults below. python-ldap is required for
the LDAP paths:  sudo apt-get install -y python3-ldap

Environment:
  LA_LISTEN_HOST (127.0.0.1)  LA_LISTEN_PORT (8889)
  LDAP_CONF      (/opt/apt/manager/ldap.json)   HTPASSWD (/opt/apt/manager/htpasswd)
  LDAP_URI ldaps://...  LDAP_CA  LDAP_TLS_REQCERT(demand)  LDAP_BIND_MODE(direct|search)
  LDAP_USER_DN_TEMPLATE  LDAP_BIND_DN LDAP_BIND_PW LDAP_BASE_DN LDAP_USER_FILTER
  LDAP_REQUIRED_GROUP  LA_REALM("apt-mirror manager")  LA_CACHE_TTL(60)
"""

import base64
import hashlib
import json
import os
import re
import shutil
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LISTEN_HOST = os.environ.get("LA_LISTEN_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("LA_LISTEN_PORT", "8889"))
CONF_PATH = os.environ.get("LDAP_CONF", "/opt/apt/manager/ldap.json")
HTPASSWD = os.environ.get("HTPASSWD", "/opt/apt/manager/htpasswd")
REALM = os.environ.get("LA_REALM", "apt-mirror manager")
CACHE_TTL = int(os.environ.get("LA_CACHE_TTL", "60"))
ALLOW_INSECURE_TLS = os.environ.get("LA_ALLOW_INSECURE") == "1"
# Usernames are taken from an untrusted Basic-auth header — constrain them hard before
# they ever reach an LDAP DN/bind or an htpasswd lookup.
SAFE_USER = re.compile(r"^[A-Za-z0-9._@-]{1,128}$")

# Environment defaults (a JSON config file, when present, overrides these).
ENV_DEFAULTS = {
    "enabled": bool(os.environ.get("LDAP_URI")),
    "uri": os.environ.get("LDAP_URI", "ldaps://dc.example.com:636"),
    "ca": os.environ.get("LDAP_CA", ""),
    "reqcert": os.environ.get("LDAP_TLS_REQCERT", "demand"),
    "bind_mode": os.environ.get("LDAP_BIND_MODE", "direct"),
    "user_dn_template": os.environ.get("LDAP_USER_DN_TEMPLATE", "{user}@example.com"),
    "bind_dn": os.environ.get("LDAP_BIND_DN", ""),
    "bind_pw": os.environ.get("LDAP_BIND_PW", ""),
    "base_dn": os.environ.get("LDAP_BASE_DN", ""),
    "user_filter": os.environ.get("LDAP_USER_FILTER", "(sAMAccountName={user})"),
    "required_group": os.environ.get("LDAP_REQUIRED_GROUP", ""),
}

_cache = {}            # sha256(user:pass) -> expiry epoch
_cache_lock = threading.Lock()


def load_cfg():
    """Environment defaults overlaid with the dashboard-managed JSON file."""
    cfg = dict(ENV_DEFAULTS)
    try:
        with open(CONF_PATH) as fh:
            cfg.update({k: v for k, v in json.load(fh).items() if v is not None})
    except Exception:
        pass
    return cfg


# ---- local htpasswd users --------------------------------------------------- #
def local_users():
    users = set()
    try:
        with open(HTPASSWD) as fh:
            for line in fh:
                line = line.strip()
                if line and ":" in line and not line.startswith("#"):
                    users.add(line.split(":", 1)[0])
    except OSError:
        pass
    return users


def check_local(user, password):
    """Verify against the htpasswd file. `-i` reads the password from stdin so it
    never lands on the process argv (visible in ps/proc)."""
    if shutil.which("htpasswd") is None or not os.path.exists(HTPASSWD):
        return False
    try:
        r = subprocess.run(["htpasswd", "-vi", HTPASSWD, user],
                           input=password.encode("utf-8"), capture_output=True, timeout=10)
        return r.returncode == 0
    except Exception:
        return False


# ---- LDAP ------------------------------------------------------------------- #
def _err(exc):
    """Readable text for a python-ldap error (its str() is often just 'option error')."""
    a = getattr(exc, "args", None)
    if a and isinstance(a[0], dict):
        d = a[0]
        return d.get("desc", "") + (": " + d["info"] if d.get("info") else "")
    return f"{type(exc).__name__}: {exc}"


def _new_conn(cfg):
    import ldap
    uri = (cfg.get("uri") or "").strip()
    if not uri:
        raise ValueError("LDAP URI is empty — set it in the Access tab (e.g. ldaps://dc.example.com:636)")
    conn = ldap.initialize(uri)
    conn.set_option(ldap.OPT_PROTOCOL_VERSION, 3)
    conn.set_option(ldap.OPT_REFERRALS, 0)
    conn.set_option(ldap.OPT_NETWORK_TIMEOUT, 8)
    # TLS options apply only to ldaps:// — setting them (esp. NEWCTX) on a plain
    # ldap:// URI is what raises the opaque "option error".
    if uri.lower().startswith("ldaps://"):
        reqcert_name = cfg.get("reqcert", "demand")
        if reqcert_name in ("never", "allow") and not ALLOW_INSECURE_TLS:
            reqcert_name = "demand"   # refuse to disable LDAPS cert verification by default
        reqcert = {"never": ldap.OPT_X_TLS_NEVER, "allow": ldap.OPT_X_TLS_ALLOW,
                   "demand": ldap.OPT_X_TLS_DEMAND}.get(reqcert_name, ldap.OPT_X_TLS_DEMAND)
        conn.set_option(ldap.OPT_X_TLS_REQUIRE_CERT, reqcert)
        ca = (cfg.get("ca") or "").strip()
        if ca:
            if not os.path.exists(ca):
                raise ValueError(f"CA bundle not found: {ca}")
            if not os.access(ca, os.R_OK):
                raise ValueError(f"CA bundle not readable by the auth service user: {ca} "
                                 f"(fix: sudo chmod 0644 {ca})")
            conn.set_option(ldap.OPT_X_TLS_CACERTFILE, ca)
        conn.set_option(ldap.OPT_X_TLS_NEWCTX, 0)  # must be last TLS option
    return conn


def _resolve_user_dn(conn, cfg, user):
    """Return the user's DN, binding the service account first in search mode."""
    import ldap
    from ldap.filter import escape_filter_chars
    from ldap.dn import escape_dn_chars
    if cfg.get("bind_mode") == "search":
        conn.simple_bind_s(cfg.get("bind_dn", ""), cfg.get("bind_pw", ""))
        flt = cfg.get("user_filter", "(sAMAccountName={user})").format(
            user=escape_filter_chars(user))
        # "1.1" = request no attributes (just DNs). Filter out AD referral
        # continuations (entries whose DN is None) — rebinding to one raises
        # "Protocol error".
        res = conn.search_s(cfg.get("base_dn", ""), ldap.SCOPE_SUBTREE, flt, ["1.1"])
        dns = [dn for dn, _attrs in res if dn]
        return dns[0] if dns else None
    return cfg.get("user_dn_template", "{user}").format(user=escape_dn_chars(user))


def _in_group(conn, cfg, user_dn):
    group = cfg.get("required_group", "")
    if not group:
        return True
    import ldap
    from ldap.filter import escape_filter_chars
    flt = (f"(|(member={escape_filter_chars(user_dn)})"
           f"(member:1.2.840.113556.1.4.1941:={escape_filter_chars(user_dn)}))")
    try:
        return bool(conn.search_s(group, ldap.SCOPE_BASE, flt, ["cn"]))
    except ldap.LDAPError:
        return False


def ldap_authenticate(cfg, user, password):
    """Return (ok, reason). Never logs the password."""
    import ldap
    from ldap.dn import escape_dn_chars
    if not user or not password:           # empty pw => AD "unauthenticated bind" => never allow
        return False, "empty"
    try:
        conn = _new_conn(cfg)
        if cfg.get("bind_mode") == "search":
            user_dn = _resolve_user_dn(conn, cfg, user)
            if not user_dn:
                return False, "user not found"
            _new_conn(cfg).simple_bind_s(user_dn, password)   # verify the password
        else:
            user_dn = cfg.get("user_dn_template", "{user}").format(user=escape_dn_chars(user))
            conn.simple_bind_s(user_dn, password)
        ok = _in_group(conn, cfg, user_dn)
        return (ok, "ok" if ok else "not in required group")
    except ldap.INVALID_CREDENTIALS:
        return False, "invalid credentials"
    except ldap.SERVER_DOWN:
        return False, "ldap server unreachable"
    except ldap.LDAPError as exc:
        return False, f"ldap error: {_err(exc)}"
    except Exception as exc:
        return False, f"error: {_err(exc)}"


def group_members(cfg):
    """List the members of the required group (read-only, for the UI)."""
    group = cfg.get("required_group", "")
    if not group:
        return {"ok": True, "members": [], "note": "no required group set"}
    try:
        import ldap
    except Exception:
        return {"ok": False, "error": "python-ldap not installed"}
    try:
        conn = _new_conn(cfg)
        if cfg.get("bind_mode") == "search" and cfg.get("bind_dn"):
            conn.simple_bind_s(cfg.get("bind_dn", ""), cfg.get("bind_pw", ""))
        res = conn.search_s(group, ldap.SCOPE_BASE, "(objectClass=*)", ["member"])
        members = []
        for _dn, attrs in res:
            for m in attrs.get("member", []):
                members.append(m.decode("utf-8", "replace") if isinstance(m, bytes) else str(m))
        return {"ok": True, "members": sorted(members)}
    except Exception as exc:
        return {"ok": False, "error": _err(exc)}


def test_config(cfg, test_user="", test_pass=""):
    """Connectivity / bind test for a candidate config. Returns {ok, steps, reason}."""
    steps = []
    try:
        import ldap  # noqa: F401
    except Exception:
        return {"ok": False, "reason": "python-ldap not installed on the auth host"}
    try:
        conn = _new_conn(cfg)
        if cfg.get("bind_mode") == "search":
            conn.simple_bind_s(cfg.get("bind_dn", ""), cfg.get("bind_pw", ""))
            steps.append("service bind: ok")
        else:
            steps.append("connection: ok (direct mode — bind verified per user)")
    except Exception as exc:
        return {"ok": False, "reason": f"connect/bind failed: {_err(exc)}", "steps": steps}
    if test_user and test_pass:
        ok, reason = ldap_authenticate(cfg, test_user, test_pass)
        steps.append(f"test user {test_user!r}: {reason}")
        return {"ok": ok, "reason": reason, "steps": steps}
    return {"ok": True, "reason": "connection ok", "steps": steps}


# ---- combined check (local first, then LDAP) -------------------------------- #
def check(user, password):
    user = (user or "").strip()
    # Reject empty passwords and unsafe usernames up front, for BOTH backends
    # (blocks empty-password unauthenticated binds and DN/filter metacharacters).
    if not user or not password or not SAFE_USER.match(user):
        return False, "invalid credentials"
    key = hashlib.sha256(f"{user}\0{password}".encode()).hexdigest()
    now = time.time()
    with _cache_lock:
        exp = _cache.get(key)
        if exp and exp > now:
            return True, "cached"
    if user in local_users():
        ok, reason = (check_local(user, password), "local")
    else:
        cfg = load_cfg()
        if not cfg.get("enabled"):
            ok, reason = False, "no local user; ldap disabled"
        else:
            ok, reason = ldap_authenticate(cfg, user, password)
    if ok and CACHE_TTL > 0:
        with _cache_lock:
            _cache[key] = now + CACHE_TTL
            for k, e in list(_cache.items()):
                if e <= now:
                    _cache.pop(k, None)
    return ok, reason


class Handler(BaseHTTPRequestHandler):
    server_version = "ldap-auth/1.1"

    def log_message(self, fmt, *args):
        pass

    def _json(self, code, body):
        data = json.dumps(body).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _deny(self, reason):
        self.send_response(401)
        self.send_header("WWW-Authenticate", f'Basic realm="{REALM}"')
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _body(self):
        n = int(self.headers.get("Content-Length", "0") or "0")
        if not n:
            return {}
        try:
            return json.loads(self.rfile.read(n).decode("utf-8"))
        except Exception:
            return {}

    def do_GET(self):
        if self.path.startswith("/group"):
            return self._json(200, group_members(load_cfg()))
        # everything else is the nginx auth_request subrequest
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Basic "):
            return self._deny("no basic header")
        try:
            user, _, pw = base64.b64decode(auth[6:]).decode("utf-8", "replace").partition(":")
        except Exception:
            return self._deny("bad header")
        ok, reason = check(user.strip(), pw)
        if ok:
            self.send_response(200)
            self.send_header("X-Auth-User", user.strip())
            self.send_header("Content-Length", "0")
            self.end_headers()
        else:
            safe = "".join(ch for ch in user.strip()[:64] if ch.isprintable())
            print(f"ldap-auth: deny user={safe!r} reason={reason}")
            self._deny(reason)

    def do_POST(self):
        if self.path.startswith("/test"):
            b = self._body()
            saved = load_cfg()
            cfg = dict(saved)
            for k in ("uri", "ca", "reqcert", "bind_mode", "user_dn_template",
                      "bind_dn", "base_dn", "user_filter", "required_group"):
                if k in b:
                    cfg[k] = b[k]
            # Anti-exfiltration: never bind the SAVED service-account password to a
            # different target. Only reuse it when uri + bind_dn are unchanged.
            same_target = (str(cfg.get("uri")) == str(saved.get("uri"))
                           and str(cfg.get("bind_dn")) == str(saved.get("bind_dn")))
            if b.get("bind_pw"):
                cfg["bind_pw"] = b["bind_pw"]
            elif not same_target:
                cfg["bind_pw"] = ""
            return self._json(200, test_config(cfg, b.get("test_user", ""),
                                               b.get("test_pass", "")))
        self._json(404, {"error": "not found"})


def main():
    httpd = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    cfg = load_cfg()
    print(f"ldap-auth listening on http://{LISTEN_HOST}:{LISTEN_PORT}  "
          f"(local_users={len(local_users())}, ldap={'on' if cfg.get('enabled') else 'off'}, "
          f"group={'set' if cfg.get('required_group') else 'any'})")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
