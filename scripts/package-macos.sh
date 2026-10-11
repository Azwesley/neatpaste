#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v cargo >/dev/null 2>&1 && [[ -f "$HOME/.cargo/env" ]]; then
  source "$HOME/.cargo/env"
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Build this first release on macOS." >&2
  exit 1
fi

npm test
npm run build:native
npm run test:native
npm run tauri build -- --bundles app -- --locked
neatpaste_bundle="src-tauri/target/release/bundle/macos/NeatPaste.app"
neatpaste_arch="$(uname -m)"
neatpaste_version="$(node -p 'require("./package.json").version')"
mkdir -p artifacts
# Local ad-hoc signing seals the complete app. This is not Developer ID signing
# or Apple notarization. Use your own distribution identity for a public release.
codesign --force --sign - "$neatpaste_bundle/Contents/Resources/neatpaste-convert"
codesign --force --deep --sign - "$neatpaste_bundle"
codesign --verify --strict "$neatpaste_bundle/Contents/Resources/neatpaste-convert"
codesign --verify --deep --strict --verbose=2 "$neatpaste_bundle"
ditto -c -k --sequesterRsrc --keepParent "$neatpaste_bundle" "artifacts/NeatPaste-v${neatpaste_version}-macOS-${neatpaste_arch}.zip"
python3 scripts/package-source.py
shasum -a 256 artifacts/*.zip > artifacts/SHA256SUMS.txt
echo "Packages are ready in artifacts/."
