// 启动台布局的随机操作测试（SPEC §5.1 / §10.2 的不变式；每次全量都跑，按需加大步数）。
// 种子固定（KITTY_LAUNCHPAD_FUZZ_SEED 换一批、KITTY_LAUNCHPAD_FUZZ 改进步数；xcodebuild 去掉 TEST_RUNNER_ 前缀），
// 每一步随机做：挪格子、建文件夹、改名、拖出、加进文件夹、卸载、新装、改行列数、重排、删 App；之后检查：
// 池子里的 App 每个恰好出现一次；没有空页、空文件夹、只剩一个 App 的文件夹；页内格子不超过容量；
// 新装的接在最后、原来的页和顺序不变（F7 / F11）。出问题时报种子和步号。

import CoreGraphics
import Foundation
import Testing

@testable import KittyTools

struct LaunchpadFuzzTests {
  /// 线性同余，够随机、可复现
  private struct Seeded {
    var state: UInt64
    mutating func next(_ bound: Int) -> Int {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Int((state >> 33) % UInt64(max(bound, 1)))
    }
  }

  private func ref(_ index: Int) -> LaunchpadAppRef {
    LaunchpadAppRef(bundleID: "com.example.app\(index)", path: "/Applications/App\(index).app")
  }

  private func check(
    _ layout: LaunchpadLayout, pool: Set<String>, capacity: Int, step: Int, seed: UInt64
  ) {
    var seen: [String] = []
    for page in layout.pages {
      #expect(!page.isEmpty, "种子 \(seed) 第 \(step) 步：空页")
      #expect(page.count <= capacity, "种子 \(seed) 第 \(step) 步：一页超过容量")
      for tile in page {
        switch tile {
        case .app(let app):
          seen.append(app.id)
        case .folder(let folder):
          #expect(folder.apps.count >= 2, "种子 \(seed) 第 \(step) 步：只剩一个 App 的文件夹")
          #expect(folder.pages.allSatisfy { !$0.isEmpty }, "种子 \(seed) 第 \(step) 步：文件夹空页")
          #expect(folder.pages.allSatisfy { $0.count <= LaunchpadLayout.folderCapacity })
          seen += folder.apps.map(\.id)
        }
      }
    }
    if Set(seen).count != seen.count {
      var counts: [String: Int] = [:]
      for id in seen { counts[id, default: 0] += 1 }
      let duplicates = counts.filter { $0.value > 1 }.map(\.key).sorted()
      Issue.record("种子 \(seed) 第 \(step) 步：有重复的 App \(duplicates)")
    }
    #expect(Set(seen) == pool, "种子 \(seed) 第 \(step) 步：App 少了 / 多了")
  }

