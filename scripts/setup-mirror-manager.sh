#!/bin/sh
# Install the mirror-manager web dashboard on the connected sync host.
#
# Copies the app to /opt/apt/mirror-manager, installs the systemd unit, and starts it
# bound to 127.0.0.1:8080. Access it via SSH tunnel:
#     ssh -L 8080:127.0.0.1:8080 <this-host>   # then open http://localhost:8080
# or expose it with the nginx auth proxy in deploy/nginx/mirror-manager.conf.
#
# Usage (from the repo clone):
#   sudo ./scripts/setup-mirror-manager.sh
#   sudo ./scripts/setup-mirror-manager.sh --port 8090 --budget-tb 1.6 --token s3cret
#
# Options:
#   --port N         Listen port (default 8080)
#   --listen-host H  Bind address (default 127.0.0.1). Use 0.0.0.0 for LAN access.
#   --allow CIDRS    Comma/space CIDR allowlist for direct access (e.g. 10.0.0.0/26).
#                    Empty = allow all. Strongly recommended whenever --listen-host != 127.0.0.1.
#   --budget-tb N    Disk budget in TB for the dashboard gauge (default 1.7)
#   --token STR      Shared secret; clients must pass ?token=STR (default: none)
#   --admin-pass STR Initial break-glass 'admin' password for the nginx front door
#                    (htpasswd/bcrypt; default: generated and printed once).
#   --user NAME      Dedicated NON-ROOT user to run the daemon as (default: apt-manager).
#                    Auto-created with all needed permissions: ownership of
#                    /opt/apt/{keys,www,var} + the app, /etc/apt/mirror.list symlinked to
#                    /opt/apt/var/mirror.list, a narrow sudoers rule for apt-mirror.{service,
#                    timer}, and membership of systemd-journal. Pass --user root to run as root.
#   --no-enable      Install files only; do not enable/start the service
#   -h, --help

set -eu

SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd)"
ROOT="$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)"

DEST=/opt/apt/mirror-manager
PORT=8080
LISTEN_HOST=127.0.0.1
ALLOW=""
BUDGET_TB=1.7
TOKEN=""
ADMIN_PASS=""
ENABLE=1
MGR_USER=apt-manager      # default: run as a dedicated non-root user (best practice)
MIRROR_LIST_PATH=/etc/apt/mirror.list
MM_STATE=""               # manager-owned state dir (set when hardened)

usage() { sed -n '2,27p' "$0"; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    --listen-host) LISTEN_HOST="$2"; shift 2 ;;
    --allow) ALLOW="$2"; shift 2 ;;
    --budget-tb) BUDGET_TB="$2"; shift 2 ;;
    --token) TOKEN="$2"; shift 2 ;;
    --admin-pass) ADMIN_PASS="$2"; shift 2 ;;
    --user) MGR_USER="$2"; shift 2 ;;
    --no-enable) ENABLE=0; shift ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo)." >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required (apt install python3)." >&2; exit 1; }
command -v gpg >/dev/null 2>&1 || echo "WARN: gpg not found — key fetch will fail until 'apt install gnupg'." >&2

# Budget TB -> bytes (integer), using awk for the float multiply.
BUDGET_BYTES="$(awk -v t="$BUDGET_TB" 'BEGIN{printf "%d", t*1000000000000}')"

echo "==> Installing app to $DEST"
install -d -m0755 "$DEST"
install -m0644 "$ROOT/scripts/mirror-manager/mirror_manager.py" "$DEST/mirror_manager.py"
install -m0644 "$ROOT/scripts/mirror-manager/index.html"        "$DEST/index.html"
install -m0644 "$ROOT/scripts/mirror-manager/presets.json"      "$DEST/presets.json"
# Quick reference for the systemd Documentation= line.
printf 'mirror-manager — see docs/MIRROR_MANAGER.md in the RepoClone repo.\n' > "$DEST/README"

echo "==> Validating app"
python3 -c "import ast,sys; ast.parse(open('$DEST/mirror_manager.py').read())"
python3 -c "import json; json.load(open('$DEST/presets.json'))"

