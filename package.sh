#!/bin/bash
# 打包成可发给同事的 dist/UnzipClick.zip（同事不需要装 Xcode）
set -euo pipefail
cd "$(dirname "$0")"

./build.sh
rm -rf dist
PKG=dist/UnzipClick
mkdir -p "$PKG"
cp -R build/UnzipClick.app "$PKG/"
cp -R QuickAction "$PKG/"
cp install.sh "$PKG/安装.command"
chmod +x "$PKG/安装.command"
cat > "$PKG/先看我.txt" <<'TXT'
安装步骤：
1. 打开「终端」，输入：xattr -cr  （后面加一个空格），把整个 UnzipClick 文件夹拖进终端，回车。
   （这一步是去掉从网络下载带来的拦截标记，因为 App 没有付费开发者签名。）
2. 双击「安装.command」。
3. 在 Finder 选中一个 .zip，按 Cmd+I，「打开方式」选 UnzipClick，点「全部更改…」。
   .tar.gz、.7z、.rar 等格式各做一次。
之后双击压缩包即可解压；右键 → 快速操作 → 「UnzipClick 解压」也行。
TXT
(cd dist && ditto -c -k --keepParent UnzipClick UnzipClick.zip)
echo "已生成 dist/UnzipClick.zip"
