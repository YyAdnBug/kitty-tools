// 系统旧启动台导入的单测（第八族，SPEC §5.4 / §10.1）：自己按实测的三张表造一个小库（items / apps / groups），
// 用 LaunchpadImport.readLayout(at:) 走一遍「拷贝 → 只读打开拷贝 → 查 → 拼行」；纯函数解析另外直接喂行。
// 不碰用户真正的库（那在 ~/Library 下的 DARWIN_USER_DIR 里）。

import Foundation
import Testing

@testable import KittyTools

struct LaunchpadImportTests {
  private func ref(_ name: String, bundle: String? = nil) -> LaunchpadAppRef {
    LaunchpadAppRef(bundleID: bundle ?? "com.example.\(name)", path: "/Applications/\(name).app")
  }

  /// 造一个和系统那个库同结构的小库；返回文件路径（调用方删临时目录）
  private func makeDatabase(at path: String) throws {
    let database = try Database(path: path)
    try database.execute(
      "CREATE TABLE items (rowid INTEGER PRIMARY KEY, uuid TEXT, flags INTEGER, type INTEGER, parent_id INTEGER, ordering INTEGER)"
    )
    try database.execute(
      "CREATE TABLE apps (item_id INTEGER, title TEXT, bundleid TEXT, storeid TEXT, category_id INTEGER, moddate REAL, bookmark BLOB)"
    )
    try database.execute("CREATE TABLE groups (item_id INTEGER, category_id INTEGER, title TEXT)")
    // 根（type 1）、两页（type 3）
    try database.execute(
      "INSERT INTO items (rowid, type, parent_id, ordering) VALUES (1, 1, 0, 0), (2, 3, 1, 1), (3, 3, 1, 2)"
    )
    // 第 1 页：一个 App（本机有）、一个本机没装的
    try database.execute(
      "INSERT INTO items (rowid, type, parent_id, ordering) VALUES (4, 4, 2, 1), (5, 4, 2, 2)")
    try database.execute(
      "INSERT INTO apps (item_id, title, bundleid) VALUES (4, 'Alpha', 'com.example.a'), (5, 'Gone', 'com.example.gone')"
    )
    // 第 1 页还有一个文件夹（type 2）：名字「工具」，里面一页两个 App
    try database.execute("INSERT INTO items (rowid, type, parent_id, ordering) VALUES (6, 2, 2, 3)")
    try database.execute("INSERT INTO groups (item_id, title) VALUES (6, '工具')")
    try database.execute("INSERT INTO items (rowid, type, parent_id, ordering) VALUES (7, 3, 6, 1)")
    try database.execute(
      "INSERT INTO items (rowid, type, parent_id, ordering) VALUES (8, 4, 7, 1), (9, 4, 7, 2)")
    try database.execute(
      "INSERT INTO apps (item_id, title, bundleid) VALUES (8, 'Beta', 'com.example.b'), (9, 'Gamma', 'com.example.c')"
    )
    // 第 2 页：一个没有 bundle id、只能按标题对上的 App，和一个「下载中」（type 5，跳过）
    try database.execute(
      "INSERT INTO items (rowid, type, parent_id, ordering) VALUES (10, 4, 3, 1), (11, 5, 3, 2)")
    try database.execute(
      "INSERT INTO apps (item_id, title, bundleid) VALUES (10, 'Local Title', NULL)")
    try database.execute(
      "INSERT INTO apps (item_id, title, bundleid) VALUES (11, 'Downloading', 'com.example.dl')")
  }

  @Test func readsFabricatedDatabaseLikeTheSystemOne() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "launchpad-import-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appending(path: "db").path
    try makeDatabase(at: path)

