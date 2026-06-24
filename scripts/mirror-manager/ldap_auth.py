#!/usr/bin/env python3
"""ldap_auth — tiny LDAPS auth backend for nginx `auth_request`.

nginx has no native LDAP auth. This daemon answers nginx's internal `auth_request`
subrequest: it reads the HTTP Basic `Authorization` header, validates the credentials
against an LDAP/AD server over **LDAPS**, and returns 200 (allow) or 401 (deny). The
browser still shows the normal Basic-auth prompt — we just check the password against the
directory instead of an htpasswd file.

Requires python-ldap:  sudo apt-get install -y python3-ldap

Two bind models (set LDAP_BIND_MODE):
  direct  — bind straight as the user (AD UPN is simplest). LDAP_USER_DN_TEMPLATE uses
            {user}, e.g. "{user}@example.com" (AD) or "uid={user},ou=people,dc=ex,dc=com".
  search  — bind a service account, search for the user, then rebind as the found DN.
            Needs LDAP_BIND_DN / LDAP_BIND_PW / LDAP_BASE_DN / LDAP_USER_FILTER.

Optional LDAP_REQUIRED_GROUP (a group DN) restricts access to its members (AD nested
groups supported via the LDAP_MATCHING_RULE_IN_CHAIN OID).

Config via environment:
  LA_LISTEN_HOST          (default 127.0.0.1)
  LA_LISTEN_PORT          (default 8889)
  LDAP_URI                (default ldaps://dc.example.com:636)  — use ldaps:// !
  LDAP_CA                 (optional CA bundle path for verifying the LDAPS cert)
  LDAP_TLS_REQCERT        (demand|allow|never; default demand)
  LDAP_BIND_MODE          (direct|search; default direct)
  LDAP_USER_DN_TEMPLATE   (direct mode; default "{user}@example.com")
  LDAP_BIND_DN, LDAP_BIND_PW, LDAP_BASE_DN, LDAP_USER_FILTER  (search mode;
                           filter default "(sAMAccountName={user})")
  LDAP_REQUIRED_GROUP     (optional group DN; empty = any authenticated user)
  LA_REALM                (Basic realm text; default "apt-mirror manager")
  LA_CACHE_TTL            (seconds to cache a successful auth; default 60)
"""

