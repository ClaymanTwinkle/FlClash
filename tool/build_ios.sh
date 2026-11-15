#!/usr/bin/env bash
# Build the iOS app from source, from the same pinned inputs as
# tool/build_android.sh: submodules, SQLite source, geodata, the CA bundle and
# unchanged lock files.
#
# Usage: tool/build_ios.sh [--unsigned] [--install DEVICE] [--env stable|pre] [--build-number N]
#   --unsigned       build without signing and pack dist/FlClash-ios-arm64-unsigned.ipa
#   --install DEVICE sign, then install on the device (a UDID or a devicectl identifier)
# Signing uses Xcode's account unless ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID name
# an App Store Connect API key. Either way the App Group in the entitlements has to
# exist in the developer account already: an API key cannot create one.
# Needs: Xcode selected with xcode-select, flutter, go and rustup/cargo on PATH.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

unsigned=false
device=""
env=stable
build_number=""
while [ $# -gt 0 ]; do
  case "$1" in
    --unsigned) unsigned=true; shift ;;
    --install) device=$2; shift 2 ;;
    --env) env=$2; shift 2 ;;
    --build-number) build_number=$2; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

fail() { echo "error: $*" >&2; exit 1; }
if [ -n "$build_number" ] && ! [[ "$build_number" =~ ^[0-9]+$ ]]; then
  fail "--build-number must be a number"
fi
if $unsigned && [ -n "$device" ]; then
  fail "an unsigned build cannot be installed"
fi
# Flutter's build hooks run xcrun without DEVELOPER_DIR, so the selected
# developer directory itself has to carry the iOS SDK.
xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1 ||
  fail "no iOS SDK: run sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"

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
trap 'rm -f "$tmp"; git -C core/Clash.Meta checkout -q -- component/ca/ca-certificates.crt' EXIT
curl -fsSL --retry 3 -o "$tmp" "https://curl.se/ca/$ca_bundle"
echo "$ca_sha256  $tmp" | shasum -a 256 -c -
cp "$tmp" "$ca_path"

echo "==> dependencies (locked)"
locks=(pubspec.lock plugins/rust_api/rust/Cargo.lock core/go.sum)
locks_before=$(shasum -a 256 "${locks[@]}")
flutter pub get --enforce-lockfile
(cd plugins/rust_api/rust && cargo fetch --locked)

echo "==> Core"
ios/scripts/build_core.sh

echo "==> build"
printf '{"APP_ENV":"%s"}' "$env" >env.json
flutter_args=(--release --dart-define-from-file=env.json)
if [ -n "$build_number" ]; then
  flutter_args+=(--build-number "$build_number")
fi
if $unsigned; then
  flutter build ios --no-codesign "${flutter_args[@]}"
  app=build/ios/iphoneos/Runner.app
  rm -rf build/ios/ipa-unsigned dist/FlClash-ios-arm64-unsigned.ipa
  mkdir -p build/ios/ipa-unsigned/Payload dist
  cp -R "$app" build/ios/ipa-unsigned/Payload/
  (cd build/ios/ipa-unsigned && zip -qry "$root/dist/FlClash-ios-arm64-unsigned.ipa" Payload)
  shasum -a 256 dist/FlClash-ios-arm64-unsigned.ipa
else
  flutter build ios --config-only "${flutter_args[@]}"
  auth=(-allowProvisioningUpdates -allowProvisioningDeviceRegistration)
  if [ -n "${ASC_KEY_PATH:-}" ]; then
    auth+=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID"
      -authenticationKeyIssuerID "$ASC_ISSUER_ID")
  fi
  destination="generic/platform=iOS"
  [ -n "$device" ] && destination="id=$device"
  xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Release \
    -destination "$destination" -derivedDataPath build/ios/xcode "${auth[@]}" build
  app=build/ios/xcode/Build/Products/Release-iphoneos/Runner.app
  if [ -n "$device" ]; then
    xcrun devicectl device install app --device "$device" "$app"
  fi
fi

echo "==> lock files"
[ "$(shasum -a 256 "${locks[@]}")" = "$locks_before" ] || fail "the build changed a lock file"
