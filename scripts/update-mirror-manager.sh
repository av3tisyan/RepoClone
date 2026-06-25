#!/bin/sh
# Apply the latest code on a RUNNING host — the safe, routine update path.
#
#   cd ~/apt-mirror && git pull && sudo ./scripts/update-mirror-manager.sh
#
# Installs the dashboard app (mirror_manager.py, index.html, presets.json) and the
# /opt/apt/var helper scripts, then RESTARTS mirror-manager so the new code loads.
#
# Deliberately does NOT touch: /etc/apt/mirror.list (the manager owns it — re-running
# setup-apt-mirror-server.sh would WIPE your added repos), GPG keys, the nginx vhost (you may
# have edited cert paths), or the systemd units / user / sudoers. Do those rare changes by
# hand (see the notes printed at the end), or re-run setup-mirror-manager.sh for unit/user/
# sudoers changes only.

set -eu
SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd)"
ROOT="$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)"
DEST=/opt/apt/mirror-manager

[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo)." >&2; exit 1; }
[ -d "$DEST" ] || { echo "$DEST not found — run scripts/setup-mirror-manager.sh first." >&2; exit 1; }

echo "==> Validating new app before install"
python3 -c "import ast; ast.parse(open('$ROOT/scripts/mirror-manager/mirror_manager.py').read())"
python3 -c "import json; json.load(open('$ROOT/scripts/mirror-manager/presets.json'))"

echo "==> Installing dashboard app -> $DEST"
install -m0644 "$ROOT/scripts/mirror-manager/mirror_manager.py" "$DEST/mirror_manager.py"
install -m0644 "$ROOT/scripts/mirror-manager/index.html"        "$DEST/index.html"
install -m0644 "$ROOT/scripts/mirror-manager/presets.json"      "$DEST/presets.json"

echo "==> Installing /opt/apt/var helper scripts"
for s in run-mirror-clean.sh fetch-binary-all.sh mirror-flat-repo.sh apt-mirror-guard.sh mirror-snapshot.sh airgap-manifest.sh mirror-backup.sh; do
  [ -f "$ROOT/scripts/$s" ] && install -m0755 "$ROOT/scripts/$s" "/opt/apt/var/$s"
done
[ -f "$ROOT/config/postmirror.sh" ] && install -m0755 "$ROOT/config/postmirror.sh" /opt/apt/var/postmirror.sh

echo "==> Restarting mirror-manager"
OLD_PID="$(systemctl show -p MainPID --value mirror-manager 2>/dev/null || echo 0)"
systemctl restart mirror-manager
sleep 1
NEW_PID="$(systemctl show -p MainPID --value mirror-manager 2>/dev/null || echo 0)"
RUNAS="$(ps -o user= -p "$NEW_PID" 2>/dev/null | tr -d ' ' || true)"
echo "    PID ${OLD_PID} -> ${NEW_PID} (running as ${RUNAS:-?})"
[ "$OLD_PID" = "$NEW_PID" ] && echo "    WARN: PID unchanged — restart may have failed; check: journalctl -u mirror-manager -n30" >&2

echo
echo "Done. Now:"
echo "  • Hard-refresh the dashboard in your browser (Ctrl/Cmd+Shift+R) to drop cached HTML/JS."
echo "  • If setup.sh / landing-page logic changed: dashboard -> Server -> Publish."
echo
echo "Rare changes this script does NOT do (apply by hand):"
echo "  • systemd unit: sudo cp deploy/systemd/apt-mirror.service /etc/systemd/system/ && sudo systemctl daemon-reload"
echo "  • nginx vhost: review cert paths, then sudo cp deploy/nginx/<vhost>.conf /etc/nginx/sites-available/ && sudo nginx -t && sudo systemctl reload nginx"
echo "  • manager unit/user/sudoers: sudo ./scripts/setup-mirror-manager.sh [--listen-host .. --allow ..]"
