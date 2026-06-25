#!/bin/sh
# Populate /opt/apt/keys on the connected sync host (or any host with outbound HTTPS).
# These files are served by nginx at https://apt.example.com/keys/<filename>
# and rsync to the airgap mirror with the rest of /opt/apt.
#
# Requires: curl, gpg (gnupg), dpkg-deb (dpkg package on Debian/Ubuntu)
# Optional: /usr/share/keyrings/debian-archive-keyring.gpg from installed debian-archive-keyring
#
# Bump UBUNTU_KEYRING_VER if Ubuntu updates the pool package (wget will fail).

set -eu

KEYS_DIR="${KEYS_DIR:-/opt/apt/keys}"
UBUNTU_KEYRING_VER="${UBUNTU_KEYRING_VER:-2023.11.28.1}"
ZABBIX_KEY_URL="${ZABBIX_KEY_URL:-https://repo.zabbix.com/zabbix-official-repo.key}"
HASHICORP_KEY_URL="${HASHICORP_KEY_URL:-https://apt.releases.hashicorp.com/gpg}"
OPENPROJECT_KEY_URL="${OPENPROJECT_KEY_URL:-https://packages.openproject.com/srv/deb/opf/openproject/gpg-key.asc}"
POSTGRESQL_KEY_URL="${POSTGRESQL_KEY_URL:-https://www.postgresql.org/media/keys/ACCC4CF8.asc}"
UBUNTU_POOL="${UBUNTU_POOL:-http://archive.ubuntu.com/ubuntu/pool/main/u/ubuntu-keyring}"

umask 022
sudo install -d -m0755 "$KEYS_DIR"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# Older runs may have left symlinks here; cp/curl will not replace a dangling symlink destination.
sudo rm -f \
  "$KEYS_DIR/debian-archive-keyring.gpg" \
  "$KEYS_DIR/ubuntu-archive-keyring.gpg" \
  "$KEYS_DIR/zabbix.gpg" \
  "$KEYS_DIR/hashicorp.gpg" \
  "$KEYS_DIR/openproject.gpg" \
  "$KEYS_DIR/postgresql.gpg"

echo "==> Debian archive keyring"
if [ -r /usr/share/keyrings/debian-archive-keyring.gpg ]; then
  # -L: on trixie/bookworm this path is often a symlink into /etc/apt; copy key bytes, not the link.
  sudo cp -L /usr/share/keyrings/debian-archive-keyring.gpg "$KEYS_DIR/debian-archive-keyring.gpg"
  sudo chmod 0644 "$KEYS_DIR/debian-archive-keyring.gpg"
  echo "    copied from /usr/share/keyrings/debian-archive-keyring.gpg"
else
  echo "    not in /usr/share/keyrings; trying apt-get install debian-archive-keyring"
  if sudo apt-get install -y debian-archive-keyring >/dev/null 2>&1 \
      && [ -r /usr/share/keyrings/debian-archive-keyring.gpg ]; then
    sudo cp -L /usr/share/keyrings/debian-archive-keyring.gpg "$KEYS_DIR/debian-archive-keyring.gpg"
    sudo chmod 0644 "$KEYS_DIR/debian-archive-keyring.gpg"
    echo "    installed package and copied"
  else
    echo "    trying apt-get download debian-archive-keyring"
    (cd "$TMPDIR" && sudo apt-get download debian-archive-keyring) || true
    f=""
    for cand in "$TMPDIR"/debian-archive-keyring_*.deb; do
      [ -f "$cand" ] && f="$cand" && break
    done
    if [ -n "$f" ]; then
      dpkg-deb -x "$f" "${TMPDIR}/da-extract"
      if [ -r "${TMPDIR}/da-extract/usr/share/keyrings/debian-archive-keyring.gpg" ]; then
        sudo cp -L "${TMPDIR}/da-extract/usr/share/keyrings/debian-archive-keyring.gpg" \
          "$KEYS_DIR/debian-archive-keyring.gpg"
        sudo chmod 0644 "$KEYS_DIR/debian-archive-keyring.gpg"
        echo "    extracted from downloaded .deb"
      fi
    fi
  fi
fi
if ! [ -r "$KEYS_DIR/debian-archive-keyring.gpg" ]; then
  echo "ERROR: could not place debian-archive-keyring.gpg in $KEYS_DIR" >&2
  echo "       Install debian-archive-keyring, or copy /usr/share/keyrings/debian-archive-keyring.gpg there." >&2
  exit 1
fi

echo "==> Ubuntu archive keyring (from ubuntu-keyring .deb)"
UBUNTU_DEB="${TMPDIR}/ubuntu-keyring.deb"
if curl -fsSL -o "$UBUNTU_DEB" "${UBUNTU_POOL}/ubuntu-keyring_${UBUNTU_KEYRING_VER}_all.deb"; then
  dpkg-deb -x "$UBUNTU_DEB" "${TMPDIR}/extract"
  if [ -r "${TMPDIR}/extract/usr/share/keyrings/ubuntu-archive-keyring.gpg" ]; then
    sudo cp -L "${TMPDIR}/extract/usr/share/keyrings/ubuntu-archive-keyring.gpg" \
      "$KEYS_DIR/ubuntu-archive-keyring.gpg"
    sudo chmod 0644 "$KEYS_DIR/ubuntu-archive-keyring.gpg"
    echo "    wrote ubuntu-archive-keyring.gpg"
  else
    echo "    ERROR: unexpected .deb layout; check package contents" >&2
    exit 1
  fi
