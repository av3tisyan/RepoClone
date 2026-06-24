#!/bin/sh
# Safe runner for apt-mirror's generated /opt/apt/var/clean.sh
#
# Two jobs:
#   1) Survive a broken clean.sh. A single quote/apostrophe in a package filename makes
#      apt-mirror emit  rm -f '.../foo'bar.deb'  which breaks sh with:
#        Syntax error: Unterminated quoted string
#   2) Protect arch:all packages managed by fetch-binary-all.sh. apt-mirror with
#      `set defaultarch amd64` never tracks binary-all/, so its clean.sh lists every
#      arch:all .deb for deletion on EVERY run — which made Zabbix/HashiCorp arch:all
#      packages get deleted and then re-downloaded each sync (non-incremental). We build
#      a keep-list from the binary-all/Packages indexes and exclude those paths here.
#
# Usage:
#   sudo ./scripts/run-mirror-clean.sh
#   sudo ./scripts/run-mirror-clean.sh /opt/apt/var/clean.sh
#   MIRROR_PATH=/opt/apt/mirror sudo ./scripts/run-mirror-clean.sh
#
# Deploy: setup-apt-mirror-server.sh installs this as /opt/apt/var/run-mirror-clean.sh

set -eu

CLEAN_SH="${1:-/opt/apt/var/clean.sh}"
MIRROR_PATH="${MIRROR_PATH:-/opt/apt/mirror}"

if [ ! -f "$CLEAN_SH" ]; then
  echo "No $CLEAN_SH — nothing to clean (run apt-mirror first)." >&2
  exit 0
fi

list="$(mktemp)"
keep="$(mktemp)"
trap 'rm -f "$list" "$list.f" "$keep"' EXIT

# --- Keep-list: arch:all packages referenced by binary-all/Packages indexes ---
# fetch-binary-all.sh places these; apt-mirror does not track them, so without this
# they are deleted and re-downloaded every cycle. Built BEFORE clean runs.
if [ -d "$MIRROR_PATH" ]; then
  find "$MIRROR_PATH" -type f -path '*/binary-all/Packages' 2>/dev/null | while IFS= read -r pkgs; do
    # repo root = path with everything from /dists/ onward removed
    root="${pkgs%%/dists/*}"
    awk '/^Filename:/{print $2}' "$pkgs" | while IFS= read -r fn; do
      [ -n "$fn" ] && printf '%s/%s\n' "$root" "$fn"
    done
  done | sort -u >"$keep"
fi

# --- Parse clean.sh into a plain path list ---
# Prefer perl (tolerates broken quoting). If perl is absent AND clean.sh is valid shell
# AND there is nothing to protect, fall back to executing it directly (legacy fast path).
if ! command -v perl >/dev/null 2>&1; then
  if [ ! -s "$keep" ] && sh -n "$CLEAN_SH" 2>/dev/null; then
    echo "==> Running $CLEAN_SH (no perl; nothing to protect)"
    exec sh "$CLEAN_SH"
  fi
  echo "ERROR: perl is required to filter/parse clean.sh safely (or to protect arch:all" >&2
  echo "       packages). Install perl, or fix the bad line: sh -n $CLEAN_SH" >&2
  exit 1
fi

perl -ne '
  next unless /^rm -f /;
  my $rest = $_;
  $rest =~ s/^rm -f //;
  chomp $rest;
  my $path;
  if ($rest =~ /^'\''(.*)'\''\s*$/) { $path = $1; }
  elsif ($rest =~ /^"(.*)"\s*$/) { $path = $1; }
  else { $path = $rest; $path =~ s/\s+$//; }
  print "$path\n" if length $path;
' "$CLEAN_SH" >"$list"

before="$(wc -l <"$list" | tr -d ' ')"

# --- Filter out protected paths ---
protected=0
if [ -s "$keep" ]; then
  # Exact pool .deb paths from the keep-list...
  grep -Fxv -f "$keep" "$list" >"$list.f" || true
  mv "$list.f" "$list"
  # ...and never delete the binary-all index files themselves.
  grep -v '/binary-all/' "$list" >"$list.f" || true
  mv "$list.f" "$list"
  after="$(wc -l <"$list" | tr -d ' ')"
  protected=$((before - after))
fi

n="$(wc -l <"$list" | tr -d ' ')"
echo "==> Removing $n stale mirror files (protected $protected arch:all/binary-all paths)"

if [ "$n" -eq 0 ]; then
  echo "Nothing to remove."
  exit 0
fi

xargs -r rm -f -- <"$list"
echo "==> Done."
