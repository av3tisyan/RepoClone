#!/bin/sh
# Configure a host to use the internal APT mirror (apt.example.com).
# - Fetches GPG keyrings from ${MIRROR}/keys/
# - Backs up /etc/apt/sources.list and replaces it with a stub (avoids duplicate repos)
# - Writes deb822 *.sources under /etc/apt/sources.list.d/
#
# Usage:
#   sudo ./setup-apt-client.sh
#   sudo APT_MIRROR_URL=https://apt.example.com ./setup-apt-client.sh --with-zabbix
#
# Options:
#   --mirror URL       Mirror base (default: https://apt.example.com or env APT_MIRROR_URL)
#   --with-zabbix      Also configure Zabbix repo (ZABBIX_MAJOR default 7.4)
#   --zabbix-major V   e.g. 7.4, 7.0, or 6.0 (7.4+ uses .../stable/{ubuntu,debian})
#   --with-hashicorp   Also configure HashiCorp repo (Terraform, Vault, Consul, etc.)
#   --with-openproject Also configure OpenProject repo (Debian bookworm only; OPENPROJECT_MAJOR default 17)
#   --openproject-major V  OpenProject stable major (default 17)
#   --with-postgresql  Also configure PostgreSQL PGDG repo (<codename>-pgdg main; provides postgresql-17 etc.)
#   --keep-sources     Do not replace /etc/apt/sources.list (only add .sources; may duplicate if old entries exist)
#   --no-apt-update    Skip apt-get update at the end
#   --no-mirror-probe  Do not curl-check InRelease on the mirror (use if you know sync is incomplete)
#   --use-gpg-not-sqv  Write apt.conf to use /usr/bin/gpg for key ops (workaround: sqv rejects
#                      some third-party SHA1-bound keys on Trixie 2026+). SECURITY: this re-enables
#                      acceptance of weak SHA1 key signatures fleet-wide — enable only if a vendor
#                      repo genuinely requires it, and prefer pressing the vendor for a SHA256 key.
#   -h, --help         Help

set -eu

MIRROR="${APT_MIRROR_URL:-https://apt.example.com}"
WITH_ZABBIX=0
WITH_HASHICORP=0
WITH_OPENPROJECT=0
OPENPROJECT_MAJOR="${OPENPROJECT_MAJOR:-17}"
WITH_POSTGRESQL=0
ZABBIX_MAJOR="${ZABBIX_MAJOR:-7.4}"
# ZABBIX_REPO_LAYOUT: stable | legacy — auto from major if unset (7.4+ => stable)
ZABBIX_REPO_LAYOUT="${ZABBIX_REPO_LAYOUT:-}"
KEEP_SOURCES=0
NO_APT_UPDATE=0
NO_MIRROR_PROBE=0
USE_GPG_NOT_SQV=0

usage() {
  sed -n '2,23p' "$0"
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --mirror)
      MIRROR="$2"
      shift 2
      ;;
    --with-zabbix)
      WITH_ZABBIX=1
      shift
      ;;
    --with-hashicorp)
      WITH_HASHICORP=1
      shift
      ;;
    --with-openproject)
      WITH_OPENPROJECT=1
      shift
      ;;
    --openproject-major)
      OPENPROJECT_MAJOR="$2"
      shift 2
      ;;
    --with-postgresql)
      WITH_POSTGRESQL=1
      shift
      ;;
    --zabbix-major)
      ZABBIX_MAJOR="$2"
      shift 2
      ;;
    --keep-sources)
      KEEP_SOURCES=1
      shift
      ;;
    --no-apt-update)
      NO_APT_UPDATE=1
      shift
      ;;
    --no-mirror-probe)
      NO_MIRROR_PROBE=1
      shift
      ;;
    --use-gpg-not-sqv)
      USE_GPG_NOT_SQV=1
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# Strip trailing slash from MIRROR
MIRROR="${MIRROR%/}"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "Install curl first." >&2
  exit 1
fi

if [ ! -r /etc/os-release ]; then
  echo "/etc/os-release not found." >&2
  exit 1
fi
# shellcheck disable=SC1091
. /etc/os-release

CODENAME="${VERSION_CODENAME:-}"
if [ -z "$CODENAME" ]; then
  echo "VERSION_CODENAME is empty in /etc/os-release; cannot select suites." >&2
  exit 1
