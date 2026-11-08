// 访达扩展（第十一族「访达右键」，2026-11-08 拍板，PLAN §10「访达右键」）：在访达的右键菜单第一层加几项。
// - 选中文件 / 文件夹右键：「拷贝路径」、设置里选的每个 App 一项「用 X 打开」（默认只有终端）。
// - 文件夹空白处右键：最前面多一个「新建文件 ▸」（第 2 批：自带五种、模板文件夹里放的每个文件、「自定义后缀…」、
//   「打开模板文件夹」），后面同样两种，对着的是这个文件夹。
// 扩展只画菜单、不碰文件（拍板 C2）：点了用 App 自己的网址把动作交给常驻菜单栏的 Kitty Tools，
// <App 的 bundle id>://finder?do=<动作>&key=<凭证>&…&file=/a，App 那边是 FinderLink（网址的写法在那边的文件头）；
// App 被退出了的话网址会把它打开。凭证、开关、「用 App 打开」的列表从 App 的偏好里读，模板文件夹只为列菜单读一下
// （Finder.entitlements 的两条只读例外，没有别的）；功能关着（或者 App 还没生成凭证）时一项都不加。
// 看所有位置（directoryURLs 设成根目录）；iCloud 云盘、网盘这类文件提供程序管的文件夹里系统不给扩展菜单。
// 要用户在 系统设置 › 通用 › 登录项与扩展 里打开它（App 设置 › 访达右键 有「去打开…」）。
// ponytail: 这个 target 用 Swift 5 语言模式（Config/Finder.xcconfig），FinderSync 加上并发标注后改回 6。

