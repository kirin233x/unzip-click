import AppKit

// UnzipClick: 双击 / 右键快速操作 -> 解压到「压缩包同名文件夹」。
// 解压引擎用系统自带的 /usr/bin/bsdtar（libarchive），支持 zip、tar.*、7z、rar、xz、zst 等。

struct ExtractError: Error {
    let archive: String
    let message: String
}

enum Failure: Error {
    case password(wrong: Bool)
    case message(String)
}

let bsdtar = URL(fileURLWithPath: "/usr/bin/bsdtar")

/// aaaa.zip -> aaaa, aaaa.tar.gz -> aaaa
func folderName(for fileName: String) -> String {
    var name = (fileName as NSString).deletingPathExtension
    if name.lowercased().hasSuffix(".tar") {
        name = (name as NSString).deletingPathExtension
    }
    return name.isEmpty ? fileName + " 解压" : name
}

/// 目标已存在时追加 " 2"、" 3"……
func uniqueURL(_ url: URL) -> URL {
    let fm = FileManager.default
    var candidate = url
    var n = 2
    while fm.fileExists(atPath: candidate.path) {
        candidate = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent) \(n)")
        n += 1
    }
    return candidate
}

// MARK: - zip 文件名编码识别（修复中文 zip 乱码）

func le(_ b: [UInt8], _ o: Int, _ n: Int) -> UInt64 {
    var v: UInt64 = 0
    for k in 0..<n { v |= UInt64(b[o + k]) << (8 * UInt64(k)) }
    return v
}

private func cfEncoding(_ e: CFStringEncodings) -> String.Encoding {
    String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(e.rawValue)))
}

/// 读取 zip 中央目录，找出「没有 UTF-8 标记、含非 ASCII 字节」的文件名。
/// 它们若不是合法 UTF-8，就依次尝试 GB18030 / Big5 / Shift-JIS / EUC-KR，返回能完整解码的字符集（iconv 名）。
/// 无需处理（纯 ASCII、已是 UTF-8、读取失败）时返回 nil。
func detectZipCharset(_ url: URL) -> String? {
    guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? fh.close() }
    guard let size = try? fh.seekToEnd(), size >= 22 else { return nil }

    let tailLen = min(size, 65_557)
    guard (try? fh.seek(toOffset: size - tailLen)) != nil,
          let tailData = try? fh.read(upToCount: Int(tailLen)) else { return nil }
    let tail = [UInt8](tailData)

    var eocd = -1
    var i = tail.count - 22
    while i >= 0 {
        if tail[i] == 0x50, tail[i + 1] == 0x4B, tail[i + 2] == 5, tail[i + 3] == 6 { eocd = i; break }
        i -= 1
    }
    guard eocd >= 0 else { return nil }

    var cdSize = le(tail, eocd + 12, 4)
    var cdOffset = le(tail, eocd + 16, 4)
    if cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
        // zip64：EOCD 前 20 字节是 zip64 定位记录
        let loc = eocd - 20
        guard loc >= 0, le(tail, loc, 4) == 0x0706_4b50 else { return nil }
        guard (try? fh.seek(toOffset: le(tail, loc + 8, 8))) != nil,
              let recData = try? fh.read(upToCount: 56), recData.count >= 56 else { return nil }
        let rec = [UInt8](recData)
        guard le(rec, 0, 4) == 0x0606_4b50 else { return nil }
        cdSize = le(rec, 40, 8)
        cdOffset = le(rec, 48, 8)
    }
    guard cdSize > 0, cdSize <= 256 << 20,
          (try? fh.seek(toOffset: cdOffset)) != nil,
          let cdData = try? fh.read(upToCount: Int(cdSize)) else { return nil }
    let cd = [UInt8](cdData)

    var names: [Data] = []
    var pos = 0
    while pos + 46 <= cd.count, le(cd, pos, 4) == 0x0201_4b50 {
        let flags = le(cd, pos + 8, 2)
        let nameLen = Int(le(cd, pos + 28, 2))
        let extraLen = Int(le(cd, pos + 30, 2))
        let commentLen = Int(le(cd, pos + 32, 2))
        guard pos + 46 + nameLen <= cd.count else { break }
        let name = cd[(pos + 46)..<(pos + 46 + nameLen)]
        if flags & 0x800 == 0, name.contains(where: { $0 >= 0x80 }), names.count < 500 {
            names.append(Data(name))
        }
        pos += 46 + nameLen + extraLen + commentLen
    }
    guard !names.isEmpty else { return nil }
    if names.allSatisfy({ String(data: $0, encoding: .utf8) != nil }) { return nil }

    let candidates: [(String.Encoding, String)] = [
        (cfEncoding(.GB_18030_2000), "GB18030"),
        (cfEncoding(.big5), "BIG5"),
        (.shiftJIS, "SHIFT_JIS"),
        (cfEncoding(.EUC_KR), "EUC-KR"),
    ]
    for (encoding, iconvName) in candidates where names.allSatisfy({ String(data: $0, encoding: encoding) != nil }) {
        return iconvName
    }
    return nil
}

