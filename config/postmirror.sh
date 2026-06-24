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

exit 0
