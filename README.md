# UnzipClick

macOS 上双击 / 右键即可解压的小工具，补上系统「归档实用工具」不支持的格式：
zip、tar.*（gz / bz2 / xz / zst）、7z、rar、xz、zst。

## 行为

- 顶层只有一个文件夹：直接解压到压缩包旁边，沿用该文件夹的名字。
- 顶层是多个文件（或单个文件）：自动建一个与压缩包同名的文件夹（`aaaa.zip` → `aaaa/`），内容放进去。
- 重名时自动加 ` 2`、` 3`，不覆盖已有文件；解压失败不留半成品。
- 自动跳过 `__MACOSX`、`.DS_Store`。
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

## 说明

- 使用 ad-hoc 签名，不需要开发者账号，不会过期。发给同事时压缩 `build/UnzipClick.app` 后，让对方运行 `install.sh`（或 `xattr -cr` 去掉隔离标记）。
- zstd 需要较新的系统自带 bsdtar（macOS 13+）；更老的系统可 `brew install zstd`。
- 暂未支持：加密压缩包的密码输入、中文 zip 文件名的 GBK 乱码修复。
