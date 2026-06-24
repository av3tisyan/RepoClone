#!/bin/sh
# Deploy mirror infrastructure from this repository onto a Debian server.
#
# Roles:
#   sync    — connected host: apt-mirror, systemd timer, logrotate, /etc/apt/mirror.list, keys
#   airgap  — isolated host: nginx for apt.example.com, directories under /opt/apt (data via rsync)
#   both    — single machine that syncs from the internet and serves clients (default)
#
# Run from the clone:
#   cd .../apt-mirror && sudo ./scripts/setup-apt-mirror-server.sh
# Or from .../apt-mirror/scripts:
#   sudo ./setup-apt-mirror-server.sh
# Do not use ./scripts/setup-... when your cwd is already scripts/ (path is wrong).
#
# Requires: apt-based system (Debian 13 recommended), root.

set -eu

SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd)"
ROOT="$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)"

ROLE=both
POPULATE_KEYS=1
ENABLE_TIMER=1
REMOVE_NGINX_DEFAULT=1
RUN_FIRST_MIRROR=0
WITH_MANAGER=0
MANAGER_LISTEN=127.0.0.1
MANAGER_ALLOW=""
MANAGER_PORT=8080
PUBLISH=0

usage() {
  echo "Usage: $0 [options]"
  echo "  --role sync|airgap|both   default: both"
  echo "  --no-keys                 do not run scripts/populate-mirror-keys.sh (sync/both)"
  echo "  --no-timer                do not enable apt-mirror.timer (sync/both)"
  echo "  --keep-nginx-default      leave /etc/nginx/sites-enabled/default in place"
  echo "  --run-mirror-now          run apt-mirror once in foreground after setup (long)"
  echo "  --with-manager            also install the mirror-manager dashboard (sync/both)"
  echo "  --manager-listen HOST     manager bind address (default 127.0.0.1; e.g. 0.0.0.0)"
  echo "  --manager-allow CIDR      manager IP allowlist (e.g. 10.0.0.0/26)"
  echo "  --publish                 generate the client landing page + setup.sh after setup"
  echo "  -h, --help"
  exit "$1"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --role)
      ROLE="$2"
      shift 2
      ;;
    --no-keys)
      POPULATE_KEYS=0
      shift
      ;;
    --no-timer)
      ENABLE_TIMER=0
      shift
      ;;
    --keep-nginx-default)
      REMOVE_NGINX_DEFAULT=0
      shift
      ;;
    --run-mirror-now)
      RUN_FIRST_MIRROR=1
      shift
      ;;
    --with-manager)
      WITH_MANAGER=1
      shift
      ;;
    --manager-listen)
      MANAGER_LISTEN="$2"
      shift 2
      ;;
    --manager-allow)
      MANAGER_ALLOW="$2"
      shift 2
      ;;
    --publish)
      PUBLISH=1
      shift
      ;;
    -h|--help)
      usage 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage 1
      ;;
  esac
done

case "$ROLE" in
  sync|airgap|both) ;;
  *) echo "Invalid --role" >&2; exit 1 ;;
esac

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

need_file() {
  f="$1"
  if [ ! -f "$f" ]; then
    echo "Missing file: $f" >&2
    echo "Resolved repo root: $ROOT" >&2
    echo "From repo root run: sudo ./scripts/setup-apt-mirror-server.sh" >&2
    echo "From scripts/ run:    sudo ./setup-apt-mirror-server.sh" >&2
    exit 1
  fi
}

need_file "$ROOT/config/mirror.list"
need_file "$ROOT/config/postmirror.sh"
need_file "$ROOT/deploy/systemd/apt-mirror.service"
need_file "$ROOT/deploy/systemd/apt-mirror.timer"
need_file "$ROOT/deploy/nginx/apt.example.com.conf"
need_file "$ROOT/deploy/logrotate.d/apt-mirror"

echo "==> Repository: $ROOT"
echo "==> Role: $ROLE"

install -d -m0755 /opt/apt/mirror /opt/apt/skel /opt/apt/var /opt/apt/keys

# --- Sync host (apt-mirror) ---
if [ "$ROLE" = "sync" ] || [ "$ROLE" = "both" ]; then
  echo "==> Installing packages (sync)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y apt-mirror debian-archive-keyring dpkg curl ca-certificates sudo

  echo "==> Installing /etc/apt/mirror.list"
  install -m0644 "$ROOT/config/mirror.list" /etc/apt/mirror.list

  echo "==> Installing postmirror.sh, run-mirror-clean.sh, fetch-binary-all.sh, guard + snapshot"
  install -m0755 "$ROOT/config/postmirror.sh" /opt/apt/var/postmirror.sh
  install -m0755 "$ROOT/scripts/run-mirror-clean.sh" /opt/apt/var/run-mirror-clean.sh
  install -m0755 "$ROOT/scripts/fetch-binary-all.sh" /opt/apt/var/fetch-binary-all.sh
  install -m0755 "$ROOT/scripts/apt-mirror-guard.sh" /opt/apt/var/apt-mirror-guard.sh
  install -m0755 "$ROOT/scripts/mirror-snapshot.sh" /opt/apt/var/mirror-snapshot.sh
  # Disk-full guard floor (edit to taste). The guard aborts a sync below this many GB free.
  if [ ! -f /etc/default/apt-mirror ]; then
    printf '# apt-mirror tunables\nMIRROR_BASE=/opt/apt\nMIN_FREE_GB=50\n' > /etc/default/apt-mirror
    chmod 0644 /etc/default/apt-mirror
  fi

  echo "==> Installing systemd units"
  install -m0644 "$ROOT/deploy/systemd/apt-mirror.service" /etc/systemd/system/apt-mirror.service
  install -m0644 "$ROOT/deploy/systemd/apt-mirror.timer" /etc/systemd/system/apt-mirror.timer
  systemctl daemon-reload

  if [ "$ENABLE_TIMER" -eq 1 ]; then
    systemctl enable apt-mirror.timer
    systemctl start apt-mirror.timer
    echo "==> apt-mirror.timer enabled (daily)"
  else
    echo "==> apt-mirror.timer not enabled (--no-timer)"
  fi

  echo "==> Installing logrotate snippet"
  install -m0644 "$ROOT/deploy/logrotate.d/apt-mirror" /etc/logrotate.d/apt-mirror

  if [ "$POPULATE_KEYS" -eq 1 ]; then
    echo "==> Populating /opt/apt/keys"
    sh "$ROOT/scripts/populate-mirror-keys.sh"
  else
    echo "==> Skipping populate-mirror-keys.sh (--no-keys)"
  fi
