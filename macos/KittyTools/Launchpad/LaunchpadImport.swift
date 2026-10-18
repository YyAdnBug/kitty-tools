// 从系统旧启动台的数据库导入布局（SPEC §5.4，R9）。macOS 27 上那个库还在：
// `/private$(getconf DARWIN_USER_DIR)com.apple.dock.launchpad/db/db`（WAL）。
// **只读拷贝**：把 db、db-shm、db-wal（有的话）拷进临时目录，用 `file:<拷贝>?mode=ro` 只读打开拷贝
// （直接只读打开原件会报「unable to open database file」，实测），读完删掉拷贝；原件一个字节都不碰。
// **不能加 `immutable=1`**：SQLite 把 immutable 的库当只读介质上的临时文件，根本不读 -wal——那个库的 -wal 会有
// 好几 MB、最近的改动都在里面，读到的会是旧排法（2026-10-18 实测少一个 App）。不加它才按 WAL 读。
// 表（实测）：items(rowid, uuid, flags, type, parent_id, ordering)、apps(item_id, title, bundleid, storeid,
// category_id, moddate, bookmark)、groups(item_id, category_id, title)。树：根(type 1) → 页(type 3) →
// App(type 4) / 文件夹(type 2) → 文件夹里的页(type 3) → App；type 5 是下载中的，跳过。同一层按 ordering。
// 解析是纯函数（单测自己造行），读库这一层只负责拷贝、查询、拼行。
// 库里有、本机已经没装的 App 跳过；本机有、库里没有的由调用方按 R2 追加到最后（LaunchpadLayout.merged）。
// 和 C API 打交道只有一处：confstr 取 DARWIN_USER_DIR（其余走 Storage/Database.swift）。

import Darwin
import Foundation

