// 启动台的 App 目录（SPEC §5.3）：复用启动器的 AppCatalog.scan()（同一份目录、同一套去重和中文名、拼音、首字母），
// 只留 .app——不要系统设置的面板，也不要访达（macOS 15 的启动台里没有访达）。扫的时候顺带取 bundle id、是不是从
// App Store 装的（Contents/_MASReceipt/receipt，而且不在 /System 下）、LSApplicationCategoryType（文件夹名字用），
// 都只读 Info.plist / 看文件在不在，便宜。显示名、搜索用的名字直接沿用 LauncherItem，和现有启动器一致。
// 图标在后台画成位图、常驻在 LaunchpadIcons（2026-10-18 真机反馈后；原来是面板收起后闲下来放掉）。

import AppKit

nonisolated struct LaunchpadProjectApp: Identifiable, Sendable {
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
  /// 扫本机的 .app。排序按显示名的本地化顺序，新装的 App 追加到布局末尾时顺序稳定。
  /// 后台扫（F31）：`@concurrent` 让它离开主 actor 跑；用到的 AppCatalog / LauncherItem 都是
  /// nonisolated + Sendable，回来仍是 Sendable 的数组
  @concurrent
  nonisolated static func loadInBackground() async -> [LaunchpadProjectApp] { load() }

  nonisolated static func load() -> [LaunchpadProjectApp] {
    let scanned = AppCatalog.scan()
      .filter { $0.kind == .app && !$0.target.hasSuffix("/Finder.app") }
      .map { app($0) }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    return disambiguated(scanned)
  }

  /// 同一个 bundle id 有两份时（Xcode / Xcode-beta…）只留一格会丢一个 App：后面几份按路径认（F26）。
  /// 路径在布局里照样能打开；导入旧库时这些份退回按标题对。纯函数，单测直接喂假 App。
  nonisolated static func disambiguated(_ apps: [LaunchpadProjectApp]) -> [LaunchpadProjectApp] {
    var seen = Set<String>()
    return apps.map { app in
      guard seen.insert(app.id).inserted else {
        return LaunchpadProjectApp(
          id: app.path, ref: LaunchpadAppRef(bundleID: nil, path: app.path), item: app.item,
          url: app.url, isSystem: app.isSystem, inUtilities: app.inUtilities,
          isAppStore: app.isAppStore, category: app.category)
      }
      return app
    }
  }

  /// 一个 .app 的额外信息（bundle id、分类、收据）；读不到 bundle id 时按路径认
  nonisolated static func app(_ item: LauncherItem) -> LaunchpadProjectApp {
    let url = URL(filePath: item.target)
    let info = infoPlist(url)
    let bundleID = info?["CFBundleIdentifier"] as? String ?? Bundle(url: url)?.bundleIdentifier
    let path = item.target
    let categoryKey = info?["LSApplicationCategoryType"] as? String
    // Safari 之类 /Applications 里指向 /System/Cryptexes 的符号链接：按解开链接后的路径算「系统 App」（F43）
    let resolved = url.resolvingSymlinksInPath().path
    return LaunchpadProjectApp(
      id: bundleID ?? path,
      ref: LaunchpadAppRef(bundleID: bundleID, path: path),
      item: item, url: url,
      isSystem: resolved.hasPrefix("/System/"),
      inUtilities: resolved.hasPrefix("/System/Applications/Utilities/"),
      isAppStore: !path.hasPrefix("/System/")
        && FileManager.default.fileExists(atPath: path + "/Contents/_MASReceipt/receipt"),
      category: categoryKey.flatMap(categoryName))
  }

  /// 建文件夹时的名字：两个 App 分类相同时用它，不同就用第一个的；第一个没分类就用第二个的（G12），
  /// 都没有叫「未命名」（SPEC R4）
  nonisolated static func folderName(first: LaunchpadProjectApp?, second: LaunchpadProjectApp?)
    -> String
  {
    let shared = first?.category == second?.category ? first?.category : nil
    return shared ?? first?.category ?? second?.category ?? LaunchpadLayout.untitledFolder
  }

  /// 这些 App 里有没有 App Store 装的（抖动模式只有它们显示 ✕）
  nonisolated static func canDelete(_ app: LaunchpadProjectApp) -> Bool { app.isAppStore }

  /// 包里的 Info.plist（解析失败返回 nil；只用来取 bundle id、分类）
  private nonisolated static func infoPlist(_ url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url.appending(path: "Contents/Info.plist")) else {
      return nil
    }
    return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
  }

  /// LSApplicationCategoryType → 中文名（文件夹名字）。系统自带的分类都在这里；第三方自定义的不认识就是 nil。
  /// 用系统设置里那套叫法（工具、效率、图形与设计…）
  nonisolated static func categoryName(_ key: String) -> String? {
    let tail = key.hasPrefix("public.app-category.") ? String(key.dropFirst(20)) : key
    return categories[tail]
  }

  nonisolated private static let categories: [String: String] = [
    "business": "商务", "developer-tools": "开发者工具", "education": "教育",
    "entertainment": "娱乐", "finance": "财务", "games": "游戏", "graphics-design": "图形与设计",
    // 游戏的子分类都并进「游戏」（F43；LSApplicationCategoryType 里它们是单独的值）
    "action-games": "游戏", "adventure-games": "游戏", "arcade-games": "游戏",
    "board-games": "游戏", "card-games": "游戏", "casino-games": "游戏", "dice-games": "游戏",
    "educational-games": "游戏", "family-games": "游戏", "kids-games": "游戏",
    "music-games": "游戏", "puzzle-games": "游戏", "racing-games": "游戏",
    "role-playing-games": "游戏", "simulation-games": "游戏", "sports-games": "游戏",
    "strategy-games": "游戏", "trivia-games": "游戏", "word-games": "游戏",
    "healthcare-fitness": "健康与健身", "lifestyle": "生活", "medical": "医疗",
    "music": "音乐", "news": "新闻", "photography": "摄影", "productivity": "效率",
    "reference": "参考", "social-networking": "社交", "sports": "体育", "travel": "旅行",
    "utilities": "工具", "video": "视频", "weather": "天气", "books": "图书",
    "food-and-drink": "美食佳饮", "magazines-newspapers": "杂志与报纸", "shopping": "购物",
  ]
}

