// 访达右键整理文件（2026-11-08 右键扩充第 1 批，拍板 C1 C2 C3）：移动到 / 复制到（常用文件夹 + 选择文件夹…）、剪切 / 粘贴、
// 发送替身到桌面。对标几家成熟产品的通行做法，另外守住「不丢用户的东西」（2026-11-08 独立评审后重写）：
// - 不覆盖：叫什么在真正动手时才算（前一批做完之后），重名加「 2」（不分大小写）；落到正式名字那一步用「目标已存在就报错」
//   的改名，算完到落下之间别人占了这个名字也盖不掉，再让一个名字。
// - 同一个卷上移动 = 直接改名（原子的）。跨卷移动、复制 = 先用 ditto 拷到目标文件夹里一个隐藏的临时名，拷完改成正式名字，
//   移动的这时才删原件。「停止」只停拷贝那一步（ditto 是单个进程，停得住），停了、失败了只删临时名——原件、别人的文件都不碰。
//   （不用 mv：它跨卷搬文件夹时另起 cp、rm 两个子进程，停不住，停在 rm 那一步原件和新的都会没，评审 H1。）
// - 符号链接复制的是链接本身（ditto 会顺着链接整棵拷过去）；不许挪进自己里面（解开替身、不分大小写比）；移动时本来就在那里的跳过。
// - 超过 1 秒才在刘海岛上挂「正在…」带「停止」（每一批停自己），做完说一声、带「在访达中显示」。不做撤销（访达的 ⌘Z 管不到）。
// - 剪切：清单只在内存里（偏好里只给扩展留「几项 + 剪贴板 changeCount」，别的程序改偏好也塞不进要搬的东西；App 启动时清掉），
//   同时像 ⌘C 一样把文件放进剪贴板（访达里按 ⌥⌘V 也能移过去）；剪贴板换过了剪切就作废（同 Windows）。
// - 替身：bookmarkData(.suitableForBookmarkFile) + writeBookmarkData，和访达 ⌥⌘ 拖出来的一样，原件挪了也打得开。
// ponytail: 查重名、比卷、改名都在主线程上（快，但目标在卡住的网络盘上会跟着卡）；真遇到再挪到主线程外。

import AppKit

@MainActor enum FileMoves {
  /// 比路径用的写法：标准化、去掉结尾的「/」（文件夹的 URL 带不带它都是同一个）
  nonisolated static func plainPath(_ url: URL) -> String {
    var path = url.standardizedFileURL.path(percentEncoded: false)
    while path.count > 1, path.hasSuffix("/") { path.removeLast() }
    return path
  }

  /// 「~」「~/…」展开成主目录下的（扩展那边同样只认这两种写法）
  nonisolated static func expand(_ path: String, home: String = NSHomeDirectory()) -> String {
    path == "~" || path.hasPrefix("~/") ? home + path.dropFirst() : path
  }

