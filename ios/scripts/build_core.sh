#!/bin/sh
# Builds libclash/ios/ClashCore.xcframework with gomobile, the way Android's
# bindCore task builds its AAR. Xcode runs it before compiling either target.
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
out="$root/libclash/ios/ClashCore.xcframework"
stamp="$root/libclash/ios/ClashCore.stamp"
# Xcode's PATH leaves out the Homebrew and Go installer locations.
export PATH="$PATH:/usr/local/bin:/opt/homebrew/bin:/usr/local/go/bin"

if [ -d "$out" ] && [ -f "$stamp" ] && [ -z "$(find "$root/core" "$root/build_config.yaml" -newer "$stamp" \
  \( -name '*.go' -o -name go.mod -o -name go.sum -o -name build_config.yaml \) \
  -not -name '*_test.go' -not -path '*/testdata/*' -print 2>/dev/null | head -n 1)" ]; then
  exit 0
fi

read_config() { sed -n "s/^$1: *//p" "$root/build_config.yaml" | tr -d '"'; }
tools=$(mktemp -d)
trap 'rm -rf "$tools"' EXIT
cd "$root/core"
go build -o "$tools/" golang.org/x/mobile/cmd/gomobile golang.org/x/mobile/cmd/gobind
godebug=$(go list -f '{{.DefaultGODEBUG}}' ./cmd/core)
mkdir -p "$root/libclash/ios"
PATH="$tools:$PATH" gomobile bind \
  -target=ios/arm64 -iosversion=15.0 \
  -tags="$(read_config tags)" \
  -ldflags="$(read_config go_ldflags) -X github.com/metacubex/mihomo/constant.Version=$(read_config core_version) -X=runtime.godebugDefault=$godebug" \
  -o "$tools/ClashCore.xcframework" ./mobile
rm -rf "$out"
mv "$tools/ClashCore.xcframework" "$out"
touch "$stamp"
