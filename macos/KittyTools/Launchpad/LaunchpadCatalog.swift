// 启动台的 App 目录（SPEC §5.3）：复用启动器的 AppCatalog.scan()（同一份目录、同一套去重和中文名、拼音、首字母），
// 只留 .app——不要系统设置的面板，也不要访达（macOS 15 的启动台里没有访达）。扫的时候顺带取 bundle id、是不是从
// App Store 装的（Contents/_MASReceipt/receipt，而且不在 /System 下）、LSApplicationCategoryType（文件夹名字用），
// 都只读 Info.plist / 看文件在不在，便宜。显示名、搜索用的名字直接沿用 LauncherItem，和现有启动器一致。
// 图标按 bundle id / 路径缓存在 LaunchpadIcons，面板收起后闲下来放掉（R11）。

import AppKit

nonisolated struct LaunchpadProjectApp: Identifiable {
  let id: String
  let ref: LaunchpadAppRef
  let item: LauncherItem
  let url: URL
  let isSystem: Bool
  let inUtilities: Bool
  let isAppStore: Bool
  /// LSApplicationCategoryType 的本地化名（「效率」「工具」…）；没有 / 不认识的是 nil
  let category: String?

  var path: String { ref.path }
  var bundleID: String? { ref.bundleID }
  var name: String { item.title }
}

enum LaunchpadCatalog {
  /// 扫本机的 .app。排序按显示名的本地化顺序，新装的 App 追加到布局末尾时顺序稳定
  static func load() -> [LaunchpadProjectApp] {
    AppCatalog.scan()
      .filter { $0.kind == .app && !$0.target.hasSuffix("/Finder.app") }
      .map { app($0) }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  /// 一个 .app 的额外信息（bundle id、分类、收据）；读不到 bundle id 时按路径认
  static func app(_ item: LauncherItem) -> LaunchpadProjectApp {
    let url = URL(filePath: item.target)
    let info = infoPlist(url)
    let bundleID = info?["CFBundleIdentifier"] as? String ?? Bundle(url: url)?.bundleIdentifier
    let path = item.target
    let categoryKey = info?["LSApplicationCategoryType"] as? String
    return LaunchpadProjectApp(
      id: bundleID ?? path,
      ref: LaunchpadAppRef(bundleID: bundleID, path: path),
      item: item, url: url,
      isSystem: path.hasPrefix("/System/"),
      inUtilities: path.hasPrefix("/System/Applications/Utilities/"),
      isAppStore: !path.hasPrefix("/System/")
        && FileManager.default.fileExists(atPath: path + "/Contents/_MASReceipt/receipt"),
      category: categoryKey.flatMap(categoryName))
  }

  /// 建文件夹时的名字：两个 App 分类相同时用它，不同就用第一个的，没有分类叫「未命名」（SPEC R4）
  static func folderName(first: LaunchpadProjectApp?, second: LaunchpadProjectApp?) -> String {
    let shared = first?.category == second?.category ? first?.category : nil
    return shared ?? first?.category ?? LaunchpadLayout.untitledFolder
  }

  /// 这些 App 里有没有 App Store 装的（抖动模式只有它们显示 ✕）
  static func canDelete(_ app: LaunchpadProjectApp) -> Bool { app.isAppStore }

  /// 包里的 Info.plist（解析失败返回 nil；只用来取 bundle id、分类）
  private static func infoPlist(_ url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url.appending(path: "Contents/Info.plist")) else {
      return nil
    }
    return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
  }

  /// LSApplicationCategoryType → 中文名（文件夹名字）。系统自带的分类都在这里；第三方自定义的不认识就是 nil。
  /// 用系统设置里那套叫法（工具、效率、图形与设计…）
  static func categoryName(_ key: String) -> String? {
    let tail = key.hasPrefix("public.app-category.") ? String(key.dropFirst(20)) : key
    return categories[tail]
  }

  private static let categories: [String: String] = [
    "business": "商务", "developer-tools": "开发者工具", "education": "教育",
    "entertainment": "娱乐", "finance": "财务", "games": "游戏", "graphics-design": "图形与设计",
    "healthcare-fitness": "健康与健身", "lifestyle": "生活", "medical": "医疗",
    "music": "音乐", "news": "新闻", "photography": "摄影", "productivity": "效率",
    "reference": "参考", "social-networking": "社交", "sports": "体育", "travel": "旅行",
    "utilities": "工具", "video": "视频", "weather": "天气", "books": "图书",
    "food-and-drink": "美食佳饮", "magazines-newspapers": "杂志与报纸", "shopping": "购物",
  ]
}

/// 图标缓存（按 bundle id / 路径）：一次打开里几十个 App 的图标只取一遍；面板收起后闲下来放掉（R11）。
/// 图标按显示大小取；同一份 NSImage 交给 SwiftUI 缩放，不按每个尺寸各存一份。
@MainActor
final class LaunchpadIcons {
  private var cache: [String: NSImage] = [:]

  func icon(for app: LaunchpadProjectApp, size: CGFloat) -> NSImage {
    if let image = cache[app.id] { return image }
    let image = NSWorkspace.shared.icon(forFile: app.path)
    image.size = NSSize(width: size, height: size)
    cache[app.id] = image
    return image
  }

  /// 面板收起后闲下来放掉（R11；由 Launchpad 的空闲回收调）
  func clear() { cache.removeAll() }

  var count: Int { cache.count }
}
