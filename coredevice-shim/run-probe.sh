#!/bin/zsh
set -euo pipefail

repo_root=${0:A:h:h:h}
tool_dir=${0:A:h}
build_dir=${TMPDIR:-/tmp}/devicekit-coredevice-probe
swiftc=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc
framework_dir=/Library/Developer/PrivateFrameworks
media_framework_dir=$framework_dir/CoreDevice.framework/Versions/A/Frameworks
sdk=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk

mkdir -p "$build_dir"

"$swiftc" \
  -sdk "$sdk" \
  -parse-as-library \
  -I "$tool_dir" \
  -F "$framework_dir" \
  -F "$media_framework_dir" \
  -framework CoreDevice \
  -framework CoreDeviceMediaStreamSupport \
  -Xlinker -rpath \
  -Xlinker "$framework_dir" \
  -Xlinker -rpath \
  -Xlinker "$media_framework_dir" \
  "$repo_root/tools/coredevice-shim/CoreDeviceProbe.swift" \
  -o "$build_dir/coredevice-probe"

exec "$build_dir/coredevice-probe" "$@"
