#!/bin/sh
# Remove configuration deployed by setup-apt-mirror-server.sh so you can reconfigure from scratch.
# Does NOT remove Debian packages (apt-mirror, nginx) unless you apt purge them yourself.
#
# Usage:
#   sudo ./scripts/remove-apt-mirror-config.sh --yes
#   sudo ./scripts/remove-apt-mirror-config.sh --yes --role sync
#   sudo ./scripts/remove-apt-mirror-config.sh --yes --role airgap
#   sudo ./scripts/remove-apt-mirror-config.sh --yes --purge-opt-apt
#
# Options:
#   --yes            Required; without it, the script exits (safety).
#   --role sync|airgap|both   What to remove (default: both).
#   --purge-opt-apt  Clear all data under /opt/apt (see below).
#   --restore-nginx-default   ln -s sites-available/default sites-enabled/default if the file exists (optional).

set -eu

ROLE=both
YES=0
PURGE_OPT=0
RESTORE_DEFAULT=0

usage() {
  sed -n '2,20p' "$0" | head -18
  exit "$1"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --yes) YES=1; shift ;;
    --role)
      ROLE="$2"
      shift 2
      ;;
    --purge-opt-apt) PURGE_OPT=1; shift ;;
    --restore-nginx-default) RESTORE_DEFAULT=1; shift ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

case "$ROLE" in sync|airgap|both) ;; *) echo "Invalid --role" >&2; exit 1 ;; esac

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

if [ "$YES" -ne 1 ]; then
  echo "Refusing to run without --yes (this removes live configuration)." >&2
  echo "Example: sudo $0 --yes [--role both] [--purge-opt-apt]" >&2
  exit 1
fi

echo "==> Stopping apt-mirror (if present)"
systemctl stop apt-mirror.service 2>/dev/null || true
systemctl stop apt-mirror.timer 2>/dev/null || true
systemctl disable apt-mirror.service 2>/dev/null || true
systemctl disable apt-mirror.timer 2>/dev/null || true

if [ "$ROLE" = "sync" ] || [ "$ROLE" = "both" ]; then
  echo "==> Removing systemd units and apt-mirror config"
  rm -f /etc/systemd/system/apt-mirror.service
  rm -f /etc/systemd/system/apt-mirror.timer
  systemctl daemon-reload
  rm -f /etc/apt/mirror.list
  rm -f /etc/logrotate.d/apt-mirror
fi

# Purge data before nginx reload so nothing keeps /opt/apt busy (nginx root/alias).
if [ "$PURGE_OPT" -eq 1 ]; then
  echo "==> Stopping nginx (releases file handles on /opt/apt)"
  systemctl stop nginx 2>/dev/null || true
  echo "==> Clearing /opt/apt contents"
  if [ -d /opt/apt ]; then
    # rm -rf /opt/apt fails if this path is a separate mount or still busy; delete children first.
    find /opt/apt -mindepth 1 -delete 2>/dev/null \
      || rm -rf /opt/apt/mirror /opt/apt/skel /opt/apt/var /opt/apt/keys 2>/dev/null \
      || true
    if ! rmdir /opt/apt 2>/dev/null; then
      rm -rf /opt/apt 2>/dev/null || true
    fi
    if [ -d /opt/apt ]; then
      echo "WARN: /opt/apt could not be fully removed (mount point or still busy)." >&2
      echo "     If it is a separate disk: sudo umount /opt/apt && sudo rmdir /opt/apt" >&2
      echo "     Then: sudo mkdir -p /opt/apt" >&2
    fi
  fi
else
  echo "==> Leaving /opt/apt data (pass --purge-opt-apt to delete mirror tree)"
  rm -f /opt/apt/var/apt-mirror.lock 2>/dev/null || true
fi

if [ "$ROLE" = "airgap" ] || [ "$ROLE" = "both" ]; then
  echo "==> Removing nginx vhost for apt.example.com"
  rm -f /etc/nginx/sites-enabled/apt.example.com.conf
  rm -f /etc/nginx/sites-enabled/apt.example.com
  rm -f /etc/nginx/sites-available/apt.example.com.conf
  rm -f /etc/nginx/sites-available/apt.example.com

  if [ "$RESTORE_DEFAULT" -eq 1 ] && [ -f /etc/nginx/sites-available/default ] && [ ! -e /etc/nginx/sites-enabled/default ]; then
    ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
    echo "==> Restored /etc/nginx/sites-enabled/default"
  fi
fi

if command -v nginx >/dev/null 2>&1; then
  nginx -t && systemctl restart nginx
  echo "==> nginx restarted"
fi

echo
echo "Done. Reinstall from the repo:"
echo "  cd /path/to/apt-mirror && sudo ./scripts/setup-apt-mirror-server.sh --role ..."
