#!/bin/zsh
set -euo pipefail

# Builds and runs the first-frame probe: opens an AVCaptureSession against the
# muxed iOS screen-capture device and counts CMSampleBuffers.
# Optional arg: capture window in seconds (default 25).
#
# NOTE: needs camera/TCC authorization. If run headless and the device shows
# auth status != 3 (authorized), grant the controlling terminal app camera
# access in System Settings > Privacy & Security > Camera, then re-run.

tool_dir=${0:A:h}
sdk=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
clang=$(xcrun -f clang)
bin=/tmp/cmio-screen-capture-firstframe

"$clang" -fobjc-arc -O0 -g \
  -isysroot "$sdk" \
  -framework Foundation \
  -framework CoreMediaIO \
  -framework AVFoundation \
  -framework CoreMedia \
  -o "$bin" \
  "$tool_dir/CMIOScreenCaptureFirstFrame.m"

echo "built $bin"
exec "$bin" "${1:-25}"
