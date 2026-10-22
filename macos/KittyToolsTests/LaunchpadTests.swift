// 启动台的布局纯函数单测（第八族，2026-10-18，SPEC §5.1 / §10）：整理、分页、默认排法、合并本机 App、
// 挪格子、建 / 加 / 拖出 / 解散文件夹、删 App、Codable 往返、偏好读写。不碰窗口、不扫真实目录（那在 LaunchpadCatalogTests）。

import Foundation
import Testing

@testable import KittyTools

struct LaunchpadTests {
  private func ref(_ name: String, bundle: String? = nil) -> LaunchpadAppRef {
    LaunchpadAppRef(
      bundleID: bundle ?? "com.example.\(name.lowercased())", path: "/Applications/\(name).app")
  }

  private func app(_ name: String, system: Bool = false, utilities: Bool = false)
    -> LaunchpadLayout.DefaultApp
  {
    LaunchpadLayout.DefaultApp(
      ref: ref(name), name: name, isSystem: system, inUtilities: utilities)
  }

  // MARK: 整理

  @Test func sanitizeDropsDuplicatesEmptyPagesAndThinFolders() {
    let a = ref("A")
    let b = ref("B")
    let c = ref("C")
    let folder = LaunchpadFolder(name: "  ", pages: [[b], [c]])
    let pages: [[LaunchpadTile]] = [
      [.app(a), .app(a), .folder(folder)],
      [],
      [.folder(LaunchpadFolder(name: "空", pages: []))],
      [.app(b)],
    ]
    let clean = LaunchpadLayout.sanitized(pages)
    // b 被文件夹先占住，后面那个 .app(b) 丢掉；文件夹里 c 也在，两个 → 保留并改名「未命名」
    #expect(clean.count == 1)
    #expect(clean[0].count == 2)
    #expect(clean[0][0].app?.id == a.id)
    #expect(clean[0][1].folder?.name == LaunchpadLayout.untitledFolder)
    #expect(clean[0][1].folder?.apps.map(\.id) == [b.id, c.id])
  }

  @Test func singleAppFolderDissolves() {
    let a = ref("A")
    let b = ref("B")
    let pages: [[LaunchpadTile]] = [[.app(a), .folder(LaunchpadFolder(name: "X", pages: [[b]]))]]
    let clean = LaunchpadLayout.sanitized(pages)
    #expect(clean == [[.app(a), .app(b)]])
  }

