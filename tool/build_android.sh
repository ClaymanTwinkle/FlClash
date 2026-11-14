#!/usr/bin/env bash
# Build the Android APKs from source without setup.dart.
#
# setup.dart only writes env.json and runs `flutter build apk --split-per-abi`,
# but it gets there through a personal fork of flutter_distributor fetched by a
# movable git tag. This script does the same build directly and refuses to run
# on inputs that do not match what the repo pins:
#   - submodules at the commits recorded in the tree
#   - SQLite source (third_party/sqlite) and geodata (assets/data) at their recorded SHA-256
#   - the CA bundle CI ships, from curl.se, checked against its SHA-256
#   - dependency lock files unchanged by the build
#
# Usage: tool/build_android.sh [--arch arm64|arm|amd64] [--env stable|pre]
# Needs: flutter, go, rustup/cargo and ANDROID_NDK_HOME (NDK 28.2.13676358) on PATH/env.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

arch=""
env=stable
while [ $# -gt 0 ]; do
  case "$1" in
    --arch) arch=$2; shift 2 ;;
    --env) env=$2; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

fail() { echo "error: $*" >&2; exit 1; }

# Same bundle and digest as the CA step in .github/workflows/build.yaml.
ca_bundle=cacert-2026-09-25.pem
ca_sha256=a41b5d356aea97a529fe27e0f7316d2f9d946d75927476cf9cf1b90637d00505
ca_path=core/Clash.Meta/component/ca/ca-certificates.crt

echo "==> submodules"
git submodule update --init --recursive
if git submodule status --recursive | grep -qE '^[-+U]'; then
  git submodule status --recursive >&2
  fail "a submodule is not at the commit the tree records"
fi

echo "==> SQLite source"
(cd third_party/sqlite && shasum -a 256 -c sqlite3.sha256)

echo "==> geodata"
awk '$1 == "sha256" { print $2 "  assets/data/" $3 }' third_party/geodata/geodata.lock |
  shasum -a 256 -c -

echo "==> CA bundle"
tmp=$(mktemp)
# The CA bundle is a build input only; leave the submodule clean however we exit.
trap 'rm -f "$tmp"; git -C core/Clash.Meta checkout -q -- component/ca/ca-certificates.crt' EXIT
curl -fsSL --retry 3 -o "$tmp" "https://curl.se/ca/$ca_bundle"
echo "$ca_sha256  $tmp" | shasum -a 256 -c -
cp "$tmp" "$ca_path"

echo "==> dependencies (locked)"
locks=(pubspec.lock plugins/rust_api/rust/Cargo.lock core/go.sum)
flutter pub get --enforce-lockfile
# From the crate's directory, so rustup picks the toolchain its rust-toolchain.toml pins.
(cd plugins/rust_api/rust && cargo fetch --locked)

echo "==> build"
printf '{"APP_ENV":"%s"}' "$env" >env.json
target=()
case "$arch" in
  "") ;;
  arm64) target=(--target-platform android-arm64) ;;
  arm) target=(--target-platform android-arm) ;;
  amd64) target=(--target-platform android-x64) ;;
  *) fail "unknown arch: $arch" ;;
esac
flutter build apk --release --split-per-abi --dart-define-from-file=env.json ${target[@]+"${target[@]}"}

echo "==> lock files"
git diff --exit-code -- "${locks[@]}" || fail "the build changed a lock file"

echo "==> APKs"
for apk in build/app/outputs/flutter-apk/*-release.apk; do
  [ -e "$apk" ] || continue
  shasum -a 256 "$apk"
done
