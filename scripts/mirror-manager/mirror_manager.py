#!/usr/bin/env python3
"""mirror-manager — a small web dashboard to manage the apt-mirror on the sync host.

Stdlib only (airgap-friendly: no pip). Lets an operator add/remove repositories
(from curated presets or a custom URL that is probed + validated), kick off a
background sync, and watch disk usage against the budget.

Design notes
------------
* Runs on the CONNECTED sync host as a dedicated non-root user (apt-manager) by
  default — it owns the managed mirror.list + /opt/apt/keys and has a narrow
  sudoers grant to start apt-mirror.service (pass --user root to opt out). Bind to
  127.0.0.1 only; expose via SSH tunnel or the nginx auth proxy in
  deploy/nginx/mirror-manager.conf.
* It never rewrites hand-maintained lines: every repo it adds lives inside a
  delimited block  "# >>> mirror-manager: <name> >>> ... <<< mirror-manager: <name> <<<".
  Lines outside those markers are shown read-only as "manual" repos.
* Syncs reuse the existing apt-mirror.service (systemctl start --no-block), whose
  postmirror.sh already runs clean + fetch-binary-all.

Config via environment (all optional):
  MM_LISTEN_HOST   (default 127.0.0.1)
  MM_LISTEN_PORT   (default 8080)
  MM_MIRROR_LIST   (default /etc/apt/mirror.list)
  MM_MIRROR_PATH   (default /opt/apt/mirror)
  MM_KEYS_DIR      (default /opt/apt/keys)
  MM_VAR_DIR       (default /opt/apt/var)
  MM_BUDGET_BYTES  (default 1700000000000  ~1.7 TB)
  MM_APT_UNIT      (default apt-mirror.service)
  MM_TOKEN         (optional shared secret; if set, required as ?token= or X-MM-Token)
  MM_ALLOW         (optional CIDR allowlist for DIRECT access, e.g. "10.0.0.0/26" or
                    "0.0.0.0/0"; empty = allow all. Only meaningful when clients reach the
                    daemon directly — behind nginx the peer is the proxy, so filter there.)
"""

__version__ = "1.0.0"

import gzip
import hashlib
import io
import ipaddress
import json
import os
import re
import shutil
import subprocess
import tarfile
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))

