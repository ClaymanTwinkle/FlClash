#!/bin/sh
# Usage: DEVELOPMENT_TEAM=<team id> ios-spike/install.sh <device-udid>
set -eu

here=$(cd "$(dirname "$0")" && pwd)
device=$1
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
: "${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM to the Apple team id that signs the spike}"
export DEVELOPMENT_TEAM

eval "$(python3 -I -c '
import json, os, shlex
c = json.load(open(os.path.expanduser("~/.appstoreconnect/config.json")))
print("key_path=" + shlex.quote(os.path.expanduser(c["signing_key_path"])))
print("key_id=" + shlex.quote(c["signing_key_id"]))
print("issuer=" + shlex.quote(c["issuer_id"]))
')"

cd "$here"
xcodegen generate -q
log=$here/build/xcodebuild.log
mkdir -p build
if ! xcodebuild -project FlClashSpike.xcodeproj -scheme FlClashSpike -configuration Release \
  -destination "id=$device" -derivedDataPath build \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration -authenticationKeyPath "$key_path" \
  -authenticationKeyID "$key_id" -authenticationKeyIssuerID "$issuer" build >"$log" 2>&1; then
  grep -E 'error:' "$log" | sort -u
  echo "build failed, see $log"
  exit 1
fi
xcrun devicectl device install app --device "$device" build/Build/Products/Release-iphoneos/FlClashSpike.app
