#!/bin/sh
# mirror-flat-repo.sh — mirror FLAT apt repos (no dists/ tree; sourced with a trailing " /")
# that apt-mirror handles unreliably. The motivating case is Kubernetes (pkgs.k8s.io), which
# is BOTH flat AND split per minor version (core:/stable:/v1.NN/deb).
#
# It fetches the repo metadata (InRelease/Release[.gpg], Packages[.gz]) verbatim, then downloads
# and SHA256-verifies the .debs for the selected architectures, laid out under MIRROR_BASE so
# nginx serves the flat repo unchanged and clients still verify the upstream signature.
# Idempotent: files already present with a matching checksum are skipped. Run it from
# config/postmirror.sh (or cron) after apt-mirror so flat repos refresh on every sync.
#
# Usage:
#   mirror-flat-repo.sh <flat-repo-url> [arches]
#   mirror-flat-repo.sh                         # mirror every entry in $FLAT_REPOS_FILE
#
# Example:
#   KEYRING=/opt/apt/keys/kubernetes.gpg \
#     ./mirror-flat-repo.sh https://pkgs.k8s.io/core:/stable:/v1.31/deb/ "amd64 all"
#
# Env:
#   MIRROR_BASE      local mirror root             (default /opt/apt/mirror)
#   ARCHES           arch allowlist, space-sep     (default "amd64 all"; arg 2 overrides)
#   FLAT_REPOS_FILE  repo list when no URL arg     (default /opt/apt/manager/flat-repos.list)
#                    one per line: "<url>" or "<url> | <arches>"; '#' starts a comment
#   KEYRING          gpg keyring to verify InRelease/Release BEFORE mirroring (recommended)
#   DRYRUN=1         list what would be fetched; download nothing
set -eu

MIRROR_BASE="${MIRROR_BASE:-/opt/apt/mirror}"
FLAT_REPOS_FILE="${FLAT_REPOS_FILE:-/opt/apt/manager/flat-repos.list}"
DEF_ARCHES="${ARCHES:-amd64 all}"
TAB="$(printf '\t')"

# Verify a file's SHA256 by computing + comparing (portable; avoids `sha256sum -c` flag quirks).
sha_ok() {  # $1 = expected hex, $2 = file
  [ -n "$1" ] || return 0
  got="$(sha256sum "$2" 2>/dev/null | awk '{print $1}')"
  [ -n "$got" ] && [ "$got" = "$1" ]
}

