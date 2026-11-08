// 访达右键「压缩 ▸ ZIP、7Z」「解压到这里」（2026-11-08 右键扩充第 2 批，拍板 D1 D2）。都交给系统自带的 tar（bsdtar；另起进程，
// 不卡主线程、停得住），不带第三方：
// - 压缩：一样东西叫「名字.zip」，几样叫「归档.zip」（同访达），放在第一样所在的文件夹、重名加「 2」。zip 里的名字标上 UTF-8
//   （zip:hdrcharset=UTF-8；访达和 ditto 打的不标，别的系统解开中文名会乱码，2026-11-08 实测），不带 __MACOSX、._*、.DS_Store
//   （--no-mac-metadata 加排除）；7z 用 LZMA2。只选了一个包（App 这类）时 zip 改用 ditto（同访达的压缩：带着扩展属性，
//   签名不坏）。不同文件夹里的同名东西包里只放得下一个，不打。不做带密码的压缩（拍板）。
// - 解压：zip、7z、tar 一族（.tar、.tar.gz / .tgz、.tar.xz / .txz、.tar.bz2 / .tbz）。zip 先读一遍中央目录（ZipNames）：
//   没标 UTF-8、名字又不是合法 UTF-8 的按 GB18030 解（不说的话 tar 直接报错，ditto 解出来是乱码，实测）；有加密的条目先问密码
//   （tar 认 ZipCrypto 和 AES；不对再问）：本 App 不在前台时先在刘海岛说「有密码」带「输入密码…」，点了再弹框——直接弹的框
//   拿不到键盘，打的字会进访达。先解进包旁边一个隐藏的临时文件夹，里面只有一样东西就把它放到包旁边，几样就把
//   临时文件夹改成包的名字（同归档实用工具），重名加「 2」；出错、停了只删临时文件夹。包带着「从网上下载」的隔离标记时，
//   系统 tar 自己会给解出来的每样东西也带上（实测），不另外做；它默认也不解绝对路径、带 .. 的路径，不顺着包里的符号链接往外写。
// - 落到正式名字都用「目标已存在就报错」的改名（FileMoves.land），算完名字到落下之间别人占了也盖不掉；和移动、复制排在同一条队
//   （FileMoves.enqueue）：超过 1 秒在刘海岛上挂「正在…」带「停止」，做完说一声、带「在访达中显示」。
// 名字、tar 的参数、出错原因是纯函数（ArchivesTests，另在临时文件夹里真压、真解一遍）。
// ponytail: 读 zip 的中央目录在主线程上（几万条的包要几十毫秒，在卡住的网络盘上会跟着卡）；真遇到再挪到主线程外。
// ponytail: zip 的密码放在 tar 的命令行上（--passphrase，本机同一个用户的进程用 ps 看得到）：tar 只认它和终端输入。

import AppKit

@MainActor enum Archives {
  nonisolated enum Format: String {
    case zip
    case sevenZip = "7z"
  }

  /// 一次的结果
  nonisolated enum Outcome: Equatable {
    case done(URL)
    case stopped
    /// 没给密码，tar 说要（中央目录没读出来加密的条目时）
    case needsPassword
    case wrongPassword
    case failed(String)
  }

  // MARK: 名字和参数（纯函数）

  /// 「解压到这里」认的（扩展里抄了一份，FinderLinkTests 比对）
  nonisolated static let suffixes = [
    ".zip", ".7z", ".tar", ".tar.gz", ".tgz", ".tar.xz", ".txz", ".tar.bz2", ".tbz", ".tbz2",
  ]

  /// 认得的扩展名里最长的那个（.tar.gz 不当成 .gz）；光有扩展名、前面没名字的不算
  nonisolated static func suffix(of url: URL) -> String? {
    let name = url.lastPathComponent.lowercased()
    return suffixes.filter { name.hasSuffix($0) && name.count > $0.count }
      .max { $0.count < $1.count }
  }

  nonisolated static func isArchive(_ url: URL) -> Bool { suffix(of: url) != nil }

  /// 解出来的文件夹叫什么：去掉扩展名（.tar.gz 整个去掉）
  nonisolated static func stem(of archive: URL) -> String {
    let name = archive.lastPathComponent
    guard let suffix = suffix(of: archive) else { return name }
    return String(name.dropLast(suffix.count))
  }