# --- Hardening: run as a dedicated non-root user (default; --user root opts out) ---
if [ -n "$MGR_USER" ] && [ "$MGR_USER" != "root" ]; then
  echo "==> Hardening: dedicated user '$MGR_USER' (non-root)"
  if ! id "$MGR_USER" >/dev/null 2>&1; then
    useradd --system --no-create-home --home-dir "$DEST" --shell /usr/sbin/nologin "$MGR_USER"
  fi
  # Group needed to read the apt-mirror journal without root.
  getent group systemd-journal >/dev/null 2>&1 && usermod -aG systemd-journal "$MGR_USER" || true

  # Manager-owned state dir, kept SEPARATE from /opt/apt/var. /opt/apt/var holds
  # postmirror.sh / run-mirror-clean.sh / clean.sh which apt-mirror.service runs AS ROOT;
  # giving the daemon write there would be a privilege-escalation path. So we never chown
  # /opt/apt/var — the manager's state (mirror.list, sizes cache, audit log) lives here.
  MM_STATE=/opt/apt/manager
  install -d -m0755 "$MM_STATE" /opt/apt/keys /opt/apt/www
  chown -R "$MGR_USER":"$MGR_USER" "$DEST" "$MM_STATE" /opt/apt/keys /opt/apt/www

  # mirror.list lives in the daemon-owned state dir; /etc/apt/mirror.list symlinks to it
  # (apt-mirror reads the symlink as root). No /etc/apt write needed by the daemon.
  MIRROR_LIST_PATH="$MM_STATE/mirror.list"
  if [ ! -L /etc/apt/mirror.list ]; then
    [ -f /etc/apt/mirror.list ] && mv /etc/apt/mirror.list "$MIRROR_LIST_PATH" || touch "$MIRROR_LIST_PATH"
    ln -sf "$MIRROR_LIST_PATH" /etc/apt/mirror.list
  fi
  [ -f "$MIRROR_LIST_PATH" ] || touch "$MIRROR_LIST_PATH"
  chown "$MGR_USER":"$MGR_USER" "$MIRROR_LIST_PATH"; chmod 0644 "$MIRROR_LIST_PATH"

  # Narrow sudoers: only the apt-mirror service/timer controls the daemon needs.
  SUDOERS=/etc/sudoers.d/mirror-manager
  cat > "$SUDOERS" <<EOF
# Managed by setup-mirror-manager.sh — lets $MGR_USER drive apt-mirror without full root.
Cmnd_Alias MM_SYSCTL = /usr/bin/systemctl start --no-block apt-mirror.service, \\
  /usr/bin/systemctl start apt-mirror.timer, /usr/bin/systemctl stop apt-mirror.timer, \\
  /usr/bin/systemctl enable --now apt-mirror.timer, /usr/bin/systemctl disable --now apt-mirror.timer
$MGR_USER ALL=(root) NOPASSWD: MM_SYSCTL
EOF
  chmod 0440 "$SUDOERS"
  if ! visudo -cf "$SUDOERS" >/dev/null 2>&1; then
    echo "ERROR: sudoers validation failed for $SUDOERS — removing it." >&2
    rm -f "$SUDOERS"; exit 1
  fi
fi

# --- Local auth files: break-glass admin for the nginx front door (Access tab) ---
AUTH_DIR=/opt/apt/manager
install -d -m0755 "$AUTH_DIR"
HTPW="$AUTH_DIR/htpasswd"
if command -v htpasswd >/dev/null 2>&1; then
  if [ ! -f "$HTPW" ]; then
    if [ -z "$ADMIN_PASS" ]; then
      ADMIN_PASS="$(head -c16 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-16)"
      GENERATED=1
    fi
    printf '%s' "$ADMIN_PASS" | htpasswd -iBc "$HTPW" admin >/dev/null 2>&1 \
      && echo "==> Created break-glass admin in $HTPW" \
      || echo "WARN: could not create $HTPW" >&2
    [ -n "${GENERATED:-}" ] && echo "    admin password (SAVE THIS - shown once): $ADMIN_PASS"
  fi
  if [ -n "$MGR_USER" ] && [ "$MGR_USER" != "root" ]; then chown "$MGR_USER":"$MGR_USER" "$HTPW" 2>/dev/null || true; fi
  chmod 0600 "$HTPW" 2>/dev/null || true
else
  echo "WARN: htpasswd not found - local user management needs 'apt install apache2-utils'." >&2
