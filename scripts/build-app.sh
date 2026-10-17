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

echo ""
echo "Built: $project_dir/build/Build/Products/Release/Joblet.app"