  /// 打出来的包叫什么：一样东西用它的名字，几样叫「归档」（同访达）。名字太长的截短：加上扩展名、重名时的「 99」
  /// 还在 255 字节以内（不然白打完一整包、落不下来）
  nonisolated static func archiveName(for items: [URL], format: Format) -> String {
    var base = items.count == 1 ? items[0].lastPathComponent : "归档"
    while (base + " 99." + format.rawValue).utf8.count > 255 { base.removeLast() }
    return base + "." + format.rawValue
  }

  /// 同名的（不分大小写、统一合成形式：解到 Mac 上会撞）第一个：包里只放得下一个
  nonisolated static func clash(in items: [URL]) -> String? {
    var seen = Set<String>()
    return items.first {
      !seen.insert($0.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()).inserted
    }?.lastPathComponent
  }

  /// 打包、解包都不要的 Mac 杂文件
  nonisolated static let junk = ["__MACOSX", "._*", ".DS_Store"]

  /// 压缩用 tar 的参数：按所在的文件夹分组，每组先「-C 文件夹」，再跟「./名字」（./ 开头的名字不会被当成选项，-s 再把它去掉；
  /// S：符号链接指向哪里不改）
  nonisolated static func compressArguments(_ items: [URL], format: Format, to archive: URL)
    -> [String]
  {
    var arguments = [
      "-c", "-f", archive.path(percentEncoded: false), "--format", format == .zip ? "zip" : "7zip",
      "--options", format == .zip ? "zip:hdrcharset=UTF-8" : "7zip:compression=lzma2",
      "--no-mac-metadata", "-s", "|^\\./||S",
    ]
    arguments += junk.flatMap { ["--exclude", $0] }
    var folder: String?
    for item in items {
      let parent = (FileMoves.plainPath(item) as NSString).deletingLastPathComponent
      if parent != folder {
        arguments += ["-C", parent]
        folder = parent
      }
      arguments.append("./" + item.lastPathComponent)
    }
    return arguments
  }

  /// 解压用 tar 的参数。没有密码也给一个：不给的话碰到加了密的条目，tar 从标准输入问、读到空的也一遍遍问
  nonisolated static func extractArguments(
    _ archive: URL, into folder: URL, gbk: Bool, password: String?
  ) -> [String] {
    var arguments = [
      "-x", "-f", archive.path(percentEncoded: false), "-C", folder.path(percentEncoded: false),
      "--passphrase", password ?? "kitty-no-password",
    ]
    if gbk { arguments += ["--options", "hdrcharset=GB18030"] }
    return arguments + junk.flatMap { ["--exclude", $0] }
  }

  /// 空间、权限这类和包本身无关的原因（压缩、解压都用）
  nonisolated static func placeProblem(_ error: String) -> String? {
    let known = [
      ("No space left", "磁盘空间不够了"),
      ("Read-only file system", "这个位置是只读的"),
      ("Operation not permitted", "没有权限读写这个位置"),
      ("Permission denied", "没有权限读写这个位置"),
    ]
    return known.first { error.localizedCaseInsensitiveContains($0.0) }?.1
  }

  /// 解压失败，给人看的原因（tar 的标准错误里认得的说成中文）。password：给过密码——这时报「密码不对」，或者数据校验不对、
  /// 解不开（ZipCrypto 只校验一个字节，错的密码有 1/256 混过校验、解到一半才报这些，Kitty Box 实测）都算密码不对；
  /// 包不完整、不是压缩包这类照实说，不然输对了密码也一遍遍问
  nonisolated static func outcome(ofFailure error: String, password: Bool) -> Outcome {
    if let problem = placeProblem(error) { return .failed(problem) }
    if error.contains("Incorrect passphrase") { return password ? .wrongPassword : .needsPassword }
    if password,
      ["bad CRC", "decompression failed"].contains(where: error.localizedCaseInsensitiveContains)
    {
      return .wrongPassword
    }
    let damaged = [
      ("ncrypt", "这个包加了密码，这里只解得开 zip 的密码"),
      ("runcated", "压缩包不完整，可能没下载完"),
      ("nexpected end", "压缩包不完整，可能没下载完"),
      ("Unrecognized archive format", "不是压缩包，或者是不支持的格式"),
    ]
    return .failed(
      damaged.first { error.localizedCaseInsensitiveContains($0.0) }?.1 ?? "压缩包可能坏了")
  }

