#!/bin/sh
# Builds the iOS Core, stages a mihomo config with the bundled geodata, and
# generates the Xcode project. Usage: ios-spike/prepare.sh <mihomo-config.yaml>
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
config=$1
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

tools=$(mktemp -d)
trap 'rm -rf "$tools"' EXIT
cd "$root/core"
go build -o "$tools/" golang.org/x/mobile/cmd/gomobile golang.org/x/mobile/cmd/gobind
godebug=$(go list -f '{{.DefaultGODEBUG}}' ./cmd/core)
read_config() { sed -n "s/^$1: *//p" "$root/build_config.yaml" | tr -d '"'; }
tags=$(read_config tags)
ldflags=$(read_config go_ldflags)
version=$(read_config core_version)
PATH="$tools:$PATH" gomobile bind \
  -target=ios/arm64 -iosversion=15.0 \
  -tags="$tags${SPIKE_TAGS:+,$SPIKE_TAGS}" \
  -ldflags="$ldflags -X github.com/metacubex/mihomo/constant.Version=$version -X=runtime.godebugDefault=$godebug" \
  -o "$root/libclash/ios/ClashCore.xcframework" ./mobile

payload=$root/ios-spike/SpikeData
rm -rf "$payload"
mkdir -p "$payload"
cp "$root"/assets/data/* "$payload/"
# A tun block of the config's own would ask for a second interface the sandbox refuses.
stripped=$tools/config.yaml
awk '
  /^[A-Za-z]/ { skip = ($0 ~ /^(tun|external-controller-unix|external-controller-pipe):/) }
  !skip
' "$config" > "$stripped"
ruby "$root/ios-spike/gen_configs.rb" "$stripped" "$payload"
while read -r code; do
  curl -sSfL -o "$payload/geosite-$code.mrs" "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/$code.mrs"
done < "$payload/geosite-codes.txt"

cd "$root/ios-spike"
xcodegen generate