LISTEN_HOST = os.environ.get("MM_LISTEN_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("MM_LISTEN_PORT", "8080"))
MIRROR_LIST = os.environ.get("MM_MIRROR_LIST", "/etc/apt/mirror.list")
MIRROR_PATH = os.environ.get("MM_MIRROR_PATH", "/opt/apt/mirror")
KEYS_DIR = os.environ.get("MM_KEYS_DIR", "/opt/apt/keys")
VAR_DIR = os.environ.get("MM_VAR_DIR", "/opt/apt/var")
BUDGET_BYTES = int(os.environ.get("MM_BUDGET_BYTES", str(1_700_000_000_000)))
APT_UNIT = os.environ.get("MM_APT_UNIT", "apt-mirror.service")
APT_TIMER = os.environ.get("MM_APT_TIMER", "apt-mirror.timer")
# Public base URL clients use to reach the mirror (for the client-config helper).
PUBLIC_URL = os.environ.get("MM_PUBLIC_URL", "https://apt.example.com").rstrip("/")
# Where the generated client landing page is written (served by nginx at PUBLIC_URL/).
WWW_DIR = os.environ.get("MM_WWW_DIR", "/opt/apt/www")
TOKEN = os.environ.get("MM_TOKEN", "")
# Storage: refuse to start a sync below this free-space floor (GB); snapshot tooling.
MIN_FREE_GB = int(os.environ.get("MM_MIN_FREE_GB", "50"))
SNAPSHOT_SH = os.environ.get("MM_SNAPSHOT_SH", "/opt/apt/var/mirror-snapshot.sh")
SNAP_DIR = os.environ.get("MM_SNAP_DIR", "/opt/apt/snapshots")
# Auth/user management (read by ldap_auth.py; written here as the apt-manager user)
AUTH_DIR = os.environ.get("MM_AUTH_DIR", "/opt/apt/manager")
LDAP_CONF = os.environ.get("MM_LDAP_CONF", os.path.join(AUTH_DIR, "ldap.json"))
HTPASSWD = os.environ.get("MM_HTPASSWD", os.path.join(AUTH_DIR, "htpasswd"))
LDAP_AUTH_URL = os.environ.get("MM_LDAP_AUTH_URL", "http://127.0.0.1:8889").rstrip("/")
BREAKGLASS_USER = os.environ.get("MM_BREAKGLASS_USER", "admin")
INSECURE_LDAP_OK = os.environ.get("MM_ALLOW_INSECURE_LDAP") == "1"

# Marker that "disables" a managed deb/clean line (apt-mirror ignores the comment).
OFF = "#MMOFF# "

# Preset id -> the setup-apt-client.sh flag(s) that configure it on a client.
PRESET_CLIENT_FLAGS = {
    "zabbix-7.4": "--with-zabbix --zabbix-major 7.4",
    "zabbix-7.0": "--with-zabbix --zabbix-major 7.0",
    "hashicorp": "--with-hashicorp",
    "openproject-17": "--with-openproject",
    "postgresql": "--with-postgresql",
    "debian": "",
    "ubuntu": "",
}

ALLOW_NETS = []
for _c in re.split(r"[,\s]+", os.environ.get("MM_ALLOW", "").strip()):
    if _c:
        try:
            ALLOW_NETS.append(ipaddress.ip_network(_c, strict=False))
        except ValueError:
            print(f"mirror-manager: ignoring invalid MM_ALLOW entry {_c!r}")

SIZES_CACHE = os.path.join(VAR_DIR, "mirror-manager-sizes.json")
AUDIT_LOG = os.path.join(VAR_DIR, "mirror-manager-audit.jsonl")
HTTP_TIMEOUT = 60

# Privilege model: run privileged systemctl via sudo when not root, so the daemon can run
# as a dedicated non-root user (see setup-mirror-manager.sh --user). As root, this is a no-op.
SUDO = [] if os.geteuid() == 0 else ["sudo", "-n"]
_audit_lock = threading.Lock()


def write_audit(entry):
    entry["ts"] = int(time.time())
    try:
        os.makedirs(VAR_DIR, exist_ok=True)
        with _audit_lock, open(AUDIT_LOG, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(entry) + "\n")
    except OSError:
        pass


def read_audit(n=100):
    try:
        with open(AUDIT_LOG, encoding="utf-8") as fh:
            lines = fh.readlines()
    except OSError:
        return []
    out = []
    for line in lines[-n:]:
        line = line.strip()
        if line:
            try:
                out.append(json.loads(line))
            except ValueError:
                pass
    return out

DEB_RE = re.compile(r"^\s*deb(?:\s+\[([^\]]*)\])?\s+(\S+)\s+(\S+)\s+(.+?)\s*$", re.MULTILINE)
CLEAN_RE = re.compile(r"^\s*clean\s+(\S+)\s*$", re.MULTILINE)
BLOCK_START = "# >>> mirror-manager: {name} >>>"
BLOCK_END = "# <<< mirror-manager: {name} <<<"
BLOCK_RE = re.compile(
    r"\n?# >>> mirror-manager: (?P<name>[^\n>]+) >>>\n(?P<body>.*?)\n# <<< mirror-manager: (?P=name) <<<\n?",
    re.DOTALL,
)


# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #
def slug(s):
    return re.sub(r"[^A-Za-z0-9._-]+", "-", s).strip("-")[:64] or "repo"


def load_presets():
    try:
        with open(os.path.join(HERE, "presets.json"), encoding="utf-8") as fh:
            return json.load(fh).get("presets", [])
    except Exception:
        return []


def read_list():
    try:
        with open(MIRROR_LIST, encoding="utf-8") as fh:
            return fh.read()
    except FileNotFoundError:
        return ""


def netloc_of(url):
    return urllib.parse.urlparse(url).netloc or url


def arch_value(opt):
    """Extract the architecture value from a deb-line option string.
    'arch=amd64,all' -> 'amd64,all'; 'arch=amd64 signed-by=…' -> 'amd64'; '' -> 'amd64'."""
    m = re.search(r"arch=([^\s\]]+)", opt or "")
    return m.group(1) if m else "amd64"


def parse_repos(text):
    """Return managed (from marker blocks) and manual (everything else) repos."""
    managed = []
    managed_spans = []
    for m in BLOCK_RE.finditer(text):
        name = m.group("name").strip()
        body = m.group("body")
        debs, cleans = [], []
        key, preset = "", ""
        active = disabled = 0
        for raw in body.splitlines():
            line = raw
            off = line.startswith(OFF)
            if off:
                line = line[len(OFF):]
            s = line.strip()
            if s.startswith("# mm-key:"):
                key = s.split(":", 1)[1].strip(); continue
            if s.startswith("# mm-preset:"):
                preset = s.split(":", 1)[1].strip(); continue
            dm = DEB_RE.match(line)
            if dm:
                debs.append({"arch": dm.group(1) or "", "url": dm.group(2),
                             "suite": dm.group(3), "components": dm.group(4)})
                disabled += 1 if off else 0
                active += 0 if off else 1
                continue
            cm = CLEAN_RE.match(line)
            if cm:
                cleans.append(cm.group(1))
        managed.append({"name": name, "managed": True, "deb": debs, "clean": cleans,
                        "enabled": disabled == 0, "key": key, "preset": preset,
                        "hosts": sorted({netloc_of(d["url"]) for d in debs})})
        managed_spans.append((m.start(), m.end()))

    # Manual deb lines = those outside any managed span.
    manual_by_host = {}
    for m in DEB_RE.finditer(text):
        if any(s <= m.start() < e for s, e in managed_spans):
            continue
        url = m.group(2)
        host = netloc_of(url)
        entry = manual_by_host.setdefault(host, {"name": host, "managed": False,
                                                 "enabled": True, "key": "", "preset": "",
                                                 "deb": [], "clean": [], "hosts": [host]})
        entry["deb"].append({"arch": m.group(1) or "", "url": url,
                             "suite": m.group(3), "components": m.group(4)})
    return managed, list(manual_by_host.values())


def atomic_write(path, text):
    tmp = path + ".mm.tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, path)


def add_block(name, entries, cleans, key="", preset="", disabled=False):
    """entries: list of {arch,url,suite/suites,components(list or str)}; cleans: list of urls."""
    name = slug(name)
    text = read_list()
    # Remove any existing block of the same name first (idempotent add/update).
    text = remove_block_text(text, name)
    pre = OFF if disabled else ""
    lines = [BLOCK_START.format(name=name)]
    if key:
        lines.append(f"# mm-key: {key}")
    if preset:
        lines.append(f"# mm-preset: {preset}")
    for e in entries:
        arch = (e.get("arch") or "amd64").strip()
        comps = e.get("components")
        if isinstance(comps, list):
            comps = " ".join(comps)
        suites = e.get("suites") or ([e["suite"]] if e.get("suite") else [])
        for suite in suites:
            lines.append(f"{pre}deb [arch={arch}] {e['url']} {suite} {comps}")
    for c in cleans or []:
        lines.append(f"{pre}clean {c}")
    lines.append(BLOCK_END.format(name=name))
    block = "\n".join(lines)
    if text and not text.endswith("\n"):
        text += "\n"
    text += "\n" + block + "\n"
    if os.path.exists(MIRROR_LIST):
        shutil.copy2(MIRROR_LIST, MIRROR_LIST + ".bak.mm")
    atomic_write(MIRROR_LIST, text)
    return name


def toggle_block(name):
    """Comment/uncomment a managed block's deb/clean lines. Returns new enabled state or None."""
    name = slug(name)
    found = {"state": None}

    def repl(m):
        if slug(m.group("name").strip()) != name:
            return m.group(0)
        body = m.group("body")
        deb_lines = [l for l in body.splitlines()
                     if DEB_RE.match(l[len(OFF):] if l.startswith(OFF) else l)
                     or CLEAN_RE.match(l[len(OFF):] if l.startswith(OFF) else l)]
        disabling = any(not l.startswith(OFF) for l in deb_lines)  # any active -> disable all
        new_lines = []
        for l in body.splitlines():
            is_repo = (DEB_RE.match(l[len(OFF):] if l.startswith(OFF) else l)
                       or CLEAN_RE.match(l[len(OFF):] if l.startswith(OFF) else l))
            if not is_repo:
                new_lines.append(l); continue
            if disabling:
                new_lines.append(l if l.startswith(OFF) else OFF + l)
            else:
                new_lines.append(l[len(OFF):] if l.startswith(OFF) else l)
        found["state"] = not disabling
        return (f"\n# >>> mirror-manager: {m.group('name')} >>>\n"
                + "\n".join(new_lines)
                + f"\n# <<< mirror-manager: {m.group('name')} <<<\n")

    text = read_list()
    new = BLOCK_RE.sub(repl, text)
    if found["state"] is None:
        return None
    if os.path.exists(MIRROR_LIST):
        shutil.copy2(MIRROR_LIST, MIRROR_LIST + ".bak.mm")
    atomic_write(MIRROR_LIST, new)
    return found["state"]


def local_path_of(url):
    """On-disk mirror path for an upstream URL (scheme stripped), or None if outside MIRROR_PATH."""
    p = urllib.parse.urlparse(url)
    rel = (p.netloc + p.path).strip("/")
    full = os.path.realpath(os.path.join(MIRROR_PATH, rel))
    base = os.path.realpath(MIRROR_PATH)
    if full == base or not full.startswith(base + os.sep):
        return None
    return full


def du_path(path):
    try:
        r = subprocess.run(["du", "-sb", path], capture_output=True, text=True, timeout=1800)
        if r.returncode == 0:
            return int(r.stdout.split()[0])
    except Exception:
        pass
    return 0


def purge_repo_paths(repo):
    """rm -rf the on-disk trees for a repo's deb/clean URL paths. Returns (removed_paths, freed_bytes)."""
    urls = {d["url"] for d in repo.get("deb", [])} | set(repo.get("clean", []))
    removed, freed = [], 0
    for u in urls:
        path = local_path_of(u)
        if path and os.path.isdir(path):
            freed += du_path(path)
            shutil.rmtree(path, ignore_errors=True)
            removed.append(path)
    return removed, freed


def release_mtime(repo):
    """Newest dists/<suite>/{InRelease,Release} mtime among the repo's on-disk paths (0 if none)."""
    newest = 0
    for d in repo.get("deb", []):
        path = local_path_of(d["url"])
        if not path:
            continue
        for fn in ("InRelease", "Release"):
            f = os.path.join(path, "dists", d["suite"], fn)
            try:
                newest = max(newest, int(os.path.getmtime(f)))
            except OSError:
                pass
    return newest


def repo_health(repo):
    """True if every enabled suite has a Release/InRelease on disk."""
    ok = True
    any_checked = False
    for d in repo.get("deb", []):
        path = local_path_of(d["url"])
        if not path:
            continue
        any_checked = True
        have = any(os.path.exists(os.path.join(path, "dists", d["suite"], fn))
                   for fn in ("InRelease", "Release"))
        ok = ok and have
    return ok if any_checked else None


def remove_block_text(text, name):
    name = slug(name)
    def repl(m):
        return "" if slug(m.group("name").strip()) == name else m.group(0)
    return BLOCK_RE.sub(repl, text)


def remove_block(name):
    text = read_list()
    new = remove_block_text(text, name)
    if new == text:
        return False
    if os.path.exists(MIRROR_LIST):
        shutil.copy2(MIRROR_LIST, MIRROR_LIST + ".bak.mm")
    atomic_write(MIRROR_LIST, new)
    return True


def http_get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "mirror-manager"})
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
        return resp.read()


def _packages_bytes(base_url, suite, comp, arch):
    url = f"{base_url.rstrip('/')}/dists/{suite}/{comp}/binary-{arch}/Packages.gz"
    try:
        raw = http_get(url)
    except Exception:
        return None
    try:
        return gzip.decompress(raw)
    except Exception:
        return raw


def packages_count(base_url, suite, comp, arch):
    """Number of Package: stanzas in dists/<suite>/<comp>/binary-<arch>/Packages.gz (None if 404)."""
    data = _packages_bytes(base_url, suite, comp, arch)
    if data is None:
        return None
    return data.count(b"\nPackage:") + (1 if data.startswith(b"Package:") else 0)


def packages_size(base_url, suite, comp, arch):
    """Sum of the Size: fields (download bytes) for a component, 0 if absent."""
    data = _packages_bytes(base_url, suite, comp, arch)
    if not data:
        return 0
    total = 0
    for line in data.splitlines():
        if line.startswith(b"Size:"):
            try:
                total += int(line.split(b":", 1)[1].strip())
            except ValueError:
                pass
    return total


def estimate_entries(entries):
    """Estimate the download size for a set of {url/base_url, suites, components, arch}.
    Fetches upstream Packages indexes and sums Size: fields (amd64, plus 'all' if requested)."""
    total = 0
    detail = []
    for e in entries:
        base = e.get("url") or e.get("base_url")
        arch = (e.get("arch") or "amd64")
        arches = ["amd64"] + (["all"] if "all" in arch else [])
        comps = e.get("components")
        comps = comps.split() if isinstance(comps, str) else (comps or ["main"])
        suites = e.get("suites") or ([e["suite"]] if e.get("suite") else [])
        for suite in suites:
            sz = 0
            for c in comps:
                for a in arches:
                    sz += packages_size(base, suite, c, a)
            total += sz
            detail.append({"base_url": base, "suite": suite, "bytes": sz})
    return {"bytes": total, "detail": detail}