fi

echo "==> Mirror: $MIRROR"
echo "==> OS: ${ID:-unknown} (${CODENAME:-unknown})"

install -d -m0755 /etc/apt/keyrings

# apt Signed-By expects a binary keyring; Zabbix publishes an armored .key from repo.zabbix.com.
dearmor_keyring_if_needed() {
  f="$1"
  if head -n1 "$f" 2>/dev/null | grep -q '^-----BEGIN PGP PUBLIC KEY BLOCK-----'; then
    if ! command -v gpg >/dev/null 2>&1; then
      echo "    ERROR: $f is armored ASCII; install gnupg (gpg) to dearmor it for apt." >&2
      exit 1
    fi
    gpg --dearmor -o "$f.dearmored" "$f"
    mv "$f.dearmored" "$f"
  fi
}

fetch_key() {
  name="$1"
  out="$2"
  url="${MIRROR}/keys/${name}"
  echo "    fetching $url"
  # Replace any existing path (including a broken symlink); chmod cannot fix modes on dangling symlinks.
  rm -f "$out.tmp" "$out"
  if curl -fsSL -o "$out.tmp" --max-time 120 "$url"; then
    mv "$out.tmp" "$out"
  elif [ -r "/usr/share/keyrings/$name" ]; then
    echo "    WARN: mirror has no $name (404 or unreachable); using /usr/share/keyrings/$name" >&2
    echo "          Fix the mirror: run scripts/populate-mirror-keys.sh and serve /opt/apt/keys/ as /keys/" >&2
    rm -f "$out.tmp"
    # -L: archive keyrings in /usr/share/keyrings are often symlinks; copy the key material, not the link.
    cp -L "/usr/share/keyrings/$name" "$out"
  else
    rm -f "$out.tmp"
    echo "    ERROR: could not fetch $url and /usr/share/keyrings/$name is missing." >&2
    exit 1
  fi
  dearmor_keyring_if_needed "$out"
  chmod 0644 "$out"
}

# Fail fast if the mirror has not synced this suite (wrong URI or incomplete apt-mirror run).
mirror_has_suite() {
  [ "$NO_MIRROR_PROBE" -eq 1 ] && return 0
  case "${ID:-}" in
    debian)
      probe="${MIRROR}/deb.debian.org/debian/dists/${CODENAME}/InRelease"
      ;;
    ubuntu)
      probe="${MIRROR}/archive.ubuntu.com/ubuntu/dists/${CODENAME}/InRelease"
      ;;
    *)
      return 0
      ;;
  esac
  echo "==> Mirror check (${CODENAME} InRelease)"
  if ! curl -fsSL -o /dev/null --max-time 60 "$probe"; then
    echo "ERROR: mirror does not serve: $probe" >&2
    echo "       URIs must look like .../deb.debian.org/debian/ (not .../debian alone). If the path is correct, wait for apt-mirror to finish syncing." >&2
    exit 1
  fi
}

echo "==> Keyrings"
case "${ID:-}" in
  debian)
    fetch_key debian-archive-keyring.gpg /etc/apt/keyrings/debian-archive-keyring.gpg
    ;;
  ubuntu)
    fetch_key ubuntu-archive-keyring.gpg /etc/apt/keyrings/ubuntu-archive-keyring.gpg
    ;;
esac
if [ "$WITH_ZABBIX" -eq 1 ]; then
  fetch_key zabbix.gpg /etc/apt/keyrings/zabbix.gpg
fi
if [ "$WITH_HASHICORP" -eq 1 ]; then
  fetch_key hashicorp.gpg /etc/apt/keyrings/hashicorp.gpg
fi
if [ "$WITH_OPENPROJECT" -eq 1 ]; then
  fetch_key openproject.gpg /etc/apt/keyrings/openproject.gpg
fi
if [ "$WITH_POSTGRESQL" -eq 1 ]; then
  fetch_key postgresql.gpg /etc/apt/keyrings/postgresql.gpg
fi

mirror_has_suite

if [ "$USE_GPG_NOT_SQV" -eq 1 ]; then
  echo "==> apt OpenPGP: use gpg instead of sqv (third-party repos with SHA1-bound keys on Trixie)"
  cat >/etc/apt/apt.conf.d/99example-use-gpg-not-sqv.conf <<'EOF'