  /// 这个位置上有没有东西（按替身本身看：断了的替身也算占着）
  nonisolated static func occupied(_ url: URL) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))) != nil
  }

  /// 能不能把 file 搬进 folder：不能是它自己或它下面（解开替身、不分大小写比：APFS 默认不分大小写）；移动时本来就在 folder
  /// 里的不搬（复制照样复制一份「 2」，同访达在原地复制）
  nonisolated static func movable(_ file: URL, into folder: URL, move: Bool) -> Bool {
    let source = plainPath(file.resolvingSymlinksInPath()).lowercased()
    let destination = plainPath(folder.resolvingSymlinksInPath()).lowercased()
    if destination == source || destination.hasPrefix(source + "/") { return false }
    let parent = plainPath(file.deletingLastPathComponent().resolvingSymlinksInPath()).lowercased()
    return !move || parent != destination
  }

  /// 在 folder 里给 name 找一个没人用的名字（这一批前面占了的也算，不分大小写）
  nonisolated static func freeName(_ name: String, in folder: URL, used: Set<String>) -> String {
    NewFile.freeName(name) { candidate in
      used.contains(candidate.lowercased()) || occupied(folder.appending(path: candidate))
    }
  }

  /// 两个位置在不在同一个卷上
  nonisolated static func sameVolume(_ a: URL, _ b: URL) -> Bool {
    let volume = { (url: URL) in
      (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
    }
    guard let first = volume(a), let second = volume(b) else { return false }
    return first == second
  }

  /// 搬一样：返回新位置，失败 / 被停是 nil（原件、别人的文件不动，只清掉自己的临时名）
  static func move(_ file: URL, into folder: URL, named name: String, copy: Bool) async -> URL? {
    let manager = FileManager.default
    var target = folder.appending(path: name)
    if !copy, sameVolume(file, folder) {
      // 同一个卷：改名，目标已存在会报错（不覆盖）；撞上了换下一个名字再试一次
      if (try? manager.moveItem(at: file, to: target)) != nil { return target }
      target = folder.appending(path: freeName(name, in: folder, used: []))
      return (try? manager.moveItem(at: file, to: target)) != nil ? target : nil
    }
    // 拷到目标文件夹里的隐藏临时名
    let temporary = folder.appending(path: ".kitty-\(UUID().uuidString)-\(name)")
    let link = (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    if link {
      guard (try? manager.copyItem(at: file, to: temporary)) != nil else { return nil }
    } else {
      let result = try? await Subprocess.run(
        "/usr/bin/ditto",
        [file.path(percentEncoded: false), temporary.path(percentEncoded: false)],
        stopsOnCancel: true)
      guard result?.status == 0, !Task.isCancelled else {
        try? manager.removeItem(at: temporary)
        return nil
      }
    }
    // 落到正式名字：目标已存在就报错；撞上了换一个名字再试一次，还不行就扔掉临时名
    if (try? manager.moveItem(at: temporary, to: target)) == nil {
      target = folder.appending(path: freeName(name, in: folder, used: []))
      guard (try? manager.moveItem(at: temporary, to: target)) != nil else {
        try? manager.removeItem(at: temporary)
        return nil
      }
    }
    // 跨卷移动：新的已经完整落下，这时才删原件（删不掉的照旧留着，新的那份不动）
    if !copy {
      if link {
        try? manager.removeItem(at: file)
      } else {
        _ = try? await Subprocess.run("/bin/rm", ["-rf", "--", file.path(percentEncoded: false)])
      }
    }
    return target
  }

  /// 一批：真正动手时才算名字；被停了就不再开始下一样
  static func execute(_ files: [URL], into folder: URL, move: Bool) async -> (
    done: [URL], failed: Int
  ) {
    var done: [URL] = []
    var failed = 0
    var used = Set<String>()
    for file in files where occupied(file) && movable(file, into: folder, move: move) {
      if Task.isCancelled { break }
      let name = freeName(file.lastPathComponent, in: folder, used: used)
      used.insert(name.lowercased())
      if let target = await self.move(file, into: folder, named: name, copy: !move) {
        done.append(target)
      } else if !Task.isCancelled {
        failed += 1
      }
    }
    return (done, failed)
  }

  /// 一批的任务（「停止」停的是它自己，不是排在后面的那一批）
  private final class Batch {
    var task: Task<Void, Never>?
  }

  /// 最后排进来的那一批（新的一批等它做完再开始）
  private static var last: Task<Void, Never>?

  /// 移动 / 复制到 folder，刘海岛报进度和结果
  static func transfer(_ files: [URL], to folder: URL, move: Bool, island: Island?) {
    guard files.contains(where: { occupied($0) && movable($0, into: folder, move: move) }) else {
      NSSound.beep()
      return
    }
    let verb = move ? "移动" : "复制"
    let place = FileManager.default.displayName(atPath: folder.path(percentEncoded: false))
    let previous = last
    let batch = Batch()
    batch.task = Task {
      await previous?.value
      let outcome = await Island.whenSlow(after: .seconds(1)) {
        island?.show(
          "正在\(verb) \(files.count) 项…", detail: "到「\(place)」", tone: .progress,
          actions: [Island.Action("停止") { batch.task?.cancel() }])
      } work: {
        await execute(files, into: folder, move: move)
      }
      report(outcome, verb: verb, place: place, island: island)
    }
    last = batch.task
  }

  private static func report(
    _ outcome: (done: [URL], failed: Int), verb: String, place: String, island: Island?
  ) {
    let reveal = Island.Action("在访达中显示", opens: true) {
      NSWorkspace.shared.activateFileViewerSelecting(outcome.done)
    }
    switch (outcome.done.isEmpty, outcome.failed) {
    case (true, 0):
      island?.show("已停止\(verb)", tone: .info)
    case (true, _):
      island?.show("没能\(verb)到「\(place)」", detail: "可能是没有权限，或者那里放不下", tone: .error)
    case (false, 0):
      island?.show(
        (verb == "移动" ? "已移到" : "已复制到") + "「\(place)」",
        detail: outcome.done.count == 1
          ? outcome.done[0].lastPathComponent : "\(outcome.done.count) 项",
        actions: [reveal])
    case (false, let failed):
      island?.show(
        "\(verb)了 \(outcome.done.count) 项，\(failed) 项没成", detail: "到「\(place)」", tone: .warning,
        actions: [reveal])
    }
  }

  /// 「选择文件夹…」：弹选文件夹的面板（照 FilePanel：本 App 不在前台时也开在最上面），选好再搬
  static func chooseAndTransfer(_ files: [URL], move: Bool, island: Island?) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = move ? "移到这里" : "复制到这里"
    panel.message =
      move ? "把选中的 \(files.count) 项移到哪个文件夹" : "把选中的 \(files.count) 项复制到哪个文件夹"
    Task {
      guard await FilePanel.begin(panel) == .OK, let folder = panel.url else { return }
      transfer(files, to: folder, move: move, island: island)
    }
  }

  // MARK: 常用文件夹

  /// 设置里的常用文件夹（偏好里存 ~ 开头的写法），展开成真的位置。这台电脑自己的、不注册默认值（同截图的存储文件夹：
  /// 别人给的设置文件不该能往右键菜单里加一个文件夹）
  static var folders: [URL] {
    (UserDefaults.standard.stringArray(forKey: Prefs.finderTransferFolders)
      ?? Prefs.finderTransferDefault)
      .map { URL(filePath: expand($0), directoryHint: .isDirectory) }
  }

  // MARK: 剪切 / 粘贴

  /// 剪切了哪几样、那一刻剪贴板的 changeCount（只在内存里）
  private static var cutList: [URL] = []
  private static var cutChange: Int?

  static func cut(_ files: [URL], island: Island?) {
    Paster.write(files: files)
    cutList = files
    let change = NSPasteboard.general.changeCount
    cutChange = change
    // 偏好里只给扩展留「几项 + changeCount」，它看剪贴板没换过才列「粘贴 N 项」
    let defaults = UserDefaults.standard
    defaults.set(files.count, forKey: Prefs.finderCutCount)
    defaults.set(change, forKey: Prefs.finderCutChange)
    island?.show(
      "已剪切 \(files.count) 项", detail: "到别的文件夹空白处右键「粘贴」，或者在访达里按 ⌥⌘V", tone: .info)
  }

  /// 忘掉剪切（粘贴之后、App 启动时：剪贴板的 changeCount 每次登录从头数，留着的会在几天后「复活」）
  static func forgetCut() {
    cutList = []
    cutChange = nil
    UserDefaults.standard.removeObject(forKey: Prefs.finderCutCount)
    UserDefaults.standard.removeObject(forKey: Prefs.finderCutChange)
  }

  static func paste(into folder: URL, island: Island?) {
    let items = cutChange == NSPasteboard.general.changeCount ? cutList.filter(occupied) : []
    forgetCut()
    guard !items.isEmpty else {
      NSSound.beep()
      return
    }
    transfer(items, to: folder, move: true, island: island)
  }

  // MARK: 替身

  /// 在 desktop 上给每一样放一个替身（名字同原件，重名加「 2」）；返回放好的
  @discardableResult static func makeAliases(
    _ files: [URL],
    in desktop: URL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
  ) -> [URL] {
    var made: [URL] = []
    for file in files {
      guard
        let data = try? file.bookmarkData(
          options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
      else { continue }
      let target = desktop.appending(path: freeName(file.lastPathComponent, in: desktop, used: []))
      if (try? URL.writeBookmarkData(data, to: target)) != nil { made.append(target) }
    }
    return made
  }

  static func aliasToDesktop(_ files: [URL], island: Island?) {
    let made = makeAliases(files.filter(occupied))
    guard !made.isEmpty else {
      NSSound.beep()
      return
    }
    island?.show(
      "已把替身放到桌面", detail: made.count == 1 ? made[0].lastPathComponent : "\(made.count) 个",
      actions: [
        Island.Action("在访达中显示", opens: true) {
          NSWorkspace.shared.activateFileViewerSelecting(made)
        }
      ])
  }
}
