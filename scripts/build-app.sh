#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

# SwiftPM builds for the current Mac's architecture. No signing identity or agent setup is needed.
"${SWIFT:-swift}" build --configuration release --product AgentUsage
bin_dir=$("${SWIFT:-swift}" build --configuration release --show-bin-path)

# Stage and verify before replacing the previous bundle. Leave other .build outputs alone.
staging=$(mktemp -d "$PWD/.build/app-staging.XXXXXX")
trap 'rm -rf "$staging"' EXIT
app="$staging/Agent Usage.app"
mkdir -p "$app/Contents/MacOS"
cp packaging/Info.plist "$app/Contents/Info.plist"
cp "$bin_dir/AgentUsage" "$app/Contents/MacOS/AgentUsage"
chmod 755 "$app/Contents/MacOS/AgentUsage"

/usr/bin/plutil -lint "$app/Contents/Info.plist"
# Ad-hoc signing is local-only. It does not use Keychain identities or establish Gatekeeper trust.
/usr/bin/codesign --force --sign - --timestamp=none "$app"
/usr/bin/codesign --verify --strict "$app"

output="$PWD/.build/Agent Usage.app"
rm -rf "$output"
mv "$app" "$output"
printf 'Built %s\n' "$output"