import base64
import hashlib
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LISTEN_HOST = os.environ.get("LA_LISTEN_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("LA_LISTEN_PORT", "8889"))
LDAP_URI = os.environ.get("LDAP_URI", "ldaps://dc.example.com:636")
LDAP_CA = os.environ.get("LDAP_CA", "")
LDAP_TLS_REQCERT = os.environ.get("LDAP_TLS_REQCERT", "demand")
BIND_MODE = os.environ.get("LDAP_BIND_MODE", "direct")
USER_DN_TEMPLATE = os.environ.get("LDAP_USER_DN_TEMPLATE", "{user}@example.com")
BIND_DN = os.environ.get("LDAP_BIND_DN", "")
BIND_PW = os.environ.get("LDAP_BIND_PW", "")
BASE_DN = os.environ.get("LDAP_BASE_DN", "")
USER_FILTER = os.environ.get("LDAP_USER_FILTER", "(sAMAccountName={user})")
REQUIRED_GROUP = os.environ.get("LDAP_REQUIRED_GROUP", "")
REALM = os.environ.get("LA_REALM", "apt-mirror manager")
CACHE_TTL = int(os.environ.get("LA_CACHE_TTL", "60"))

_cache = {}            # sha256(user:pass) -> expiry epoch
_cache_lock = threading.Lock()


def _new_conn():
    import ldap
    conn = ldap.initialize(LDAP_URI)
    conn.set_option(ldap.OPT_PROTOCOL_VERSION, 3)
    conn.set_option(ldap.OPT_REFERRALS, 0)
    conn.set_option(ldap.OPT_NETWORK_TIMEOUT, 8)
    reqcert = {"never": ldap.OPT_X_TLS_NEVER, "allow": ldap.OPT_X_TLS_ALLOW,
               "demand": ldap.OPT_X_TLS_DEMAND}.get(LDAP_TLS_REQCERT, ldap.OPT_X_TLS_DEMAND)
    conn.set_option(ldap.OPT_X_TLS_REQUIRE_CERT, reqcert)
    if LDAP_CA:
        conn.set_option(ldap.OPT_X_TLS_CACERTFILE, LDAP_CA)
    conn.set_option(ldap.OPT_X_TLS_NEWCTX, 0)  # must be last TLS option
    return conn


def _in_group(conn, user_dn):
    """True if user_dn is a (possibly nested) member of REQUIRED_GROUP."""
    if not REQUIRED_GROUP:
        return True
    import ldap
    from ldap.filter import escape_filter_chars
    # AD nested-group match; for OpenLDAP a plain (member=...) also works on most setups.
    flt = (f"(|(member={escape_filter_chars(user_dn)})"
           f"(member:1.2.840.113556.1.4.1941:={escape_filter_chars(user_dn)}))")
    try:
        res = conn.search_s(REQUIRED_GROUP, ldap.SCOPE_BASE, flt, ["cn"])
        return bool(res)
    except ldap.LDAPError:
        return False


def ldap_authenticate(user, password):
    """Return (ok: bool, reason: str). Never logs the password."""
    import ldap
    from ldap.filter import escape_filter_chars
    if not user or not password:
        return False, "empty"
    try:
        conn = _new_conn()
        if BIND_MODE == "search":
            conn.simple_bind_s(BIND_DN, BIND_PW)
            flt = USER_FILTER.format(user=escape_filter_chars(user))
            res = conn.search_s(BASE_DN, ldap.SCOPE_SUBTREE, flt, ["dn"])
            if not res:
                return False, "user not found"
            user_dn = res[0][0]
            conn2 = _new_conn()
            conn2.simple_bind_s(user_dn, password)   # verify the password
            ok = _in_group(conn, user_dn)
            return (ok, "ok" if ok else "not in required group")
        else:  # direct
            user_dn = USER_DN_TEMPLATE.format(user=user)
            conn.simple_bind_s(user_dn, password)    # bind as the user
            ok = _in_group(conn, user_dn) if REQUIRED_GROUP else True
            return (ok, "ok" if ok else "not in required group")
    except ldap.INVALID_CREDENTIALS:
        return False, "invalid credentials"
    except ldap.SERVER_DOWN:
        return False, "ldap server unreachable"
    except ldap.LDAPError as exc:
        return False, f"ldap error: {exc}"


def check(user, password):
    key = hashlib.sha256(f"{user}\0{password}".encode()).hexdigest()
    now = time.time()
    with _cache_lock:
        exp = _cache.get(key)
        if exp and exp > now:
            return True, "cached"
    ok, reason = ldap_authenticate(user, password)
    if ok and CACHE_TTL > 0:
        with _cache_lock:
            _cache[key] = now + CACHE_TTL
            # opportunistic prune
            for k, e in list(_cache.items()):
                if e <= now:
                    _cache.pop(k, None)
    return ok, reason


class Handler(BaseHTTPRequestHandler):
    server_version = "ldap-auth/1.0"

    def log_message(self, fmt, *args):
        pass

    def _deny(self, reason):
        self.send_response(401)
        self.send_header("WWW-Authenticate", f'Basic realm="{REALM}"')
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
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
            # one quiet line to the journal — username + reason, never the password
            print(f"ldap-auth: deny user={user.strip()!r} reason={reason}")
            self._deny(reason)


def main():
    httpd = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    print(f"ldap-auth listening on http://{LISTEN_HOST}:{LISTEN_PORT}  "
          f"(uri={LDAP_URI}, mode={BIND_MODE}, group={'set' if REQUIRED_GROUP else 'any'})")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