// MARK: - 解压

func runBsdtar(archive: URL, into dir: URL, password: String?, charset: String?) throws {
    var args = ["-xf", archive.path, "-C", dir.path, "--exclude", "__MACOSX", "--exclude", ".DS_Store"]
    if let charset { args += ["--options", "hdrcharset=\(charset)"] }
    if let password { args += ["--passphrase", password] }

    let process = Process()
    process.executableURL = bsdtar
    process.arguments = args
    // 从图形界面启动时没有 locale，bsdtar 写中文文件名会失败
    var env = ProcessInfo.processInfo.environment
    env["LC_ALL"] = "en_US.UTF-8"
    process.environment = env
    let stderr = Pipe()
    process.standardError = stderr
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    let output = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus != 0 else { return }

    let text = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if text.lowercased().contains("passphrase") {
        throw Failure.password(wrong: password != nil)
    }
    throw Failure.message(text.isEmpty ? "bsdtar 退出码 \(process.terminationStatus)" : text)
}

/// 解压一次。先解到压缩包旁边的隐藏临时目录（同一磁盘，移动是瞬间完成的），成功后再改名，失败不留半成品。
func extractOnce(_ archive: URL, password: String?, charset: String?) throws -> URL {
    let fm = FileManager.default
    let parent = archive.deletingLastPathComponent()
    let name = folderName(for: archive.lastPathComponent)
    let tmp = parent.appendingPathComponent(".unzipclick-\(UUID().uuidString.prefix(8))")
    try fm.createDirectory(at: tmp, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: tmp) }

    try runBsdtar(archive: archive, into: tmp, password: password, charset: charset)

    // 防 tarbomb：
    //  - 顶层只有一个文件夹：直接放到压缩包旁边，沿用它自己的名字（不会出现 aaaa/aaaa/ 套娃）
    //  - 顶层是多个文件，或单个文件：新建与压缩包同名的文件夹，把内容放进去
    let items = try fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: [.isDirectoryKey])
    if items.count == 1, (try? items[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
        let destination = uniqueURL(parent.appendingPathComponent(items[0].lastPathComponent))
        try fm.moveItem(at: items[0], to: destination)
        return destination
    }

    let destination = uniqueURL(parent.appendingPathComponent(name))
    try fm.moveItem(at: tmp, to: destination)
    return destination
}

/// 弹窗询问密码（在主线程），取消或留空返回 nil。
func askPassword(for name: String, wrong: Bool) -> String? {
    var result: String?
    DispatchQueue.main.sync {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = wrong ? "密码不正确" : "「\(name)」需要密码"
        alert.informativeText = "请输入解压密码："
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "解压")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty {
            result = field.stringValue
        }
    }
    return result
}

/// 解压一个压缩包，必要时自动选文件名编码、询问密码。返回最终生成的文件夹。
func extract(_ archive: URL) throws -> URL {
    let isZip = archive.pathExtension.lowercased() == "zip"
    var charset = isZip ? detectZipCharset(archive) : nil
    var password: String?
    while true {
        do {
            return try extractOnce(archive, password: password, charset: charset)
        } catch Failure.password(let wrong) {
            guard let entered = askPassword(for: archive.lastPathComponent, wrong: wrong) else {
                throw ExtractError(archive: archive.lastPathComponent, message: "已取消（需要密码）")
            }
            password = entered
        } catch Failure.message(let text) {
            if charset != nil {
                charset = nil   // 指定编码失败时退回默认行为再试一次
                continue
            }
            throw ExtractError(archive: archive.lastPathComponent, message: text)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let worker = DispatchQueue(label: "unzipclick.extract")
    private var received = false
    private var running = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 直接打开 App（没带文件）时给个提示，然后退出
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            guard !received else { return }
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "UnzipClick"
            alert.informativeText = "把它设为压缩包的默认打开方式后双击压缩包即可解压；也可以在 Finder 里选中文件，右键 → 快速操作 → UnzipClick 解压。"
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        received = true
        running += 1
        worker.async { [self] in
            var done: [URL] = []
            var errors: [String] = []
            for url in urls {
                do {
                    done.append(try extract(url))
                } catch let error as ExtractError {
                    errors.append("\(error.archive)：\(error.message)")
                } catch {
                    errors.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async { [self] in
                finish(done: done, errors: errors)
            }
        }
    }

    private func finish(done: [URL], errors: [String]) {
        if !done.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(done)
        }
        if !errors.isEmpty {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "有 \(errors.count) 个文件解压失败"
            alert.informativeText = errors.joined(separator: "\n")
            alert.runModal()
        }
        running -= 1
        if running == 0 {
            NSApp.terminate(nil)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
