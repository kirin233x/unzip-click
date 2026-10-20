#!/bin/bash
# 构建并安装：App -> ~/Applications，右键快速操作 -> ~/Library/Services
set -euo pipefail
cd "$(dirname "$0")"

# 分发包里 App 就在脚本旁边；源码仓库里则先编译
if [ -d UnzipClick.app ]; then
  SRC=UnzipClick.app
else
  [ -d build/UnzipClick.app ] || ./build.sh
  SRC=build/UnzipClick.app
fi

mkdir -p ~/Applications
rm -rf ~/Applications/UnzipClick.app
cp -R "$SRC" ~/Applications/
# 同事拿到的 zip 带有隔离标记，去掉它就不会被 Gatekeeper 拦
xattr -cr ~/Applications/UnzipClick.app

WF=~/Library/Services/UnzipClick\ 解压.workflow
rm -rf "$WF"
mkdir -p "$WF/Contents"
cp QuickAction/Info.plist "$WF/Contents/Info.plist"
cp QuickAction/document.wflow "$WF/Contents/document.wflow"

/System/Library/CoreServices/pbs -update >/dev/null 2>&1 || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f ~/Applications/UnzipClick.app

cat <<'EOF'
安装完成。最后一步（只需一次）：设为默认打开方式
  在 Finder 里选中一个 .zip -> Cmd+I -> 「打开方式」选 UnzipClick -> 点「全部更改…」
  对 .tar.gz / .7z / .rar / .xz / .zst 各重复一次。
右键快速操作：若菜单里没有，到 系统设置 -> 隐私与安全性 -> 扩展 -> Finder，勾选「UnzipClick 解压」。
EOF