fi

echo "==> Installing systemd unit"
UNIT=/etc/systemd/system/mirror-manager.service
install -m0644 "$ROOT/deploy/systemd/mirror-manager.service" "$UNIT"

# Apply settings via a drop-in so the shipped unit stays pristine.
DROPIN=/etc/systemd/system/mirror-manager.service.d
install -d -m0755 "$DROPIN"
{
  echo "[Service]"
  echo "Environment=MM_LISTEN_HOST=$LISTEN_HOST"
  echo "Environment=MM_LISTEN_PORT=$PORT"
  echo "Environment=MM_BUDGET_BYTES=$BUDGET_BYTES"
  echo "Environment=MM_MIRROR_LIST=$MIRROR_LIST_PATH"
  echo "Environment=MM_AUTH_DIR=$AUTH_DIR"
  [ -n "$MM_STATE" ] && echo "Environment=MM_VAR_DIR=$MM_STATE"
  [ -n "$ALLOW" ] && echo "Environment=MM_ALLOW=$ALLOW"
  [ -n "$TOKEN" ] && echo "Environment=MM_TOKEN=$TOKEN"
  if [ -n "$MGR_USER" ] && [ "$MGR_USER" != "root" ]; then
    # Override the shipped User=root. Confinement is by unix ownership: the daemon only owns
    # /opt/apt/{manager,keys,www}; /opt/apt/var + /opt/apt/mirror stay root-owned.
    echo "User=$MGR_USER"
    echo "Group=$MGR_USER"
    echo "SupplementaryGroups=systemd-journal"
    echo "ProtectSystem=strict"
    echo "ReadWritePaths=/opt/apt"
    echo "NoNewPrivileges=no"   # required so the narrow sudoers rule can escalate
  fi
} > "$DROPIN/override.conf"
chmod 0644 "$DROPIN/override.conf"

# Safety: a non-local bind with no allowlist and no token exposes a root API to the LAN.
if [ "$LISTEN_HOST" != "127.0.0.1" ] && [ "$LISTEN_HOST" != "::1" ] && [ -z "$ALLOW" ] && [ -z "$TOKEN" ]; then
  echo "WARN: --listen-host $LISTEN_HOST with no --allow and no --token exposes this" >&2
  echo "      root-privileged API to the whole network. Add --allow <CIDR> and/or --token." >&2
fi

systemctl daemon-reload

if [ "$ENABLE" -eq 1 ]; then
  echo "==> Enabling and (re)starting mirror-manager.service"
  systemctl enable mirror-manager.service >/dev/null 2>&1 || true
  # restart (not just `enable --now`) so a re-run actually applies the new drop-in;
  # `enable --now` is a no-op when the service is already running.
  systemctl restart mirror-manager.service
  sleep 1
  systemctl --no-pager --full status mirror-manager.service | sed -n '1,6p' || true
  echo "Listening on:"; ss -tulpn 2>/dev/null | grep ":$PORT " || true
  echo
  if [ "$MGR_USER" = "root" ]; then
    echo "Running as: root"
  else
    echo "Running as: $MGR_USER (non-root; mirror.list -> $MIRROR_LIST_PATH, sudoers for apt-mirror.{service,timer})"
  fi
  echo "Dashboard bound to: http://$LISTEN_HOST:$PORT"
  if [ "$LISTEN_HOST" = "127.0.0.1" ] || [ "$LISTEN_HOST" = "::1" ]; then
    echo "From your workstation:  ssh -L $PORT:127.0.0.1:$PORT $(hostname)"
  else
    IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
    echo "LAN URL: http://${IP:-$LISTEN_HOST}:$PORT"
    [ -n "$ALLOW" ] && echo "Allowed clients (MM_ALLOW): $ALLOW" || echo "MM_ALLOW: (all — consider restricting)"
  fi
  [ -n "$TOKEN" ] && echo "Token required: append ?token=$TOKEN to the URL"
  echo "Front with TLS+auth at apt-manager.example.com: see deploy/nginx/mirror-manager.conf"
  echo "Manage local users + LDAP/LDAPS in the dashboard Access tab (auth enforced by that proxy + ldap_auth.py)."
else
  echo "==> Installed (not enabled). Start with: systemctl enable --now mirror-manager.service"
fi
