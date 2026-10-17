#!/bin/bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Building Joblet requires macOS and Xcode 15 or later." >&2
  exit 1
fi

if ! xcrun --find xcodebuild >/dev/null 2>&1; then
  echo "Install Xcode and select it under Xcode > Settings > Locations." >&2
  exit 1
fi

xcodebuild \
  -project "$project_dir/Joblet.xcodeproj" \
  -scheme Joblet \
  -configuration Release \
  -derivedDataPath "$project_dir/build" \
  CODE_SIGN_IDENTITY=- \
  build

# Bundle the headless MCP server so the configured path stays stable after installing the app.
app="$project_dir/build/Build/Products/Release/Joblet.app"
swift build --package-path "$project_dir" --configuration release --product joblet-mcp
bin_dir="$(swift build --package-path "$project_dir" --configuration release --show-bin-path)"
mkdir -p "$app/Contents/Helpers"
install -m 755 "$bin_dir/joblet-mcp" "$app/Contents/Helpers/joblet-mcp"
# Modifying a signed bundle invalidates its signature; re-sign locally (ad-hoc).
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"

echo ""
echo "Built: $app"
echo "MCP server: $app/Contents/Helpers/joblet-mcp"
