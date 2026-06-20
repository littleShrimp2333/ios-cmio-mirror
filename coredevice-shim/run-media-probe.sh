#!/bin/zsh
set -euo pipefail

repo_root=${0:A:h:h:h}
tool_dir=${0:A:h}
swift=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift
framework_dir=/Library/Developer/PrivateFrameworks
media_framework_dir=$framework_dir/CoreDevice.framework/Versions/A/Frameworks
sdk=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk

exec "$swift" \
  -sdk "$sdk" \
  -I "$tool_dir" \
  -F "$framework_dir" \
  -F "$media_framework_dir" \
  -framework CoreDevice \
  -framework CoreDeviceMediaStreamSupport \
  "$repo_root/tools/coredevice-shim/MediaStreamProbe.swift"