// Managed by setup-apt-client.sh --use-gpg-not-sqv. Remove this file to restore default (sqv) verification.
APT::Key::GPGCommand "/usr/bin/gpg";
EOF
fi

D="/etc/apt/sources.list.d"
install -d -m0755 "$D"

for f in "$D"/example-*.sources; do
  [ -e "$f" ] && rm -f "$f"
done
rm -f "$D/example-zabbix.sources" "$D/example-zabbix.list"

write_debian() {
  c="$1"
  cat >"$D/example-debian-main.sources" <<EOF
# example internal mirror — main archive
Types: deb
URIs: ${MIRROR}/deb.debian.org/debian
Suites: ${c} ${c}-updates
Components: main contrib non-free non-free-firmware
Signed-By: /etc/apt/keyrings/debian-archive-keyring.gpg
EOF
  cat >"$D/example-debian-security.sources" <<EOF
# example internal mirror — security
Types: deb
URIs: ${MIRROR}/security.debian.org/debian-security
Suites: ${c}-security
Components: main contrib non-free non-free-firmware
Signed-By: /etc/apt/keyrings/debian-archive-keyring.gpg
EOF
}

write_ubuntu() {
  c="$1"
  cat >"$D/example-ubuntu.sources" <<EOF
# example internal mirror — Ubuntu ${c}
Types: deb
URIs: ${MIRROR}/archive.ubuntu.com/ubuntu
Suites: ${c} ${c}-updates ${c}-security
Components: main universe
Signed-By: /etc/apt/keyrings/ubuntu-archive-keyring.gpg
EOF
}

# 7.4+ roots: .../zabbix/<ver>/stable/{ubuntu,debian} — https://repo.zabbix.com/zabbix/7.4/stable/
# (/release/ has only binary-all; not compatible with apt-mirror defaultarch amd64.)
# 7.0/6.0:     .../zabbix/<ver>/{ubuntu,debian}
zabbix_repo_uri() {
  os="$1"
  layout="$ZABBIX_REPO_LAYOUT"
  if [ -z "$layout" ]; then
    case "$ZABBIX_MAJOR" in
      7.4|7.5|7.6|7.7|7.8|7.9|8.*|9.*) layout=stable ;;
      *) layout=legacy ;;
    esac
  fi
  case "$layout" in
    stable|release)
      # "release" kept as alias for stable (older docs); upstream /release/ is not mirrored.
      printf '%s/repo.zabbix.com/zabbix/%s/stable/%s' "$MIRROR" "$ZABBIX_MAJOR" "$os"
      ;;
    *)
      printf '%s/repo.zabbix.com/zabbix/%s/%s' "$MIRROR" "$ZABBIX_MAJOR" "$os"
      ;;
  esac
}

write_zabbix_ubuntu() {
  c="$1"
  uri="$(zabbix_repo_uri ubuntu)"
  # One-line deb [arch=amd64]: mirror has no binary-all/; deb822 Architectures alone is ignored on some apt builds.
  cat >"$D/example-zabbix.list" <<EOF
# example internal mirror — Zabbix ${ZABBIX_MAJOR} (Ubuntu ${c})
deb [arch=amd64 signed-by=/etc/apt/keyrings/zabbix.gpg] ${uri} ${c} main
EOF
}

write_zabbix_debian() {
  c="$1"
  uri="$(zabbix_repo_uri debian)"
  cat >"$D/example-zabbix.list" <<EOF
# example internal mirror — Zabbix ${ZABBIX_MAJOR} (Debian ${c})
deb [arch=amd64 signed-by=/etc/apt/keyrings/zabbix.gpg] ${uri} ${c} main
EOF
}

# Single repo root, suite = OS codename, component "main" — https://apt.releases.hashicorp.com/
write_hashicorp() {
  c="$1"
  cat >"$D/example-hashicorp.sources" <<EOF
# example internal mirror — HashiCorp (${c})
Types: deb
URIs: ${MIRROR}/apt.releases.hashicorp.com
Suites: ${c}
Components: main
Signed-By: /etc/apt/keyrings/hashicorp.gpg
EOF
}

