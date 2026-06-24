#!/bin/sh
# Point-in-time snapshots of the apt-mirror tree, for rollback and client date-pinning.
#
# Snapshots are HARDLINK copies (cp -al) on the same filesystem: a snapshot of a multi-TB
# mirror costs almost no extra space — only files that later change diverge. nginx can serve
# them at /snapshots/<id>/… so a client can pin a known-good date (snapshot.debian.org style).
#
# Usage:
#   mirror-snapshot.sh create [id]      # default id = YYYYMMDD-HHMM
#   mirror-snapshot.sh list             # ids, newest last
#   mirror-snapshot.sh prune [keep]     # delete all but the newest <keep> (default KEEP=4)
#   mirror-snapshot.sh du               # disk used by the snapshots dir
#   mirror-snapshot.sh restore <id>     # rsync a snapshot back over the live mirror (rollback)
#
# Env: MIRROR_PATH (/opt/apt/mirror), SNAP_DIR (/opt/apt/snapshots), KEEP (4)

set -eu

MIRROR_PATH="${MIRROR_PATH:-/opt/apt/mirror}"
SNAP_DIR="${SNAP_DIR:-/opt/apt/snapshots}"
KEEP="${KEEP:-4}"
cmd="${1:-list}"

case "$cmd" in
  create)
    id="${2:-$(date +%Y%m%d-%H%M)}"
    dest="$SNAP_DIR/$id"
    [ -e "$dest" ] && { echo "snapshot already exists: $dest" >&2; exit 1; }
    [ -d "$MIRROR_PATH" ] || { echo "no mirror tree at $MIRROR_PATH" >&2; exit 1; }
    install -d -m0755 "$SNAP_DIR"
    echo "==> Creating hardlink snapshot $id (this can take a while on a large mirror)…"
    rm -rf "$dest.partial"
    cp -al "$MIRROR_PATH" "$dest.partial"
    mv "$dest.partial" "$dest"
    echo "created $dest"
    ;;
  list)
    [ -d "$SNAP_DIR" ] && ls -1 "$SNAP_DIR" 2>/dev/null | grep -v '\.partial$' | sort || true
    ;;
  prune)
    keep="${2:-$KEEP}"
    [ -d "$SNAP_DIR" ] || exit 0
    # shellcheck disable=SC2012
    snaps=$(ls -1 "$SNAP_DIR" 2>/dev/null | grep -v '\.partial$' | sort)
    total=$(printf '%s\n' "$snaps" | grep -c . || true)
    del=$((total - keep))
    if [ "$del" -gt 0 ]; then
      printf '%s\n' "$snaps" | head -n "$del" | while IFS= read -r s; do
        [ -n "$s" ] || continue
        rm -rf "${SNAP_DIR:?}/$s"
        echo "pruned $s"
      done
    fi
    ;;
  du)
    du -sh "$SNAP_DIR" 2>/dev/null || echo "0	$SNAP_DIR"
    ;;
  restore)
    id="${2:-}"
    [ -n "$id" ] && [ -d "$SNAP_DIR/$id" ] || { echo "usage: $0 restore <existing-id>" >&2; exit 1; }
    command -v rsync >/dev/null 2>&1 || { echo "rsync required for restore" >&2; exit 1; }
    echo "==> Restoring $id over $MIRROR_PATH (rollback)…"
    rsync -a --delete "$SNAP_DIR/$id/" "$MIRROR_PATH/"
    echo "restored $id"
    ;;
  *)
    echo "usage: $0 create [id] | list | prune [keep] | du | restore <id>" >&2
    exit 1
    ;;
esac
