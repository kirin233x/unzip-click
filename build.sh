#!/bin/bash
# 在 Mac 上编译并打包 build/UnzipClick.app（需要 Xcode 命令行工具：xcode-select --install）
set -euo pipefail
cd "$(dirname "$0")"

APP=build/UnzipClick.app
rm -rf build
mkdir -p "$APP/Contents/MacOS"

# 同时编译 Apple 芯片和 Intel，合成通用二进制
for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos11" Sources/main.swift -o "build/UnzipClick-$arch"
done
lipo -create build/UnzipClick-arm64 build/UnzipClick-x86_64 -output "$APP/Contents/MacOS/UnzipClick"
rm build/UnzipClick-arm64 build/UnzipClick-x86_64

cp Resources/Info.plist "$APP/Contents/Info.plist"

# ad-hoc 签名：不需要开发者账号，也不会过期
codesign --force --sign - "$APP"
echo "已生成 $APP"