    let local = [
      LaunchpadImport.LocalApp(ref: ref("a", bundle: "com.example.a"), name: "Alpha"),
      LaunchpadImport.LocalApp(ref: ref("b", bundle: "com.example.b"), name: "Beta"),
      LaunchpadImport.LocalApp(ref: ref("c", bundle: "com.example.c"), name: "Gamma"),
      LaunchpadImport.LocalApp(
        ref: LaunchpadAppRef(bundleID: nil, path: "/Applications/Local Title.app"),
        name: "Local Title"),
    ]
    let result = try #require(
      LaunchpadImport.readLayout(at: path, local: local, capacity: 35))
    // 第 1 页：Alpha + 「工具」文件夹；第 2 页：Local Title（按标题对上）——页的边界照库里的
    #expect(result.layout.pages.count == 2)
    #expect(result.layout.pages[0].count == 2)
    #expect(result.layout.pages[0][0].app?.id == "com.example.a")
    guard case .folder(let folder) = result.layout.pages[0][1] else {
      Issue.record("第二个应该是「工具」文件夹")
      return
    }
    #expect(folder.name == "工具")
    #expect(folder.apps.map(\.id) == ["com.example.b", "com.example.c"])
    guard result.layout.pages.count > 1 else { return }
    #expect(result.layout.pages[1].compactMap { $0.app?.id } == [local[3].ref.id])
    // 本机没装的 Gone 跳过；下载中的不进
    #expect(result.skipped == 1)
    #expect(!result.layout.apps.contains { $0.id == "com.example.gone" })
  }

  @Test func folderWithoutPagesAndWithoutName() {
    let items = [
      LaunchpadImport.Item(id: 1, type: 1, parent: 0, ordering: 0),
      LaunchpadImport.Item(id: 2, type: 3, parent: 1, ordering: 1),
      LaunchpadImport.Item(id: 3, type: 2, parent: 2, ordering: 1, groupTitle: "  "),
      // 文件夹下面直接是 App（有的版本没有中间那层页）
      LaunchpadImport.Item(
        id: 4, type: 4, parent: 3, ordering: 1, bundleID: "com.example.a"),
      LaunchpadImport.Item(
        id: 5, type: 4, parent: 3, ordering: 2, bundleID: "com.example.b"),
    ]
    let local = [
      LaunchpadImport.LocalApp(ref: ref("a", bundle: "com.example.a"), name: "A"),
      LaunchpadImport.LocalApp(ref: ref("b", bundle: "com.example.b"), name: "B"),
    ]
    let result = LaunchpadImport.layout(items: items, local: local, capacity: 35)
    #expect(result.layout.pages.count == 1)
    #expect(result.layout.pages[0][0].folder?.name == "未命名")
    #expect(result.layout.pages[0][0].folder?.apps.map(\.id) == ["com.example.a", "com.example.b"])
  }

  @Test func emptyAndUnmatchedDatabaseFallBackToEmpty() {
    let items = [LaunchpadImport.Item(id: 1, type: 1, parent: 0, ordering: 0)]
    let result = LaunchpadImport.layout(items: items, local: [], capacity: 35)
    #expect(result.layout.tiles.isEmpty)
    #expect(result.matched == 0 && result.skipped == 0)
  }

  @Test func manyAppsKeepTheDatabasePageBoundaries() {
    var items = [LaunchpadImport.Item(id: 1, type: 1, parent: 0, ordering: 0)]
    items.append(LaunchpadImport.Item(id: 2, type: 3, parent: 1, ordering: 1))
    for index in 0..<10 {
      items.append(
        LaunchpadImport.Item(
          id: Int64(3 + index), type: 4, parent: 2, ordering: index,
          bundleID: "com.example.\(index)"))
    }
    let local = (0..<10).map {
      LaunchpadImport.LocalApp(ref: ref("\($0)", bundle: "com.example.\($0)"), name: "\($0)")
    }
    let result = LaunchpadImport.layout(items: items, local: local, capacity: 35)
    // 库里就一页（10 个）——照它的边界，不按容量重排
    #expect(result.layout.pages.map(\.count) == [10])
    #expect(result.matched == 10)
    // 哪一页真的超过容量时才整体重排
    let tiny = LaunchpadImport.layout(items: items, local: local, capacity: 3)
    #expect(tiny.layout.pages.map(\.count) == [3, 3, 3, 1])
  }

  @Test func systemDatabasePathIsUnderDarwinUserDirectory() throws {
    let path = try #require(LaunchpadImport.systemDatabasePath())
    #expect(path.hasPrefix("/"))
    #expect(path.hasSuffix("com.apple.dock.launchpad/db/db"))
  }
  /// 两个根（ROOTPAGE 的 rowid 反而更大）、重复 App、只剩一个 App 的文件夹：用 ROOTPAGE 那棵、整理干净（F28）
  @Test func picksRootPageAndSanitizesImportedRows() {
    let local = [
      LaunchpadImport.LocalApp(ref: ref("a", bundle: "com.example.a"), name: "Alpha"),
      LaunchpadImport.LocalApp(ref: ref("b", bundle: "com.example.b"), name: "Beta"),
    ]
    let items: [LaunchpadImport.Item] = [
      .init(id: 10, type: 1, parent: 0, ordering: 0, uuid: "ROOTPAGE"),
      .init(id: 1, type: 1, parent: 0, ordering: 0, uuid: "ROOTPAGE_VERS"),
      .init(id: 20, type: 3, parent: 10, ordering: 1),
      .init(id: 2, type: 3, parent: 1, ordering: 1),
      // ROOTPAGE 第 1 页：Alpha 两次（同一 bundle id）、一个只有 Alpha 的文件夹
      .init(id: 21, type: 4, parent: 20, ordering: 1, bundleID: "com.example.a", title: "Alpha"),
      .init(
        id: 22, type: 4, parent: 20, ordering: 2, bundleID: "com.example.a", title: "Alpha again"),
      .init(id: 23, type: 2, parent: 20, ordering: 3, groupTitle: "只有一个"),
      .init(id: 24, type: 3, parent: 23, ordering: 1),
      .init(id: 25, type: 4, parent: 24, ordering: 1, bundleID: "com.example.a", title: "Alpha"),
      // ROOTPAGE_VERS：不能取到这棵树
      .init(id: 3, type: 4, parent: 2, ordering: 1, bundleID: "com.example.b", title: "Beta"),
    ]
    let result = LaunchpadImport.layout(items: items, local: local, capacity: 35)
    #expect(result.layout.pages.count == 1)
    #expect(result.layout.pages[0].count == 1)
    #expect(result.layout.pages[0][0].app?.id == local[0].ref.id)
    #expect(!result.layout.apps.contains { $0.id == local[1].ref.id })
    #expect(result.layout.tiles.allSatisfy { $0.folder == nil })
  }

}
