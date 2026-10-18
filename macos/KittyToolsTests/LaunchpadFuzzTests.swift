// 启动台布局的随机操作测试（SPEC §5.1 的不变式；按需 / 每次全量都跑，步数小、快）。
// 种子固定（可用 TEST_RUNNER_KITTY_LAUNCHPAD_FUZZ_SEED 换一批），每一步做一种拖动 / 文件夹 / 删 App / 重新分页操作，
// 之后检查：池子里的 App 每个恰好出现一次；没有空页、空文件夹、只剩一个 App 的文件夹；页内格子不超过容量。
// 出问题时报出种子和步号，能照着复现。

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
    let seed = UInt64(environment["TEST_RUNNER_KITTY_LAUNCHPAD_FUZZ_SEED"] ?? "") ?? 0x5EED_1018
    // 按需开：TEST_RUNNER_KITTY_LAUNCHPAD_FUZZ=<步数>（默认 1500；几万步也只要几秒）
    let steps = Int(environment["TEST_RUNNER_KITTY_LAUNCHPAD_FUZZ"] ?? "") ?? 1500
    var random = Seeded(state: seed)
    let pool = (0..<26).map(ref)
    let ids = pool.map(\.id)
    let idSet = Set(ids)
    let capacity = 6
    var layout = LaunchpadLayout.defaultLayout(
      pool.enumerated().map { index, ref in
        LaunchpadLayout.DefaultApp(
          ref: ref, name: "App\(index)", isSystem: index % 3 != 2, inUtilities: index % 3 == 1)
      }, capacity: capacity)
    check(layout, pool: idSet, capacity: capacity, step: 0, seed: seed)

    for step in 1...max(steps, 1) {
      let operation = random.next(7)
      let tileIDs = layout.tiles.map(\.id)
      let appIDs = layout.apps.map(\.id)
      switch operation {
      case 0 where tileIDs.count > 1:
        layout = layout.moving(
          tileIDs[random.next(tileIDs.count)], toPage: random.next(layout.pageCount + 1),
          slot: random.next(capacity + 2), capacity: capacity)
      case 1 where appIDs.count > 1:
        // 拖一个 App 到另一格上（目标可能是 App 或文件夹）
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
            folder.apps[random.next(folder.apps.count)].id, from: folder.id, capacity: capacity)
        }
      case 4:
        layout = layout.repaginated(capacity: capacity)
      case 5 where appIDs.count > 1:
        // 从布局里拿掉一个再合并回来（模拟卸载 / 重装），App 必须还是一个不少
        let removed = appIDs[random.next(appIDs.count)]
        var without = layout.removing(removed, capacity: capacity)
        without = without.merged(apps: pool, capacity: capacity)
        layout = without
      default:
        let folders = layout.tiles.compactMap(\.folder)
        if let folder = folders[safe: random.next(folders.count)] {
          layout = layout.dissolving(folder.id, capacity: capacity)
        }
      }
      check(layout, pool: idSet, capacity: capacity, step: step, seed: seed)
    }
  }
}
