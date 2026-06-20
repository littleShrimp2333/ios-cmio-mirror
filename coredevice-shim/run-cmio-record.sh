#!/bin/zsh
set -euo pipefail

# Records the muxed iOS screen-capture device to a .mov.
# Args: [seconds] [output.mov]  (defaults: 10 /tmp/cmio-capture.mov)

tool_dir=${0:A:h}
sdk=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
clang=$(xcrun -f clang)
bin=/tmp/cmio-screen-capture-record

"$clang" -fobjc-arc -O0 -g \
  -isysroot "$sdk" \
  -framework Foundation \
  -framework CoreMediaIO \
  -framework AVFoundation \
  -framework CoreMedia \
  -o "$bin" \
  "$tool_dir/CMIOScreenCaptureRecord.m"

echo "built $bin"
exec "$bin" "${1:-10}" "${2:-/tmp/cmio-capture.mov}"