nonisolated struct LaunchpadImport {
  /// 库里的一行（三张表拼起来的视图，纯函数只认它）
  struct Item: Equatable, Sendable {
    var id: Int64
    /// 1 根 / 2 文件夹 / 3 页 / 4 App / 5 下载中的 App
    var type: Int
    var parent: Int64
    var ordering: Int
    var bundleID: String?
    var title: String?
    /// 文件夹的名字（groups 表；空 = 没名字，当文件夹用）
    var groupTitle: String?
    /// items.uuid：根有两个（ROOTPAGE / ROOTPAGE_VERS），按名字取 ROOTPAGE 那一棵，不靠 SELECT 碰巧的顺序
    var uuid: String? = nil
  }

  /// 本机的一个 App（用来把库里的 bundle id / 标题对上本机的路径）
  struct LocalApp: Equatable, Sendable {
    var ref: LaunchpadAppRef
    var name: String
  }

  struct Result: Equatable, Sendable {
    var layout: LaunchpadLayout
    /// 放进布局的 App 数
    var matched: Int
    /// 库里有、本机没装的（跳过）
    var skipped: Int
  }

  /// 把库里的行拼成布局（纯函数）。没有页时返回空布局。
  static func layout(items: [Item], local: [LocalApp], capacity: Int) -> Result {
    let byBundle = Dictionary(
      local.compactMap { app in app.ref.bundleID.map { ($0.lowercased(), app.ref) } },
      uniquingKeysWith: { first, _ in first })
    let byTitle = Dictionary(
      local.map { (LauncherMatch.fold($0.name), $0.ref) }, uniquingKeysWith: { first, _ in first })
    var matched = 0
    var skipped = 0

    func appRef(_ item: Item) -> LaunchpadAppRef? {
      if let bundleID = item.bundleID, let ref = byBundle[bundleID.lowercased()] { return ref }
      if let title = item.title, let ref = byTitle[LauncherMatch.fold(title)] { return ref }
      return nil
    }

    var children: [Int64: [Item]] = [:]
    for item in items { children[item.parent, default: []].append(item) }
    for key in children.keys {
      children[key]?.sort { ($0.ordering, $0.id) < ($1.ordering, $1.id) }
    }
    let root =
      items.first { $0.type == 1 && $0.uuid == "ROOTPAGE" }?.id
      ?? items.first { $0.type == 1 }?.id ?? 0

    func apps(of page: Item) -> [LaunchpadAppRef] {
      children[page.id, default: []].compactMap { child in
        guard child.type == 4 else { return nil }
        if let ref = appRef(child) {
          matched += 1
          return ref
        }
        skipped += 1
        return nil
      }
    }

    func folder(_ item: Item) -> LaunchpadTile? {
      let pages = children[item.id, default: []].filter { $0.type == 3 }
      var inner = pages.map { apps(of: $0) }.filter { !$0.isEmpty }
      if inner.isEmpty {
        // 有的版本文件夹下面直接是 App，没有中间那层页
        let direct = children[item.id, default: []].filter { $0.type == 4 }
        if !direct.isEmpty {
          inner = [
            direct.compactMap { child in
              guard let ref = appRef(child) else {
                skipped += 1
                return nil
              }
              matched += 1
              return ref
            }
          ]
        }
      }
      guard !inner.isEmpty else { return nil }
      let name = (item.groupTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      return .folder(
        LaunchpadFolder(
          name: name.isEmpty ? LaunchpadLayout.untitledFolder : name, pages: inner))
    }

    var pages: [[LaunchpadTile]] = []
    for page in children[root, default: []].filter({ $0.type == 3 }) {
      var tiles: [LaunchpadTile] = []
      for child in children[page.id, default: []] {
        switch child.type {
        case 4:
          if let ref = appRef(child) {
            matched += 1
            tiles.append(.app(ref))
          } else {
            skipped += 1
          }
        case 2:
          if let tile = folder(child) { tiles.append(tile) }
        default:
          break
        }
      }
      if !tiles.isEmpty { pages.append(tiles) }
    }
    // 页的边界照库里那份（导入的多页布局不被按容量重排）；只有哪一页真的超过容量时才整体重排。
    // 整理（去重复的 App、解散只剩一个的文件夹、文件夹内页按 folderCapacity 重分）在这一步做掉——导入的布局不能
    // 留到下次打开才被修，F7 改完以后 open() 也不再整份重排了
    let layout = LaunchpadLayout(pages: LaunchpadLayout.sanitized(pages))
    let clean =
      layout.pages.allSatisfy { $0.count <= max(capacity, 1) }
      ? layout : layout.repaginated(capacity: capacity)
    return Result(layout: clean, matched: matched, skipped: skipped)
  }

  /// 系统旧启动台库的路径（`confstr(_CS_DARWIN_USER_DIR)`）
  static func systemDatabasePath() -> String? {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    let length = confstr(_CS_DARWIN_USER_DIR, &buffer, buffer.count)
    guard length > 0 else { return nil }
    let bytes = buffer.prefix(max(Int(length) - 1, 0)).map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self) + "com.apple.dock.launchpad/db/db"
  }

  /// 后台读本机的旧库（F31）；`@concurrent` 离开主 actor
  @concurrent
  nonisolated static func readSystemLayoutInBackground(
    local: [LocalApp], capacity: Int
  ) async -> Result? {
    readSystemLayout(local: local, capacity: capacity)
  }

  /// 读本机的旧库（读不到返回 nil）
  static func readSystemLayout(local: [LocalApp], capacity: Int) -> Result? {
    guard let path = systemDatabasePath(), FileManager.default.fileExists(atPath: path) else {
      return nil
    }
    return readLayout(at: path, local: local, capacity: capacity)
  }

  /// 从某个库文件读（**只读拷贝**：db、db-shm、db-wal 拷进临时目录，`file:…?mode=ro` 只读打开拷贝，
  /// 原件一个字节都不碰）。不加 `immutable=1`：那会跳过 -wal（F8）。单测用它喂自己造的小库。
  static func readLayout(at path: String, local: [LocalApp], capacity: Int) -> Result? {
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory.appending(
      path: "kitty-launchpad-import-\(UUID().uuidString)")
    guard
      (try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true))
        != nil
    else { return nil }
    defer { try? fileManager.removeItem(at: directory) }
    let copy = directory.appending(path: "db")
    do {
      // 先拷 -wal / -shm 再拷主文件：先拷主文件的话，两次拷贝之间 checkpoint 一次会把新帧并进主文件、
      // 再读到的 -wal 就旧了（和启动器克隆浏览历史同一个顺序）
      for suffix in ["-wal", "-shm"] {
        let side = path + suffix
        if fileManager.fileExists(atPath: side) {
          try fileManager.copyItem(at: URL(filePath: side), to: URL(filePath: copy.path + suffix))
        }
      }
      try fileManager.copyItem(at: URL(filePath: path), to: copy)
    } catch {
      return nil
    }
    guard
      let database = try? Database(
        path: "file:\(copy.path)?mode=ro", readOnly: true, wal: false, uri: true)
    else { return nil }
    do {
      let appRows = try database.query("SELECT item_id, title, bundleid FROM apps") { row in
        (item: row.int(0) ?? 0, title: row.text(1), bundleID: row.text(2))
      }
      let groupRows = try database.query("SELECT item_id, title FROM groups") { row in
        (item: row.int(0) ?? 0, title: row.text(1))
      }
      let itemRows = try database.query(
        "SELECT rowid, type, parent_id, ordering, uuid FROM items"
      ) { row in
        (
          id: row.int(0) ?? 0, type: Int(row.int(1) ?? 0), parent: row.int(2) ?? 0,
          ordering: Int(row.int(3) ?? 0), uuid: row.text(4)
        )
      }
      var apps: [Int64: (title: String?, bundleID: String?)] = [:]
      for row in appRows { apps[row.item] = (row.title, row.bundleID) }
      var groups: [Int64: String] = [:]
      for row in groupRows { groups[row.item] = row.title }
      let items = itemRows.map { row in
        Item(
          id: row.id, type: row.type, parent: row.parent, ordering: row.ordering,
          bundleID: apps[row.id]?.bundleID, title: apps[row.id]?.title,
          groupTitle: groups[row.id], uuid: row.uuid)
      }
      guard !items.isEmpty else { return nil }
      return layout(items: items, local: local, capacity: capacity)
    } catch {
      return nil
    }
  }
}
