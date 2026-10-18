// 启动台的布局模型和全部纯函数（SPEC §5.1）：页数组，每页是格子数组，格子是 App（按 bundle id 认，没有 bundle id 的按
// 解开链接后的路径）或文件夹（名字 + 内部的页）。Codable，整份存进偏好（Prefs.launchpadLayout，JSON 字符串）。
// 这里不碰窗口、不读文件、不读偏好：合并本机 App、默认排法、旧库导入后的整理、挪格子、建 / 加 / 拖出文件夹、按行列数
// 重新分页、搜索排序都在这里，单测直接喂值。不变式（随机操作测试锁住）：每个本机 App 恰好出现一次；没有空页（整份为空
// 时除外）、没有空文件夹、没有只剩一个 App 的文件夹；顺序稳定。
// 坐标口径：页是顶层分页，一格一个 LaunchpadTile；文件夹内部的页固定 7 × 5 = 35 个 App（同 macOS 15），不跟顶层的行列数走。

import Foundation

/// 布局里的一个 App：bundle id 优先；没有 bundle id 的（少数第三方工具）按解开链接后的路径认。
/// 只存身份，不存显示名、图标、分类——那些每次从 LaunchpadCatalog 现取，App 改名、换图标不用重写布局。
nonisolated struct LaunchpadAppRef: Codable, Hashable, Sendable {
  var bundleID: String?
  var path: String

  init(bundleID: String? = nil, path: String) {
    self.bundleID = bundleID
    self.path = path
  }

  /// 布局里认这一个 App 的 id（bundle id 优先，其次路径）
  var id: String { bundleID ?? path }
}

/// 一个文件夹：名字 + 内部的页（每页最多 35 个 App）。id 在拖动、改名、动画里认它。
nonisolated struct LaunchpadFolder: Codable, Hashable, Sendable, Identifiable {
  var id: UUID
  var name: String
  var pages: [[LaunchpadAppRef]]

  init(id: UUID = UUID(), name: String, pages: [[LaunchpadAppRef]]) {
    self.id = id
    self.name = name
    self.pages = pages
  }

  var apps: [LaunchpadAppRef] { pages.flatMap { $0 } }
}

/// 顶层的一格：一个 App 或一个文件夹。
nonisolated enum LaunchpadTile: Codable, Hashable, Sendable, Identifiable {
  case app(LaunchpadAppRef)
  case folder(LaunchpadFolder)

  var id: String {
    switch self {
    case .app(let app): "app\n" + app.id
    case .folder(let folder): "folder\n" + folder.id.uuidString
    }
  }

  var app: LaunchpadAppRef? {
    if case .app(let app) = self { return app }
    return nil
  }

  var folder: LaunchpadFolder? {
    if case .folder(let folder) = self { return folder }
    return nil
  }

  /// 这一格里所有 App 的 id（文件夹里的一起算）
  var appIDs: [String] {
    switch self {
    case .app(let app): [app.id]
    case .folder(let folder): folder.apps.map(\.id)
    }
  }

  private enum CodingKeys: String, CodingKey {
    case kind, app, folder
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(String.self, forKey: .kind) {
    case "app": self = .app(try container.decode(LaunchpadAppRef.self, forKey: .app))
    case "folder": self = .folder(try container.decode(LaunchpadFolder.self, forKey: .folder))
    case let other:
      throw DecodingError.dataCorruptedError(
        forKey: .kind, in: container, debugDescription: "不认识的格子类型：\(other)")
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .app(let app):
      try container.encode("app", forKey: .kind)
      try container.encode(app, forKey: .app)
    case .folder(let folder):
      try container.encode("folder", forKey: .kind)
      try container.encode(folder, forKey: .folder)
    }
  }
}

