#!/bin/sh
# Airgap transfer integrity: prove the copy on the airgap host matches what the sync host
# produced (rsync or a USB/disk shuttle can truncate, corrupt, or be tampered with, and the
# airgap host cannot re-fetch from upstream to check).
#
#   On the SYNC host, after a sync:        ./airgap-manifest.sh create [--quick]
#   Carry $BASE/MANIFEST.sha256 across the gap together with the data.
#   On the AIRGAP host, after the copy:    ./airgap-manifest.sh verify
#
# Modes:
#   (default) SHA-256 of every file — thorough (catches bit-rot + tampering) but reads the
#             whole tree, so it is slow on a multi-TB mirror; run it off-peak.
#   --quick   size only — fast; catches truncated/missing files (most transfer faults), not
#             silent bit-flips. Good for a routine post-rsync sanity check.
#
# Env: BASE (default /opt/apt), MANIFEST (default $BASE/MANIFEST.sha256).
# Excludes the manifest itself, snapshots/ (hardlinks = same inodes), and skel/var/backups.

set -eu

BASE="${BASE:-/opt/apt}"
MANIFEST="${MANIFEST:-$BASE/MANIFEST.sha256}"
cmd="${1:-}"
MODE=full
[ "${2:-}" = "--quick" ] && MODE=quick

cd "$BASE"
# Portable-ish file list (GNU find on Debian). Exclude volatile / derived / hardlinked trees.
files() {
  find . -type f \
    ! -name 'MANIFEST.sha256' ! -name 'MANIFEST.sha256.*' \
    ! -path './snapshots/*' ! -path './skel/*' ! -path './var/*' ! -path './backups/*' "$@"
}

case "$cmd" in
  create)
    if [ "$MODE" = quick ]; then
      # "size<TAB>path" lines, sorted for stable diffing.
      files | sort | while IFS= read -r f; do printf '%s\t%s\n' "$(stat -c %s "$f")" "$f"; done > "$MANIFEST.tmp"
    else
      files -print0 | xargs -0 sha256sum > "$MANIFEST.tmp"
    fi
    mv "$MANIFEST.tmp" "$MANIFEST"
    echo "wrote $MANIFEST — $(wc -l < "$MANIFEST") files, mode=$MODE"
    ;;
  verify)
    [ -f "$MANIFEST" ] || { echo "no manifest at $MANIFEST — run 'create' on the sync host first" >&2; exit 2; }
    if head -n1 "$MANIFEST" | grep -qE '^[0-9a-f]{64} '; then
      echo "==> Verifying SHA-256 of $(wc -l < "$MANIFEST") files (full; can be slow)…"
      if sha256sum -c --quiet "$MANIFEST"; then
        echo "OK — airgap copy matches the manifest (hashes verified)."
      else
        echo "FAIL — files above are missing or changed; re-transfer them." >&2; exit 1
      fi
    else
      echo "==> Verifying sizes (quick)…"
      cur="$(mktemp)"
      files | sort | while IFS= read -r f; do printf '%s\t%s\n' "$(stat -c %s "$f")" "$f"; done > "$cur"
      if diff "$MANIFEST" "$cur" >/dev/null; then
        echo "OK — airgap copy matches the manifest (sizes; $(wc -l < "$MANIFEST") files)."
        rm -f "$cur"
      else
        echo "FAIL — differences ('<' = expected from sync, '>' = on this host):" >&2
        diff "$MANIFEST" "$cur" >&2 || true
        rm -f "$cur"; exit 1
      fi
    fi
    ;;
  *)
    echo "usage: $0 create [--quick] | verify   (env: BASE, MANIFEST)" >&2
    exit 1
    ;;
esac