# OpenProject (packager.io): suite is the OS version number (12), not a codename;
# only Debian bookworm is published upstream. amd64 only, no binary-all — one-line
# deb [arch=amd64] (deb822 Architectures is ignored on some apt builds).
write_openproject() {
  uri="${MIRROR}/packages.openproject.com/srv/deb/opf/openproject/stable/${OPENPROJECT_MAJOR}/debian"
  cat >"$D/example-openproject.list" <<EOF
# example internal mirror — OpenProject ${OPENPROJECT_MAJOR} (Debian 12 / bookworm)
deb [arch=amd64 signed-by=/etc/apt/keyrings/openproject.gpg] ${uri} 12 main
EOF
}

# PostgreSQL PGDG: suite is <codename>-pgdg, component main (carries postgresql-17,
# postgresql-common, libpq5, and every extension). amd64 only, no usable binary-all —
# one-line deb [arch=amd64]. Works on bookworm, trixie, and noble.
write_postgresql() {
  c="$1"
  cat >"$D/example-postgresql.list" <<EOF
# example internal mirror — PostgreSQL PGDG (${c})
deb [arch=amd64 signed-by=/etc/apt/keyrings/postgresql.gpg] ${MIRROR}/apt.postgresql.org/pub/repos/apt ${c}-pgdg main
EOF
}

echo "==> APT sources (${D})"

case "${ID:-}" in
  debian)
    case "$CODENAME" in
      bookworm|trixie)
        write_debian "$CODENAME"
        ;;
      *)
        echo "Unsupported Debian codename: $CODENAME (expected bookworm or trixie)." >&2
        exit 1
        ;;
    esac
    if [ "$WITH_ZABBIX" -eq 1 ]; then
      write_zabbix_debian "$CODENAME"
    fi
    if [ "$WITH_HASHICORP" -eq 1 ]; then
      write_hashicorp "$CODENAME"
    fi
    if [ "$WITH_OPENPROJECT" -eq 1 ]; then
      if [ "$CODENAME" != "bookworm" ]; then
        echo "ERROR: OpenProject is only published for Debian 12 (bookworm); not available for $CODENAME." >&2
        exit 1
      fi
      write_openproject
    fi
    if [ "$WITH_POSTGRESQL" -eq 1 ]; then
      write_postgresql "$CODENAME"
    fi
    ;;
  ubuntu)
    case "$CODENAME" in
      noble)
        write_ubuntu "$CODENAME"
        ;;
      *)
        echo "Unsupported Ubuntu codename: $CODENAME (expected noble)." >&2
        exit 1
        ;;
    esac
    if [ "$WITH_ZABBIX" -eq 1 ]; then
      write_zabbix_ubuntu "$CODENAME"
    fi
    if [ "$WITH_HASHICORP" -eq 1 ]; then
      write_hashicorp "$CODENAME"
    fi
    if [ "$WITH_OPENPROJECT" -eq 1 ]; then
      echo "ERROR: OpenProject is only published for Debian 12 (bookworm), not Ubuntu." >&2
      exit 1
    fi
    if [ "$WITH_POSTGRESQL" -eq 1 ]; then
      write_postgresql "$CODENAME"
    fi
    ;;
  *)
    echo "Unsupported ID=$ID (only debian and ubuntu are scripted)." >&2
    exit 1
    ;;
esac

if [ "$KEEP_SOURCES" -eq 0 ] && [ -f /etc/apt/sources.list ]; then
  if ! grep -q 'Managed by setup-apt-client.sh' /etc/apt/sources.list 2>/dev/null; then
    bak="/etc/apt/sources.list.bak.example-$(date +%Y%m%d%H%M%S)"
    cp -a /etc/apt/sources.list "$bak"
    echo "==> Backed up /etc/apt/sources.list to $bak"
  fi
  cat >/etc/apt/sources.list <<'EOF'
# Managed by setup-apt-client.sh — repositories are in /etc/apt/sources.list.d/example-*.sources
EOF
  echo "==> Replaced /etc/apt/sources.list with stub (use --keep-sources to skip)"
elif [ "$KEEP_SOURCES" -eq 1 ]; then
  echo "==> Left /etc/apt/sources.list unchanged (--keep-sources); remove duplicate entries if apt complains."
fi

if [ "$NO_APT_UPDATE" -eq 0 ]; then
  echo "==> apt-get update"
  apt-get update -qq || apt-get update
fi

echo "Done."