else
  echo "    ERROR: download failed. Set UBUNTU_KEYRING_VER to a current version from:" >&2
  echo "    ${UBUNTU_POOL}/" >&2
  exit 1
fi

echo "==> Zabbix repo key"
if ! command -v gpg >/dev/null 2>&1; then
  echo "ERROR: gpg (package gnupg) is required to dearmor the Zabbix repo key for apt Signed-By." >&2
  exit 1
fi
ZB_TMP="${TMPDIR}/zabbix-official-repo.key"
curl -fsSL -o "$ZB_TMP" "$ZABBIX_KEY_URL"
gpg --dearmor -o "${TMPDIR}/zabbix.gpg" "$ZB_TMP"
sudo cp -a "${TMPDIR}/zabbix.gpg" "$KEYS_DIR/zabbix.gpg"
sudo chmod 0644 "$KEYS_DIR/zabbix.gpg"
echo "    wrote zabbix.gpg (dearmored for apt Signed-By)"

echo "==> HashiCorp repo key"
HC_TMP="${TMPDIR}/hashicorp.key"
curl -fsSL -o "$HC_TMP" "$HASHICORP_KEY_URL"
gpg --dearmor -o "${TMPDIR}/hashicorp.gpg" "$HC_TMP"
sudo cp -a "${TMPDIR}/hashicorp.gpg" "$KEYS_DIR/hashicorp.gpg"
sudo chmod 0644 "$KEYS_DIR/hashicorp.gpg"
echo "    wrote hashicorp.gpg (dearmored for apt Signed-By)"

echo "==> OpenProject repo key"
OP_TMP="${TMPDIR}/openproject.asc"
curl -fsSL -o "$OP_TMP" "$OPENPROJECT_KEY_URL"
gpg --dearmor -o "${TMPDIR}/openproject.gpg" "$OP_TMP"
sudo cp -a "${TMPDIR}/openproject.gpg" "$KEYS_DIR/openproject.gpg"
sudo chmod 0644 "$KEYS_DIR/openproject.gpg"
echo "    wrote openproject.gpg (dearmored for apt Signed-By)"

echo "==> PostgreSQL (PGDG) repo key"
PG_TMP="${TMPDIR}/postgresql.asc"
curl -fsSL -o "$PG_TMP" "$POSTGRESQL_KEY_URL"
gpg --dearmor -o "${TMPDIR}/postgresql.gpg" "$PG_TMP"
sudo cp -a "${TMPDIR}/postgresql.gpg" "$KEYS_DIR/postgresql.gpg"
sudo chmod 0644 "$KEYS_DIR/postgresql.gpg"
echo "    wrote postgresql.gpg (dearmored for apt Signed-By)"

echo "==> Manifest"
# List each file explicitly — glob + sudo sh -c can omit matches on some systems.
sudo sh -c "cd \"$KEYS_DIR\" && : > SHA256SUMS && for f in debian-archive-keyring.gpg ubuntu-archive-keyring.gpg zabbix.gpg hashicorp.gpg openproject.gpg postgresql.gpg; do [ -f \"\$f\" ] && sha256sum \"\$f\" >> SHA256SUMS; done"
sudo chmod 0644 "$KEYS_DIR/SHA256SUMS"
echo "    SHA256SUMS:"
sudo cat "$KEYS_DIR/SHA256SUMS" | sed 's/^/    /'

echo
echo "==> Key fingerprints — verify each against the vendor's PUBLISHED fingerprint."
echo "    (To enforce, set e.g. EXPECT_POSTGRESQL_FPR=<fpr> before running; mismatch aborts.)"
fp_fail=0
for kf in debian-archive-keyring ubuntu-archive-keyring zabbix hashicorp openproject postgresql; do
  f="$KEYS_DIR/$kf.gpg"
  [ -f "$f" ] || continue
  fpr="$(gpg --no-default-keyring --keyring "$f" --with-colons --fingerprint 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')"
  echo "    $kf.gpg: ${fpr:-<unreadable>}"
  var="EXPECT_$(printf '%s' "$kf" | tr 'a-z-' 'A-Z_')_FPR"
  exp="$(eval "printf '%s' \"\${$var:-}\"")"
  if [ -n "$exp" ] && [ "$exp" != "$fpr" ]; then
    echo "    !! MISMATCH: $kf.gpg fingerprint $fpr != expected $exp" >&2
    fp_fail=1
  fi
done
[ "$fp_fail" -eq 0 ] || { echo "ERROR: key fingerprint verification failed — not trusting these keys." >&2; exit 1; }

echo
echo "Done. Files under $KEYS_DIR — sync to airgap and ensure nginx serves /keys/ (see deploy/nginx/)."
