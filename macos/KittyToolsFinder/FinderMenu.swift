// 访达扩展（第十一族「访达右键」，2026-11-08 拍板，PLAN §10「访达右键」）：在访达的右键菜单第一层加几项。
// - 选中文件 / 文件夹右键：「拷贝路径」、设置里选的每个 App 一项「用 X 打开」（默认只有终端）。
// - 文件夹空白处右键：同样两种，对着的是这个文件夹。
// 扩展只画菜单、不碰文件（拍板 C2）：点了用 App 自己的网址把动作交给常驻菜单栏的 Kitty Tools，
// <App 的 bundle id>://finder?do=copy|open&key=<凭证>&app=<bundle id>&file=/a&file=/b，App 那边是 FinderLink；
// App 被退出了的话网址会把它打开。凭证、开关、「用 App 打开」的列表都从 App 的偏好里读（Finder.entitlements 的只读例外），
// 所以沙盒例外只有这一条；功能关着（或者 App 还没生成凭证）时一项都不加。
// 看所有位置（directoryURLs 设成根目录）；iCloud 云盘、网盘这类文件提供程序管的文件夹里系统不给扩展菜单。
// 要用户在 系统设置 › 通用 › 登录项与扩展 里打开它（App 设置 › 访达右键 有「去打开…」）。
// ponytail: 这个 target 用 Swift 5 语言模式（Config/Finder.xcconfig），FinderSync 加上并发标注后改回 6。

import AppKit
import FinderSync
import os

/// 交给 App 失败这类记一笔（扩展没有界面，Console 里按 subsystem 看）
private let log = Logger(subsystem: "com.yy.kitty-tools.native", category: "finder")

final class FinderMenu: FIFinderSync {
  /// App 的 id：扩展的 id 是 App 的 id 加 .finder（Debug、Release 各认各的），App 拿它当网址的 scheme
  private static let appID =
    (Bundle.main.bundleIdentifier.map { ($0 as NSString).deletingPathExtension })
    ?? "com.yy.kitty-tools.native"

  /// App 的偏好（只读例外）。ponytail: 下面三个键名和默认值、网址的写法、maxFiles 抄的 App 的 Feature.finderMenu.prefsKey
  /// （defaultOn 是关）、Prefs.finderMenuKey、Prefs.finderOpenWithApps、FinderLink，那边改了这里跟着改（FinderLinkTests 读这个文件比对）
  private static var appDefaults: UserDefaults? { UserDefaults(suiteName: appID) }

  /// 功能开着、App 生成过凭证才出菜单
  private static var key: String? {
    guard let defaults = appDefaults, defaults.bool(forKey: "feature.finderMenu") else {
      return nil
    }
    return defaults.string(forKey: "finderMenuKey").flatMap { $0.isEmpty ? nil : $0 }
  }

  /// 一次最多交这么多个：再多 App 不认，这里先响一声
  private static let maxFiles = 2000

  /// 包着这个扩展的 App（…/Kitty Tools.app/Contents/PlugIns/KittyToolsFinder.appex 往上三级）：网址直接投给它，不让
  /// LaunchServices 按 scheme 去找——别的 App 也能声明同一个 scheme，机器上也可能有好几份（挂着的 DMG、构建目录里的）
  private static let appURL = Bundle.main.bundleURL.deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

  /// 设置里选的 App（bundle id，这台 Mac 上找得到的）
  private static var openWithApps: [(id: String, url: URL)] {
    (appDefaults?.stringArray(forKey: "finderOpenWithApps") ?? ["com.apple.Terminal"])
      .compactMap { id in
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { (id, $0) }
      }
  }

  override init() {
    super.init()
    FIFinderSyncController.default().directoryURLs = [URL(filePath: "/")]
  }