mirror_one() {
  url="${1%/}"; arches="${2:-$DEF_ARCHES}"
  rel="$(printf '%s' "$url" | sed -E 's#^[a-z][a-z0-9+.-]*://##')"
  dest="$MIRROR_BASE/$rel"
  T="$(mktemp -d)"
  echo "==> flat repo: $url"
  echo "    -> $dest   (arches: $arches)"
  [ -n "${DRYRUN:-}" ] || install -d -m0755 "$dest"

  # --- metadata (InRelease preferred; Release[.gpg] fallback) ---
  meta=0
  for m in InRelease Release Release.gpg; do
    if curl -fsSL --retry 3 -o "$T/$m" "$url/$m" 2>/dev/null; then
      [ -n "${DRYRUN:-}" ] || { install -d -m0755 "$dest"; cp "$T/$m" "$dest/$m"; }
      [ "$m" = Release.gpg ] || meta=1
    fi
  done
  [ "$meta" = 1 ] || { echo "    !! no InRelease/Release at $url (is it a flat repo root?)" >&2; rm -rf "$T"; return 1; }

  # --- optional signature verification before we trust the index ---
  if [ -n "${KEYRING:-}" ]; then
    if [ -f "$T/InRelease" ] && gpgv --keyring "$KEYRING" "$T/InRelease" >/dev/null 2>&1; then
      echo "    signature: InRelease verified"
    elif [ -f "$T/Release" ] && [ -f "$T/Release.gpg" ] && \
         gpgv --keyring "$KEYRING" "$T/Release.gpg" "$T/Release" >/dev/null 2>&1; then
      echo "    signature: Release verified"
    else
      echo "    !! signature verification FAILED against $KEYRING — aborting this repo" >&2
      rm -rf "$T"; return 1
    fi
  fi

  # --- Packages index (keep both forms on disk for clients; parse one) ---
  pk="$T/Packages.work"
  if curl -fsSL --retry 3 -o "$T/Packages.gz" "$url/Packages.gz" 2>/dev/null; then
    [ -n "${DRYRUN:-}" ] || cp "$T/Packages.gz" "$dest/Packages.gz"
    gzip -dc "$T/Packages.gz" > "$pk" 2>/dev/null || :
  fi
  if curl -fsSL --retry 3 -o "$T/Packages" "$url/Packages" 2>/dev/null; then
    [ -n "${DRYRUN:-}" ] || cp "$T/Packages" "$dest/Packages"
    [ -s "$pk" ] || cp "$T/Packages" "$pk"
  fi
  [ -s "$pk" ] || { echo "    !! no Packages index at $url" >&2; rm -rf "$T"; return 1; }

  # --- parse stanzas -> "arch <TAB> sha256 <TAB> filename" ---
  awk -v RS='' '{
    fn=""; ar=""; sh=""; n=split($0, L, "\n");
    for (i=1;i<=n;i++) {
      if      (L[i] ~ /^Filename: /)     fn=substr(L[i],11);
      else if (L[i] ~ /^Architecture: /) ar=substr(L[i],15);
      else if (L[i] ~ /^SHA256: /)       sh=substr(L[i],9);
    }
    if (fn != "") printf "%s\t%s\t%s\n", ar, sh, fn
  }' "$pk" > "$T/list"

  total=0; want=0; got=0; skip=0; fail=0
  while IFS="$TAB" read -r arch sha fn; do
    total=$((total+1))
    case " $arches " in *" $arch "*) : ;; *) continue ;; esac
    want=$((want+1)); fn="${fn#./}"
    if [ -n "${DRYRUN:-}" ]; then echo "    would fetch [$arch] $fn"; continue; fi
    out="$dest/$fn"; install -d -m0755 "$(dirname "$out")"
    if [ -f "$out" ] && sha_ok "$sha" "$out"; then
      skip=$((skip+1)); continue
    fi
    if curl -fsSL --retry 3 -o "$out.part" "$url/$fn" 2>/dev/null; then
      if ! sha_ok "$sha" "$out.part"; then
        echo "    !! SHA256 mismatch, discarding: $fn" >&2; rm -f "$out.part"; fail=$((fail+1)); continue
      fi
      mv "$out.part" "$out"; got=$((got+1))
    else
      echo "    !! download failed: $fn" >&2; rm -f "$out.part"; fail=$((fail+1))
    fi
  done < "$T/list"

  if [ -n "${DRYRUN:-}" ]; then
    echo "    (dry run) $want of $total packages match [$arches]"
  else
    echo "    done: $got fetched, $skip current, $fail failed ($want of $total matched [$arches])"
  fi
  rm -rf "$T"
  [ "$fail" = 0 ]
}

if [ "$#" -ge 1 ]; then
  mirror_one "$1" "${2:-}"
else
  [ -f "$FLAT_REPOS_FILE" ] || { echo "No repo URL given and $FLAT_REPOS_FILE not found." >&2; exit 1; }
  rc=0
  while IFS= read -r line; do
    line="${line%%#*}"
    u="$(printf '%s' "${line%%|*}" | xargs 2>/dev/null || true)"
    a=""; case "$line" in *"|"*) a="$(printf '%s' "${line#*|}" | xargs 2>/dev/null || true)";; esac
    [ -n "$u" ] || continue
    mirror_one "$u" "$a" || rc=1
  done < "$FLAT_REPOS_FILE"
  exit "$rc"
fi
