# UnzipClick

macOS 上双击 / 右键即可解压的小工具，补上系统「归档实用工具」不支持的格式：
zip、tar.*（gz / bz2 / xz / zst）、7z、rar、xz、zst。

## 行为

- 顶层只有一个条目（单个文件或单个文件夹）：直接解压到压缩包旁边，沿用它自己的名字。
- 顶层有多个条目：自动建一个与压缩包同名的文件夹（`aaaa.zip` → `aaaa/`），内容放进去。
- 重名时自动加 ` 2`、` 3`，不覆盖已有文件；解压失败不留半成品。
- 自动跳过 `__MACOSX`、`.DS_Store`。
- 加密 zip：弹窗输入密码，输错可重试，取消则放弃。
- 中文 zip 乱码：读取 zip 中央目录，文件名不是 UTF-8 时自动按 GB18030 / Big5 / Shift-JIS / EUC-KR 解码，无需手动选择。
- 可同时选中多个压缩包，各自独立解压。
- 解压引擎是系统自带的 `/usr/bin/bsdtar`（libarchive），无需安装其他依赖。

## 安装（在 Mac 上，需先 `xcode-select --install`）

```bash
./install.sh
```

然后设为默认打开方式（一次即可）：Finder 选中 `.zip` → `Cmd+I` → 「打开方式」选 UnzipClick → 「全部更改…」；
`.tar.gz`、`.7z`、`.rar` 等各做一次。

右键快速操作：安装后在 Finder 右键 → 快速操作 → 「UnzipClick 解压」。
若没出现，到 系统设置 → 隐私与安全性 → 扩展 → Finder 里勾选。

## 分发给同事

```bash
./package.sh      # 生成 dist/UnzipClick.zip
```

把 zip 发给同事，对方按里面的「先看我.txt」操作即可（不需要装 Xcode）。
也可以把它传到 GitHub 仓库的 Releases 里，发链接给大家。

## 说明

- 图标由 `python3 tools/make_icon.py` 生成（需要 Pillow），想换图标可改这个脚本，或直接替换 `Resources/AppIcon.icns`。
- 使用 ad-hoc 签名，不需要开发者账号，不会过期。发给同事时压缩 `build/UnzipClick.app` 后，让对方运行 `install.sh`（或 `xattr -cr` 去掉隔离标记）。
- zstd：App 内置了一个小的解压器（`Sources/zstd-shim.c` + `ThirdParty/zstd`，BSD 协议），老版本 macOS 的 bsdtar 没有 zstd 也能解，无需 `brew install zstd`。
- 密码功能只对 zip 有效：libarchive 读不了加密的 7z / rar，遇到会直接报错。
- 文件名编码自动识别只针对 zip；tar 里的非 UTF-8 文件名暂不处理。