  // 访达在主线程上要菜单、点菜单项
  override func menu(for menuKind: FIMenuKind) -> NSMenu? {
    guard Self.key != nil else { return nil }
    // 空白处右键对着的是这个文件夹：记在每一项的 tag 里（菜单项要跨进程交给访达，只有 tag 带得回来）。
    // 不能点的时候再看「有没有选中的」：窗口里选着文件、却在空白处右键时，选中的那几样还在
    let container: Int
    switch menuKind {
    case .contextualMenuForItems: container = 0
    case .contextualMenuForContainer: container = Self.containerTag
    default: return nil
    }
    // 不加分隔线：macOS 26 上扩展菜单里的分隔线会画成一行空白（2026-09 开发者论坛，没解答）
    let menu = NSMenu()
    let copy = menu.addItem(withTitle: "拷贝路径", action: #selector(copyPath(_:)), keyEquivalent: "")
    copy.tag = container
    copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
    for (index, app) in Self.openWithApps.enumerated() {
      let item = menu.addItem(
        withTitle: Self.openTitle(app.url), action: #selector(open(_:)), keyEquivalent: "")
      item.tag = container + index
      item.image = NSWorkspace.shared.icon(forFile: app.url.path)
      item.image?.size = NSSize(width: 16, height: 16)
    }
    return menu
  }

  /// 「用终端打开」「用 Visual Studio Code 打开」：西文名两边空一格
  private static func openTitle(_ app: URL) -> String {
    var name = FileManager.default.displayName(atPath: app.path)
    if name.hasSuffix(".app") { name.removeLast(4) }
    let gap = { (end: Character?) in end?.isASCII == true ? " " : "" }
    return "用" + gap(name.first) + name + gap(name.last) + "打开"
  }

  /// 空白处那份菜单的 tag 从这里起（App 不会有这么多个）
  private static let containerTag = 10_000

  /// 右键对着的东西：在选中的东西上右键是选中的那几样；空白处是这个文件夹
  private static func targets(container: Bool) -> [URL] {
    let controller = FIFinderSyncController.default()
    if container { return controller.targetedURL().map { [$0] } ?? [] }
    return controller.selectedItemURLs() ?? []
  }

  @objc private func copyPath(_ sender: AnyObject?) {
    let tag = (sender as? NSMenuItem)?.tag ?? 0
    hand("copy", app: nil, container: tag >= Self.containerTag)
  }

  @objc private func open(_ sender: AnyObject?) {
    let apps = Self.openWithApps
    guard let tag = (sender as? NSMenuItem)?.tag else { return }
    let container = tag >= Self.containerTag
    let index = container ? tag - Self.containerTag : tag
    guard apps.indices.contains(index) else { return }
    hand("open", app: apps[index].id, container: container)
  }

  /// 交给 App。拷贝路径不激活它（菜单栏 App，激活了只会把前台从访达抢走）；用 X 打开要激活：macOS 14 起不在前台的 App
  /// 叫别的 App 打开时，那个 App 不一定能到前面（协作式激活），这一下是用户在访达里点的，App 借着它把前台交给要打开的 App
  private func hand(_ action: String, app: String?, container: Bool) {
    let files = Self.targets(container: container)
    guard let key = Self.key, !files.isEmpty else { return }
    guard files.count <= Self.maxFiles else {
      NSSound.beep()
      return
    }
    var link = URLComponents()
    link.scheme = Self.appID
    link.host = "finder"
    link.queryItems =
      [URLQueryItem(name: "do", value: action), URLQueryItem(name: "key", value: key)]
      + (app.map { [URLQueryItem(name: "app", value: $0)] } ?? [])
      + files.map { URLQueryItem(name: "file", value: $0.path) }
    guard let url = link.url else { return }
    let activates = action == "open"
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = activates
    // 只记错误码：错误说明里带着网址（凭证和路径）
    NSWorkspace.shared.open([url], withApplicationAt: Self.appURL, configuration: configuration) {
      _, error in
      guard let error else { return }
      log.error("交给 App 失败：\((error as NSError).code)")
      // ponytail: 沙盒里直接投给包着它的 App 没成时（真机没验过会不会），退回按 scheme 找
      let retry = NSWorkspace.OpenConfiguration()
      retry.activates = activates
      NSWorkspace.shared.open(url, configuration: retry) { _, error in
        if let error { log.error("交给 App 失败：\((error as NSError).code)") }
      }
    }
  }
}
