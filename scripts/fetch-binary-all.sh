#!/bin/sh
# Fetch binary-all/Packages index and arch:all .deb files for repos listed with
# [arch=...,all] in mirror.list.
#
# apt-mirror with defaultarch amd64 does not reliably download binary-all/Packages
# for HTTPS third-party repos (Zabbix, HashiCorp). apt-mirror's clean.sh also
# removes any manually placed files. Running this AFTER clean.sh (from postmirror.sh)
# ensures binary-all packages survive every sync cycle.
#
# Usage (standalone):
#   sudo ./scripts/fetch-binary-all.sh
#   MIRROR_LIST=/path/to/mirror.list MIRROR_PATH=/opt/apt/mirror sudo ./scripts/fetch-binary-all.sh
#
# Deploy: setup-apt-mirror-server.sh installs this as /opt/apt/var/fetch-binary-all.sh

set -eu

MIRROR_LIST="${MIRROR_LIST:-/etc/apt/mirror.list}"
MIRROR_PATH="${MIRROR_PATH:-/opt/apt/mirror}"
CURL_TIMEOUT="${CURL_TIMEOUT:-120}"

if [ ! -f "$MIRROR_LIST" ]; then
  printf 'fetch-binary-all: %s not found — skip\n' "$MIRROR_LIST" >&2
  exit 0
fi

echo "==> fetch-binary-all: syncing arch:all packages"

tmplist=$(mktemp)
filelist=$(mktemp)
trap 'rm -f "$tmplist" "$filelist"' EXIT

# Extract repos explicitly configured with [arch=...,all] in mirror.list.
grep -E '^\s*deb \[arch=[^]]*,all' "$MIRROR_LIST" > "$tmplist" || true

if [ ! -s "$tmplist" ]; then
  echo "    no [arch=...,all] repos in $MIRROR_LIST — nothing to do"
  exit 0
fi

errors=0

while IFS= read -r line; do
  # Parse: deb [arch=amd64,all] <url> <suite> <components...>
  # shellcheck disable=SC2086
  set -- $line
  shift         # "deb"
  shift         # "[arch=...]"
  url="$1"; shift
  suite="$1"; shift
  components="$*"

  # Derive local path: strip protocol to match apt-mirror's on-disk layout.
  host_path=$(printf '%s' "$url" | sed 's|^https://||; s|^http://||')
  local_root="${MIRROR_PATH}/${host_path}"

  for component in $components; do
    pkg_url="${url}/dists/${suite}/${component}/binary-all/Packages"
    local_dir="${local_root}/dists/${suite}/${component}/binary-all"
    local_pkg="${local_dir}/Packages"

    mkdir -p "$local_dir"

    # Download binary-all/Packages index.
    if ! curl -fsSL --max-time "$CURL_TIMEOUT" "$pkg_url" \
         -o "${local_pkg}.tmp" 2>/dev/null; then
      rm -f "${local_pkg}.tmp"
      # 404 is normal — repo simply has no arch:all packages.
      printf '    skip %s %s/%s (no binary-all upstream)\n' \
        "$host_path" "$suite" "$component"
      continue
    fi
    mv "${local_pkg}.tmp" "$local_pkg"
    printf '    index %s %s/%s\n' "$host_path" "$suite" "$component"

    # Compressed variant — preferred by apt clients to save bandwidth.
    curl -fsSL --max-time "$CURL_TIMEOUT" \
      "${url}/dists/${suite}/${component}/binary-all/Packages.gz" \
      -o "${local_dir}/Packages.gz" 2>/dev/null \
      || rm -f "${local_dir}/Packages.gz"

    # Sync arch:all .deb files. Idempotent + self-healing + verified:
    #   - skip files already present with the expected Size (no needless re-download);
    #   - (re)download missing/short/corrupt files, verify Size and SHA256 before commit.
    # This is why a steady-state sync should report "N present, 0 fetched" instead of
    # re-pulling Zabbix/HashiCorp arch:all packages every run. (It only stays incremental
    # if run-mirror-clean.sh keeps these files — apt-mirror's clean would otherwise delete
    # them; see docs/TROUBLESHOOTING.md.)
    #
    # Emit "Filename<TAB>Size<TAB>SHA256" per stanza from the Packages index.
    awk '
      function flush(){ if (fn != "") printf "%s\t%s\t%s\n", fn, sz, sha; fn=""; sz=""; sha="" }
      /^Filename:[ \t]/ { fn=$2 }
      /^Size:[ \t]/     { sz=$2 }
      /^SHA256:[ \t]/   { sha=$2 }
      /^[ \t]*$/        { flush() }
      END               { flush() }
    ' "$local_pkg" > "$filelist"

    present=0; fetched=0
    TAB=$(printf '\t')
    while IFS="$TAB" read -r fname sz sha; do
      [ -z "$fname" ] && continue
      deb_local="${local_root}/${fname}"

      # Already present and the right size? Leave it — this is the incremental fast path.
      if [ -f "$deb_local" ]; then
        cur=$(stat -c %s "$deb_local" 2>/dev/null || wc -c < "$deb_local" | tr -d ' ')
        if [ -z "$sz" ] || [ "$cur" = "$sz" ]; then
          present=$((present + 1))
          continue
        fi
        printf '    re-fetch (size %s != %s): %s\n' "$cur" "$sz" "$(basename "$deb_local")"
      fi

      mkdir -p "$(dirname "$deb_local")"
      if ! curl -fsSL --max-time "$CURL_TIMEOUT" "${url}/${fname}" \
           -o "${deb_local}.tmp" 2>/dev/null; then
        rm -f "${deb_local}.tmp"
        printf '    WARN: failed to fetch %s/%s\n' "$url" "$fname" >&2
        errors=$((errors + 1)); continue
      fi
      # Verify size, then SHA256 if we can, before committing the file.
      if [ -n "$sz" ]; then
        got=$(stat -c %s "${deb_local}.tmp" 2>/dev/null || wc -c < "${deb_local}.tmp" | tr -d ' ')
        if [ "$got" != "$sz" ]; then
          rm -f "${deb_local}.tmp"
          printf '    WARN: size mismatch %s (%s != %s)\n' "$fname" "$got" "$sz" >&2
          errors=$((errors + 1)); continue
        fi
      fi
      if [ -n "$sha" ] && command -v sha256sum >/dev/null 2>&1; then
        got=$(sha256sum "${deb_local}.tmp" | awk '{print $1}')
        if [ "$got" != "$sha" ]; then
          rm -f "${deb_local}.tmp"
          printf '    WARN: SHA256 mismatch %s\n' "$fname" >&2
          errors=$((errors + 1)); continue
        fi
      fi
      mv "${deb_local}.tmp" "$deb_local"
      fetched=$((fetched + 1))
      printf '    fetch %s\n' "$(basename "$deb_local")"
    done < "$filelist"

    printf '    %s %s/%s: %d present, %d fetched\n' \
      "$host_path" "$suite" "$component" "$present" "$fetched"

  done
done < "$tmplist"

if [ "$errors" -gt 0 ]; then
  echo "==> fetch-binary-all: done ($errors download(s) failed)" >&2
  exit 1
fi
echo "==> fetch-binary-all: done"
