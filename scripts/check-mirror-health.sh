#!/bin/sh
# HTTP(S) checks for published InRelease files (after first apt-mirror run).
# Use in cron; exit non-zero if any curl fails.
#
# Usage:
#   ./check-mirror-health.sh
#   ./check-mirror-health.sh https://apt.example.com
#
# Optional: CURL_INSECURE=1 to add curl -k (lab only; do not use in production).

set -eu

BASE="${1:-https://apt.example.com}"
BASE="${BASE%/}"

failed=0
echo "==> Base: ${BASE}"
while IFS= read -r p || [ -n "$p" ]; do
  [ -z "$p" ] && continue
  url="${BASE}${p}"
  if ! curl -fsSL ${CURL_INSECURE:+-k} -o /dev/null --max-time 60 "${url}"; then
    echo "FAIL: ${url}" >&2
    failed=1
  else
    echo "OK:   ${url}"
  fi
done <<'PATHS'
/keys/debian-archive-keyring.gpg
/deb.debian.org/debian/dists/bookworm/InRelease
/deb.debian.org/debian/dists/trixie/InRelease
/security.debian.org/debian-security/dists/bookworm-security/InRelease
/security.debian.org/debian-security/dists/trixie-security/InRelease
/archive.ubuntu.com/ubuntu/dists/noble/InRelease
/repo.zabbix.com/zabbix/7.4/stable/ubuntu/dists/noble/InRelease
/repo.zabbix.com/zabbix/7.4/stable/debian/dists/bookworm/InRelease
PATHS

exit "${failed}"