  @Test func paginateByCapacityAndFolderCapacity() {
    let refs = (0..<10).map { ref("A\($0)") }
    let tiles = refs.map(LaunchpadTile.app)
    let pages = LaunchpadLayout.paginate(tiles, capacity: 4)
    #expect(pages.map(\.count) == [4, 4, 2])
    let folder = LaunchpadLayout.paginateFolder(refs)
    // macOS 15 的文件夹一页是 7 × 5 = 35 个（F10：本机旧库里有一个 35 个的文件夹页）
    #expect(folder.map(\.count) == [10])
    #expect(LaunchpadLayout.paginate([], capacity: 4).isEmpty)
    #expect(
      LaunchpadLayout.paginate(tiles, capacity: 0).map(\.count) == [1, 1, 1, 1, 1, 1, 1, 1, 1, 1])
  }

  // MARK: 默认排法

  @Test func defaultLayoutPutsSystemFirstUtilitiesInFolderThenOthers() {
    let apps = [
      app("Zoom"), app("活动监视器", system: true), app("终端", system: true, utilities: true),
      app("Safari", system: true), app("磁盘工具", system: true, utilities: true), app("Alfred"),
    ]
    let layout = LaunchpadLayout.defaultLayout(apps, capacity: 4)
    let names = layout.tiles.map { tile -> String in
      switch tile {
      case .app(let ref): ref.bundleID ?? ref.path
      case .folder(let folder): "folder:" + folder.name
      }
    }
    // 系统 App 按显示名（本地化顺序）：Safari、活动监视器 → 两个 App 一页（容量 4 放得下）
    // 再「其他」文件夹（终端、磁盘工具），最后别的（Alfred、Zoom）
    #expect(names.count == 5)
    #expect(names[0] == "com.example.safari")
    #expect(names[1] == "com.example.活动监视器")
    #expect(names[2] == "folder:其他")
    #expect(names[3] == "com.example.alfred")
    #expect(names[4] == "com.example.zoom")
    guard case .folder(let utilities) = layout.tiles[2] else {
      Issue.record("第三个应该是「其他」文件夹")
      return
    }
    #expect(utilities.apps.count == 2)
    #expect(utilities.pages.count == 1)
  }

  // MARK: 合并本机 App

  @Test func mergeAppendsNewAndRemovesGone() {
    let a = ref("A")
    let b = ref("B")
    let c = ref("C")
    let layout = LaunchpadLayout(pages: [[.app(a), .app(b)]])
    let merged = layout.merged(apps: [a, c], capacity: 4)
    #expect(merged.apps.map(\.id) == [a.id, c.id])
    // 没有变化时原样返回（导入的多页布局不被重排）
    #expect(merged.merged(apps: [a, c], capacity: 4) == merged)
  }

  @Test func mergeDissolvesFolderThatLostApps() {
    let a = ref("A")
    let b = ref("B")
    let folder = LaunchpadFolder(name: "X", pages: [[a, b]])
    let layout = LaunchpadLayout(pages: [[.folder(folder)]])
    let merged = layout.merged(apps: [a], capacity: 4)
    #expect(merged.tiles.count == 1)
    #expect(merged.tiles[0].app?.id == a.id)
  }

  // MARK: 挪格子

  @Test func movingWithinPageAndAcrossPages() {
    let refs = (0..<5).map { ref("A\($0)") }
    let layout = LaunchpadLayout(pages: [[.app(refs[0]), .app(refs[1])], [.app(refs[2])]])
    // 把第 0 页第 2 格挪到第 0 页最前（slot 是拿掉这一格之后的下标，F2）
    let moved = layout.moving(LaunchpadTile.app(refs[1]).id, toPage: 0, slot: 0, capacity: 2)
    #expect(moved.tiles.map { $0.app?.id } == [refs[1].id, refs[0].id, refs[2].id])
    // 挪到第 1 页末尾：容量 2 放得下，页边界不往前补
    let pushed = layout.moving(LaunchpadTile.app(refs[0]).id, toPage: 1, slot: 1, capacity: 2)
    #expect(pushed.pages.map(\.count) == [1, 2])
    #expect(pushed.tiles.map { $0.app?.id } == [refs[1].id, refs[2].id, refs[0].id])
    // 按整份下标挪
    let flat = layout.moving(LaunchpadTile.app(refs[2]).id, toFlatIndex: 0, capacity: 4)
    #expect(flat.tiles.map { $0.app?.id } == [refs[2].id, refs[0].id, refs[1].id])
    // 满的一页往里插：多出来的那个推到下一页开头，只往后不往前
    let full = LaunchpadLayout(pages: [
      [.app(refs[0]), .app(refs[1])], [.app(refs[2]), .app(refs[3])],
    ])
    let overflow = full.moving(LaunchpadTile.app(refs[2]).id, toPage: 0, slot: 0, capacity: 2)
    #expect(overflow.pages.map(\.count) == [2, 2])
    #expect(overflow.pages[0].map { $0.app?.id } == [refs[2].id, refs[0].id])
    #expect(overflow.pages[1].map { $0.app?.id } == [refs[1].id, refs[3].id])
  }

  // MARK: 文件夹

  @Test func foldingCreatesFolderWithTargetFirst() {
    let a = ref("A")
    let b = ref("B")
    let layout = LaunchpadLayout(pages: [[.app(a), .app(b)]])
    let folded = layout.folding(
      LaunchpadTile.app(b).id, onto: LaunchpadTile.app(a).id, name: "工具", capacity: 4)
    #expect(folded.tiles.count == 1)
    guard case .folder(let folder) = folded.tiles[0] else {
      Issue.record("应该是一个文件夹")
      return
    }
    #expect(folder.name == "工具")
    #expect(folder.apps.map(\.id) == [a.id, b.id])
  }

  @Test func addingAndDraggingOutOfFolder() {
    let a = ref("A")
    let b = ref("B")
    let c = ref("C")
    let layout = LaunchpadLayout(pages: [[.app(a), .app(b), .app(c)]])
    let folded = layout.folding(
      LaunchpadTile.app(b).id, onto: LaunchpadTile.app(a).id, name: "X", capacity: 4)
    // 把 c 拖到文件夹上
    guard let folderID = folded.tiles.compactMap(\.folder).first?.id else {
      Issue.record("没有文件夹")
      return
    }
    let added = folded.adding(c.id, to: folderID, capacity: 4)
    #expect(added.tiles.count == 1)
    #expect(added.tiles[0].folder?.apps.map(\.id) == [a.id, b.id, c.id])
    // 把 c 拖出来：文件夹还在（剩两个），c 回到文件夹后面
    let out = added.draggingOut(c.id, from: folderID, capacity: 4)
    #expect(out.tiles.count == 2)
    #expect(out.tiles[0].folder?.apps.map(\.id) == [a.id, b.id])
    #expect(out.tiles[1].app?.id == c.id)
    // 再把 b 拖出来：文件夹只剩 a，解散成两个 App
    let dissolved = out.draggingOut(b.id, from: folderID, capacity: 4)
    #expect(dissolved.tiles.count == 3)
    #expect(dissolved.tiles.compactMap { $0.app?.id } == [a.id, b.id, c.id])
  }

  @Test func removingAppFromFolderDissolvesWhenOneLeft() {
    let a = ref("A")
    let b = ref("B")
    let folder = LaunchpadFolder(name: "X", pages: [[a, b]])
    let layout = LaunchpadLayout(pages: [[.folder(folder), .app(ref("C"))]])
    let removed = layout.removing(b.id, capacity: 4)
    #expect(removed.tiles.compactMap { $0.app?.id } == [a.id, "com.example.c"])
  }

  @Test func dissolvingFolderReturnsAppsToTopLevel() {
    let a = ref("A")
    let b = ref("B")
    let folder = LaunchpadFolder(name: "X", pages: [[a, b]])
    let layout = LaunchpadLayout(pages: [[.app(ref("C")), .folder(folder)]])
    guard let id = layout.tiles.compactMap(\.folder).first?.id else { return }
    let dissolved = layout.dissolving(id, capacity: 4)
    #expect(dissolved.tiles.compactMap { $0.app?.id } == ["com.example.c", a.id, b.id])
  }

  @Test func renamingFolderTrimsAndFallsBack() {
    let folder = LaunchpadFolder(name: "X", pages: [[ref("A"), ref("B")]])
    let layout = LaunchpadLayout(pages: [[.folder(folder)]])
    #expect(layout.renaming(folder.id, to: "  开发工具  ").tiles[0].folder?.name == "开发工具")
    #expect(layout.renaming(folder.id, to: "   ").tiles[0].folder?.name == "未命名")
  }

  // MARK: 存偏好

  @Test func codableRoundTripAndBadFormat() throws {
    let folder = LaunchpadFolder(name: "工具", pages: [[ref("A"), ref("B")]])
    let layout = LaunchpadLayout(pages: [[.app(ref("C")), .folder(folder)]])
    let text = try #require(layout.jsonString())
    let empty = try #require(UserDefaults(suiteName: "launchpad.test"))
    empty.removePersistentDomain(forName: "launchpad.test")
    #expect(LaunchpadLayout.load(from: empty) == nil)  // 没存过 → nil
    let decoded = try JSONDecoder().decode(LaunchpadLayout.self, from: Data(text.utf8))
    #expect(decoded == layout)
    // 更新版本的格式：读成 nil（不炸）
    let newer = "{\"format\":99,\"pages\":[]}"
    #expect((try? JSONDecoder().decode(LaunchpadLayout.self, from: Data(newer.utf8))) == nil)
    // 偏好往返
    let defaults = try #require(UserDefaults(suiteName: "launchpad.test.roundtrip"))
    defaults.removePersistentDomain(forName: "launchpad.test.roundtrip")
    defaults.set(text, forKey: Prefs.launchpadLayout)
    #expect(LaunchpadLayout.load(from: defaults) == layout)
    #expect(LaunchpadLayout.isStored(in: defaults, domainName: "launchpad.test.roundtrip"))
    defaults.removePersistentDomain(forName: "launchpad.test.roundtrip")
  }

  @Test func emptyLayoutHasOneDisplayPage() {
    let layout = LaunchpadLayout(pages: [])
    #expect(layout.pageCount == 1)
    #expect(layout.tiles.isEmpty)
  }
}

