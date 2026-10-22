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
    case cancelled
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

// MARK: - 进度

/// 一次压缩包的解压任务：持有 bsdtar 进程（用于取消）和进度回调。
final class Job {
    private let lock = NSLock()
    private var _process: Process?
    private var _cancelled = false
    /// 参数：已读压缩包字节数、压缩包总字节数（任意线程调用）
    var report: (UInt64, UInt64) -> Void = { _, _ in }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }

    func attach(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        _process = process
    }

    func cancel() {
        lock.lock()
        _cancelled = true
        let process = _process
        lock.unlock()
        process?.terminate()
    }
}

/// 读取 bsdtar 进程里「压缩包那个文件描述符」当前的读取位置，用它当进度。
/// 通过 libproc 找到 inode 和大小都与压缩包一致的 vnode fd，取 fi_offset。拿不到时返回 nil。
func archiveReadOffset(pid: pid_t, size: UInt64, inode: UInt64) -> UInt64? {
    let listSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard listSize > 0 else { return nil }
    let capacity = Int(listSize) / MemoryLayout<proc_fdinfo>.stride + 8
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
    let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(capacity * MemoryLayout<proc_fdinfo>.stride))
    guard got > 0 else { return nil }
    let count = Int(got) / MemoryLayout<proc_fdinfo>.stride

    for fd in fds.prefix(count) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
        var info = vnode_fdinfo()
        let want = Int32(MemoryLayout<vnode_fdinfo>.size)
        let r = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEINFO, &info, want)
        if r == want,
           UInt64(info.pvi.vi_stat.vst_size) == size,
           UInt64(info.pvi.vi_stat.vst_ino) == inode {
            return UInt64(max(0, info.pfi.fi_offset))
        }
    }
    return nil
}

/// 解压进度窗口：任务超过 0.8 秒才弹出，避免小文件一闪而过。
final class ProgressWindow {
    var onCancel: () -> Void = {}

    private let window: NSWindow
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private var token = 0
    private var startedAt = Date()

    init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 130),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "UnzipClick"
        window.isReleasedWhenClosed = false

        titleLabel.font = .boldSystemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 1
        bar.isIndeterminate = true

        let cancel = NSButton(title: "取消", target: nil, action: nil)
        cancel.target = self
        cancel.action = #selector(cancelTapped)
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let buttonRow = NSStackView(views: [spacer, cancel])
        buttonRow.orientation = .horizontal
        buttonRow.distribution = .fill

        let stack = NSStackView(views: [titleLabel, bar, detailLabel, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 14, right: 16)
        for view in [titleLabel, bar, detailLabel, buttonRow] {
            view.widthAnchor.constraint(equalToConstant: 388).isActive = true
        }
        window.contentView = stack
        window.setContentSize(stack.fittingSize)
    }

    @objc private func cancelTapped() {
        detailLabel.stringValue = "正在取消…"
        onCancel()
    }

    func begin(name: String, index: Int, total: Int) {
        token += 1
        let mine = token
        startedAt = Date()
        titleLabel.stringValue = total > 1 ? "正在解压（\(index)/\(total)）：\(name)" : "正在解压：\(name)"
        detailLabel.stringValue = "准备中…"
        bar.isIndeterminate = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
            guard token == mine else { return }
            window.center()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            if bar.isIndeterminate { bar.startAnimation(nil) }
        }
    }

    func update(read: UInt64, total: UInt64) {
        guard total > 0 else { return }
        let fraction = min(1, Double(read) / Double(total))
        if bar.isIndeterminate {
            bar.stopAnimation(nil)
            bar.isIndeterminate = false
        }
        bar.doubleValue = fraction
        let fmt = { (n: UInt64) in ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }
        var text = "\(fmt(read)) / \(fmt(total))（\(Int(fraction * 100))%）"
        let elapsed = Date().timeIntervalSince(startedAt)
        if elapsed > 3, fraction > 0.02, fraction < 1 {
            let remaining = Int(elapsed * (1 - fraction) / fraction)
            text += remaining < 60 ? " · 剩余约 \(remaining) 秒" : " · 剩余约 \((remaining + 59) / 60) 分钟"
        }
        detailLabel.stringValue = text
    }

    func end() {
        token += 1
        window.orderOut(nil)
    }
}

