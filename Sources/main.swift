import AppKit

// UnzipClick: 双击 / 右键快速操作 -> 解压到「压缩包同名文件夹」。
// 解压引擎用系统自带的 /usr/bin/bsdtar（libarchive），支持 zip、tar.*、7z、rar、xz、zst 等。

struct ExtractError: Error {
    let archive: String
    let message: String
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

func runBsdtar(archive: URL, into dir: URL) throws {
    let process = Process()
    process.executableURL = bsdtar
    process.arguments = [
        "-xf", archive.path,
        "-C", dir.path,
        "--exclude", "__MACOSX",
        "--exclude", ".DS_Store",
    ]
    let stderr = Pipe()
    process.standardError = stderr
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    let output = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        let text = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw ExtractError(archive: archive.lastPathComponent,
                           message: text.isEmpty ? "bsdtar 退出码 \(process.terminationStatus)" : text)
    }
}

/// 解压一个压缩包，返回最终生成的文件夹。
/// 先解到压缩包旁边的隐藏临时目录（同一磁盘，移动是瞬间完成的），成功后再改名，失败不留半成品。
func extract(_ archive: URL) throws -> URL {
    let fm = FileManager.default
    let parent = archive.deletingLastPathComponent()
    let name = folderName(for: archive.lastPathComponent)
    let tmp = parent.appendingPathComponent(".unzipclick-\(UUID().uuidString.prefix(8))")
    try fm.createDirectory(at: tmp, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: tmp) }

    try runBsdtar(archive: archive, into: tmp)

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