/// 图标位图缓存（2026-10-18 真机反馈「第一次打开卡一阵」）：每个 App 的图标在**后台**按显示尺寸画成一张位图，
/// **常驻**（本机 111 个、185 px 见方约 15 MB；用户定的，不再闲两分钟就放掉），打开时只贴位图。
/// 原来交给界面的是系统的多尺寸 NSImage，每画一次都按尺寸重新渲染：本机 111 个第一次画 1.8 s、之后每遍 0.25 s，全在主线程。
/// 还没画好的先给一块透明占位，画好一批 `generation` 加一、界面自己刷新（@Observable）。`synchronous`（单测、截图自检）：缺了当场画。
/// `NSWorkspace.icon(forFile:)` 文档写明任何线程都能调；画位图用这一个线程自己的 NSGraphicsContext。
@Observable
@MainActor
final class LaunchpadIcons {
  /// 位图本身不进观察（同步模式在界面求值时就地写，写观察中的属性会让 SwiftUI 报「更新中改状态」）
  @ObservationIgnored private var bitmaps: [String: NSImage] = [:]
  /// 后台画好一批就加一：界面读它，画好了自己刷新
  private var generation = 0
  @ObservationIgnored private var rendering: Set<String> = []
  /// 位图的边长（像素）：按最大那块屏上的图标 × 缩放倍数取，屏变大了重画
  @ObservationIgnored private(set) var pixelSize: Int
  @ObservationIgnored let synchronous: Bool

  init(synchronous: Bool = true, pixelSize: Int = 164) {
    self.synchronous = synchronous
    self.pixelSize = pixelSize
  }

  func icon(for app: LaunchpadProjectApp, size: CGFloat) -> NSImage {
    _ = generation
    if let image = bitmaps[app.id] { return image }
    if synchronous {
      let image =
        Self.render(path: app.path, pixelSize: pixelSize).map(Self.image) ?? Self.placeholder
      bitmaps[app.id] = image
      return image
    }
    prewarm([app])
    return Self.placeholder
  }

  /// 后台把还没画的画好（App 启动、目录扫完时调；界面要了一个没画的也会走到这里）；`pixelSize` 变大了全部重画
  func prewarm(_ apps: [LaunchpadProjectApp], pixelSize wanted: Int? = nil) {
    if let wanted, wanted > pixelSize {
      pixelSize = wanted
      // 旧的先留着显示，新的一张张换上（尺寸不对的晚到结果在 start 里丢掉）
      rendering.removeAll()
      start(apps.map { (id: $0.id, path: $0.path) })
      return
    }
    start(
      apps.filter { bitmaps[$0.id] == nil && !rendering.contains($0.id) }
        .map { (id: $0.id, path: $0.path) })
  }

  private func start(_ items: [(id: String, path: String)]) {
    guard !items.isEmpty else { return }
    for item in items { rendering.insert(item.id) }
    let size = pixelSize
    Task { [weak self] in
      let results = await Self.renderAll(items, pixelSize: size)
      guard let self, size == self.pixelSize else { return }
      for item in items { rendering.remove(item.id) }
      for (id, bitmap) in results { bitmaps[id] = Self.image(bitmap) }
      generation += 1
    }
  }

  /// 已经画好的有几个（单测用）
  var count: Int { bitmaps.count }

  @concurrent
  nonisolated private static func renderAll(
    _ items: [(id: String, path: String)], pixelSize: Int
  ) async -> [(String, CGImage)] {
    items.compactMap { item in render(path: item.path, pixelSize: pixelSize).map { (item.id, $0) } }
  }

  /// 一个 App 的图标画成 `pixelSize` 见方的位图（任何线程都能调）
  nonisolated static func render(path: String, pixelSize: Int) -> CGImage? {
    let side = max(pixelSize, 1)
    guard
      let context = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    let icon = NSWorkspace.shared.icon(forFile: path)
    let previous = NSGraphicsContext.current
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
    NSGraphicsContext.current = previous
    return context.makeImage()
  }

  /// 位图包成只有这一张的 NSImage（尺寸按 @2x 记，交给 NSImageView / SwiftUI 缩放，不再重渲染）
  private static func image(_ bitmap: CGImage) -> NSImage {
    NSImage(cgImage: bitmap, size: NSSize(width: bitmap.width / 2, height: bitmap.height / 2))
  }

  /// 还没画好时的占位：透明（不画灰方块，免得一开一闪）
  static let placeholder = NSImage(size: NSSize(width: 1, height: 1))
}