func runBsdtar(archive: URL, into dir: URL, password: String?, charset: String?, job: Job) throws {
    if job.isCancelled { throw Failure.cancelled }
    var args = ["-xf", archive.path, "-C", dir.path, "--exclude", "__MACOSX", "--exclude", ".DS_Store"]
    if let charset { args += ["--options", "hdrcharset=\(charset)"] }
    if let password { args += ["--passphrase", password] }

    let process = Process()
    process.executableURL = bsdtar
    process.arguments = args
    // 从图形界面启动时没有 locale，bsdtar 写中文文件名会失败
    var env = ProcessInfo.processInfo.environment
    env["LC_ALL"] = "en_US.UTF-8"
    // 把 App 内置的 zstd 解压器放进 PATH（老系统的 bsdtar 解 zstd 要调外部 zstd 程序）
    if let bin = Bundle.main.resourceURL?.appendingPathComponent("bin").path {
        env["PATH"] = bin + ":" + (env["PATH"] ?? "/usr/bin:/bin")
    }
    process.environment = env
    let stderr = Pipe()
    process.standardError = stderr
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    job.attach(process)
    if job.isCancelled { process.terminate() }

    // 定时读取 bsdtar 读压缩包的位置作为进度；zip / 7z 一开始会先跳到末尾读目录，所以前 0.5 秒不上报
    let attrs = try? FileManager.default.attributesOfItem(atPath: archive.path)
    let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
    let inode = (attrs?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    timer.schedule(deadline: .now() + 0.5, repeating: 0.25)
    timer.setEventHandler {
        if let offset = archiveReadOffset(pid: process.processIdentifier, size: size, inode: inode) {
            job.report(offset, size)
        }
    }
    timer.resume()

    let output = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    timer.cancel()
    if job.isCancelled { throw Failure.cancelled }
    guard process.terminationStatus != 0 else { return }

    let text = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if text.lowercased().contains("passphrase") {
        throw Failure.password(wrong: password != nil)
    }
    throw Failure.message(text.isEmpty ? "bsdtar 退出码 \(process.terminationStatus)" : text)
}

/// 解压一次。先解到压缩包旁边的隐藏临时目录（同一磁盘，移动是瞬间完成的），成功后再改名，失败不留半成品。
func extractOnce(_ archive: URL, password: String?, charset: String?, job: Job) throws -> URL {
    let fm = FileManager.default
    let parent = archive.deletingLastPathComponent()
    let name = folderName(for: archive.lastPathComponent)
    let tmp = parent.appendingPathComponent(".unzipclick-\(UUID().uuidString.prefix(8))")
    try fm.createDirectory(at: tmp, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: tmp) }

    try runBsdtar(archive: archive, into: tmp, password: password, charset: charset, job: job)

    // 防 tarbomb：
    //  - 顶层只有一个条目（文件或文件夹）：直接放到压缩包旁边，沿用它自己的名字
    //  - 顶层有多个条目：新建与压缩包同名的文件夹，把内容放进去
    let items = try fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)
    if items.count == 1 {
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
func extract(_ archive: URL, job: Job) throws -> URL {
    let isZip = archive.pathExtension.lowercased() == "zip"
    var charset = isZip ? detectZipCharset(archive) : nil
    var password: String?
    while true {
        do {
            return try extractOnce(archive, password: password, charset: charset, job: job)
        } catch Failure.password(let wrong) {
            guard let entered = askPassword(for: archive.lastPathComponent, wrong: wrong) else {
                throw ExtractError(archive: archive.lastPathComponent, message: "已取消（需要密码）")
            }
            password = entered
        } catch Failure.cancelled {
            throw ExtractError(archive: archive.lastPathComponent, message: "已取消")
        } catch Failure.message(let text) {
            if charset != nil {
                charset = nil   // 指定编码失败时退回默认行为再试一次
                continue
            }
            throw ExtractError(archive: archive.lastPathComponent, message: text)
        }
    }
}

/// 追加写入 ~/Library/Logs/UnzipClick.log，方便排查「Finder 打开却没反应」这类问题
func uzLog(_ message: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/UnzipClick.log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) [\(getpid())] \(message)\n"
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? Data(line.utf8).write(to: url)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let worker = DispatchQueue(label: "unzipclick.extract")
    private var received = false
    private var running = 0
    private var lastBatch: (urls: Set<URL>, time: Date)?
    private let progressUI = ProgressWindow()
    private var currentJob: Job?   // 仅主线程访问

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 直接接管「打开文档」Apple Event。Finder 走这条路径时，AppKit 默认处理有时会因为
        // 「没有窗口」而判定打开失败并直接退出，根本不会调用 application(_:open:)。
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenDocuments(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments))
        progressUI.onCancel = { [weak self] in self?.currentJob?.cancel() }
        uzLog("willFinishLaunching")
    }

    @objc func handleOpenDocuments(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        var urls: [URL] = []
        if let direct = event.paramDescriptor(forKeyword: keyDirectObject) {
            if direct.numberOfItems > 0 {
                for i in 1...direct.numberOfItems {
                    if let url = direct.atIndex(i)?.fileURLValue { urls.append(url) }
                }
            } else if let url = direct.fileURLValue {
                urls.append(url)
            }
        }
        uzLog("odoc event: \(urls.map(\.path))")
        handle(urls)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        uzLog("didFinishLaunching")
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
        uzLog("open urls: \(urls.map(\.path))")
        handle(urls)
    }

    private func handle(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        // 两条路径万一都触发了，2 秒内相同的一批文件只处理一次
        let batch = Set(urls)
        if let last = lastBatch, last.urls == batch, Date().timeIntervalSince(last.time) < 2 { return }
        lastBatch = (batch, Date())

        received = true
        running += 1
        worker.async { [self] in
            var done: [URL] = []
            var errors: [String] = []
            for (index, url) in urls.enumerated() {
                let job = Job()
                job.report = { [weak self] read, total in
                    DispatchQueue.main.async { self?.progressUI.update(read: read, total: total) }
                }
                DispatchQueue.main.async { [self] in
                    currentJob = job
                    progressUI.begin(name: url.lastPathComponent, index: index + 1, total: urls.count)
                }
                do {
                    done.append(try extract(url, job: job))
                } catch let error as ExtractError {
                    if !job.isCancelled { errors.append("\(error.archive)：\(error.message)") }
                } catch {
                    errors.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                }
                DispatchQueue.main.async { [self] in
                    progressUI.end()
                }
                if job.isCancelled { break }   // 取消后跳过剩下的压缩包
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