  // MARK: 压缩

  /// 打一个包：先写到 archive 旁边的隐藏临时名，打完落到 archive（重名换「 2」）
  static func pack(_ items: [URL], format: Format, to archive: URL) async -> Outcome {
    let temporary = FileMoves.temporary(in: archive.deletingLastPathComponent())
    let package =
      format == .zip && items.count == 1
      && (try? items[0].resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
    let result =
      package
      ? try? await Subprocess.run(
        "/usr/bin/ditto",
        [
          "-c", "-k", "--sequesterRsrc", "--keepParent", items[0].path(percentEncoded: false),
          temporary.path(percentEncoded: false),
        ], captures: true, quality: .userInitiated, stopsOnCancel: true)
      : try? await Subprocess.run(
        "/usr/bin/tar", compressArguments(items, format: format, to: temporary), captures: true,
        quality: .userInitiated, stopsOnCancel: true)
    let failure: Outcome
    if Task.isCancelled {
      failure = .stopped
    } else if let result, result.status != 0 {
      failure = .failed(placeProblem(result.error) ?? "有文件读不到（被移走、改名了，或者没有权限）")
    } else if result == nil {
      failure = .failed("系统的工具没能运行")
    } else if let placed = FileMoves.land(temporary, at: archive) {
      FileMoves.release(temporary)
      return .done(placed)
    } else {
      failure = .failed("没能放到旁边")
    }
    await FileMoves.discard(temporary)
    return failure
  }

  static func compress(_ files: [URL], format: Format, island: Island?) {
    var items: [URL] = []
    for file in files where FileMoves.occupied(file) {
      let path = FileMoves.plainPath(file)
      if !items.contains(where: { FileMoves.plainPath($0) == path }) { items.append(file) }
    }
    guard let first = items.first else {
      NSSound.beep()
      return
    }
    if let name = clash(in: items) {
      island?.show(
        "没有压缩", detail: "「\(name)」有不止一个（在不同的文件夹里），包里只放得下一个", tone: .warning)
      return
    }
    let folder = URL(
      filePath: (FileMoves.plainPath(first) as NSString).deletingLastPathComponent,
      directoryHint: .isDirectory)
    let name = archiveName(for: items, format: format)
    FileMoves.enqueue(
      "正在压缩 \(items.count) 项…", detail: "打成「\(name)」", island: island
    ) {
      await pack(
        items, format: format,
        to: folder.appending(path: FileMoves.freeName(name, in: folder, used: [])))
    } finish: { outcome in
      report(outcome, verb: "压缩", island: island)
    }
  }

  // MARK: 解压

  /// 解一个包到它旁边
  static func unpack(_ archive: URL, password: String?, gbk: Bool) async -> Outcome {
    let manager = FileManager.default
    let parent = archive.deletingLastPathComponent()
    let work = FileMoves.temporary(in: parent)
    guard (try? manager.createDirectory(at: work, withIntermediateDirectories: false)) != nil else {
      FileMoves.release(work)
      return .failed("没有权限写这个位置")
    }
    let result = try? await Subprocess.run(
      "/usr/bin/tar", extractArguments(archive, into: work, gbk: gbk, password: password),
      captures: true, quality: .userInitiated, stopsOnCancel: true)
    let failure: Outcome
    if Task.isCancelled {
      failure = .stopped
    } else if let result, result.status != 0 {
      failure = outcome(ofFailure: result.error, password: password != nil)
    } else if result == nil {
      failure = .failed("系统的工具没能运行")
    } else if let placed = settle(work, stem: stem(of: archive), in: parent) {
      FileMoves.release(work)
      return .done(placed)
    } else {
      failure = .failed("没能放到压缩包旁边")
    }
    await FileMoves.discard(work)
    return failure
  }

  /// 解好之后：里面只有一样东西（不是隐藏的、不是符号链接：放出来访达里看不见，还会悄悄落在包旁边起作用）就把它放到包旁边，
  /// 不然把临时文件夹改成包的名字；重名加「 2」
  static func settle(_ work: URL, stem: String, in parent: URL) -> URL? {
    let manager = FileManager.default
    guard let children = try? manager.contentsOfDirectory(atPath: work.path(percentEncoded: false))
    else { return nil }
    if children.count == 1, !children[0].hasPrefix("."),
      (try? manager.destinationOfSymbolicLink(
        atPath: work.appending(path: children[0]).path(percentEncoded: false))) == nil,
      let placed = FileMoves.land(
        work.appending(path: children[0]),
        at: parent.appending(path: FileMoves.freeName(children[0], in: parent, used: [])))
    {
      try? manager.removeItem(at: work)
      return placed
    }
    return FileMoves.land(
      work, at: parent.appending(path: FileMoves.freeName(stem, in: parent, used: [])))
  }

  static func extract(_ files: [URL], island: Island?) {
    let archives = files.filter { isArchive($0) && FileMoves.occupied($0) }
    guard !archives.isEmpty else {
      NSSound.beep()
      return
    }
    for archive in archives { extract(archive, retry: nil, island: island) }
  }

  /// 排一个包进队。有加密条目的 zip 先问密码（排队之前问：框开着的时候别挂「正在解压」）。retry：上一回 tar 说要密码
  /// （needsPassword：中央目录没读出来，包前面多了一截这种）或者密码不对——这时不管认没认出来都问，每一回都要用户点，
  /// 取消就停（评审：不问就重排会一直转下去、把队堵死）
  private static func extract(
    _ archive: URL, retry: Outcome?, island: Island?, askNow: Bool = false
  ) {
    var password: String?
    var gbk = false
    var encrypted = retry != nil
    if ZipNames.isZip(archive), let entries = ZipNames.entries(of: archive) {
      gbk = ZipNames.charset(for: entries) == .gb18030
      encrypted = encrypted || entries.contains(where: \.encrypted)
    }
    // 本 App 不在前台时直接弹的框拿不到键盘（打的字进了访达，评审）：先在刘海岛说一声，点了按钮（点的是本 App）再弹
    if encrypted, !askNow, let island, !NSApp.isActive {
      island.show(
        retry == .wrongPassword ? "密码不对" : "「\(archive.lastPathComponent)」有密码",
        detail: "点「输入密码」再解压", tone: .info,
        actions: [
          Island.Action("输入密码…") {
            extract(archive, retry: retry, island: island, askNow: true)
          }
        ])
      return
    }
    if encrypted {
      guard let given = askPassword(for: archive, wrong: retry == .wrongPassword) else {
        // 重问时取消了：「正在解压」那一条可能还挂着，换成一句
        if retry != nil { island?.show("没有解压", detail: archive.lastPathComponent, tone: .info) }
        return
      }
      password = given
    }
    FileMoves.enqueue("正在解压「\(archive.lastPathComponent)」…", island: island) {
      await unpack(archive, password: password, gbk: gbk)
    } finish: { outcome in
      if outcome == .wrongPassword || outcome == .needsPassword {
        // 这一批先收尾，再另起一个去问：框开着的时候别堵住后面排着的
        Task { extract(archive, retry: outcome, island: island) }
      } else {
        report(outcome, verb: "解压", island: island)
      }
    }
  }

  /// 问 zip 的密码；取消、空着、已经开着一个框是 nil
  private static func askPassword(for archive: URL, wrong: Bool) -> String? {
    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
    let alert = NSAlert()
    alert.messageText = wrong ? "密码不对，再输一次" : "「\(archive.lastPathComponent)」有密码"
    alert.informativeText = "输入解压的密码。"
    alert.addButton(withTitle: "解压")
    // Esc = 取消
    alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
    alert.accessoryView = field
    guard FinderLink.ask(alert, focus: field) == .alertFirstButtonReturn,
      !field.stringValue.isEmpty
    else { return nil }
    return field.stringValue
  }

  // MARK: 说一声

  private static func report(_ outcome: Outcome, verb: String, island: Island?) {
    switch outcome {
    case .done(let url):
      island?.show(
        verb == "压缩" ? "已压缩" : "已解压", detail: url.lastPathComponent,
        actions: [
          Island.Action("在访达中显示", opens: true) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
          }
        ])
    case .stopped:
      island?.show("已停止\(verb)", tone: .info)
    case .needsPassword, .wrongPassword:
      island?.show("没能\(verb)", detail: "密码不对", tone: .error)
    case .failed(let reason):
      island?.show("没能\(verb)", detail: reason, tone: .error)
    }
  }
}
