#!/bin/bash
# 在 Mac 上编译并打包 build/UnzipClick.app（需要 Xcode 命令行工具：xcode-select --install）
set -euo pipefail
cd "$(dirname "$0")"

APP=build/UnzipClick.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"

# 同时编译 Apple 芯片和 Intel，合成通用二进制
for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos11" Sources/main.swift -o "build/UnzipClick-$arch"
  # 内置 zstd 解压器：老版本 macOS 的 bsdtar 不带 zstd，会去 PATH 里找 zstd 程序
  clang -O2 -arch "$arch" -mmacosx-version-min=11.0 -IThirdParty/zstd \
    Sources/zstd-shim.c ThirdParty/zstd/zstddeclib.c -o "build/zstd-$arch"
done
lipo -create build/UnzipClick-arm64 build/UnzipClick-x86_64 -output "$APP/Contents/MacOS/UnzipClick"
lipo -create build/zstd-arm64 build/zstd-x86_64 -output "$APP/Contents/Resources/bin/zstd"
rm build/UnzipClick-arm64 build/UnzipClick-x86_64 build/zstd-arm64 build/zstd-x86_64

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# ad-hoc 签名：不需要开发者账号，也不会过期
codesign --force --deep --sign - "$APP"
echo "已生成 $APP"
