#!/usr/bin/env bash
# Refresh assets/data from MetaCubeX/meta-rules-dat, pinned to one commit of its
# `release` branch, and check every file against the SHA-256 digests that
# GitHub reports for the same files on the project's `latest` release.
#
# Usage: tool/update_geodata.sh [commit]   (default: current head of `release`)
# Needs: gh (authenticated), curl, shasum.
set -euo pipefail

repo=MetaCubeX/meta-rules-dat
root=$(cd "$(dirname "$0")/.." && pwd)
data="$root/assets/data"
lock="$root/third_party/geodata/geodata.lock"

commit=${1:-$(gh api "repos/$repo/branches/release" --jq .commit.sha)}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# upstream name -> name the app ships it under
files=(
  "geoip.dat:GEOIP.dat"
  "geosite.dat:GEOSITE.dat"
  "geoip.metadb:GEOIP.metadb"
  "GeoLite2-ASN.mmdb:ASN.mmdb"
)

gh api "repos/$repo/releases/tags/latest" \
  --jq '.assets[] | .name + " " + (.digest // "")' >"$work/digests"

for pair in "${files[@]}"; do
  src=${pair%%:*}
  curl -fsSL --retry 3 -o "$work/$src" \
    "https://raw.githubusercontent.com/$repo/$commit/$src"
  got=$(shasum -a 256 "$work/$src" | cut -c1-64)
  want=$(awk -v n="$src" '$1 == n { sub(/^sha256:/, "", $2); print $2 }' "$work/digests")
  if [ "$got" != "$want" ]; then
    echo "error: $src at $commit is $got, but the latest release says ${want:-nothing}." >&2
    echo "The release has probably moved on; rerun without a commit to take its current head." >&2
    exit 1
  fi
done

{
  echo "# Written by tool/update_geodata.sh; do not edit by hand."
  echo "repo $repo"
  echo "commit $commit"
  for pair in "${files[@]}"; do
    src=${pair%%:*}
    dst=${pair##*:}
    cp "$work/$src" "$data/$dst"
    echo "sha256 $(shasum -a 256 "$data/$dst" | cut -c1-64) $dst <- $src"
  done
} >"$lock"

echo "assets/data now matches $repo@$commit; see ${lock#"$root"/}"
