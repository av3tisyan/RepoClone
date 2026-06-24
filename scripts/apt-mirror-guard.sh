#!/bin/sh
# Disk-full guard for apt-mirror: refuse to start a sync when free space is below a floor,
# so a run can never fill the volume to 100% (which breaks nginx, apt clients, and the box).
#
# Used as the apt-mirror.service ExecStart (installed to /opt/apt/var/apt-mirror-guard.sh by
# setup-apt-mirror-server.sh). Tunables via /etc/default/apt-mirror or environment:
#   MIRROR_BASE   filesystem to check (default /opt/apt)
#   MIN_FREE_GB   abort if free space is below this many GB (default 50)
#
# Exit non-zero (sync fails, visible in `systemctl status` / journal) when below the floor.

set -eu

[ -r /etc/default/apt-mirror ] && . /etc/default/apt-mirror

MIRROR_BASE="${MIRROR_BASE:-/opt/apt}"
MIN_FREE_GB="${MIN_FREE_GB:-50}"

free_kb=$(df -Pk "$MIRROR_BASE" | awk 'NR==2{print $4}')
free_gb=$((free_kb / 1024 / 1024))
min_kb=$((MIN_FREE_GB * 1024 * 1024))

if [ "$free_kb" -lt "$min_kb" ]; then
  echo "apt-mirror-guard: ABORT — only ${free_gb} GB free on ${MIRROR_BASE} (floor MIN_FREE_GB=${MIN_FREE_GB}). Free space or raise the floor." >&2
  exit 1
fi

echo "apt-mirror-guard: ${free_gb} GB free on ${MIRROR_BASE} (>= ${MIN_FREE_GB} GB) — proceeding."
exec /usr/bin/apt-mirror "$@"
