// 启动器的「路径模式」（2026-11-18，论坛两次反馈「输路径时想直接看到下面的子目录」；拍板页
// https://claude.ai/artifact/BMbwNiPSrhLinB5W1JhAyQ「全部按推荐，除了 1B」= 单栏，PLAN §10「启动器浏览文件夹」）：
// 以 / 或 ~/ 开头（单独一个 ~ 当 ~/）就只出路径的行。输入正好是一个存在的文件夹（末尾有没有 / 都算）就列它里面的东西，
// 第一行是这个文件夹本身；最后一段没打完就在上一级里按开头（再按名字中间）筛。文件夹在前、访达的名字顺序，最多 50 行。
// 隐藏项：还没打字时只列访达里看得见的（点开头的和带隐藏标记的不列），打了字在全部里找，进到隐藏文件夹里（~/.local/）照常全列。
// 包（.app 这类）当文件：Tab 不往里进，手打 / 照样能进。
// 这个文件只有纯函数（配单测）和一个主线程外读目录的函数（read：卡住的网络盘、外接盘不能冻住 App，mac-native §3）：
// 读之前先看位置——桌面 / 文稿 / 下载 / iCloud 云盘没问过授权不读（读一下就弹系统框），别的 App 的数据不读，
// 外接盘、网络盘第一次先问用户（系统可能弹框）。读不了的（系统不弹框，直接拒绝）照实说。
// 对标：Alfred 输 / 或 ~ 进文件导航、Tab 补全；Raycast ⇧Tab 回上一级；访达「前往文件夹」Tab 补全。

import Foundation
import UniformTypeIdentifiers