import AppKit
import FinderSync
import UniformTypeIdentifiers
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

  /// 随 App 的五个模板（ponytail: 抄的 App 的 NewFile.builtIn，文件在 App 包里，扩展只列名字）
  private static let builtIn = [
    "文本文件.txt", "Markdown.md", "Word 文档.docx", "Excel 表格.xlsx", "PPT 演示文稿.pptx",
  ]

  /// 用户的模板文件夹：App 数据目录里的「新建文件模板」（ponytail: 抄的 NewFile.folderName）。沙盒里 FileManager 给的
  /// home 是容器，这里要真的 home
  private static var templatesFolder: URL? {
    guard let home = getpwuid(getuid())?.pointee.pw_dir else { return nil }
    return URL(filePath: String(cString: home))
      .appending(path: "Library/Application Support/\(appID)/新建文件模板", directoryHint: .isDirectory)
  }

  /// 模板文件夹里的（隐藏文件不算），按名字排
  private static var myTemplates: [URL] {
    guard let folder = templatesFolder else { return [] }
    return
      ((try? FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [])
      .sorted {
        $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
      }
  }

  /// 模板文件夹里的那几项 tag 从这里起
  private static let mineTag = 100

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
    if container != 0 {
      menu.addItem(withTitle: "新建文件", action: nil, keyEquivalent: "").submenu = Self.newFileMenu()
    }
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

  /// 「新建文件 ▸」：自带五种（图标按类型取）、模板文件夹里的（图标按文件取）、自定义后缀、打开模板文件夹
  private static func newFileMenu() -> NSMenu {
    let menu = NSMenu()
    let add = { (title: String, tag: Int, icon: NSImage) in
      let item = menu.addItem(withTitle: title, action: #selector(create(_:)), keyEquivalent: "")
      item.tag = tag
      item.image = icon
      item.image?.size = NSSize(width: 16, height: 16)
    }
    for (index, name) in builtIn.enumerated() {
      let type = UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
      add((name as NSString).deletingPathExtension, index, NSWorkspace.shared.icon(for: type))
    }
    let mine = myTemplates
    for (index, title) in titles(mine).enumerated() {
      add(title, mineTag + index, NSWorkspace.shared.icon(forFile: mine[index].path))
    }
    menu.addItem(withTitle: "自定义后缀…", action: #selector(createCustom(_:)), keyEquivalent: "")
    menu.addItem(withTitle: "打开模板文件夹", action: #selector(showTemplates(_:)), keyEquivalent: "")
    return menu
  }

  /// 模板文件夹里那几项的标题：文件去掉扩展名（文件夹照原名，「项目 v1.2」不截）；去掉后撞名的写全名
  private static func titles(_ urls: [URL]) -> [String] {
    let stems = urls.map { url in
      (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
    }
    return zip(urls, stems).map { url, stem in
      stems.filter { $0 == stem }.count > 1 ? url.lastPathComponent : stem
    }
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

  @objc private func create(_ sender: AnyObject?) {
    guard let tag = (sender as? NSMenuItem)?.tag else { return }
    let name: String
    var extra = [URLQueryItem]()
    if tag >= Self.mineTag {
      // 点的时候重新列一遍：菜单弹出来之后文件夹里加了、删了东西，序号就对不上了，标题也对上才建
      let mine = Self.myTemplates
      let index = tag - Self.mineTag
      guard mine.indices.contains(index), Self.titles(mine)[index] == (sender as? NSMenuItem)?.title
      else {
        NSSound.beep()
        return
      }
      name = mine[index].lastPathComponent
      extra.append(URLQueryItem(name: "mine", value: "1"))
    } else {
      guard Self.builtIn.indices.contains(tag) else { return }
      name = Self.builtIn[tag]
    }
    hand("new", extra: [URLQueryItem(name: "template", value: name)] + extra, container: true)
  }

  /// 问后缀的框由 App 弹（扩展是后台进程，弹不出窗口）：要激活 App，框才能直接打字
  @objc private func createCustom(_ sender: AnyObject?) {
    hand("suffix", container: true)
  }

  @objc private func showTemplates(_ sender: AnyObject?) {
    hand("templates", files: [])
  }

  private func hand(
    _ action: String, app: String? = nil, extra: [URLQueryItem] = [], container: Bool
  ) {
    hand(action, app: app, extra: extra, files: Self.targets(container: container))
  }

  /// 交给 App。拷贝路径、新建文件不激活它（菜单栏 App，激活了只会把前台从访达抢走）；用 X 打开、打开模板文件夹要激活：
  /// macOS 14 起不在前台的 App 叫别的 App 打开时，那个 App 不一定能到前面（协作式激活），这一下是用户在访达里点的，
  /// App 借着它把前台交给要打开的 App；自定义后缀要激活，框才能打字
  private func hand(_ action: String, app: String? = nil, extra: [URLQueryItem] = [], files: [URL])
  {
    guard let key = Self.key, !files.isEmpty || action == "templates" else { return }
    guard files.count <= Self.maxFiles else {
      NSSound.beep()
      return
    }
    var link = URLComponents()
    link.scheme = Self.appID
    link.host = "finder"
    link.queryItems =
      [URLQueryItem(name: "do", value: action), URLQueryItem(name: "key", value: key)]
      + (app.map { [URLQueryItem(name: "app", value: $0)] } ?? []) + extra
      + files.map { URLQueryItem(name: "file", value: $0.path) }
    guard let url = link.url else { return }
    let activates = ["open", "suffix", "templates"].contains(action)
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = activates
    // 沙盒里也能直接投给指定的 App，前提是它登记了这个 scheme（App 的 CFBundleURLTypes；没登记的系统回
    // kLSAppDoesNotClaimTypeErr，2026-11-08 用沙盒里的小程序实测）。不退回按 scheme 找：那样会被别的 App 截走，
    // 第一次其实送到了的话还会做两遍。只记错误码：错误说明里带着网址（凭证和路径）
    NSWorkspace.shared.open([url], withApplicationAt: Self.appURL, configuration: configuration) {
      _, error in
      if let error { log.error("交给 App 失败：\((error as NSError).code)") }
    }
  }
}