fi

# --- Airgap / web front-end (nginx) ---
if [ "$ROLE" = "airgap" ] || [ "$ROLE" = "both" ]; then
  echo "==> Installing packages (nginx)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y nginx curl ca-certificates sudo

  # airgap-only: sync/both already ran populate-mirror-keys in the apt-mirror section above
  if [ "$ROLE" = "airgap" ] && [ "$POPULATE_KEYS" -eq 1 ]; then
    echo "==> Populating /opt/apt/keys (requires debian-archive-keyring or outbound HTTPS)"
    apt-get install -y debian-archive-keyring dpkg ca-certificates 2>/dev/null || true
    if sh "$ROOT/scripts/populate-mirror-keys.sh"; then
      echo "==> Keyrings ready under /opt/apt/keys"
    else
      echo "WARN: populate-mirror-keys.sh failed (offline airgap?). Rsync /opt/apt/keys from the sync host." >&2
    fi
  fi

  echo "==> Installing nginx vhost"
  install -m0644 "$ROOT/deploy/nginx/apt.example.com.conf" \
    /etc/nginx/sites-available/apt.example.com.conf
  ln -sf /etc/nginx/sites-available/apt.example.com.conf /etc/nginx/sites-enabled/apt.example.com.conf

  if [ "$REMOVE_NGINX_DEFAULT" -eq 1 ] && [ -e /etc/nginx/sites-enabled/default ]; then
    rm -f /etc/nginx/sites-enabled/default
    echo "==> Removed /etc/nginx/sites-enabled/default"
  fi

  nginx -t
  systemctl enable nginx
  systemctl reload nginx
  echo "==> nginx reloaded"
fi

# --- Optional first apt-mirror run ---
if [ "$RUN_FIRST_MIRROR" -eq 1 ]; then
  if [ "$ROLE" = "sync" ] || [ "$ROLE" = "both" ]; then
    echo "==> Running apt-mirror (this can take many hours)..."
    apt-mirror
  else
    echo "Ignoring --run-mirror-now (not a sync role)" >&2
  fi
fi

# --- Optional: mirror-manager dashboard ---
if [ "$WITH_MANAGER" -eq 1 ]; then
  if [ "$ROLE" = "airgap" ]; then
    echo "Ignoring --with-manager (manager belongs on the sync/both host)." >&2
  else
    need_file "$ROOT/scripts/setup-mirror-manager.sh"
    echo "==> Installing mirror-manager (listen=$MANAGER_LISTEN${MANAGER_ALLOW:+, allow=$MANAGER_ALLOW})"
    set -- --port "$MANAGER_PORT" --listen-host "$MANAGER_LISTEN"
    [ -n "$MANAGER_ALLOW" ] && set -- "$@" --allow "$MANAGER_ALLOW"
    sh "$ROOT/scripts/setup-mirror-manager.sh" "$@"
  fi
fi

# --- Optional: publish client landing page + setup.sh ---
if [ "$PUBLISH" -eq 1 ]; then
  if [ "$WITH_MANAGER" -eq 1 ] && [ "$ROLE" != "airgap" ]; then
    echo "==> Publishing client landing page + setup.sh"
    sleep 1
    if curl -fsS -X POST -H 'X-MM: 1' "http://127.0.0.1:$MANAGER_PORT/api/landing" >/dev/null; then
      echo "    published to /opt/apt/www (re-publish after the first sync to include synced repos)"
    else
      echo "WARN: publish call failed — run it from the dashboard (Server -> Publish) once the manager is up." >&2
    fi
  else
    echo "Ignoring --publish (requires --with-manager on a sync/both host)." >&2
  fi
fi

echo
echo "Done."
case "$ROLE" in
  sync)
    echo "Next: review /etc/apt/mirror.list, then run: sudo apt-mirror   (or wait for the timer)"
    echo "Then rsync /opt/apt to the airgap server (scripts/rsync-to-airgap.sh)."
    ;;
  airgap)
    echo "Next: rsync /opt/apt from the sync host, then: sudo nginx -t && sudo systemctl reload nginx"
    echo "DNS: point apt.example.com to this host."
    ;;
  both)
    echo "Next: review /etc/apt/mirror.list, run sudo apt-mirror when ready (or wait for timer)."
    echo "TLS: verify ssl_certificate paths in /etc/nginx/sites-available/apt.example.com.conf match your PKI."
    if [ "$WITH_MANAGER" -eq 1 ]; then
      echo "Manager: http://$MANAGER_LISTEN:$MANAGER_PORT  (SSH-tunnel if bound to localhost)."
      echo "After the first sync finishes, re-publish (Server -> Publish) so setup.sh includes synced repos."
      echo "Clients: curl -fsSL https://apt.example.com/setup.sh | sudo sh"
    fi
    ;;
esac
