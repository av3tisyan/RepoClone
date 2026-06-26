#!/bin/sh
# Back up / restore the mirror CONFIG (not the multi-TB data — that is re-syncable from
# upstream and/or covered by snapshots). This is the small, versionable bundle you need to
# rebuild the server after a loss: mirror.list, GPG keyrings, tunables, and the manager +
# nginx units. Keep a copy off-box.
#
#   mirror-backup.sh backup [out.tgz]     # default /opt/apt/backups/mirror-config-<ts>.tgz
#   mirror-backup.sh restore <file.tgz>   # extract back to / (review 'list' first!)
#   mirror-backup.sh list <file.tgz>      # show what a bundle contains
#
# Rebuild drill (fresh host): install apt-mirror + nginx (setup-apt-mirror-server.sh),
# 'mirror-backup.sh restore <bundle>', then 'apt-mirror' (or restore a snapshot) for the data.

set -eu
umask 077                       # bundle holds private keyrings + sudoers — keep it tight

ITEMS="/etc/apt/mirror.list /opt/apt/manager/mirror.list /opt/apt/keys \
/etc/default/apt-mirror /etc/systemd/system/mirror-manager.service.d \
/etc/systemd/system/apt-mirror.service /etc/systemd/system/apt-mirror.timer \
/etc/nginx/sites-available/apt.example.com.conf /etc/sudoers.d/mirror-manager"

cmd="${1:-}"
case "$cmd" in
  backup)
    ts="$(date +%Y%m%d-%H%M%S)"
    out="${2:-/opt/apt/backups/mirror-config-$ts.tgz}"
    install -d -m0700 "$(dirname "$out")"
    # -h dereferences the mirror.list symlink so the real content is captured.
    # --ignore-failed-read: skip items not present on this host/role.
    existing=""
    for p in $ITEMS; do [ -e "$p" ] && existing="$existing $p"; done
    # shellcheck disable=SC2086
    tar czhf "$out" --ignore-failed-read $existing 2>/dev/null || true
    chmod 0600 "$out"
    echo "wrote $out ($(du -h "$out" | cut -f1))"
    echo "Contents:"; tar tzf "$out" | sed 's/^/  /'
    echo "Keep this OFF the mirror host (it contains private signing keyrings)."
    ;;
  list)
    f="${2:?usage: $0 list <file.tgz>}"
    tar tzf "$f"
    ;;
  restore)
    f="${2:?usage: $0 restore <file.tgz>}"
    [ -f "$f" ] || { echo "no such file: $f" >&2; exit 1; }
    echo "==> Restoring config from $f to / — current files will be overwritten."
    echo "    Contents:"; tar tzf "$f" | sed 's/^/      /'
    # Refuse a tampered/hostile bundle: no absolute paths and no '..' traversal.
    if tar tzf "$f" | grep -qE '(^/|(^|/)[.][.](/|$))'; then
      echo "REFUSING: archive contains absolute or '..' paths — possible path-traversal bundle." >&2
      exit 1
    fi
    printf "Proceed? [y/N] "; read -r ans
    case "$ans" in y|Y|yes) ;; *) echo "aborted"; exit 1 ;; esac
    tar xzf "$f" -C / --no-overwrite-dir
    echo "restored. Run: sudo systemctl daemon-reload && sudo nginx -t && sudo systemctl reload nginx"
    echo "If the manager runs as a non-root user, re-run scripts/setup-mirror-manager.sh to fix ownership."
    ;;
  *)
    echo "usage: $0 backup [out.tgz] | restore <file.tgz> | list <file.tgz>" >&2
    exit 1
    ;;
esac
