// 启动台 App 目录的单测（SPEC §5.3）：真实扫一遍本机（约 65ms，和 LauncherTests 一样），确认只留 .app、没有访达、
// 没有系统设置的面板、id 不重复；默认排法能把每一个 App 都放进去、一个不多一个不少；分类名映射和文件夹名字。

import Foundation
import Testing

@testable import KittyTools

struct LaunchpadCatalogTests {
  @Test func realScanKeepsAppsOnly() {
    let apps = LaunchpadCatalog.load()
    #expect(!apps.isEmpty)
    #expect(apps.allSatisfy { $0.path.hasSuffix(".app") })
    #expect(!apps.contains { $0.path.hasSuffix("/Finder.app") })
    #expect(Set(apps.map(\.id)).count == apps.count)
    // 系统设置的面板（AppCatalog 里 kind 是 .url）一个都不在
    #expect(!apps.contains { $0.path.contains("ExtensionKit/Extensions") })
    // 系统 App 至少认得出 Safari / 活动监视器里的一个
    #expect(apps.contains { $0.isSystem })
    // 排序按显示名（新装的追加顺序稳定）
    let names = apps.map(\.name)
    #expect(names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
  }

  @Test func defaultLayoutCoversEveryAppExactlyOnce() {
    let apps = LaunchpadCatalog.load()
    let layout = LaunchpadLayout.defaultLayout(
      apps.map {
        LaunchpadLayout.DefaultApp(
          ref: $0.ref, name: $0.name, isSystem: $0.isSystem, inUtilities: $0.inUtilities)
      }, capacity: 35)
    #expect(Set(layout.apps.map(\.id)) == Set(apps.map(\.id)))
    #expect(layout.apps.count == apps.count)
    // 每页不超过容量
    #expect(layout.pages.allSatisfy { $0.count <= 35 })
    // 一个页都没有 / 文件夹只剩一个：默认排法不会产生
    #expect(layout.tiles.allSatisfy { $0.folder == nil || ($0.folder?.apps.count ?? 0) >= 2 })
  }

  @Test func categoryNamesAndFolderNaming() {
    #expect(LaunchpadCatalog.categoryName("public.app-category.productivity") == "效率")
    #expect(LaunchpadCatalog.categoryName("public.app-category.utilities") == "工具")
    #expect(LaunchpadCatalog.categoryName("public.app-category.unknown-thing") == nil)
    #expect(LaunchpadCatalog.categoryName("something-else") == nil)
    let a = LaunchpadCatalog.load().first { $0.category != nil }
    if let a {
      // 两个分类相同 → 用分类；不同 / 没有 → 第一个的分类；第一个也没有 → 未命名
      #expect(LaunchpadCatalog.folderName(first: a, second: a) == a.category)
      #expect(LaunchpadCatalog.folderName(first: a, second: nil) == a.category)
      #expect(LaunchpadCatalog.folderName(first: nil, second: nil) == "未命名")
    }
  }
}
