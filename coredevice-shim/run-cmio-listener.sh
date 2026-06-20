#!/bin/zsh
set -euo pipefail

# Builds and runs the resident CoreMediaIO screen-capture listener.
# Optional arg: how many seconds to stay resident (default 45).

tool_dir=${0:A:h}
sdk=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
clang=$(xcrun -f clang)
bin=/tmp/cmio-screen-capture-listener

"$clang" -fobjc-arc -O0 -g \
  -isysroot "$sdk" \
  -framework Foundation \
  -framework CoreMediaIO \
  -framework AVFoundation \
  -o "$bin" \
  "$tool_dir/CMIOScreenCaptureListener.m"

echo "built $bin"
exec "$bin" "${1:-45}"