def estimate_all():
    """Budget estimation: full upstream download size of EVERY configured (enabled) repo,
    vs current free space and budget. Reads upstream Packages indexes — slow; on-demand."""
    managed, manual = parse_repos(read_list())
    per, total = [], 0
    for r in [x for x in managed + manual if x.get("enabled", True)]:
        entries = [{"url": d["url"], "suites": [d["suite"]],
                    "components": d["components"].split(), "arch": arch_value(d.get("arch"))}
                   for d in r["deb"]]
        b = estimate_entries(entries)["bytes"]
        per.append({"name": r["name"], "bytes": b})
        total += b
    disk = disk_status()
    return {"total": total, "per": sorted(per, key=lambda x: -x["bytes"]),
            "used": disk["used"], "free": disk["free"], "budget": disk["budget"],
            "exceeds_free": total > disk["free"], "exceeds_budget": total > disk["budget"]}


def timer_state():
    info = {}
    r = run(["systemctl", "show", APT_TIMER, "-p", "NextElapseUSecRealtime",
             "-p", "LastTriggerUSec", "-p", "ActiveState"])
    for line in r.stdout.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            info[k] = v
    en = run(["systemctl", "is-enabled", APT_TIMER])
    return {"enabled": en.stdout.strip() == "enabled",
            "active": info.get("ActiveState", "") == "active",
            "next": info.get("NextElapseUSecRealtime", "").strip(),
            "last": info.get("LastTriggerUSec", "").strip()}


# Known archive hosts -> their keyring filename (base OS repos carry no mm-key tag).
KEYRING_BY_HOST = {
    "deb.debian.org": "debian-archive-keyring.gpg",
    "security.debian.org": "debian-archive-keyring.gpg",
    "ftp.debian.org": "debian-archive-keyring.gpg",
    "archive.ubuntu.com": "ubuntu-archive-keyring.gpg",
    "security.ubuntu.com": "ubuntu-archive-keyring.gpg",
}
DEB_VER = {"bookworm": "12", "trixie": "13", "bullseye": "11"}
UBU_VER = {"noble": "24.04", "jammy": "22.04", "focal": "20.04"}
GENERIC_SUITES = {"stable", "oldstable", "nodistro"}
# Base-OS keyrings — repos using these are always included in client setup (never optional).
ARCHIVE_KEYS = {"debian-archive-keyring.gpg", "ubuntu-archive-keyring.gpg"}


def _backup_defaults_sh(indent=""):
    """Shell lines that back up + disable the distro's default APT sources (idempotent)."""
    return "\n".join(indent + l for l in [
        'TS=$(date +%Y%m%d%H%M%S)',
        '# Back up + disable distro defaults so the client uses only the mirror.',
        'for f in /etc/apt/sources.list /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list.d/debian.sources; do',
        '  [ -f "$f" ] || continue',
        '  grep -q "apt-mirror bootstrap" "$f" 2>/dev/null && continue',
        '  cp -a "$f" "$f.example-bak-$TS"',
        '  printf "# Disabled by apt-mirror bootstrap %s — original backed up to %s\\n" "$TS" "$f.example-bak-$TS" > "$f"',
        '  echo "backed up + disabled $f"',
        'done',
    ])


def preset_keyring_map():
    """host -> key filename, derived from presets.json (keeps manual repos' keyrings correct)."""
    m = {}
    for p in load_presets():
        kn = (p.get("key") or {}).get("name")
        if not kn:
            continue
        for e in p.get("entries", []):
            m[netloc_of(e["base_url"])] = kn
    return m


def keyring_for(repo, host, pmap=None):
    if repo.get("key"):
        return repo["key"]
    if host in KEYRING_BY_HOST:
        return KEYRING_BY_HOST[host]
    if pmap and host in pmap:
        return pmap[host]
    return slug(repo["name"]) + ".gpg"


def suite_synced(url, suite):
    """True if this suite is actually mirrored on disk (has InRelease/Release) — so client
    config never points at a repo apt-mirror hasn't downloaded yet."""
    base = local_path_of(url)
    if not base:
        return False
    dd = os.path.join(base, "dists", suite)
    return os.path.exists(os.path.join(dd, "InRelease")) or os.path.exists(os.path.join(dd, "Release"))


def suite_applies(suite, codename, ver):
    """Does a repo suite apply to a client running <codename>?"""
    if suite == codename or suite.startswith(codename + "-"):
        return True                       # bookworm / bookworm-updates / bookworm-pgdg
    if ver and suite == ver:
        return True                       # numeric suites (OpenProject "12")
    return suite in GENERIC_SUITES        # distro-agnostic (grafana "stable", node "nodistro")


def _assemble_sources(codename, groups):
    """Turn per-repo {name,lines,keys} groups into a .list body + install script."""
    lines, keys, seen = [], {}, set()
    for g in groups:
        for ln in g["lines"]:
            if ln not in seen:
                seen.add(ln)
                lines.append(ln)
        keys.update(g["keys"])
    body = "\n".join(lines) if lines else "# (no repos selected for " + codename + ")"
    script = ["#!/bin/sh", "set -eu",
              "# Generated by mirror-manager — APT client setup for " + codename,
              'if [ "$(id -u)" -ne 0 ]; then echo "Run as root (sudo)." >&2; exit 1; fi',
              _backup_defaults_sh(),
              "install -d -m0755 /etc/apt/keyrings"]
    for name in sorted(keys):
        script.append(f"curl -fsSL {keys[name]} -o /etc/apt/keyrings/{name}")
        script.append(f"chmod 0644 /etc/apt/keyrings/{name}")
    script.append("tee /etc/apt/sources.list.d/example.list >/dev/null <<'EOF'\n"
                  + body + "\nEOF")
    script.append("apt-get update")
    return body, "\n".join(script), keys


def client_sources(codename, selected=None):
    """Per-repo client sources for one OS. `selected` = iterable of repo names to include
    (None = all applicable). Returns groups (for UI checkboxes) + the assembled output."""
    managed, manual = parse_repos(read_list())
    repos = [r for r in managed + manual if r.get("enabled", True)]
    sel = set(selected) if selected is not None else None
    ver = DEB_VER.get(codename) or UBU_VER.get(codename)
    pmap = preset_keyring_map()
    groups = []
    for r in repos:
        rlines, rkeys = [], {}
        applicable = False
        for d in r["deb"]:
            if not suite_applies(d["suite"], codename, ver):
                continue
            applicable = True
            # Skip suites not yet on disk so clients never get a 404 for an un-synced repo.
            if not suite_synced(d["url"], d["suite"]):
                continue
            p = urllib.parse.urlparse(d["url"])
            uri = f"{PUBLIC_URL}/{p.netloc}{p.path}".rstrip("/")
            arch = arch_value(d.get("arch"))
            keyname = keyring_for(r, p.netloc, pmap)
            rlines.append(f"deb [arch={arch} signed-by=/etc/apt/keyrings/{keyname}] "
                          f"{uri} {d['suite']} {d['components']}")
            rkeys[keyname] = f"{PUBLIC_URL}/keys/{keyname}"
        if applicable:
            host0 = netloc_of(r["deb"][0]["url"]) if r.get("deb") else ""
            base = keyring_for(r, host0, pmap) in ARCHIVE_KEYS
            groups.append({"name": r["name"], "managed": r.get("managed", False),
                           "base": base, "synced": bool(rlines), "lines": rlines, "keys": rkeys})
    chosen = groups if sel is None else [g for g in groups if g["name"] in sel]
    body, script, keys = _assemble_sources(codename, chosen)
    return {"codename": codename, "groups": groups, "selected": sorted(g["name"] for g in chosen),
            "list": body, "script": script, "keys": keys}


def server_setup():
    """The current mirror.list plus commands to bootstrap another mirror server."""
    cmds = (
        "# Stand up another apt-mirror server (fresh Debian 13), from a clone of the repo:\n"
        "sudo ./scripts/setup-apt-mirror-server.sh --role both\n"
        "# Use the mirror.list this manager maintains (saved above), then first sync:\n"
        f"sudo cp mirror.list {MIRROR_LIST}\n"
        "sudo ./scripts/populate-mirror-keys.sh      # archive keyrings (Debian/Ubuntu)\n"
        "sudo apt-mirror                              # initial sync (long)\n"
        "# Optional: run this dashboard there too:\n"
        "sudo ./scripts/setup-mirror-manager.sh\n"
    )
    return {"mirror_list": read_list(), "path": MIRROR_LIST, "commands": cmds}


# ---- integrity verification ---- #
def _sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _release_hashes(text):
    """Parse the SHA256: section of a Release/InRelease file -> {relpath: hexhash}."""
    out, insec = {}, False
    for line in text.splitlines():
        if line.startswith("SHA256:"):
            insec = True
            continue
        if insec:
            if line[:1] in (" ", "\t"):
                parts = line.split()
                if len(parts) >= 3:
                    out[parts[2]] = parts[0]
            elif line.strip():
                insec = False
    return out