  @Test func randomOperationsKeepInvariants() {
    let environment = ProcessInfo.processInfo.environment
    let seed = UInt64(environment["KITTY_LAUNCHPAD_FUZZ_SEED"] ?? "") ?? 0x5EED_1018
    // 按需开：KITTY_LAUNCHPAD_FUZZ=<步数>（默认 1500；几万步也只要几秒）
    let steps = Int(environment["KITTY_LAUNCHPAD_FUZZ"] ?? "") ?? 1500
    print("launchpad-fuzz seed=\(seed) steps=\(max(steps, 1))")
    var random = Seeded(state: seed)
    let all = (0..<40).map(ref)
    var installed = Array(all.prefix(26))
    var installedIDs = Set(installed.map(\.id))
    let capacityChoices = [4, 6, 9, 12, 35]
    var capacity = 6
    var layout = LaunchpadLayout.defaultLayout(
      installed.enumerated().map { index, ref in
        LaunchpadLayout.DefaultApp(
          ref: ref, name: "App\(index)", isSystem: index % 3 != 2, inUtilities: index % 3 == 1)
      }, capacity: capacity)
    check(layout, pool: installedIDs, capacity: capacity, step: 0, seed: seed)

    for step in 1...max(steps, 1) {
      do {
        autoreleasepool {
          let operation = random.next(11)
          let tileIDs = layout.tiles.map(\.id)
          let appIDs = layout.apps.map(\.id)
          switch operation {
          case 0 where tileIDs.count > 1:
            let tileID = tileIDs[random.next(tileIDs.count)]
            let target = random.next(layout.pageCount + 1)
            let before = layout
            let source = before.locate(tileID)?.page ?? 0
            layout = layout.moving(
              tileID, toPage: target, slot: random.next(capacity + 2), capacity: capacity)
            // 页边界（F7 / G19）：源页和目标页之间的那几页一格都不动——整份重排会让它们都往前串一格
            if before.pages[source].count > 1, target > source + 1, target < before.pages.count {
              for page in (source + 1)..<target {
                #expect(
                  layout.pages[safe: page] == before.pages[page],
                  "种子 \(seed) 第 \(step) 步：挪动改了中间第 \(page) 页")
              }
            }
          case 1 where appIDs.count > 1:
            let appID = appIDs[random.next(appIDs.count)]
            let source = layout.tiles.first { $0.app?.id == appID }?.id
            let target = tileIDs[random.next(tileIDs.count)]
            if let source, source != target {
              layout = layout.folding(source, onto: target, name: "文件夹", capacity: capacity)
            }
          case 2:
            let folders = layout.tiles.compactMap(\.folder)
            if let folder = folders[safe: random.next(folders.count)] {
              layout = layout.renaming(folder.id, to: "名\(random.next(100))")
            }
          case 3:
            let folders = layout.tiles.compactMap(\.folder)
            if let folder = folders[safe: random.next(folders.count)], folder.apps.count > 1 {
              layout = layout.draggingOut(
                folder.apps[random.next(folder.apps.count)].id, from: folder.id,
                capacity: capacity)
            }
          case 4:
            let folders = layout.tiles.compactMap(\.folder)
            if let folder = folders[safe: random.next(folders.count)],
              let appID = appIDs[safe: random.next(appIDs.count)]
            {
              layout = layout.adding(appID, to: folder.id, capacity: capacity)
            }
          case 5 where installed.count > 2:
            let app = installed[random.next(installed.count)]
            installed.removeAll { $0.id == app.id }
            installedIDs.remove(app.id)
            layout = layout.removing(app.id, capacity: capacity)
          case 6 where installed.count < all.count:
            // 新装的插在目录任意位置，布局里都只能接在最后
            let fresh = all.first { !installedIDs.contains($0.id) }!
            let before = layout
            installed.insert(fresh, at: random.next(installed.count + 1))
            installedIDs.insert(fresh.id)
            layout = layout.merged(apps: installed, capacity: capacity)
            // 原来每一页、每个 App 的相对顺序都不动；新 App 在最后
            let oldTiles = before.tiles.map(\.id)
            let newTiles = layout.tiles.map(\.id)
            #expect(
              Array(newTiles.prefix(oldTiles.count)) == oldTiles,
              "种子 \(seed) 第 \(step) 步：新装的重排了原来的图标")
            #expect(layout.apps.last?.id == fresh.id)
          case 7:
            capacity = capacityChoices[random.next(capacityChoices.count)]
            layout = layout.repaginated(capacity: capacity)
          case 8:
            let folders = layout.tiles.compactMap(\.folder)
            if let folder = folders[safe: random.next(folders.count)] {
              layout = layout.dissolving(folder.id, capacity: capacity)
            }
          case 9:
            // 放进文件夹的任意一格（顶层、别的文件夹、同一个文件夹里挪，2026-10-18 交互对齐）
            let folders = layout.tiles.compactMap(\.folder)
            if let folder = folders[safe: random.next(folders.count)],
              let appID = appIDs[safe: random.next(appIDs.count)]
            {
              let before = layout.apps.count
              layout = layout.placing(
                appID, inFolder: folder.id, page: random.next(folder.pages.count + 1),
                index: random.next(LaunchpadLayout.folderCapacity + 2), capacity: capacity)
              #expect(layout.apps.count == before, "种子 \(seed) 第 \(step) 步：放进文件夹丢了 App")
            }
          default:
            layout = layout.tidied(capacity: capacity)
          }
        }
      }
      check(layout, pool: installedIDs, capacity: capacity, step: step, seed: seed)
    }
  }
  /// 过一遍 model 的随机操作（F11 第二层）：翻页、搜索、抖动、按住 / 拖 / 松手、取消、开关文件夹、滚轮。
  /// 不做界面，只碰状态机；每一步后检查同一组不变式。定时器（1 秒抖动 / 0.4 秒停留）不等它响，结束前统一收掉。
  @Test func modelOperationsKeepInvariants() {
    let environment = ProcessInfo.processInfo.environment
    let seed = UInt64(environment["KITTY_LAUNCHPAD_FUZZ_SEED"] ?? "") ?? 0x5EED_1018
    let steps = min(Int(environment["KITTY_LAUNCHPAD_FUZZ"] ?? "") ?? 800, 4000)
    print("launchpad-model-fuzz seed=\(seed) steps=\(max(steps, 1))")
    var random = Seeded(state: seed &+ 0x9E37)
    let pool = (0..<18).map(ref)
    let layout = LaunchpadLayout.defaultLayout(
      pool.enumerated().map { index, ref in
        LaunchpadLayout.DefaultApp(
          ref: ref, name: "App\(index)", isSystem: index % 3 != 2, inUtilities: index % 3 == 1)
      }, capacity: 6)
    let model = LaunchpadModel(
      layout: layout,
      catalog: pool.map { app in
        LaunchpadProjectApp(
          id: app.id, ref: app,
          item: LauncherItem(
            kind: .app, target: app.path, title: app.bundleID ?? "App", subtitle: "应用程序"),
          url: URL(filePath: app.path), isSystem: false, inUtilities: false, isAppStore: false,
          category: nil)
      }, icons: LaunchpadIcons(), columns: 3, rows: 2, screenSize: CGSize(width: 900, height: 600),
      dragTiming: .immediate)
    let frame = CGRect(
      x: model.metrics.side, y: 0, width: model.metrics.gridWidth, height: model.metrics.gridHeight)
    for page in 0..<model.pageCount { model.gridFrames[page] = frame }
    let idSet = Set(pool.map(\.id))
    func point() -> CGPoint {
      CGPoint(
        x: frame.minX + CGFloat(random.next(Int(frame.width))),
        y: frame.minY + CGFloat(random.next(Int(frame.height))))
    }

    for step in 1...max(steps, 1) {
      // 每步包一层（SPEC §8；一步里会建界面用的动画事务、几个 Task）
      autoreleasepool {
        let operation = random.next(11)
        switch operation {
        case 0:
          model.go(to: random.next(model.pageCount + 2))
        case 1:
          model.go(to: 0)
          model.query = model.query.isEmpty ? "App" : ""
        case 2:
          model.optionChanged(random.next(2) == 0)
        case 3:
          if model.jiggling { model.exitJiggle() } else { model.enterJiggle() }
        case 4:
          let tiles = model.currentTiles
          if let tile = tiles[safe: random.next(tiles.count)] {
            model.beginDrag(
              tile: tile, appID: tile.app?.id, folder: nil as UUID?, at: point())
            model.updateDrag(location: point(), pageWidth: 900)
            model.updateDrag(location: point(), pageWidth: 900)
            // 一半的时候当成在图标中心停够了：走合成那一支（计时器 0.4 秒，这里不等，G19）
            if random.next(2) == 0 { model.armCombineForTesting() }
            model.endDrag()
          }
        case 5:
          let tiles = model.currentTiles
          if let tile = tiles[safe: random.next(tiles.count)] {
            model.beginDrag(
              tile: tile, appID: tile.app?.id, folder: nil as UUID?, at: point())
            model.updateDrag(location: point(), pageWidth: 900)
            model.cancel()
            model.updateDrag(location: point(), pageWidth: 900)
            model.endDrag()
          }
        case 6:
          if let folder = model.layout.tiles.compactMap({ $0.folder })[safe: 0] {
            if model.openFolderID == nil {
              model.openFolder(folder.id)
            } else {
              model.closeFolder()
            }
          }
        case 7:
          model.scroll(
            deltaX: 0, deltaY: CGFloat(random.next(5) - 2), precise: false, phase: [],
            momentum: [], time: Double(step), inverted: false)
        case 8:
          // 文件夹开着时从里面拖：落在面板里（文件夹里挪）或拖出去（关上、回主网格），2026-10-18 交互对齐
          let apps = model.folderApps
          let index = random.next(max(apps.count, 1))
          if model.openFolderID != nil, let ref = apps[safe: index] {
            model.beginDrag(
              tile: .app(ref), appID: ref.id, folder: model.openFolderID,
              at: model.folderCellCenter(index), origin: model.folderCellCenter(index))
            for _ in 0..<3 {
              model.updateDrag(
                location: CGPoint(x: random.next(900), y: random.next(600)), pageWidth: 900)
            }
            if random.next(2) == 0 { model.armCombineForTesting() }
            model.endDrag()
          }
        case 9:
          // 空白处按住拖着翻页（或没挪够 = 点了空白）
          let travel = CGFloat(random.next(700) - 350)
          model.backgroundDragChanged(
            translation: CGSize(width: travel / 2, height: 0), time: Double(step))
          model.backgroundDragChanged(
            translation: CGSize(width: travel, height: 0), time: Double(step) + 0.05)
          model.backgroundDragEnded(time: Double(step) + 0.06)
        default:
          if model.jiggling { model.exitJiggle() }
          model.query = ""
          model.closeFolder()
        }
        check(
          model.layout, pool: idSet, capacity: 6, step: step, seed: seed)
        #expect(model.page >= 0 && model.page < max(model.displayPages.count, 1))
      }
    }
    model.exitJiggle()
    model.cancel()
    model.endDrag()
    model.query = ""
    check(model.layout, pool: idSet, capacity: 6, step: steps, seed: seed)
  }

}