nonisolated struct LaunchpadLayout: Codable, Equatable, Sendable {
  /// 文件格式：以后改结构时加、读到不认识的按空布局算，不让一份坏 JSON 把整个启动台卡住
  static let currentFormat = 1
  /// 文件夹内部一页几个：7 × 5 = 35（2026-10-18 对照本机系统旧库：有一个文件夹的一页正好 35 个 App，
  /// 和主网格默认的 7 × 5 一样；macOS 15 的文件夹展开后也是 7 列）。导入时按这个重分文件夹内页
  static let folderCapacity = 35
  /// 文件夹面板一页几列（macOS 15 展开后 7 列；`folderCapacity` 就是 7 × 5）
  static let folderColumns = 7
  /// 文件夹没有共同分类、第一个 App 也没分类时的名字（SPEC R4）
  static let untitledFolder = "未命名"

  var format: Int
  var pages: [[LaunchpadTile]]

  init(pages: [[LaunchpadTile]]) {
    self.format = Self.currentFormat
    self.pages = pages
  }

  private enum CodingKeys: String, CodingKey {
    case format, pages
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard
      try container.decodeIfPresent(Int.self, forKey: .format) ?? Self.currentFormat
        == Self.currentFormat
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .format, in: container, debugDescription: "更新版本的布局")
    }
    // 一格坏了只丢那一格，不连累整份（以后的版本降回来、手改坏一行都不至于让布局整个读不出来）
    let raw = try container.decode([[LossyTile]].self, forKey: .pages)
    self.init(pages: raw.map { $0.compactMap(\.tile) })
    pages = Self.sanitized(pages)
  }

  /// 解码时把解不出的格子变成 nil（`try?` 吞掉那一格的错误）
  private struct LossyTile: Decodable {
    var tile: LaunchpadTile?
    init(from decoder: Decoder) throws { tile = try? LaunchpadTile(from: decoder) }
  }

  // MARK: 读

  /// 所有顶层格子（按页、页内顺序）
  var tiles: [LaunchpadTile] { pages.flatMap { $0 } }

  /// 布局里的所有 App（文件夹里的也算），按出现顺序
  var apps: [LaunchpadAppRef] {
    tiles.flatMap { tile in
      switch tile {
      case .app(let app): [app]
      case .folder(let folder): folder.apps
      }
    }
  }

  func contains(appID: String) -> Bool { apps.contains { $0.id == appID } }

  /// 按 id 找布局里存的 App 身份（打开搜到的结果、拖出文件夹时用）
  func appRef(_ appID: String) -> LaunchpadAppRef? { apps.first { $0.id == appID } }

  /// 顶层某一格在哪一页的第几格
  func locate(_ tileID: String) -> (page: Int, index: Int)? {
    for (page, tiles) in pages.enumerated() {
      if let index = tiles.firstIndex(where: { $0.id == tileID }) { return (page, index) }
    }
    return nil
  }

  /// 顶层上的某个 App 在哪（文件夹里的不算）
  func locateTopLevel(_ appID: String) -> (page: Int, index: Int)? {
    for (page, tiles) in pages.enumerated() {
      if let index = tiles.firstIndex(where: { $0.app?.id == appID }) { return (page, index) }
    }
    return nil
  }

  /// 某个 App 在哪（顶层或文件夹里）
  func locateAnyApp(_ appID: String) -> AppLocation? {
    for (page, tiles) in pages.enumerated() {
      for (index, tile) in tiles.enumerated() {
        switch tile {
        case .app(let app) where app.id == appID:
          return AppLocation(page: page, tile: index)
        case .folder(let folder):
          for (innerPage, refs) in folder.pages.enumerated() {
            if let innerIndex = refs.firstIndex(where: { $0.id == appID }) {
              return AppLocation(
                page: page, tile: index, folder: folder.id, innerPage: innerPage,
                innerIndex: innerIndex)
            }
          }
        default: break
        }
      }
    }
    return nil
  }

  struct AppLocation: Equatable, Sendable {
    var page: Int
    var tile: Int
    var folder: UUID?
    var innerPage: Int = 0
    var innerIndex: Int = 0
  }

  /// 页数（至少 1：空布局在界面上也有一页）
  var pageCount: Int { max(pages.count, 1) }

  func tiles(at page: Int) -> [LaunchpadTile] {
    pages.indices.contains(page) ? pages[page] : []
  }

  // MARK: 整理

  /// 去掉重复的 App / 文件夹、空页、空文件夹和只剩一个 App 的文件夹（剩下那一个提回原处）。
  /// 保留页的边界（导入的布局可能每页没排满），只在调用方需要时再按容量重排。
  static func sanitized(_ pages: [[LaunchpadTile]]) -> [[LaunchpadTile]] {
    var seenApps = Set<String>()
    var seenFolders = Set<UUID>()
    var result: [[LaunchpadTile]] = []
    for page in pages {
      var tiles: [LaunchpadTile] = []
      for tile in page {
        switch tile {
        case .app(let app):
          guard seenApps.insert(app.id).inserted else { continue }
          tiles.append(.app(app))
        case .folder(let folder):
          guard seenFolders.insert(folder.id).inserted else { continue }
          var inner: [[LaunchpadAppRef]] = []
          for refs in folder.pages {
            var kept: [LaunchpadAppRef] = []
            for app in refs where seenApps.insert(app.id).inserted { kept.append(app) }
            if !kept.isEmpty { inner.append(kept) }
          }
          let all = inner.flatMap { $0 }
          if all.count >= 2 {
            // 文件夹内部的页按 folderCapacity 重分：导入的库里有「一页 35 个」这种，旧的 3 × 3 口径会把大半藏起来
            var cleaned = LaunchpadFolder(
              id: folder.id, name: folder.name, pages: paginateFolder(all))
            cleaned.name = cleaned.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.name.isEmpty { cleaned.name = untitledFolder }
            tiles.append(.folder(cleaned))
          } else if let only = all.first {
            tiles.append(.app(only))
          }
        }
      }
      if !tiles.isEmpty { result.append(tiles) }
    }
    return result
  }

  /// 按一页能放几个（列 × 行）重新分页：文件夹内部的页按 35 个一页，顶层的按容量。
  static func paginate(_ tiles: [LaunchpadTile], capacity: Int) -> [[LaunchpadTile]] {
    let capacity = max(1, capacity)
    guard !tiles.isEmpty else { return [] }
    return stride(from: 0, to: tiles.count, by: capacity).map {
      Array(tiles[$0..<min($0 + capacity, tiles.count)])
    }
  }

  /// 文件夹内部的 App 按 35 个一页排好（丢掉空页）
  static func paginateFolder(_ apps: [LaunchpadAppRef]) -> [[LaunchpadAppRef]] {
    guard !apps.isEmpty else { return [] }
    return stride(from: 0, to: apps.count, by: folderCapacity).map {
      Array(apps[$0..<min($0 + folderCapacity, apps.count)])
    }
  }

  /// 顶层按容量重排（改行列数、恢复默认之后用；日常编辑不许调它，页边界要保住，见 `pushed`）
  func repaginated(capacity: Int) -> LaunchpadLayout {
    LaunchpadLayout(pages: Self.paginate(Self.sanitized(pages).flatMap { $0 }, capacity: capacity))
  }

  /// 打开时用：只在一页真的超过容量（用户改过行列数）时才整份重排，否则页边界原样保留（导入的多页布局不被压紧）
  func tidied(capacity: Int) -> LaunchpadLayout {
    let clean = Self.sanitized(pages)
    let capacity = max(capacity, 1)
    guard clean.contains(where: { $0.count > capacity }) else {
      return LaunchpadLayout(pages: clean)
    }
    return LaunchpadLayout(pages: Self.paginate(clean.flatMap { $0 }, capacity: capacity))
  }

  /// 编辑之后：哪一页超过容量，就把多出来的从前端推到下一页开头，逐页往后；空页去掉。
  /// **从不往前补**（macOS 15：页可以不满，只有挤出来的那个顺到下一页开头）
  static func pushed(_ pages: [[LaunchpadTile]], capacity: Int) -> [[LaunchpadTile]] {
    let capacity = max(capacity, 1)
    var result = pages
    var index = 0
    while index < result.count {
      if result[index].count > capacity {
        let overflow = Array(result[index][capacity...])
        result[index] = Array(result[index][..<capacity])
        if index + 1 < result.count {
          result[index + 1].insert(contentsOf: overflow, at: 0)
        } else {
          result.append(overflow)
        }
      }
      index += 1
    }
    return result.filter { !$0.isEmpty }
  }

  // MARK: 合并本机 App

  /// App 目录变了：拿掉布局里本机已经没有的、把新装的追加到最后一页末尾，然后整理（解散只剩一个的文件夹、去空页）。
  /// **页边界保住**：卸掉的只让它所在页变短，不从后面往前补；新装的接在最后一页末尾，最后一页满了才另起一页。
  /// 没有变化时原样返回（导入的多页布局不被无谓重排）。
  /// **空列表 = 还不知道**（App 刚启动、后台扫目录还没回来），原样返回——当成「全卸了」会把用户的布局清空并存盘（G2）。
  func merged(apps: [LaunchpadAppRef], capacity: Int) -> LaunchpadLayout {
    guard !apps.isEmpty else { return self }
    let wanted = Set(apps.map(\.id))
    guard wanted != Set(self.apps.map(\.id)) else { return self }
    var pages: [[LaunchpadTile]] = []
    for page in self.pages {
      var tiles: [LaunchpadTile] = []
      for tile in page {
        switch tile {
        case .app(let app):
          if wanted.contains(app.id) { tiles.append(.app(app)) }
        case .folder(let folder):
          let kept = folder.pages.map { $0.filter { wanted.contains($0.id) } }
            .filter { !$0.isEmpty }
          let all = kept.flatMap { $0 }
          if all.count >= 2 {
            tiles.append(
              .folder(
                LaunchpadFolder(
                  id: folder.id, name: folder.name, pages: Self.paginateFolder(all))))
          } else if let only = all.first {
            tiles.append(.app(only))
          }
        }
      }
      if !tiles.isEmpty { pages.append(tiles) }
    }
    var present = Set(pages.flatMap { $0 }.flatMap(\.appIDs))
    let capacity = max(capacity, 1)
    for app in apps where !present.contains(app.id) {
      if pages.isEmpty { pages = [[]] }
      if pages[pages.count - 1].count >= capacity { pages.append([]) }
      pages[pages.count - 1].append(.app(app))
      present.insert(app.id)
    }
    return LaunchpadLayout(pages: pages)
  }

  // MARK: 默认排法（SPEC §3.6）

  /// 第一次打开、又没有系统旧启动台可导入时：先系统 App（按显示名），`/System/Applications/Utilities` 的放进一个
  /// 「其他」文件夹，再别的 App（按显示名）。
  struct DefaultApp: Equatable, Sendable {
    var ref: LaunchpadAppRef
    var name: String
    var isSystem: Bool
    var inUtilities: Bool
  }

  static func defaultLayout(_ apps: [DefaultApp], capacity: Int) -> LaunchpadLayout {
    let sorted = { (list: [DefaultApp]) in
      list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    let system = sorted(apps.filter { $0.isSystem && !$0.inUtilities })
    let utilities = sorted(apps.filter { $0.inUtilities })
    // 工具文件夹里的（inUtilities）不重复出现在「别的」里：真目录里它们本来也 isSystem，这里防一手脏数据
    let others = sorted(apps.filter { !$0.isSystem && !$0.inUtilities })
    var sequence = system.map { LaunchpadTile.app($0.ref) }
    if !utilities.isEmpty {
      sequence.append(
        .folder(
          LaunchpadFolder(
            name: "其他", pages: paginateFolder(utilities.map(\.ref)))))
    }
    sequence += others.map { LaunchpadTile.app($0.ref) }
    return LaunchpadLayout(pages: Self.paginate(sequence, capacity: capacity))
  }

  // MARK: 挪格子

  /// 把顶层某一格挪到目标页的第 slot 格（slot 统一是**拿掉这一格之后**、目标页里的插入位置）。
  /// 目标页放不下时挤出来的那一个顺到下一页开头，逐页往后；**不整份重排**，页边界不动。
  /// `targetPage >= 页数` = 拖到最后一页右边缘再往右，新开一页。
  func moving(_ tileID: String, toPage targetPage: Int, slot: Int, capacity: Int) -> LaunchpadLayout
  {
    guard let source = locate(tileID) else { return self }
    var pages = self.pages
    let tile = pages[source.page].remove(at: source.index)
    var wantedPage = targetPage
    if pages[source.page].isEmpty, pages.count > 1 {
      // 这一页只有手里这一个，还落回同一页：就是没挪（不能把空页删掉再插到下一页去）
      if targetPage == source.page { return self }
      pages.remove(at: source.page)
      if targetPage > source.page { wantedPage -= 1 }
    }
    if pages.isEmpty { pages = [[]] }
    let page: Int
    if wantedPage >= pages.count {
      pages.append([])
      page = pages.count - 1
    } else {
      page = min(max(wantedPage, 0), pages.count - 1)
    }
    let index = min(max(slot, 0), pages[page].count)
    pages[page].insert(tile, at: index)
    return LaunchpadLayout(pages: Self.pushed(pages, capacity: capacity))
  }

  /// 按整份展开后的下标挪（拖动时界面按格算位置更方便，测试用这个）
  func moving(_ tileID: String, toFlatIndex index: Int, capacity: Int) -> LaunchpadLayout {
    guard let flat = tiles.firstIndex(where: { $0.id == tileID }) else { return self }
    var sequence = tiles
    let tile = sequence.remove(at: flat)
    let target = min(max(index > flat ? index - 1 : index, 0), sequence.count)
    sequence.insert(tile, at: target)
    return LaunchpadLayout(pages: Self.paginate(sequence, capacity: capacity))
  }

  // MARK: 文件夹

  /// 把一个 App 那一格拖到另一个 App 那一格上：建成一个文件夹放在目标那一格，两个都进去（目标在前）。
  /// 拖到文件夹上就是加进那个文件夹。两个参数都是**格子的 id**（LaunchpadTile.id），拖动时手里拿的就是它。
  func folding(_ sourceID: String, onto targetID: String, name: String, capacity: Int)
    -> LaunchpadLayout
  {
    guard sourceID != targetID, let target = locate(targetID),
      let targetTile = pages.indices.contains(target.page)
        ? pages[target.page][safe: target.index] : nil,
      let source = locate(sourceID), let sourceApp = pages[source.page][safe: source.index]?.app
    else { return self }
    let appID = sourceApp.id
    if case .folder(let folder) = targetTile {
      return adding(appID, to: folder.id, capacity: capacity)
    }
    guard case .app(let targetApp) = targetTile else { return self }
    var pages = pages
    pages[source.page].remove(at: source.index)
    var page = target.page
    var index = target.index
    if source.page == target.page, source.index < target.index { index -= 1 }
    if pages[source.page].isEmpty, pages.count > 1 {
      pages.remove(at: source.page)
      if target.page > source.page { page -= 1 }
    }
    guard pages.indices.contains(page), pages[page].indices.contains(index) else { return self }
    let folder = LaunchpadFolder(
      name: name, pages: Self.paginateFolder([targetApp, sourceApp]))
    pages[page][index] = .folder(folder)
    return LaunchpadLayout(pages: Self.pushed(pages, capacity: capacity))
  }

  /// 把一个 App 加进已有的文件夹（拖到文件夹上）：加在最后一页末尾，满了另起一页。
  func adding(_ appID: String, to folderID: UUID, capacity: Int) -> LaunchpadLayout {
    guard let source = locateAnyApp(appID), source.folder != folderID,
      let sourceRef = appRef(appID)
    else { return self }
    var pages = pages
    // 先把 App 从原处拿掉（可能在另一页、另一个文件夹里），再按 id 找回文件夹（位置可能挪了）
    removeAppFromPages(appID, pages: &pages)
    pages.removeAll { $0.isEmpty }
    guard let folderLocation = tileLocation(ofFolder: folderID, in: pages),
      case .folder(var folder) = pages[folderLocation.page][folderLocation.index]
    else { return self }
    folder.pages = Self.appending(sourceRef, to: folder.pages)
    pages[folderLocation.page][folderLocation.index] = .folder(folder)
    return LaunchpadLayout(pages: Self.pushed(pages, capacity: capacity))
  }

  /// 把 App 从文件夹里拖出来：放回文件夹后面那一格；文件夹只剩一个时解散（两个都回到顶层）。
  /// 直接在这里从文件夹里拿掉：不能先走 removeAppFromPages——它会在文件夹只剩一个时当场解散，后面就找不到这个文件夹了。
  func draggingOut(_ appID: String, from folderID: UUID, capacity: Int) -> LaunchpadLayout {
    guard let location = locateAnyApp(appID), location.folder == folderID,
      let ref = appRef(appID),
      let now = tileLocation(ofFolder: folderID),
      case .folder(var folder) = pages[now.page][now.index]
    else { return self }
    var pages = pages
    var remaining = folder.pages
    if remaining.indices.contains(location.innerPage) {
      remaining[location.innerPage].remove(at: location.innerIndex)
    }
    remaining = remaining.filter { !$0.isEmpty }
    let left = remaining.flatMap { $0 }
    switch left.count {
    case 0:
      pages[now.page][now.index] = .app(ref)
    case 1:
      // 只剩一个：解散，原来的加上拖出来的两个都回到顶层
      pages[now.page][now.index] = .app(left[0])
      pages[now.page].insert(.app(ref), at: now.index + 1)
    default:
      folder.pages = remaining
      pages[now.page][now.index] = .folder(folder)
      pages[now.page].insert(.app(ref), at: now.index + 1)
    }
    return LaunchpadLayout(pages: Self.pushed(pages, capacity: capacity))
  }

  /// 改名（去掉两头空白；空的回到「未命名」）
  func renaming(_ folderID: UUID, to name: String) -> LaunchpadLayout {
    guard let location = tileLocation(ofFolder: folderID) else { return self }
    var pages = pages
    guard case .folder(var folder) = pages[location.page][location.index] else { return self }
    folder.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if folder.name.isEmpty { folder.name = Self.untitledFolder }
    pages[location.page][location.index] = .folder(folder)
    return LaunchpadLayout(pages: pages)
  }

  /// 从布局里拿掉一个 App（卸载了、删掉了）：顶层和文件夹里都找，整理后按容量重排。
  func removing(_ appID: String, capacity: Int) -> LaunchpadLayout {
    var pages = pages
    removeAppFromPages(appID, pages: &pages)
    pages.removeAll { $0.isEmpty }
    return LaunchpadLayout(pages: pages)
  }

  /// 删掉整个文件夹（App 回到顶层原处；文件夹里的 App 一个不少）
  func dissolving(_ folderID: UUID, capacity: Int) -> LaunchpadLayout {
    guard let location = tileLocation(ofFolder: folderID),
      case .folder(let folder) = pages[location.page][location.index]
    else { return self }
    var pages = pages
    let refs = folder.apps
    pages[location.page].remove(at: location.index)
    pages[location.page].insert(contentsOf: refs.map(LaunchpadTile.app), at: location.index)
    return LaunchpadLayout(pages: Self.pushed(pages, capacity: capacity))
  }

  // MARK: 内部

  func tileLocation(ofFolder id: UUID, in pages: [[LaunchpadTile]]? = nil) -> (
    page: Int, index: Int
  )? {
    let pages = pages ?? self.pages
    for (page, tiles) in pages.enumerated() {
      if let index = tiles.firstIndex(where: { $0.folder?.id == id }) { return (page, index) }
    }
    return nil
  }

  private func removeAppFromPages(_ appID: String, pages: inout [[LaunchpadTile]]) {
    for pageIndex in pages.indices {
      pages[pageIndex] = pages[pageIndex].compactMap { tile in
        switch tile {
        case .app(let app):
          return app.id == appID ? nil : tile
        case .folder(var folder):
          folder.pages = folder.pages.map { $0.filter { $0.id != appID } }
            .filter { !$0.isEmpty }
          switch folder.apps.count {
          case 0: return nil
          case 1: return folder.apps.first.map(LaunchpadTile.app)
          default: return .folder(folder)
          }
        }
      }
    }
  }

  // MARK: 偏好里的存法

  /// 偏好里存的 JSON 字符串（SettingsArchive 的「设置」一类跟着走：它注册了默认值，用户改过才写进文件）
  func jsonString() -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(self) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  /// 偏好里存过的原样（用来判断「存过但读不出来」：不能拿默认排法把人家的布局覆盖掉）
  static func storedText(
    in defaults: UserDefaults = .standard,
    domainName: String? = Bundle.main.bundleIdentifier
  ) -> String? {
    // 先读自己这个 defaults（单测、设置页注入的 suite 都用它）；再退到持久域（App 正常跑时 Bundle id 那个域）
    if let text = defaults.string(forKey: Prefs.launchpadLayout), !text.isEmpty { return text }
    guard let domainName, let domain = defaults.persistentDomain(forName: domainName),
      let text = domain[Prefs.launchpadLayout] as? String, !text.isEmpty
    else { return nil }
    return text
  }

  /// 存过的布局的三种状态：没存过 / 读出来了 / 存过但读不出来（原文留着，打开时另存到一个键、不写盘）
  enum Stored: Equatable {
    case missing
    case loaded(LaunchpadLayout)
    case unreadable(String)
  }

  static func stored(
    in defaults: UserDefaults = .standard,
    domainName: String? = Bundle.main.bundleIdentifier
  ) -> Stored {
    guard let text = storedText(in: defaults, domainName: domainName) else { return .missing }
    guard let data = text.data(using: .utf8),
      let layout = try? JSONDecoder().decode(LaunchpadLayout.self, from: data)
    else { return .unreadable(text) }
    return .loaded(layout)
  }

  /// 读偏好里的布局；没存过、空串、坏 JSON、更新版本的格式都返回 nil（调用方按第一次用处理）。
  /// 走 `stored`，和打开时同一套「读得出来 / 读不出来」的判断。
  static func load(from defaults: UserDefaults) -> LaunchpadLayout? {
    guard case .loaded(let layout) = stored(in: defaults, domainName: nil) else { return nil }
    return layout
  }

  /// 打开时拿哪份布局、要不要存（F7 / F27 的纯函数，单测直接喂）：
  /// - 没存过 → 默认排法，先不存（等旧库导入或用户第一次改动再写）
  /// - 存过但读不出来 → 这次只在内存里用默认排法，**不写盘**（原文留着，用户第一次改动才覆盖）
  /// - 读出来了 → 合并本机目录、只在有一页超过容量时整理；和存的一样就不重写
  nonisolated static func openingPlan(
    stored: Stored, apps: [LaunchpadAppRef], defaults: [DefaultApp], capacity: Int
  ) -> (layout: LaunchpadLayout, shouldSave: Bool) {
    switch stored {
    case .unreadable:
      return (defaultLayout(defaults, capacity: capacity), false)
    case .missing:
      return (defaultLayout(defaults, capacity: capacity), false)
    case .loaded(let loaded):
      let merged = loaded.merged(apps: apps, capacity: capacity).tidied(capacity: capacity)
      return (merged, merged != loaded)
    }
  }

  /// 偏好里到底存没存过（设置 › 启动台用它说「沿用现在的排列」）；单测传自己的套件名
  static func isStored(
    in defaults: UserDefaults = .standard,
    domainName: String? = Bundle.main.bundleIdentifier
  ) -> Bool {
    storedText(in: defaults, domainName: domainName) != nil
  }

  /// 存盘（只在真的变了时写：打开一次就重写一遍既多余，也会在「存过但读不出来」时把原文顶掉）
  @discardableResult
  static func save(
    _ layout: LaunchpadLayout, to defaults: UserDefaults = .standard,
    domainName: String? = Bundle.main.bundleIdentifier
  ) -> Bool {
    guard let text = layout.jsonString() else { return false }
    guard storedText(in: defaults, domainName: domainName) != text else { return false }
    defaults.set(text, forKey: Prefs.launchpadLayout)
    return true
  }

  static func appending(_ app: LaunchpadAppRef, to pages: [[LaunchpadAppRef]])
    -> [[LaunchpadAppRef]]
  {
    var pages = pages
    if pages.isEmpty { pages = [[]] }
    if pages[pages.count - 1].count >= folderCapacity { pages.append([]) }
    pages[pages.count - 1].append(app)
    return pages
  }
}

extension Array {
  /// 越界时给 nil（整数下标越界在拖动、导入的脏数据里都可能碰到）
  nonisolated subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