def verify_mirror(names=None):
    """Verify InRelease signatures + index hashes for mirrored suites on disk.
    Hashes only the index files we actually hold (skips files apt-mirror didn't fetch)."""
    managed, manual = parse_repos(read_list())
    sel = set(names) if names else None
    repos = [r for r in managed + manual if (sel is None or r["name"] in sel)]
    pmap = preset_keyring_map()
    results = []
    for r in repos:
        host0 = netloc_of(r["deb"][0]["url"]) if r.get("deb") else ""
        keyname = keyring_for(r, host0, pmap)
        krpath = os.path.join(KEYS_DIR, keyname)
        seen = set()
        for d in r["deb"]:
            base = local_path_of(d["url"])
            if not base:
                continue
            distdir = os.path.join(base, "dists", d["suite"])
            if distdir in seen:
                continue
            seen.add(distdir)
            res = {"repo": r["name"], "suite": d["suite"], "key": keyname,
                   "checked": 0, "mismatch": [], "signature": "n/a"}
            inrel, rel = os.path.join(distdir, "InRelease"), os.path.join(distdir, "Release")
            relgpg = rel + ".gpg"
            if not (os.path.exists(inrel) or os.path.exists(rel)):
                res["status"] = "missing"
                results.append(res)
                continue
            # signature (needs gpgv + the keyring file)
            if not os.path.exists(krpath):
                res["signature"] = "no-key"
            elif os.path.exists(inrel):
                res["signature"] = "ok" if run(["gpgv", "--keyring", krpath, inrel]).returncode == 0 else "bad"
            elif os.path.exists(relgpg):
                res["signature"] = "ok" if run(["gpgv", "--keyring", krpath, relgpg, rel]).returncode == 0 else "bad"
            else:
                res["signature"] = "no-sig"
            # index hashes
            try:
                with open(inrel if os.path.exists(inrel) else rel, encoding="utf-8", errors="replace") as fh:
                    text = fh.read()
            except OSError:
                text = ""
            for relp, want in _release_hashes(text).items():
                f = os.path.join(distdir, relp)
                if os.path.isfile(f):
                    res["checked"] += 1
                    try:
                        if _sha256(f) != want:
                            res["mismatch"].append(relp)
                    except OSError:
                        res["mismatch"].append(relp)
            res["status"] = "fail" if (res["signature"] == "bad" or res["mismatch"]) else (
                "warn" if res["signature"] in ("no-key", "no-sig") else "ok")
            results.append(res)
    summary = {"ok": 0, "fail": 0, "warn": 0, "missing": 0}
    for x in results:
        summary[x["status"]] = summary.get(x["status"], 0) + 1
    return {"results": results, "summary": summary, "total": len(results)}


# ---- client landing page ---- #
LANDING_OSES = [("bookworm", "Debian 12 (bookworm)"), ("trixie", "Debian 13 (trixie)"),
                ("noble", "Ubuntu 24.04 (noble)")]


def landing_html():
    managed, manual = parse_repos(read_list())
    repos = [r for r in managed + manual if r.get("enabled", True)]
    rows = "".join(
        f"<tr><td>{_h(r['name'])}</td><td>{_h(', '.join(sorted({d['suite'] for d in r['deb']})))}</td>"
        f"<td>{_h(', '.join(r['hosts']))}</td></tr>" for r in repos)
    blocks = []
    for cn, label in LANDING_OSES:
        src = client_sources(cn)
        if not src["groups"]:
            continue
        blocks.append(f"<details><summary>{_h(label)}</summary>"
                      f"<p>Run as root:</p><pre>{_h(src['script'])}</pre></details>")
    return f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>APT Mirror — {_h(PUBLIC_URL)}</title>
