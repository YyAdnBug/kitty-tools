// 访达右键整理文件（2026-11-08 右键扩充第 1 批，拍板 C1 C2 C3）：移动到 / 复制到（常用文件夹 + 选择文件夹…）、剪切 / 粘贴、
// 发送替身到桌面。对标几家成熟产品的通行做法，另外守住「不丢用户的东西」（2026-11-08 独立评审后重写）：
// - 不覆盖：叫什么在真正动手时才算（前一批做完之后），重名加「 2」（不分大小写）；落到正式名字那一步用
//   renamex_np(RENAME_EXCL)——「目标已存在就报错」和改名是同一步，算完到落下之间别人占了这个名字也盖不掉，再让一个名字
//   （FileManager.moveItem 是先看再改、跨卷时还会在主线程上偷偷整份拷贝，第三轮评审实测）。
// - 同一个卷上移动 = 直接改名（原子的）。跨卷移动、复制 = 先用 ditto 拷到目标文件夹里一个隐藏的临时名，拷完改成正式名字，
//   移动的这时才删原件。「停止」只停拷贝那一步（ditto 是单个进程，停得住），停了、失败了只删临时名——原件、别人的文件都不碰。
//   （不用 mv：它跨卷搬文件夹时另起 cp、rm 两个子进程，停不住，停在 rm 那一步原件和新的都会没，评审 H1。）
// - 符号链接复制的是链接本身（ditto 会顺着链接整棵拷过去）；不许挪进自己里面（解开替身、不分大小写比）；移动时本来就在那里的跳过。
// - 拷之前看一遍（preflight，另起 find）：里面有命名管道、套接字的不拷（ditto 碰到管道一直卡着、把整条队堵死）；从分大小写的盘
//   拷到不分的盘时，同一层只差大小写的两个只能留一个，不拷（ditto 会悄悄盖掉一个、还报成功）。跨卷移动拷完再数一遍，
//   少了就不删原件；原件没删掉（只读的盘、上了锁）照实说。ACL 不跟着拷（--noacl：文稿、桌面这些文件夹带「不许删」的 ACL，
//   拷过去后临时名改不了名、也删不掉）；上了锁的先解锁、落下后再锁上。都是第三轮评审实测出来的。
// - 超过 1 秒才在刘海岛上挂「正在…」带「停止」（每一批停自己），做完说一声、带「在访达中显示」。不做撤销（访达的 ⌘Z 管不到）。
// - 剪切：清单只在内存里（偏好里只给扩展留「几项 + 剪贴板 changeCount」，别的程序改偏好也塞不进要搬的东西；App 启动时清掉），
//   同时像 ⌘C 一样把文件放进剪贴板（访达里按 ⌥⌘V 也能移过去）；剪贴板换过了剪切就作废（同 Windows）。
// - 替身：bookmarkData(.suitableForBookmarkFile) + writeBookmarkData，和访达 ⌥⌘ 拖出来的一样，原件挪了也打得开。
// ponytail: 查重名、比卷、改名都在主线程上（快，但目标在卡住的网络盘上会跟着卡）；真遇到再挪到主线程外。
// ponytail: preflight 把 find 列出的路径读进主线程按层比（十万个文件约几十毫秒）；更大的再挪出去。

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
    // 根目录「/」的下层也是「/」开头（不能拿「//」比，评审）
    if destination == source || destination.hasPrefix(source == "/" ? "/" : source + "/") {
      return false
    }
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

  /// 改名落到 target：目标已存在就报错（不覆盖）；撞上了在同一个文件夹里换一个没人用的名字再试一次。返回落下的位置
  /// （压缩、解压、修复乱码文件名也用它）
  nonisolated static func land(_ item: URL, at target: URL) -> URL? {
    landing(item, at: target).url
  }

  /// 同 land，另外给出失败的原因（errno：EXDEV 是不在同一个卷上，调用方改走拷贝）
  nonisolated static func landing(_ item: URL, at target: URL) -> (url: URL?, error: Int32) {
    var error = rename(item, to: target)
    if error == 0 { return (target, 0) }
    guard error == EEXIST || error == ENOTEMPTY else { return (nil, error) }
    let folder = target.deletingLastPathComponent()
    let other = folder.appending(path: freeName(target.lastPathComponent, in: folder, used: []))
    error = rename(item, to: other)
    return error == 0 ? (other, 0) : (nil, error)
  }

  /// renamex_np(RENAME_EXCL)：成了是 0，不然是 errno。exFAT 这类盘不支持 RENAME_EXCL（报 ENOTSUP，评审在 exFAT 映像上
  /// 实测；网络盘、第三方文件系统多半一样）：退回「先看在不在、再普通改名」。
  /// ponytail: 退回的那条路看完到改名之间有极短的空当，别人恰好落下同名的会被盖掉；这些盘上没有别的原子做法
  nonisolated static func rename(_ from: URL, to: URL) -> Int32 {
    from.withUnsafeFileSystemRepresentation { source in
      to.withUnsafeFileSystemRepresentation { destination in
        guard let source, let destination else { return EINVAL }
        if renamex_np(source, destination, UInt32(RENAME_EXCL)) == 0 { return 0 }
        let error = errno
        guard error == ENOTSUP || error == EINVAL else { return error }
        if occupied(to) { return EEXIST }
        return Darwin.rename(source, destination) == 0 ? 0 : errno
      }
    }
  }

  // MARK: 临时名

  /// 记临时名的偏好（Prefs.finderTemporaries，这台电脑自己的、不注册默认值；App 启动时接上，单测里是 nil、不写偏好）
  static var ledger: UserDefaults?

  /// 在 folder 里要一个隐藏的临时名（不带原名：名字长的再加一截会超过 255 字节），记进偏好：App 退出、崩溃、更新重启时，
  /// 子进程（ditto、tar）不跟着走、会把它写完，可再没人把它改成正式名字，下次启动删掉（cleanLeftovers）
  static func temporary(in folder: URL) -> URL {
    let url = folder.appending(path: ".kitty-\(UUID().uuidString)")
    note(url, using: true)
    return url
  }

  /// 临时名用完了（落成了正式名字，或者删掉了）
  static func release(_ url: URL) { note(url, using: false) }

  private static func note(_ url: URL, using: Bool) {
    guard let ledger else { return }
    let path = plainPath(url)
    var list = (ledger.stringArray(forKey: Prefs.finderTemporaries) ?? []).filter { $0 != path }
    if using { list.append(path) }
    if list.isEmpty {
      ledger.removeObject(forKey: Prefs.finderTemporaries)
    } else {
      ledger.set(list, forKey: Prefs.finderTemporaries)
    }
  }

  /// 是不是自己的临时名：「.kitty-<UUID>」（偏好别的程序也写得进，启动时只删这种名字的）
  nonisolated static func isTemporary(_ url: URL) -> Bool {
    let name = url.lastPathComponent
    return name.hasPrefix(".kitty-") && UUID(uuidString: String(name.dropFirst(7))) != nil
  }

  /// 扔掉一个临时名：符号链接只删链接本身；别的先把锁、ACL、权限都放开（上了锁的文件、带「不许删」ACL 的文件夹、
  /// 包里解出来的 000 的文件夹，rm 都删不掉，评审实测）。真删掉了才销账，删不掉的留着下次启动再试
  static func discard(_ url: URL) async {
    let path = plainPath(url)
    if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
      try? FileManager.default.removeItem(at: url)
    } else {
      _ = try? await Subprocess.run("/usr/bin/chflags", ["-R", "nouchg,nouappnd", path])
      _ = try? await Subprocess.run("/bin/chmod", ["-R", "-N", path])
      _ = try? await Subprocess.run("/bin/chmod", ["-R", "u+rwx", path])
      await remove(url)
    }
    if !occupied(url) { release(url) }
  }

  /// 启动时：上次没收尾的临时名删掉。等半分钟再动：更新重启、退出后马上重开时，上一次的 ditto / tar 可能还在往里写，
  /// 一起删会删不干净。所在的文件夹不在（盘没接上）的留着账，下次再看
  static func cleanLeftovers(after delay: Duration = .seconds(30)) {
    guard let list = ledger?.stringArray(forKey: Prefs.finderTemporaries) else { return }
    Task {
      try? await Task.sleep(for: delay)
      for path in list {
        let url = URL(filePath: path)
        if !isTemporary(url) {
          release(url)
        } else if occupied(url) {
          await discard(url)
        } else if occupied(url.deletingLastPathComponent()) {
          release(url)
        }
      }
    }
  }

  /// 搬一样的结果
  struct Moved {
    var url: URL?
    /// 拷不了的原因（给人看）
    var problem: String?
    /// 跨卷移动：新的落下了，原件没删掉（或只删了一部分）
    var keptOriginal = false
  }

  /// 搬一样：失败 / 被停时 url 是 nil（原件、别人的文件不动，只清掉自己的临时名）
  static func move(_ file: URL, into folder: URL, named name: String, copy: Bool) async -> Moved {
    let manager = FileManager.default
    let target = folder.appending(path: name)
    // 同一个卷（目标文件夹是替身时按它指向的那个比）：改名；内核说其实不在同一个卷上（EXDEV）就改走拷贝
    if !copy, sameVolume(file, folder.resolvingSymlinksInPath()) {
      let landed = landing(file, at: target)
      if let url = landed.url { return Moved(url: url) }
      guard landed.error == EXDEV else { return Moved() }
    }
    let check = await preflight(file, into: folder)
    if let problem = check.problem { return Moved(problem: problem) }
    if Task.isCancelled { return Moved() }
    // 排在前一批后面等的时候目标文件夹被删了：不拷（ditto 会把缺的上一层建出来）
    var isDirectory: ObjCBool = false
    guard
      FileManager.default.fileExists(
        atPath: folder.path(percentEncoded: false), isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return Moved(problem: "要放进去的文件夹不在了") }
    // 拷到目标文件夹里的隐藏临时名
    let temporary = temporary(in: folder)
    let link = (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    var copied: Bool
    if link {
      copied = (try? manager.copyItem(at: file, to: temporary)) != nil
    } else {
      let result = try? await Subprocess.run(
        "/usr/bin/ditto",
        ["--noacl", file.path(percentEncoded: false), temporary.path(percentEncoded: false)],
        stopsOnCancel: true)
      copied = result?.status == 0 && !Task.isCancelled
    }
    // 拷完再数一遍：少了就当没拷成（不报成功、移动的不删原件）。拷到 FAT 这类盘会多出 ._ 开头的，多了不算
    var problem: String?
    if copied, let expected = check.count, let got = await count(temporary), got < expected {
      copied = false
      problem = "拷过去少了 \(expected - got) 样，原件没动"
    }
    // 上了锁的改不了名：先解锁，落下后再锁上（同访达拷出来的照样锁着）
    let locked = immutable(temporary)
    if copied, locked { setImmutable(temporary, false) }
    // 落到正式名字，没拷成、落不下就扔掉临时名（拷了一半的那棵可能很大：另起进程删）
    guard copied, !Task.isCancelled, let placed = land(temporary, at: target) else {
      await discard(temporary)
      return Moved(problem: problem)
    }
    release(temporary)
    if locked { setImmutable(placed, true) }
    // 跨卷移动：新的已经完整落下，这时才删原件；删不掉的（只读的盘、上了锁、没有权限）照旧留着，照实说
    guard !copy else { return Moved(url: placed) }
    if link {
      try? manager.removeItem(at: file)
    } else {
      await remove(file)
    }
    return Moved(url: placed, keptOriginal: occupied(file))
  }

  /// 拷之前看一遍（见文件头）：返回拷不了的原因，和文件夹里一共几样（拷完对数用；不是文件夹、数不全时是 nil）
  static func preflight(_ file: URL, into folder: URL) async -> (problem: String?, count: Int?) {
    let values = try? file.resourceValues(forKeys: [
      .fileResourceTypeKey, .isDirectoryKey, .isSymbolicLinkKey,
    ])
    let name = file.lastPathComponent
    if values?.fileResourceType == .namedPipe || values?.fileResourceType == .socket {
      return ("「\(name)」是管道、套接字这类特殊文件，没法拷", nil)
    }
    guard values?.isDirectory == true, values?.isSymbolicLink != true else { return (nil, nil) }
    let path = plainPath(file)
    let special = try? await Subprocess.run(
      "/usr/bin/find", [path, "(", "-type", "p", "-o", "-type", "s", ")", "-print", "-quit"],
      captures: true, quality: .userInitiated, stopsOnCancel: true)
    if let line = special?.output.split(separator: "\n").first {
      return (
        "「\(name)」里有管道、套接字这类特殊文件（\((String(line) as NSString).lastPathComponent)），没法拷", nil
      )
    }
    guard
      let listing = try? await Subprocess.run(
        "/usr/bin/find", [path, "!", "-name", "._*", "-print0"], captures: true,
        quality: .userInitiated, stopsOnCancel: true), listing.status == 0
    else { return (nil, nil) }
    let entries = listing.output.split(separator: "\0").map(String.init)
    if caseSensitive(file), !caseSensitive(folder), let clash = caseClash(entries) {
      return ("「\(name)」里有只差大小写的同名文件（「\(clash.0)」和「\(clash.1)」），拷到这里只能留一个", nil)
    }
    return (nil, entries.count)
  }

  /// 同一层里只差大小写（和 NFC / NFD 写法）的头一对；没有是 nil
  nonisolated static func caseClash(_ paths: [String]) -> (String, String)? {
    var seen: [String: String] = [:]
    for path in paths {
      let key = path.precomposedStringWithCanonicalMapping.lowercased()
      // 按字节比（Swift 的 == 认为 NFC、NFD 两种写法相等，网络盘上它们是两个文件）
      if let other = seen[key], !other.unicodeScalars.elementsEqual(path.unicodeScalars) {
        return ((other as NSString).lastPathComponent, (path as NSString).lastPathComponent)
      }
      seen[key] = path
    }
    return nil
  }

  /// 一棵里一共几样（find 数的，含它自己）；数不全是 nil。「._」开头的不数：FAT 这类盘上每个文件旁边都有一个存扩展属性的，
  /// ditto 拷的时候把它们并回扩展属性、不单独拷（评审实测：从 U 盘拷文件夹两边数不上）
  static func count(_ url: URL) async -> Int? {
    guard
      let listing = try? await Subprocess.run(
        "/usr/bin/find", [plainPath(url), "!", "-name", "._*", "-print0"], captures: true,
        quality: .userInitiated, stopsOnCancel: true),
      listing.status == 0
    else { return nil }
    return listing.output.split(separator: "\0").count
  }

  /// 所在的卷分不分大小写
  nonisolated static func caseSensitive(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
      .volumeSupportsCaseSensitiveNames == true
  }

  /// 上了锁（访达「显示简介」里的「已锁定」）
  nonisolated static func immutable(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isUserImmutableKey]))?.isUserImmutable == true
  }

  nonisolated static func setImmutable(_ url: URL, _ locked: Bool) {
    var url = url
    var values = URLResourceValues()
    values.isUserImmutable = locked
    try? url.setResourceValues(values)
  }

  /// 删掉一整棵（另起 rm：几万个文件的文件夹在主线程上删要好几秒）。路径去掉结尾的「/」：指向文件夹的符号链接写成
  /// 「链接/」时，rm 会顺着它把那边文件夹里的东西删光；-x 不穿过挂载点（文件夹里挂着网盘、磁盘映像时，不删到那个卷里去，
  /// 评审）。stops：任务被取消时停掉 rm（只有彻底删除要；扔临时名的时候任务往往已经取消了，不能停）
  static func remove(_ url: URL, stops: Bool = false) async {
    _ = try? await Subprocess.run(
      "/bin/rm", ["-rfx", "--", plainPath(url)], stopsOnCancel: stops)
  }

  /// 一批做下来怎样
  struct Outcome {
    var done: [URL] = []
    var failed = 0
    /// 头一个拷不了的原因（给人看）
    var problem: String?
    /// 跨卷移动里原件没删掉的几样
    var kept = 0
  }

  /// 一批：真正动手时才算名字；被停了就不再开始下一样。移动时卷的根、系统文件夹、主目录不动（refusal 已经说过）
  static func execute(_ files: [URL], into folder: URL, move: Bool) async -> Outcome {
    var outcome = Outcome()
    var used = Set<String>()
    let isProtected = protection()
    for file in files
    where occupied(file) && movable(file, into: folder, move: move) && !(move && isProtected(file))
    {
      if Task.isCancelled { break }
      let name = freeName(file.lastPathComponent, in: folder, used: used)
      used.insert(name.lowercased())
      let moved = await self.move(file, into: folder, named: name, copy: !move)
      if let url = moved.url {
        outcome.done.append(url)
        if moved.keptOriginal { outcome.kept += 1 }
      } else if !Task.isCancelled {
        outcome.failed += 1
        outcome.problem = outcome.problem ?? moved.problem
      }
    }
    return outcome
  }

  /// 一批的任务（「停止」停的是它自己，不是排在后面的那一批）
  private final class Batch {
    var task: Task<Void, Never>?
  }

  /// 最后排进来的那一批（新的一批等它做完再开始）
  private static var last: Task<Void, Never>?

  /// 动文件的一批（移动、复制、压缩、解压）排进同一条队，挨个来；超过 1 秒在刘海岛上挂 notice 带「停止」（停的是这一批自己，
  /// work 里的子进程要 stopsOnCancel），做完交给 finish
  static func enqueue<T>(
    _ notice: String, detail: String? = nil, island: Island?, work: @escaping () async -> T,
    finish: @escaping (T) -> Void
  ) {
    let previous = last
    let batch = Batch()
    batch.task = Task {
      await previous?.value
      // 超过 1 秒挂「正在…」带「停止」；进行中的那一条刘海岛 60 秒后会收起，每 50 秒再挂一次，做得久的也一直停得了
      let ticker = Task {
        try? await Task.sleep(for: .seconds(1))
        while !Task.isCancelled {
          // 再挂时不抢别的：岛上空着、或者正挂着这一条才挂（别的提示、挂着的提醒照常露出来）
          if island?.content == nil || island?.content?.title == notice {
            island?.show(
              notice, detail: detail, tone: .progress,
              actions: [Island.Action("停止") { batch.task?.cancel() }])
          }
          try? await Task.sleep(for: .seconds(50))
        }
      }
      let result = await work()
      ticker.cancel()
      finish(result)
    }
    last = batch.task
  }

  /// 移动 / 复制到 folder，刘海岛报进度和结果
  static func transfer(_ files: [URL], to folder: URL, move: Bool, island: Island?) {
    let verb = move ? "移动" : "复制"
    let place = FileManager.default.displayName(atPath: folder.path(percentEncoded: false))
    if let reason = refusal(files, into: folder, move: move, place: place) {
      island?.show("没有\(verb)", detail: reason, tone: .warning)
      return
    }
    enqueue("正在\(verb) \(files.count) 项…", detail: "到「\(place)」", island: island) {
      await execute(files, into: folder, move: move)
    } finish: { outcome in
      report(outcome, verb: verb, place: place, island: island)
    }
  }

  /// 一样都做不了时的原因（给人看，同访达碰到这些会说为什么）；有能做的是 nil。文件夹不在了不替它建回来
  /// （不查的话 ditto 会把缺的上一层建出来、还报「已移到」，评审实测）；卷的根、系统文件夹、主目录只能复制、不能移动
  /// （同访达：拖一块盘永远是复制）
  static func refusal(_ files: [URL], into folder: URL, move: Bool, place: String) -> String? {
    var isDirectory: ObjCBool = false
    guard
      FileManager.default.fileExists(
        atPath: folder.path(percentEncoded: false), isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return "「\(place)」不在了（删掉、改了名，或者那块盘没接上）" }
    let present = files.filter(occupied)
    if present.isEmpty { return "选中的东西不在了" }
    let isProtected = protection()
    let candidates = move ? present.filter { !isProtected($0) } : present
    if candidates.isEmpty { return "整块盘、系统文件夹、主目录不能移动，可以复制" }
    if candidates.contains(where: { movable($0, into: folder, move: move) }) { return nil }
    let destination = plainPath(folder.resolvingSymlinksInPath()).lowercased()
    let already = candidates.allSatisfy {
      plainPath($0.deletingLastPathComponent().resolvingSymlinksInPath()).lowercased()
        == destination
    }
    return move && already ? "已经在「\(place)」里了" : "不能放进它自己里面"
  }

  private static func report(_ outcome: Outcome, verb: String, place: String, island: Island?) {
    let reveal = Island.Action("在访达中显示", opens: true) {
      NSWorkspace.shared.activateFileViewerSelecting(outcome.done)
    }
    switch (outcome.done.isEmpty, outcome.failed) {
    case (true, 0):
      island?.show("已停止\(verb)", tone: .info)
    case (true, _):
      island?.show(
        "没能\(verb)到「\(place)」", detail: outcome.problem ?? "可能是没有权限，或者那里放不下",
        tone: .error)
    case (false, 0) where outcome.kept > 0:
      island?.show(
        "已复制到「\(place)」，\(outcome.kept) 项的原件没能删掉", detail: "原件在只读的盘上、上了锁，或者没有权限",
        tone: .warning, actions: [reveal])
    case (false, 0):
      island?.show(
        (verb == "移动" ? "已移到" : "已复制到") + "「\(place)」",
        detail: outcome.done.count == 1
          ? outcome.done[0].lastPathComponent : "\(outcome.done.count) 项",
        actions: [reveal])
    case (false, let failed):
      island?.show(
        "\(verb)了 \(outcome.done.count) 项，\(failed) 项没成",
        detail: outcome.kept > 0
          ? "\(outcome.kept) 项的原件没能删掉；" + (outcome.problem ?? "到「\(place)」")
          : outcome.problem ?? "到「\(place)」",
        tone: .warning, actions: [reveal])
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
      remember(folder)
      transfer(files, to: folder, move: move, island: island)
    }
  }

  // MARK: 常用文件夹

  /// 设置里的常用文件夹（偏好里存 ~ 开头的写法），展开成真的位置。这台电脑自己的、不注册默认值（同截图的存储文件夹：
  /// 别人给的设置文件不该能往右键菜单里加一个文件夹）
  /// 后面接最近用「选择文件夹…」选过的（Prefs.finderRecentFolders，常用里有的不重复，列 3 个；同几家成熟产品的文件夹历史），
  /// 扩展里列的和这里一样（那边抄了一份）
  static var folders: [URL] {
    let favorites =
      UserDefaults.standard.stringArray(forKey: Prefs.finderTransferFolders)
      ?? Prefs.finderTransferDefault
    let recent = (UserDefaults.standard.stringArray(forKey: Prefs.finderRecentFolders) ?? [])
      .filter { !favorites.contains($0) }.prefix(3)
    return (favorites + recent).map { URL(filePath: expand($0), directoryHint: .isDirectory) }
  }

  /// 记下用「选择文件夹…」选的（~ 开头的写法，最近的在前，存 5 个）
  static func remember(_ folder: URL) {
    let path = (plainPath(folder) as NSString).abbreviatingWithTildeInPath
    let list =
      [path]
      + (UserDefaults.standard.stringArray(forKey: Prefs.finderRecentFolders) ?? [])
      .filter { $0 != path }
    UserDefaults.standard.set(Array(list.prefix(5)), forKey: Prefs.finderRecentFolders)
  }

  // MARK: 剪切 / 粘贴

  /// 剪切了哪几样、那一刻剪贴板的 changeCount（只在内存里）
  private static var cutList: [URL] = []
  private static var cutChange: Int?

  static func cut(_ files: [URL], island: Island?) {
    // 整块盘、系统文件夹、主目录不剪切（粘贴就是移动，同访达不移动一块盘）
    let isProtected = protection()
    let files = files.filter { !isProtected($0) }
    guard !files.isEmpty else {
      island?.show("没有剪切", detail: "整块盘、系统文件夹、主目录不能移动，可以复制", tone: .warning)
      return
    }
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

  /// 剪切了、剪贴板还没换过
  static var hasCut: Bool { cutChange == NSPasteboard.general.changeCount && !cutList.isEmpty }

  /// 忘掉剪切（粘贴之后、App 启动时：剪贴板的 changeCount 每次登录从头数，留着的会在几天后「复活」）
  static func forgetCut() {
    cutList = []
    cutChange = nil
    UserDefaults.standard.removeObject(forKey: Prefs.finderCutCount)
    UserDefaults.standard.removeObject(forKey: Prefs.finderCutChange)
  }

  static func paste(into folder: URL, island: Island?) {
    let items = cutChange == NSPasteboard.general.changeCount ? cutList.filter(occupied) : []
    guard !items.isEmpty else {
      forgetCut()
      island?.show("剪切已经作废了", detail: "剪切之后又拷了别的东西，或者剪切的已经不在了；再剪切一次", tone: .warning)
      return
    }
    // 这里放不了（比如就是原来那个文件夹）：说原因，剪切留着，换个地方再粘贴
    let place = FileManager.default.displayName(atPath: folder.path(percentEncoded: false))
    if let reason = refusal(items, into: folder, move: true, place: place) {
      island?.show("没有移动", detail: reason, tone: .warning)
      return
    }
    forgetCut()
    transfer(items, to: folder, move: true, island: island)
  }

  // MARK: 彻底删除

  /// 不让彻底删除（也不让隐藏）的：根目录、第一层的系统文件夹（/Users、/Applications 这种）、主目录本身、卷的根。
  /// 除了按路径，还按文件的身份比（fileResourceIdentifier）：「/users/yy」「/System/Volumes/Data/Users/yy」和主目录是
  /// 同一个文件夹，按字符串比不上（评审实测）
  nonisolated static func protected(_ url: URL, home: String = NSHomeDirectory()) -> Bool {
    protection(home: home)(url)
  }

  /// 同 protected，先把要比的那几样的身份取好（一批几千样时不用每样都列一遍根目录）
  nonisolated static func protection(home: String = NSHomeDirectory()) -> (URL) -> Bool {
    let root = URL(filePath: "/")
    let homePath = plainPath(URL(filePath: home))
    let identity = { (url: URL) in
      (try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier
        as? NSObject
    }
    let guarded =
      ([root, URL(filePath: home)]
      + ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))
      ?? []).map { $0.resolvingSymlinksInPath() }).compactMap(identity)
    return { url in
      let path = plainPath(url)
      if URL(filePath: path).pathComponents.count <= 2 || path == homePath { return true }
      let values = try? url.resourceValues(forKeys: [.isVolumeKey, .fileResourceIdentifierKey])
      if values?.isVolume == true { return true }
      guard let id = values?.fileResourceIdentifier as? NSObject else { return false }
      return guarded.contains(id)
    }
  }

  /// 「彻底删除…」（2026-11-08 右键扩充拍板 E4，默认关）：一定先问——列前 5 个名字和总数，写明不进废纸篓、删了找不回来，
  /// 默认按钮是「取消」，删除按钮是危险色（交给系统画）；不提供跳过确认的办法。符号链接只删链接本身。
  /// 删得久时同样能停（已经删掉的找不回来，说清楚）
  static func erase(_ files: [URL], island: Island?) {
    let isProtected = protection()
    let present = files.filter(occupied)
    let items = present.filter { !isProtected($0) }
    guard !items.isEmpty else {
      island?.show(
        "没有彻底删除",
        detail: present.isEmpty ? "选中的东西不在了" : "整块盘、系统文件夹、主目录不能彻底删除", tone: .warning)
      return
    }
    guard confirmErase(items) else { return }
    enqueue("正在彻底删除 \(items.count) 项…", island: island) {
      var done = 0
      for item in items {
        if Task.isCancelled { break }
        if (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
          try? FileManager.default.removeItem(at: item)
        } else {
          await remove(item, stops: true)
        }
        if !occupied(item) { done += 1 }
      }
      return done
    } finish: { done in
      if done == items.count {
        island?.show("已彻底删除" + (done == 1 ? "「\(items[0].lastPathComponent)」" : " \(done) 项"))
      } else {
        island?.show(
          "删了 \(done) 项，\(items.count - done) 项没删完",
          detail: "停下了，或者里面有没有权限删的；已经删掉的找不回来",
          tone: .warning)
      }
    }
  }

  /// 问一下；点了「彻底删除」才是 true
  private static func confirmErase(_ items: [URL]) -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText =
      items.count == 1 ? "彻底删除「\(items[0].lastPathComponent)」？" : "彻底删除这 \(items.count) 项？"
    var names =
      items.count == 1
      ? "" : items.prefix(5).map { "「\($0.lastPathComponent)」" }.joined(separator: "\n")
    if items.count > 5 { names += "\n……一共 \(items.count) 项" }
    alert.informativeText = (names.isEmpty ? "" : names + "\n\n") + "不进废纸篓，删了无法恢复。"
    // 第一个按钮是默认的（回车）：取消
    let cancel = alert.addButton(withTitle: "取消")
    alert.addButton(withTitle: "彻底删除").hasDestructiveAction = true
    return FinderLink.ask(alert, focus: cancel) == .alertSecondButtonReturn
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
      island?.show("没能放替身", detail: "选中的东西不在了，或者桌面上写不进去", tone: .warning)
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
