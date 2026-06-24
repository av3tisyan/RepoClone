#!/bin/sh
# One-way sync of mirrored content from the connected sync host to the airgap mirror server.
# Run from the sync host (or a bastion) with SSH key or local rsync to removable media.
#
# Usage:
#   SYNC_HOST=sync.internal AIRGAP=apt-mirror.internal ./scripts/rsync-to-airgap.sh
#   DEST=/mnt/usb/apt-mirror ./scripts/rsync-to-airgap.sh   # offline media
#
# Requires: rsync, SSH to airgap if network link exists

set -eu

: "${SRC:=/opt/apt}"
: "${DEST_USER:=root}"
: "${AIRGAP:=apt.example.com}"
: "${DEST:=}"
: "${MANIFEST_MODE:=--quick}"   # --quick (size) or "" for full SHA-256; "off" to skip

RSYNC_OPTS="-aH --numeric-ids --delete-delay --partial --info=progress2"

# Write an integrity manifest first so the airgap side can verify the copy is faithful.
# (On the airgap host after the transfer: scripts/airgap-manifest.sh verify)
GUARD="$(CDPATH= cd "$(dirname "$0")" && pwd)/airgap-manifest.sh"
if [ "${MANIFEST_MODE}" != "off" ] && [ -x "$GUARD" ]; then
  echo "==> Writing transfer manifest (mode=${MANIFEST_MODE:-full})"
  BASE="${SRC}" sh "$GUARD" create ${MANIFEST_MODE} || echo "WARN: manifest create failed" >&2
fi

if [ -n "${DEST}" ]; then
  echo "Syncing ${SRC}/ to ${DEST}/"
  rsync ${RSYNC_OPTS} "${SRC}/" "${DEST}/"
  echo "Then on the airgap host: BASE=${DEST} sh scripts/airgap-manifest.sh verify"
  exit 0
fi

if [ -z "${AIRGAP}" ]; then
  echo "Set AIRGAP=host or DEST=/path for offline copy" >&2
  exit 1
fi

echo "Syncing ${SRC}/ to ${DEST_USER}@${AIRGAP}:/opt/apt/"
rsync ${RSYNC_OPTS} -e ssh "${SRC}/" "${DEST_USER}@${AIRGAP}:/opt/apt/"
echo "Then on ${AIRGAP}: sh scripts/airgap-manifest.sh verify"
