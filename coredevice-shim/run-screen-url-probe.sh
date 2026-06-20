#!/bin/zsh
set -euo pipefail

repo_root=${0:A:h:h:h}
tool_dir=${0:A:h}
swift=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift
framework_dir=/Library/Developer/PrivateFrameworks
sdk=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk

exec "$swift" \
  -sdk "$sdk" \
  -I "$tool_dir" \
  -F "$framework_dir" \
  -framework CoreDevice \
  "$repo_root/tools/coredevice-shim/ScreenViewingURLProbe.swift"