nonisolated enum PathBrowser {
  /// 最多列多少行（同文件搜索）
  static let limit = 50

  /// 输入拆成「目录那一截」和「最后一段」
  struct Request: Equatable, Sendable {
    /// 展开 ~ 之后的目录（绝对路径，没有结尾的 /；根目录是 "/"）
    var directory: String
    /// 最后一段（还没打完的名字）；以 / 结尾时是空的
    var name: String
    /// 输入里目录那一截的原样（带结尾的 /）：补全接在它后面，保留 ~ 和符号链接的写法
    var typedDirectory: String
  }

  /// 以 / 或 ~/ 开头（或者只有 ~）才是路径模式；~foo（别的用户的主目录）、相对路径都不算
  static func request(for query: String) -> Request? {
    let text = query == "~" ? "~/" : query
    guard text.hasPrefix("/") || text.hasPrefix("~/"), !text.contains("\n") else { return nil }
    let cut = text.lastIndex(of: "/").map { text.index(after: $0) } ?? text.endIndex
    let typed = String(text[..<cut])
    return Request(directory: expand(typed), name: String(text[cut...]), typedDirectory: typed)
  }

  /// 「~/.local/」→「/Users/x/.local」，「/」→「/」
  static func expand(_ typed: String) -> String {
    let path = (typed as NSString).expandingTildeInPath
    return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
  }

  /// 目录里再走一层的绝对路径
  static func child(_ name: String, of directory: String) -> String {
    directory == "/" ? "/" + name : directory + "/" + name
  }

  /// ⇧Tab：去掉最后一段，回到上一级（「~/.local/share/」「~/.local/sh」→「~/.local/」，「~/」→ 主目录的上一级）。
  /// 已经在根目录上是 nil
  static func parentQuery(of query: String) -> String? {
    guard let request = request(for: query) else { return nil }
    if !request.name.isEmpty { return request.typedDirectory }
    guard request.directory != "/" else { return nil }
    let trimmed = String(request.typedDirectory.dropLast())
    // 「~/」去掉一段就没了：换成展开的写法往上走
    guard trimmed != "~" else {
      let up = (request.directory as NSString).deletingLastPathComponent
      return up == "/" ? "/" : up + "/"
    }
    guard let slash = trimmed.lastIndex(of: "/") else { return nil }
    return String(trimmed[...slash])
  }

  // MARK: 读到的东西

  /// 目录里的一项
  struct Entry: Equatable, Sendable {
    var name: String
    /// 折叠过的名字（筛选用；读的时候算好，打字时不再每项折一遍）
    var key: String
    /// 文件夹（跟着符号链接看；包不算）
    var isFolder: Bool
    /// .app、.bundle 这类包：访达里是一个文件
    var isPackage: Bool
    /// 点开头，或者带隐藏标记（/usr、~/Library）
    var isHidden: Bool
  }

  /// 为什么没读
  enum Problem: Equatable, Sendable {
    /// 桌面 / 文稿 / 下载 / iCloud 云盘，还没问过授权（读一下就会弹系统框）
    case needsFolderAccess(String)
    /// 外接盘、网络盘，用户还没点过「允许读取」（系统可能弹框）
    case needsVolumeConsent(String)
    /// 别的 App 的数据（各个 App 的容器、第三方云盘）：读一下会弹「要访问别的 App 的数据」
    case otherAppsData
    /// 没有权限（系统不弹框，直接拒绝）
    case denied
    /// 不在了
    case missing
  }

  struct Listing: Equatable, Sendable {
    /// 文件夹在前、访达的名字顺序
    var entries: [Entry] = []
    var problem: Problem?
  }

  /// 读之前先看位置（纯函数，不碰磁盘）。盘不分大小写：按小写比；/System/Volumes/Data 是数据卷的另一个入口（firmlink），去掉再比。
  /// 调用方先拿输入的样子比一遍（解开链接要 stat 路径上的每一段，碰到受保护的文件夹里面就会弹框），解开后再比一遍
  static func problem(
    at path: String, home: String = NSHomeDirectory(), folderAccess: Bool, volumes: Bool
  ) -> Problem? {
    var original = (path as NSString).standardizingPath
    if original.lowercased().hasPrefix("/system/volumes/data/") {
      original.removeFirst("/system/volumes/data".count)
    }
    let path = original.lowercased()
    let home = home.lowercased()
    func inside(_ folder: String) -> Bool { path == folder || path.hasPrefix(folder + "/") }
    if !folderAccess {
      for (name, relative) in [
        (String(localized: "桌面"), "desktop"), (String(localized: "文稿"), "documents"),
        (String(localized: "下载"), "downloads"),
        (String(localized: "iCloud 云盘"), "library/mobile documents"),
      ] where inside(home + "/" + relative) {
        return .needsFolderAccess(name)
      }
    }
    // 各个 App 的容器里面（列容器文件夹本身只是名字，不弹框）、第三方云盘里面
    let components = path.split(separator: "/", omittingEmptySubsequences: true)
    let homeDepth = home.split(separator: "/").count
    if inside(home + "/library"), components.count > homeDepth + 2,
      ["containers", "group containers", "cloudstorage"].contains(components[homeDepth + 1])
    {
      return .otherAppsData
    }
    // 读一下会弹日历、通讯录、照片授权框的（ponytail: 按名单，系统再加新的这类位置要补）
    for relative in ["library/calendars", "library/application support/addressbook"]
    where inside(home + "/" + relative) {
      return .otherAppsData
    }
    if components.contains(where: { $0.hasSuffix(".photoslibrary") }) { return .otherAppsData }
    if inside("/volumes"), components.count >= 2, !volumes {
      // 盘名照原样显示
      let name = original.split(separator: "/", omittingEmptySubsequences: true)
      return .needsVolumeConsent(String(name[1]))
    }
    return nil
  }

  /// 在主线程外读一个目录：先解开符号链接看位置，再 readdir + 每项 lstat（隐藏标记），符号链接再 stat 看指向的是不是文件夹，
  /// 最后排好序。实测（macOS 27、Apple 芯片、SSD）：~ 约 120 项 0.16 ms，/usr/bin 932 项 4.8 ms + 排序 3.2 ms，
  /// 10 万项 255 ms + 排序 471 ms。只收路径和两个开关、交回值类型（mac-native §3「启动器读目录」）
  @concurrent static func read(_ directory: String, folderAccess: Bool, volumes: Bool) async
    -> Listing
  {
    // 先按输入的样子看（不碰磁盘），再解开链接看一遍（~/docs 链到 ~/Documents 这种）
    if let problem = problem(at: directory, folderAccess: folderAccess, volumes: volumes) {
      return Listing(problem: problem)
    }
    let resolved = URL(filePath: directory).resolvingSymlinksInPath().path(percentEncoded: false)
    if let problem = problem(at: resolved, folderAccess: folderAccess, volumes: volumes) {
      return Listing(problem: problem)
    }
    guard let handle = opendir(directory) else {
      return Listing(problem: errno == ENOENT || errno == ENOTDIR ? .missing : .denied)
    }
    defer { closedir(handle) }
    var entries: [Entry] = []
    while let record = readdir(handle) {
      let type = record.pointee.d_type
      let name = withUnsafeBytes(of: record.pointee.d_name) {
        String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
      }
      guard name != ".", name != ".." else { continue }
      let full = child(name, of: directory)
      var info = stat()
      let flags = lstat(full, &info) == 0 ? info.st_flags : 0
      var isDirectory = type == DT_DIR
      if type == DT_LNK || type == DT_UNKNOWN {
        // 链接指到受保护的地方（~/.zshrc 链到 ~/Documents/dotfiles 这种）：不跟过去 stat（会弹框），当文件列
        let link = try? FileManager.default.destinationOfSymbolicLink(atPath: full)
        let target = link.map { $0.hasPrefix("/") ? $0 : child($0, of: directory) }
        let guarded =
          target.flatMap { problem(at: $0, folderAccess: folderAccess, volumes: volumes) } != nil
        var info = stat()
        isDirectory =
          !guarded && stat(full, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
      }
      let ext = (name as NSString).pathExtension
      // 按目录认扩展名（不加 conformingTo 的话「app」认成 com.apple.application-file，不是包）
      let isPackage =
        isDirectory && !ext.isEmpty
        && UTType(filenameExtension: ext, conformingTo: .directory)?.conforms(to: .package) == true
      entries.append(
        Entry(
          name: name, key: LauncherMatch.fold(name), isFolder: isDirectory && !isPackage,
          isPackage: isPackage, isHidden: name.hasPrefix(".") || flags & UInt32(UF_HIDDEN) != 0))
    }
    return Listing(entries: sorted(entries))
  }

  /// 文件夹在前，再按访达的名字顺序（数字按大小：第 2 在第 10 前）
  static func sorted(_ entries: [Entry]) -> [Entry] {
    entries.sorted {
      if $0.isFolder != $1.isFolder { return $0.isFolder }
      return $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }

  /// 列哪些：没打字时只列看得见的（在隐藏文件夹里全列）；打了字先名字开头对上的（在全部里找），再名字中间对上的
  /// （至少两个字、点开头的不比中间，不带隐藏项）。
  /// 交回前 limit 项和一共多少项
  static func pick(_ entries: [Entry], filter: String, in directory: String) -> (
    entries: [Entry], total: Int
  ) {
    let key = LauncherMatch.fold(filter)
    let showsHidden = directory.split(separator: "/").contains { $0.hasPrefix(".") }
    let matched: [Entry]
    if key.isEmpty {
      matched = showsHidden ? entries : entries.filter { !$0.isHidden }
    } else if key.hasPrefix(".") || key.count < 2 {
      // 点开头是在找隐藏项、一个字的话名字中间几乎都有它（真机实测 ~/L 带出一串点文件）：只比开头
      matched = entries.filter { $0.key.hasPrefix(key) }
    } else {
      // 名字中间对上的不带隐藏项（在隐藏文件夹里除外）
      matched =
        entries.filter { $0.key.hasPrefix(key) }
        + entries.filter {
          !$0.key.hasPrefix(key) && $0.key.contains(key) && (showsHidden || !$0.isHidden)
        }
    }
    return (Array(matched.prefix(limit)), matched.count)
  }

  /// 最后一段正好是这个目录里的一个文件夹（不是包）：输入就当是进到它里面。先比大小写一样的，再不分大小写
  static func folder(named name: String, in entries: [Entry]) -> Entry? {
    guard !name.isEmpty else { return nil }
    return entries.first { $0.isFolder && $0.name == name }
      ?? entries.first {
        $0.isFolder && $0.name.compare(name, options: .caseInsensitive) == .orderedSame
      }
  }

  /// 这一项的类型：文件夹、包和文件按扩展名（不读文件）；认不出的是普通数据
  static func contentType(of entry: Entry) -> UTType {
    if entry.isFolder { return .folder }
    let ext = (entry.name as NSString).pathExtension
    guard !ext.isEmpty else { return .data }
    if entry.isPackage {
      return UTType(filenameExtension: ext, conformingTo: .directory) ?? .package
    }
    return UTType(filenameExtension: ext) ?? .data
  }

  /// 在主线程外看一批路径还在不在（收藏、常用里的文件和应用程序目录以外的 App：在卡住的盘上的 stat 不能冻住 App）
  @concurrent static func missing(_ paths: [String]) async -> Set<String> {
    Set(paths.filter { !FileManager.default.fileExists(atPath: $0) })
  }
}
