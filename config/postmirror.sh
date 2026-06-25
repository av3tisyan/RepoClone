#!/bin/sh
# Deploy to: /opt/apt/var/postmirror.sh (referenced from mirror.list postmirror_script)
# Ensure executable: chmod +x /opt/apt/var/postmirror.sh

set -eu

# Optional: fix ownership if apt-mirror runs as root but nginx reads as www-data
# chown -R apt-mirror:apt-mirror /opt/apt/mirror 2>/dev/null || true

# Remove stale pool files when apt-mirror generated clean.sh (safe wrapper handles broken quoting).
if [ -x /opt/apt/var/run-mirror-clean.sh ]; then
  /opt/apt/var/run-mirror-clean.sh
elif [ -f /opt/apt/var/clean.sh ]; then
  sh -n /opt/apt/var/clean.sh 2>/dev/null && sh /opt/apt/var/clean.sh || true
fi

# Fetch binary-all/Packages and arch:all .deb files for repos with [arch=...,all].
# Must run AFTER clean.sh — apt-mirror's cleanup removes these files if run before.
if [ -x /opt/apt/var/fetch-binary-all.sh ]; then
  /opt/apt/var/fetch-binary-all.sh
fi

# Mirror FLAT repos (no dists/ tree; e.g. Kubernetes pkgs.k8s.io) that apt-mirror can't handle.
# Reads /opt/apt/manager/flat-repos.list ("<url> | <arches>" per line). After clean so the
# .debs aren't swept. Non-fatal: a flat-repo failure must not fail the whole sync.
if [ -x /opt/apt/var/mirror-flat-repo.sh ] && [ -f /opt/apt/manager/flat-repos.list ]; then
  /opt/apt/var/mirror-flat-repo.sh || echo "WARN: mirror-flat-repo.sh reported errors" >&2
fi

exit 0
