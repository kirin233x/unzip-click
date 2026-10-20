# 测试用压缩包

用来验证 UnzipClick 的行为，预期结果如下（解压后都在压缩包所在目录）：

| 文件 | 预期结果 |
|---|---|
| `multi-files.tar` / `.tar.bz2` / `.tar.xz` / `.tar.zst` / `.7z` | 生成同名文件夹（如 `multi-files/`），里面是 a.txt、b.txt、c.txt |
| `single-file.tar` | 直接得到 `hello.txt`，不建文件夹 |
| `single-folder.tar.gz` / `single-folder.7z` | 直接得到 `project/`（含 README.md、sub/deep.txt） |
| `with-macosx.zip` | 只得到 `real/file.txt`；`__MACOSX`、`.DS_Store` 被跳过 |
| `gbk-names.zip` | 文件名是 GBK 编码，应还原成「中文.txt」「测试文件.txt」，不乱码 |
| `password-123456.zip` | 弹出密码框，输入 `123456` 解压出 a/b/c.txt；先输错应提示重试 |

多选几个一起双击 / 右键解压，应各自独立处理。重复解压同一个，应得到带 ` 2` 后缀的新文件夹。
没有 `.rar` 样本：这里没有 rar 工具，无法生成，需要你自己准备一个。