<style>body{{font:15px/1.6 system-ui,-apple-system,Segoe UI,Roboto,sans-serif;max-width:860px;margin:40px auto;padding:0 18px;color:#1a2230}}
h1{{font-size:22px}}h2{{font-size:16px;margin-top:30px}}code,pre{{font-family:ui-monospace,Menlo,Consolas,monospace}}
pre{{background:#0d1117;color:#d6dee8;padding:14px;border-radius:8px;overflow:auto;font-size:12.5px}}
table{{border-collapse:collapse;width:100%}}td,th{{text-align:left;padding:7px 10px;border-bottom:1px solid #e3e8ef}}
th{{color:#5b6776;font-size:12px;text-transform:uppercase;letter-spacing:.04em}}summary{{cursor:pointer;font-weight:600;margin:8px 0}}
.muted{{color:#5b6776}}a{{color:#2f6df6}}</style></head><body>
<h1>APT Mirror</h1>
<p class="muted">Internal Debian/Ubuntu package mirror at <code>{_h(PUBLIC_URL)}</code>.</p>
<h2>Quick setup</h2>
<p>On a Debian/Ubuntu client, run:</p>
<pre>curl -fsSL {_h(PUBLIC_URL)}/setup.sh | sudo sh</pre>
<p class="muted">Auto-detects the OS and configures APT to use this mirror. Or follow the per-OS steps below.</p>
<h2>Available repositories</h2>
<table><thead><tr><th>Repository</th><th>Suites</th><th>Upstream host(s)</th></tr></thead><tbody>{rows}</tbody></table>
<h2>Client setup</h2>
{''.join(blocks) or '<p class="muted">No repositories configured yet.</p>'}
<p class="muted" style="margin-top:30px">Keys are published under <a href="{_h(PUBLIC_URL)}/keys/">/keys/</a>. Generated by mirror-manager.</p>
</body></html>"""


def _h(s):
    return (str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def bootstrap_script(selected=None):
    """A self-contained 'curl | sudo sh' installer: detects the client OS, lets the operator
    choose which OPTIONAL repos to add (base OS is always configured), backs up + disables the
    distro defaults, installs keyrings, writes sources, and updates."""
    supported = [cn for cn, _ in LANDING_OSES if client_sources(cn, selected)["groups"]]
    p = ["#!/bin/sh",
         "# APT mirror client bootstrap.",
         f"#   curl -fsSL {PUBLIC_URL}/setup.sh | sudo sh                      # base OS + ALL repos",
         f"#   curl -fsSL {PUBLIC_URL}/setup.sh | sudo sh -s -- grafana docker # base OS + only these",
         f"#   curl -fsSL {PUBLIC_URL}/setup.sh | sudo sh -s -- --none         # base OS only",
         f"#   curl -fsSL {PUBLIC_URL}/setup.sh | sudo sh -s -- --list         # list optional repos",
         "# Base OS (Debian/Ubuntu) is always configured; named args pick which OPTIONAL repos to add.",
         "set -eu",
         'if [ "$(id -u)" -ne 0 ]; then echo "Run as root (pipe to sudo sh)." >&2; exit 1; fi',
         'command -v curl >/dev/null 2>&1 || { echo "curl is required." >&2; exit 1; }',
         '[ -r /etc/os-release ] || { echo "/etc/os-release missing." >&2; exit 1; }',
         ". /etc/os-release",
         'CN="${VERSION_CODENAME:-}"',
         'WANT=""; LISTONLY=0; NONE=0',
         'for a in "$@"; do case "$a" in --list) LISTONLY=1 ;; --none) NONE=1 ;; -*) ;; *) WANT="$WANT $a" ;; esac; done',
         'want(){ [ "$NONE" = 1 ] && return 1; [ -z "$WANT" ] && return 0; for w in $WANT; do [ "$w" = "$1" ] && return 0; done; return 1; }',
         'AVAIL=""; KNAMES=""; KURLS=""; SRC=""',
         'addkey(){ case " $KNAMES " in *" $1 "*) : ;; *) KNAMES="$KNAMES $1"; KURLS="$KURLS $1|$2" ;; esac; }',
         'addbase(){ addkey "$1" "$2"; SRC="$SRC$3',
         '"; }',
         'addrepo(){ case " $AVAIL " in *" $1 "*) : ;; *) AVAIL="$AVAIL $1" ;; esac; want "$1" || return 0; addkey "$2" "$3"; SRC="$SRC$4',
         '"; }',
         'case "$CN" in']
    for cn, _label in LANDING_OSES:
        src = client_sources(cn, selected)
        if not src["groups"]:
            continue
        p.append(f"  {cn})")
        for g in src["groups"]:
            kname = next(iter(g["keys"]), "")
            kurl = g["keys"].get(kname, "")
            for line in g["lines"]:
                if g.get("base"):
                    p.append(f'    addbase "{kname}" "{kurl}" "{line}"')
                else:
                    p.append(f'    addrepo "{g["name"]}" "{kname}" "{kurl}" "{line}"')
        p.append("    ;;")
    p.append('  *) echo "Unsupported OS codename: ${CN:-unknown}. Supported: '
             + ", ".join(supported) + '." >&2; exit 1 ;;')
    p.append("esac")
    p.append('if [ "$LISTONLY" = 1 ]; then echo "Optional repos for ${CN}:${AVAIL:- (none)}"; '
             'echo "Pick some: ... | sudo sh -s -- <repo> [repo...]   (omit args = all)"; exit 0; fi')
    p.append('[ -n "$SRC" ] || { echo "No repositories selected/applicable for ${CN}." >&2; exit 1; }')
    p.append(_backup_defaults_sh())
    p.append("install -d -m0755 /etc/apt/keyrings")
    p.append('for e in $KURLS; do n=${e%%|*}; u=${e#*|}; '
             'curl -fsSL "$u" -o "/etc/apt/keyrings/$n"; chmod 0644 "/etc/apt/keyrings/$n"; done')
    p.append('printf "%s" "$SRC" > /etc/apt/sources.list.d/example.list')
    p.append("apt-get update")
    p.append(f'echo "Configured ${{CN}} for {PUBLIC_URL}; optional repos: ${{WANT:- all}}. Done."')
    return "\n".join(p) + "\n"


def publish_landing():
    os.makedirs(WWW_DIR, exist_ok=True)
    html = landing_html()
    idx = os.path.join(WWW_DIR, "index.html")
    atomic_write(idx, html)
    os.chmod(idx, 0o644)
    sh = bootstrap_script()
    setup = os.path.join(WWW_DIR, "setup.sh")
    atomic_write(setup, sh)
    os.chmod(setup, 0o755)
    return {"path": idx, "setup_path": setup, "bytes": len(html), "setup_bytes": len(sh),
            "url": PUBLIC_URL + "/", "setup_url": PUBLIC_URL + "/setup.sh",
            "oneliner": f"curl -fsSL {PUBLIC_URL}/setup.sh | sudo sh"}


def client_config(repo):
    """Generate client .list line(s) and the setup-apt-client.sh command for a repo."""
    host0 = netloc_of(repo["deb"][0]["url"]) if repo.get("deb") else ""
    keyname = keyring_for(repo, host0, preset_keyring_map())
    keyring = f"/etc/apt/keyrings/{keyname}"
    lines = []
    seen = set()
    for d in repo.get("deb", []):
        p = urllib.parse.urlparse(d["url"])
        mirror_uri = f"{PUBLIC_URL}/{p.netloc}{p.path}".rstrip("/")
        arch = arch_value(d.get("arch"))
        line = (f"deb [arch={arch} signed-by={keyring}] "
                f"{mirror_uri} {d['suite']} {d['components']}")
        if line not in seen:
            seen.add(line)
            lines.append(line)
    cmd = None
    preset = repo.get("preset")
    if preset in PRESET_CLIENT_FLAGS:
        flags = PRESET_CLIENT_FLAGS[preset]
        cmd = f"sudo ./scripts/setup-apt-client.sh {flags}".rstrip()
    return {"keyring": keyring, "key_url": f"{PUBLIC_URL}/keys/{keyname}",
            "lines": lines, "command": cmd}


# ---- "just paste a URL" auto-discovery ---- #
DISCOVER_SUITES = ["stable", "oldstable", "bookworm", "bookworm-updates", "bookworm-security",
                   "trixie", "trixie-updates", "trixie-security", "noble", "noble-updates",
                   "noble-security", "jammy", "focal", "12", "13", "24.04", "22.04"]
KEY_CANDIDATES = ["gpg", "key", "key.asc", "key.gpg", "pubkey.gpg", "repo.key",
                  "release.key", "apt.gpg", "archive.key", "gpg-key.asc"]


def match_preset(url):
    """Return a preset whose host (+ path prefix) matches this URL, else None."""
    u = url.rstrip("/")
    host = urllib.parse.urlparse(u).netloc
    for preset in load_presets():
        for e in preset.get("entries", []):
            b = e["base_url"].rstrip("/")
            if urllib.parse.urlparse(b).netloc == host and (u.startswith(b) or b.startswith(u)):
                return preset
    return None


def autoindex_suites(base):
    """If dists/ has an autoindex listing, extract the directory names."""
    try:
        html = http_get(base.rstrip("/") + "/dists/").decode("utf-8", "replace")
    except Exception:
        return []
    names = []
    for m in re.finditer(r'href="([^"?#]+?)/?"', html):
        n = m.group(1).strip("/")
        if n and n not in ("..", ".") and "/" not in n and not n.startswith("http"):
            names.append(n)
    return list(dict.fromkeys(names))


def discover_probe(base, suite):
    """Light per-suite probe: Release components/arches + arch:all detection.
    Returns {suite, components, arch} or None for missing/empty-stub suites."""
    try:
        rel = http_get(f"{base.rstrip('/')}/dists/{suite}/Release").decode("utf-8", "replace")
    except Exception:
        return None
    comps = []
    for line in rel.splitlines():
        if line.startswith("Components:"):
            comps = line.split(":", 1)[1].split()
    comps = comps or ["main"]
    nonempty, has_all = [], False
    for c in comps[:16]:                       # cap scan for big repos (e.g. PGDG)
        if packages_count(base, suite, c, "amd64"):
            nonempty.append(c)
        if packages_count(base, suite, c, "all"):
            has_all = True
    if not nonempty and not has_all:
        return None                            # empty stub (OpenProject trixie-style)
    return {"suite": suite, "components": nonempty or comps,
            "arch": "amd64,all" if has_all else "amd64"}


def discover_key(base, host):
    for rel in KEY_CANDIDATES:
        for u in (f"{base.rstrip('/')}/{rel}", f"https://{host}/{rel}"):
            try:
                data = http_get(u)
            except Exception:
                continue
            head = data[:64]
            if b"BEGIN PGP PUBLIC KEY" in data[:200] or head[:1] in (b"\x98", b"\x99", b"\xc5", b"\xc6"):
                return u
    return None


def discover(url):
    url = url.strip().rstrip("/")
    if not url.startswith(("http://", "https://")):
        url = "https://" + url
    p = urllib.parse.urlparse(url)
    out = {"input": url}
    mp = match_preset(url)
    if mp:
        out.update(matched_preset=mp["id"], label=mp["label"], note=mp.get("notes", ""))
        return out
    base = url
    hint = []
    if "/dists/" in p.path:
        base = url.split("/dists/")[0]
        hint = [p.path.split("/dists/")[1].strip("/").split("/")[0]]
    out["base_url"] = base
    cands = (hint or autoindex_suites(base) or DISCOVER_SUITES)[:24]
    found = [dp for dp in (discover_probe(base, s) for s in cands) if dp]
    out["suites"] = found
    out["key_url"] = discover_key(base, p.netloc)
    seg = p.path.strip("/").split("/")[0] if p.path.strip("/") else ""
    out["name"] = slug(p.netloc.split(".")[0] + (("-" + seg) if seg else ""))
    if not found:
        out["warning"] = ("No non-empty suites found — give the repo ROOT (the dir above "
                          "dists/), or the server may not allow listing. Add manually if needed.")
    return out


def probe(base_url, suite):
    """Fetch the Release file, parse Components/Architectures, and report which
    components actually have amd64 / all packages. Mirrors the manual checks we do."""
    rel_url = f"{base_url.rstrip('/')}/dists/{suite}/Release"
    out = {"base_url": base_url, "suite": suite, "release_url": rel_url, "ok": False}
    try:
        rel = http_get(rel_url).decode("utf-8", "replace")
    except Exception as exc:
        out["error"] = f"Release not reachable: {exc}"
        return out
    comps, arches = [], []
    for line in rel.splitlines():
        if line.startswith("Components:"):
            comps = line.split(":", 1)[1].split()
        elif line.startswith("Architectures:"):
            arches = line.split(":", 1)[1].split()
    out.update(ok=True, components=comps, architectures=arches)
    detail = []
    has_all = False
    nonempty = []
    for c in comps:
        amd = packages_count(base_url, suite, c, "amd64")
        alln = packages_count(base_url, suite, c, "all")
        if alln:
            has_all = True
        if amd:
            nonempty.append(c)
        detail.append({"component": c, "amd64": amd, "all": alln})
    out["component_detail"] = detail
    out["nonempty_components"] = nonempty
    out["has_binary_all"] = has_all
    out["suggested_arch"] = "amd64,all" if has_all else "amd64"
    if not nonempty and not has_all:
        out["warning"] = ("Release exists but no component has amd64 or arch:all packages "
                          "(suite may be an empty stub — like OpenProject trixie/noble).")
    return out


def fetch_key(name, url):
    """Download a key and write a binary keyring to KEYS_DIR/<name> for apt Signed-By.
    Handles both ASCII-armored keys (.asc / BEGIN PGP …) and already-binary keyrings
    (e.g. Tailscale's *.noarmor.gpg) — dearmor only the armored ones."""
    os.makedirs(KEYS_DIR, exist_ok=True)
    raw = http_get(url)
    dest = os.path.join(KEYS_DIR, name)
    tmp = os.path.join(KEYS_DIR, name + ".in")
    out = os.path.join(KEYS_DIR, name + ".new")
    armored = b"BEGIN PGP PUBLIC KEY BLOCK" in raw[:200] or raw.lstrip()[:5] == b"-----"
    try:
        if armored:
            with open(tmp, "wb") as fh:
                fh.write(raw)
            subprocess.run(["gpg", "--batch", "--yes", "--dearmor", "-o", out, tmp],
                           check=True, capture_output=True, timeout=60)
        else:
            # Already a binary keyring — write it through unchanged.
            with open(out, "wb") as fh:
                fh.write(raw)
        os.chmod(out, 0o644)
        # Atomic replace — also works when an existing key file is owned by root (we own the dir).
        os.replace(out, dest)
    finally:
        for f in (tmp, out):
            try:
                os.remove(f)
            except OSError:
                pass
    refresh_keys_manifest()
    return dest


def refresh_keys_manifest():
    try:
        names = sorted(f for f in os.listdir(KEYS_DIR) if f.endswith(".gpg"))
    except OSError:
        return
    lines = []
    for n in names:
        p = os.path.join(KEYS_DIR, n)
        try:
            r = subprocess.run(["sha256sum", n], cwd=KEYS_DIR, capture_output=True,
                               text=True, timeout=30)
            if r.returncode == 0:
                lines.append(r.stdout.strip())
        except Exception:
            pass
    if lines:
        atomic_write(os.path.join(KEYS_DIR, "SHA256SUMS"), "\n".join(lines) + "\n")


def disk_status():
    target = MIRROR_PATH if os.path.exists(MIRROR_PATH) else os.path.dirname(MIRROR_PATH) or "/"
    total, used, free = shutil.disk_usage(target)
    return {"path": target, "total": total, "used": used, "free": free,
            "budget": BUDGET_BYTES,
            "budget_used_pct": round(100 * used / BUDGET_BYTES, 1) if BUDGET_BYTES else None,
            "disk_used_pct": round(100 * used / total, 1) if total else None}


# ---- per-repo (per-host) sizes: slow du, cached + refreshed in background ---- #
_sizes_lock = threading.Lock()
_sizes_state = {"computing": False}


def load_sizes_cache():
    try:
        with open(SIZES_CACHE, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return {"updated": 0, "hosts": {}}


def compute_sizes():
    with _sizes_lock:
        if _sizes_state["computing"]:
            return
        _sizes_state["computing"] = True
    hosts = {}
    try:
        if os.path.isdir(MIRROR_PATH):
            for entry in os.scandir(MIRROR_PATH):
                if not entry.is_dir():
                    continue
                try:
                    r = subprocess.run(["du", "-sb", entry.path], capture_output=True,
                                       text=True, timeout=3600)
                    if r.returncode == 0:
                        hosts[entry.name] = int(r.stdout.split()[0])
                except Exception:
                    pass
        data = {"updated": int(time.time()), "hosts": hosts}
        os.makedirs(VAR_DIR, exist_ok=True)
        atomic_write(SIZES_CACHE, json.dumps(data))
    finally:
        with _sizes_lock:
            _sizes_state["computing"] = False


def sizes_background_refresh():
    threading.Thread(target=compute_sizes, daemon=True).start()


# ---- sync control via systemd ---- #
def run(cmd, timeout=30, env=None):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env)
    except Exception as exc:
        class R:
            returncode = 1
            stdout = ""
            stderr = str(exc)
        return R()



# ---- auth / user management (config consumed by ldap_auth.py) ---------------- #
LDAP_FIELDS = ("uri", "ca", "reqcert", "bind_mode", "user_dn_template",
               "bind_dn", "base_dn", "user_filter", "required_group")
USER_RE = re.compile(r"^[A-Za-z0-9._@-]{1,64}$")


def load_ldap_conf():
    try:
        with open(LDAP_CONF) as fh:
            return json.load(fh)
    except Exception:
        return {}


def ldap_conf_public():
    """LDAP config for the UI — never returns the bind password itself."""
    c = load_ldap_conf()
    out = {k: c.get(k, "") for k in LDAP_FIELDS}
    out["enabled"] = bool(c.get("enabled", False))
    out["bind_pw_set"] = bool(c.get("bind_pw"))
    return out


def save_ldap_conf(body):
    c = load_ldap_conf()
    for k in LDAP_FIELDS:
        if k in body:
            c[k] = ("" if body[k] is None else str(body[k]))
    # never persist an insecure TLS mode unless the operator explicitly opted in
    rc = str(c.get("reqcert") or "demand")
    if rc != "demand" and not INSECURE_LDAP_OK:
        rc = "demand"
    c["reqcert"] = rc
    c["enabled"] = bool(body.get("enabled", c.get("enabled", False)))
    if body.get("bind_pw"):                 # only replace when a new one is supplied
        c["bind_pw"] = str(body["bind_pw"])
    if body.get("clear_bind_pw"):
        c.pop("bind_pw", None)
    os.makedirs(AUTH_DIR, mode=0o700, exist_ok=True)
    tmp = LDAP_CONF + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)  # 0600 from creation
    with os.fdopen(fd, "w") as fh:
        json.dump(c, fh, indent=2)
    os.replace(tmp, LDAP_CONF)
    return ldap_conf_public()


def htpasswd_users():
    users = []
    try:
        with open(HTPASSWD) as fh:
            for line in fh:
                line = line.strip()
                if line and ":" in line and not line.startswith("#"):
                    users.append(line.split(":", 1)[0])
    except OSError:
        pass
    return sorted(set(users))


def htpasswd_set(user, password):
    if not USER_RE.match(user or ""):
        return False, "invalid username (allowed: letters, digits, . _ @ -)"
    if not password or len(password) < 8:
        return False, "password must be at least 8 characters"
    if shutil.which("htpasswd") is None:
        return False, "htpasswd not found — install apache2-utils on the sync host"
    os.makedirs(AUTH_DIR, mode=0o700, exist_ok=True)
    create = ["-c"] if not os.path.exists(HTPASSWD) else []
    try:  # -i reads the password from stdin so it never appears on the process argv
        r = subprocess.run(["htpasswd", "-iB"] + create + [HTPASSWD, user],
                           input=password.encode("utf-8"), capture_output=True, timeout=15)
    except Exception as exc:
        return False, f"htpasswd error: {exc}"
    if r.returncode != 0:
        return False, (r.stderr.decode("utf-8", "replace") or "htpasswd failed").strip()
    try:
        os.chmod(HTPASSWD, 0o600)
    except OSError:
        pass
    return True, "ok"


def htpasswd_delete(user):
    if user == BREAKGLASS_USER:
        return False, f"cannot delete the break-glass admin ({BREAKGLASS_USER})"
    if user not in htpasswd_users():
        return False, "no such local user"
    if shutil.which("htpasswd") is None:
        return False, "htpasswd not found — install apache2-utils"
    r = run(["htpasswd", "-D", HTPASSWD, user], timeout=15)
    return (r.returncode == 0), ((r.stderr or "ok").strip())


def ldap_proxy(path, payload=None, timeout=12):
    """Delegate LDAP bind/test/group-listing to ldap_auth.py — the daemon is
    stdlib-only and has no LDAP client."""
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = urllib.request.Request(
        LDAP_AUTH_URL + path, data=data,
        method=("POST" if data is not None else "GET"),
        headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read().decode("utf-8") or "{}")
    except Exception as exc:
        return {"ok": False, "error": f"auth backend unreachable: {exc}"}


def auth_overview():
    return {
        "htpasswd_users": htpasswd_users(),
        "htpasswd_available": shutil.which("htpasswd") is not None,
        "breakglass": BREAKGLASS_USER,
        "ldap": ldap_conf_public(),
        "auth_backend": LDAP_AUTH_URL,
    }


def sync_state():
    r = run(["systemctl", "show", APT_UNIT, "-p", "ActiveState", "-p", "SubState",
             "-p", "ExecMainStatus", "-p", "InactiveEnterTimestamp"])
    info = {}
    for line in r.stdout.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            info[k] = v
    active = info.get("ActiveState", "")
    return {"running": active in ("active", "activating"),
            "active_state": active, "sub_state": info.get("SubState", ""),
            "last_exit": info.get("ExecMainStatus", ""),
            "finished": info.get("InactiveEnterTimestamp", "")}


def start_sync():
    if sync_state()["running"]:
        return False, "already running"
    free_gb = disk_status()["free"] / 1_000_000_000
    if free_gb < MIN_FREE_GB:
        return False, (f"refused: only {free_gb:.0f} GB free (< MM_MIN_FREE_GB={MIN_FREE_GB}). "
                       "Free space, prune snapshots, or lower the floor.")
    r = run(SUDO + ["systemctl", "start", "--no-block", APT_UNIT])
    if r.returncode != 0:
        return False, (r.stderr or "failed to start (check sudoers for apt-mirror.service)").strip()
    return True, "started"


# ---- snapshots (hardlink point-in-time copies) ---- #
_snap_state = {"running": False, "last": ""}


def snapshots_list():
    try:
        names = [n for n in os.listdir(SNAP_DIR)
                 if not n.endswith(".partial") and os.path.isdir(os.path.join(SNAP_DIR, n))]
    except OSError:
        return []
    return sorted(names)


def snapshots_info():
    total = 0
    if os.path.isdir(SNAP_DIR):
        total = du_path(SNAP_DIR)
    return {"snapshots": snapshots_list(), "bytes": total, "dir": SNAP_DIR,
            "creating": _snap_state["running"], "last": _snap_state["last"]}


def snapshot_create_bg(snap_id=""):
    def worker():
        _snap_state["running"] = True
        try:
            cmd = ["sh", SNAPSHOT_SH, "create"] + ([snap_id] if snap_id else [])
            r = run(cmd, timeout=86400, env=_snap_env())
            _snap_state["last"] = (r.stdout or r.stderr or "").strip()[-200:]
        finally:
            _snap_state["running"] = False
    if _snap_state["running"]:
        return False
    threading.Thread(target=worker, daemon=True).start()
    return True


def _snap_env():
    return {**os.environ, "MIRROR_PATH": MIRROR_PATH, "SNAP_DIR": SNAP_DIR}


def snapshot_prune(keep):
    return run(["sh", SNAPSHOT_SH, "prune", str(int(keep))], timeout=3600, env=_snap_env())


def sync_log(lines=200):
    r = run(["journalctl", "-u", APT_UNIT, "-n", str(int(lines)), "--no-pager",
             "--output=cat"], timeout=30)
    if r.returncode != 0 or not r.stdout:
        r = run(["journalctl", "-u", "mirror-manager-sync", "-n", str(int(lines)),
                 "--no-pager", "--output=cat"], timeout=30)
    return r.stdout


def sync_progress(log):
    """Best-effort progress summary parsed from apt-mirror's output."""
    phase, total_files, pct = "", None, None
    for line in log.splitlines():
        s = line.strip()
        if not s:
            continue
        m = re.search(r"Downloading (\d+) archive files", s)
        if m:
            total_files = int(m.group(1)); phase = s
        elif re.search(r"\b(Processing|Cleaning|Begin time|End time|Downloading|"
                       r"Receiving|Building|Proceeding)\b", s):
            phase = s
        m2 = re.search(r"(\d+)%", s)
        if m2:
            pct = int(m2.group(1))
    return {"phase": phase[:200], "total_files": total_files, "percent": pct}


# --------------------------------------------------------------------------- #
# HTTP
# --------------------------------------------------------------------------- #
class Handler(BaseHTTPRequestHandler):
    server_version = "mirror-manager/1.0"

    def log_message(self, fmt, *args):  # quieter logs
        pass

    # -- access control: ip allowlist + token + csrf ----------------------- #
    def _ip_ok(self):
        if not ALLOW_NETS:
            return True
        try:
            ip = ipaddress.ip_address(self.client_address[0])
        except Exception:
            return False
        return any(ip in net for net in ALLOW_NETS)

    def _authed(self):
        if not TOKEN:
            return True
        q = urllib.parse.urlparse(self.path).query
        tok = urllib.parse.parse_qs(q).get("token", [""])[0] or self.headers.get("X-MM-Token", "")
        return tok == TOKEN

    def _mutating_ok(self):
        # Custom header can't be set by a cross-site <form>, so this blunts CSRF.
        return self.headers.get("X-MM", "") == "1"

    def _gate(self, mutating=False):
        """Return True if the request may proceed; otherwise send 403 and return False."""
        if not self._ip_ok():
            self._send(403, {"error": "forbidden: client IP not in MM_ALLOW"})
            return False
        if not self._authed():
            self._send(403, {"error": "bad token"})
            return False
        if mutating and not self._mutating_ok():
            self._send(403, {"error": "missing X-MM header"})
            return False
        return True

    # -- response helpers --------------------------------------------------- #
    def _send(self, code, body, ctype="application/json"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode("utf-8")
        elif isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _json_body(self):
        n = int(self.headers.get("Content-Length", "0") or "0")
        if not n:
            return {}
        try:
            return json.loads(self.rfile.read(n).decode("utf-8"))
        except Exception:
            return {}

    # -- routing ------------------------------------------------------------ #
    def do_GET(self):
        if not self._gate():
            return
        path = urllib.parse.urlparse(self.path).path
        if path in ("/", "/index.html"):
            try:
                with open(os.path.join(HERE, "index.html"), "rb") as fh:
                    return self._send(200, fh.read(), "text/html; charset=utf-8")
            except OSError:
                return self._send(500, {"error": "index.html missing"})
        if path == "/api/status":
            return self._send(200, self._status())
        if path == "/api/presets":
            return self._send(200, {"presets": load_presets()})
        if path == "/api/probe":
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            base = q.get("base_url", [""])[0]
            suite = q.get("suite", [""])[0]
            if not base or not suite:
                return self._send(400, {"error": "base_url and suite required"})
            return self._send(200, probe(base, suite))
        if path == "/api/log":
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            n = q.get("lines", ["200"])[0]
            log = sync_log(n)
            return self._send(200, {"log": log, "sync": sync_state(),
                                    "progress": sync_progress(log)})
        if path == "/api/repo":
            return self._repo_detail(urllib.parse.parse_qs(
                urllib.parse.urlparse(self.path).query).get("name", [""])[0])
        if path == "/api/discover":
            u = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("url", [""])[0]
            if not u:
                return self._send(400, {"error": "url required"})
            return self._send(200, discover(u))
        if path == "/api/sources":
            cn = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("codename", ["bookworm"])[0]
            return self._send(200, client_sources(cn))
        if path == "/api/server-setup":
            return self._send(200, server_setup())
        if path == "/api/verify":
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("repos", [""])[0]
            names = [n for n in q.split(",") if n] or None
            return self._send(200, verify_mirror(names))
        if path == "/api/landing":
            return self._send(200, landing_html(), "text/html; charset=utf-8")
        if path == "/api/setup":
            return self._send(200, bootstrap_script(), "text/plain; charset=utf-8")
        if path == "/api/audit":
            n = int(urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("n", ["100"])[0] or 100)
            return self._send(200, {"entries": read_audit(min(n, 1000))})
        if path == "/api/snapshots":
            return self._send(200, snapshots_info())
        if path == "/api/estimate-all":
            return self._send(200, estimate_all())
        if path == "/api/backup":
            return self._backup()
        if path == "/api/auth":
            return self._send(200, auth_overview())
        if path == "/api/auth/group":
            return self._send(200, ldap_proxy("/group"))
        return self._send(404, {"error": "not found"})

    def _backup(self):
        """Stream a small .tgz of the mirror CONFIG (mirror.list, keyrings, tunables, units)
        for disaster recovery. NOT the multi-TB data."""
        items = [(MIRROR_LIST, "mirror.list"), (KEYS_DIR, "keys"),
                 ("/etc/default/apt-mirror", "etc-default-apt-mirror"),
                 ("/etc/systemd/system/mirror-manager.service.d", "mirror-manager.service.d")]
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w:gz") as tar:
            for p, arc in items:
                if os.path.exists(p):
                    try:
                        tar.add(p, arcname=arc)
                    except Exception:
                        pass
        data = buf.getvalue()
        self.send_response(200)
        self.send_header("Content-Type", "application/gzip")
        self.send_header("Content-Disposition", 'attachment; filename="mirror-config.tgz"')
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        self._audit("backup", "config bundle download")

    def _audit(self, action, detail=""):
        user = self.headers.get("X-Auth-User") or self.headers.get("X-Forwarded-User") or "-"
        ip = (self.headers.get("X-Forwarded-For", "").split(",")[0].strip()
              or self.client_address[0])
        write_audit({"action": action, "detail": detail, "user": user, "ip": ip})

    def do_POST(self):
        if not self._gate(mutating=True):
            return
        path = urllib.parse.urlparse(self.path).path
        if path == "/api/repos":
            return self._add_repo(self._json_body())
        if path == "/api/estimate":
            return self._estimate(self._json_body())
        if path == "/api/sources":
            b = self._json_body()
            return self._send(200, client_sources(b.get("codename", "bookworm"),
                                                  b.get("repos")))
        if path == "/api/repos/toggle":
            name = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("name", [""])[0]
            state = toggle_block(name)
            if state is None:
                return self._send(404, {"error": "no managed block"})
            self._audit("toggle", f"{name} -> {'enabled' if state else 'disabled'}")
            return self._send(200, {"ok": True, "enabled": state})
        if path == "/api/sync":
            ok, msg = start_sync()
            if ok:
                self._audit("sync", "started")
            return self._send(200 if ok else 409, {"ok": ok, "message": msg})
        if path == "/api/timer/toggle":
            want = self._json_body().get("enable", not timer_state()["enabled"])
            run(SUDO + ["systemctl", "enable" if want else "disable", "--now", APT_TIMER])
            self._audit("timer", "enable" if want else "disable")
            return self._send(200, {"ok": True, "timer": timer_state()})
        if path == "/api/sizes/refresh":
            sizes_background_refresh()
            return self._send(202, {"ok": True, "message": "computing"})
        if path == "/api/snapshots":
            sid = (self._json_body().get("id") or "").strip()
            if not snapshot_create_bg(sid):
                return self._send(409, {"ok": False, "message": "a snapshot is already being created"})
            self._audit("snapshot-create", sid or "auto")
            return self._send(202, {"ok": True, "message": "creating snapshot (background)"})
        if path == "/api/snapshots/prune":
            keep = int(self._json_body().get("keep", 4))
            r = snapshot_prune(keep)
            self._audit("snapshot-prune", f"keep={keep}")
            return self._send(200, {"ok": r.returncode == 0, "output": (r.stdout or r.stderr).strip()})
        if path == "/api/landing":
            try:
                res = publish_landing()
                self._audit("publish", "landing + setup.sh")
                return self._send(200, {"ok": True, **res})
            except Exception as exc:
                return self._send(500, {"error": f"publish failed: {exc}"})
        if path == "/api/auth/ldap":
            cfg = save_ldap_conf(self._json_body())
            self._audit("auth-ldap", "enabled" if cfg.get("enabled") else "disabled")
            return self._send(200, {"ok": True, "ldap": cfg})
        if path == "/api/auth/ldap/test":
            return self._send(200, ldap_proxy("/test", self._json_body()))
        if path == "/api/auth/users":
            b = self._json_body()
            action = (b.get("action") or "set").strip()
            user = (b.get("username") or "").strip()
            if action == "delete":
                ok, msg = htpasswd_delete(user)
                if ok:
                    self._audit("user-delete", user)
                return self._send(200 if ok else 400, {"ok": ok, "message": msg})
            ok, msg = htpasswd_set(user, b.get("password") or "")
            if ok:
                self._audit("user-set", user)
            return self._send(200 if ok else 400, {"ok": ok, "message": msg})
        return self._send(404, {"error": "not found"})

    def do_DELETE(self):
        if not self._gate(mutating=True):
            return
        path = urllib.parse.urlparse(self.path).path
        if path == "/api/repos":
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            name = q.get("name", [""])[0]
            purge = q.get("purge", ["0"])[0] in ("1", "true", "yes")
            if not name:
                return self._send(400, {"error": "name required"})
            freed, removed_paths = 0, []
            if purge:
                managed, _ = parse_repos(read_list())
                repo = next((r for r in managed if r["name"] == name), None)
                if repo:
                    removed_paths, freed = purge_repo_paths(repo)
            removed = remove_block(name)
            if removed:
                sizes_background_refresh()
                self._audit("remove", name + (f" +purge ({freed} bytes)" if purge else ""))
            return self._send(200 if removed else 404,
                              {"ok": removed, "message": "removed" if removed else "no managed block",
                               "purged_paths": removed_paths, "freed": freed})
        return self._send(404, {"error": "not found"})

    # -- composite views ---------------------------------------------------- #
    def _status(self):
        text = read_list()
        managed, manual = parse_repos(text)
        cache = load_sizes_cache()
        host_sizes = cache.get("hosts", {})
        repos_total = 0
        for r in managed + manual:
            r["size"] = sum(host_sizes.get(h, 0) for h in r.get("hosts", []))
            r["last_updated"] = release_mtime(r)
            r["health"] = repo_health(r)
            repos_total += r["size"]
        disk = disk_status()
        return {"disk": disk, "sync": sync_state(), "timer": timer_state(),
                "sizes_updated": cache.get("updated", 0),
                "sizes_computing": _sizes_state["computing"],
                "repos_total": repos_total, "public_url": PUBLIC_URL,
                "min_free_gb": MIN_FREE_GB,
                "low_disk": (disk["free"] / 1_000_000_000) < MIN_FREE_GB,
                "managed": managed, "manual": manual,
                "mirror_list": MIRROR_LIST}

    def _repo_detail(self, name):
        text = read_list()
        managed, manual = parse_repos(text)
        repo = next((r for r in managed + manual if r["name"] == name), None)
        if not repo:
            return self._send(404, {"error": "repo not found"})
        # On-disk size per deb-URL path + package count from local Packages files.
        paths = {}
        for d in repo["deb"]:
            p = local_path_of(d["url"])
            if p and os.path.isdir(p) and p not in paths:
                paths[p] = du_path(p)
        repo["path_sizes"] = [{"path": p, "bytes": b} for p, b in paths.items()]
        repo["client"] = client_config(repo)
        return self._send(200, repo)

    def _estimate(self, body):
        preset_id = body.get("preset_id")
        if preset_id:
            preset = next((p for p in load_presets() if p["id"] == preset_id), None)
            if not preset:
                return self._send(404, {"error": "unknown preset"})
            entries = preset["entries"]
        else:
            c = body.get("custom") or {}
            base = c.get("base_url", "").strip()
            suites = c.get("suites") or ([c["suite"]] if c.get("suite") else [])
            if not base or not suites:
                return self._send(400, {"error": "base_url and suite(s) required"})
            entries = [{"base_url": base, "suites": suites,
                        "components": c.get("components") or ["main"],
                        "arch": c.get("arch", "amd64")}]
        est = estimate_entries(entries)
        free = disk_status()["free"]
        est["free"] = free
        est["exceeds_free"] = est["bytes"] > free
        return self._send(200, est)

    def _add_repo(self, body):
        if not os.access(os.path.dirname(MIRROR_LIST) or "/", os.W_OK):
            return self._send(403, {"error": f"cannot write {MIRROR_LIST} (run as root)"})
        preset_id = body.get("preset_id")
        entries, cleans, key, name = None, None, None, None
        preset_tag = ""
        if preset_id:
            preset = next((p for p in load_presets() if p["id"] == preset_id), None)
            if not preset:
                return self._send(404, {"error": "unknown preset"})
            entries = preset["entries"]
            cleans = preset.get("clean", [])
            key = preset.get("key")
            name = preset["id"]
            preset_tag = preset["id"]
        else:
            c = body.get("custom") or {}
            base = c.get("base_url", "").strip()
            suites = c.get("suites") or ([c["suite"]] if c.get("suite") else [])
            comps = c.get("components") or ["main"]
            if not base or not suites:
                return self._send(400, {"error": "base_url and suite(s) required"})
            entries = [{"base_url": base, "suites": suites, "components": comps,
                        "arch": c.get("arch", "amd64")}]
            cleans = [base]
            name = c.get("name") or netloc_of(base)
            if c.get("key_url"):
                key = {"name": (slug(name) + ".gpg"), "kind": "url", "url": c["key_url"]}
        # normalize entries to add_block's shape (url key)
        norm = [{"arch": e.get("arch", "amd64"), "url": e["base_url"],
                 "suites": e.get("suites") or [e.get("suite")], "components": e["components"]}
                for e in entries]

        result = {"name": slug(name)}
        keyname = (key or {}).get("name", "")
        if key and key.get("kind") == "url" and key.get("url"):
            try:
                fetch_key(key["name"], key["url"])
                result["key"] = f"fetched {key['name']}"
            except Exception as exc:
                return self._send(502, {"error": f"key fetch failed: {exc}"})
        elif key and key.get("kind") == "archive":
            result["key"] = (f"{key['name']} is a distro archive keyring — "
                             "run scripts/populate-mirror-keys.sh")

        try:
            added = add_block(name, norm, cleans, key=keyname, preset=preset_tag,
                              disabled=bool(body.get("disabled")))
            result["added"] = added
        except Exception as exc:
            return self._send(500, {"error": f"writing mirror.list failed: {exc}"})
        self._audit("add", added + (f" (preset {preset_tag})" if preset_tag else " (custom)"))

        if body.get("sync", True):
            ok, msg = start_sync()
            result["sync"] = msg if ok else f"not started: {msg}"
        sizes_background_refresh()
        return self._send(200, {"ok": True, **result})


def main():
    # Warm the size cache on boot if stale (older than 1h) or missing.
    cache = load_sizes_cache()
    if time.time() - cache.get("updated", 0) > 3600:
        sizes_background_refresh()
    httpd = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    allow = ",".join(str(n) for n in ALLOW_NETS) or "(all)"
    print(f"mirror-manager listening on http://{LISTEN_HOST}:{LISTEN_PORT}  "
          f"(mirror.list={MIRROR_LIST}, budget={BUDGET_BYTES}, allow={allow})")
    if LISTEN_HOST not in ("127.0.0.1", "::1", "localhost") and not ALLOW_NETS and not TOKEN:
        print("WARNING: bound to a non-local address with no MM_ALLOW and no MM_TOKEN — "
              "this root-privileged API is open to the whole network. Set MM_ALLOW "
              "(e.g. 10.0.0.0/26) and/or MM_TOKEN, or front it with an authenticated proxy.")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