/// macOS 15 上整个藏起来（2026-10-19 用户定：15 有系统自带的启动台）。开发机是 27，真 15 只能手测；
/// 这里把「这台系统有没有」喂成 false，看各入口列的东西里都没有它
@MainActor
struct LaunchpadAvailabilityTests {
  @Test func hiddenOnMacOS15() {
    #expect(
      Launchpad.isAvailable == (ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26))
    #expect(HotKeyAction.launchpad.isAvailable == Launchpad.isAvailable)
    #expect(Feature.launchpad.isAvailable == Launchpad.isAvailable)
    #expect(HotKeyAction.clipboard.isAvailable)

    // 快捷键页、菜单栏、启动器共用的分节（macOS 15 上 Feature.enabled 里没有启动台）
    let all = Set(Feature.allCases)
    let without = all.subtracting([.launchpad])
    let hidden = HotKeyAction.visibleSections(enabled: without).flatMap(\.actions)
    let shown = HotKeyAction.visibleSections(enabled: all).flatMap(\.actions)
    #expect(!hidden.contains(.launchpad))
    #expect(shown.contains(.launchpad))
    #expect(shown.filter { $0 != .launchpad } == hidden)
    // 设置侧栏
    #expect(!SettingsPage.visible(launchpad: false).contains(.launchpad))
    #expect(SettingsPage.visible(launchpad: true) == SettingsPage.allCases)
    // 速查表
    #expect(!ShortcutsSheet.groups(enabled: without).contains { $0.globals.contains(.launchpad) })
    #expect(ShortcutsSheet.groups(enabled: all).contains { $0.globals.contains(.launchpad) })
    #expect(
      ShortcutsSheet.groups(enabled: without).count + 1 == ShortcutsSheet.groups(enabled: all).count
    )
  }
}
