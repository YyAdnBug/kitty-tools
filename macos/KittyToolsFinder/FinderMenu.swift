// 访达扩展（第十一族「访达右键」，2026-11-08 拍板，PLAN §10「访达右键」）：在访达的右键菜单第一层加几项。
// - 选中文件 / 文件夹右键：「拷贝路径」「拷贝名称」、设置里选的每个 App 一项「在“X”中打开」（默认只有终端；叫法照访达
//   自己的「在“照片”中打开」）、「移动到 ▸」「复制到 ▸」（常用文件夹 + 选择文件夹…）、「剪切」、「发送替身到桌面」。
// - 文件夹空白处右键：最前面「新建文件 ▸」（自带五种、模板文件夹里放的每个文件、「自定义后缀…」、「打开模板文件夹」），
//   剪切过、剪贴板还没换过时多一项「粘贴 N 项」，然后「拷贝路径」「在“X”中打开」，对着的是这个文件夹。
// 每一项在 App 设置里能单独关（App 的 FinderMenuItem；同几家成熟产品），默认开关照 2026-11-08 右键扩充拍板 A2。
// 扩展只画菜单、不碰文件（拍板 C2）：点了用 App 自己的网址把动作交给常驻菜单栏的 Kitty Tools，
// <App 的 bundle id>://finder?do=<动作>&key=<凭证>&…&file=/a，App 那边是 FinderLink（网址的写法在那边的文件头）；
// App 被退出了的话网址会把它打开。凭证、开关、「用 App 打开」的列表从 App 的偏好里读，模板文件夹只为列菜单读一下
// （Finder.entitlements 的两条只读例外，没有别的）；功能关着（或者 App 还没生成凭证）时一项都不加。
// 图标：每一项都带（没图标的项文字会和带图标的错开一截）。拷贝路径、新建文件是自己画的（icons/finder/，
// swift icons/build-icons.swift finder 生成到本 target 的 Assets.xcassets），线宽照 SF Symbols 常规粗细；另两项用系统符号。
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

  /// 某一项开没开（App 的 FinderMenuItem：键「finderMenu<名字>」；注册的默认值不在偏好文件里、扩展读不到，没存过就用
  /// 这里抄的默认值 on，FinderLinkTests 读这个文件比对）
  private static func shows(_ key: String, default on: Bool) -> Bool {
    appDefaults?.object(forKey: key) as? Bool ?? on
  }

  /// 真的主目录（沙盒里 FileManager / ~ 给的是容器）
  private static var home: String? {
    getpwuid(getuid())?.pointee.pw_dir.map { String(cString: $0) }
  }

  /// 「移动到」「复制到」的常用文件夹（App 的 Prefs.finderTransferFolders，~ 开头的写法；ponytail: 键名和默认值抄的那边）
  private static var transferFolders: [URL] {
    guard let home else { return [] }
    return
      (appDefaults?.stringArray(forKey: "finderTransferFolders")
      ?? ["~/Desktop", "~/Documents", "~/Downloads"])
      .map { $0 == "~" || $0.hasPrefix("~/") ? home + $0.dropFirst() : $0 }
      .map { URL(filePath: $0, directoryHint: .isDirectory) }
  }

  /// 剪切了、剪贴板还没换过的有几样（App 的 FileMoves.cut 记的；剪贴板换过了就不列「粘贴」，同 Windows）
  private static var cutCount: Int {
    guard let defaults = appDefaults,
      defaults.object(forKey: "finderCutChange") as? Int == NSPasteboard.general.changeCount
    else { return 0 }
    return defaults.integer(forKey: "finderCutCount")
  }

  /// 「移动到」「复制到」子菜单里「选择文件夹…」的 tag
  private static let chooseTag = 999

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
    let items = container == 0
    if !items, Self.shows("finderMenuNewFile", default: true) {
      let new = menu.addItem(withTitle: "新建文件", action: nil, keyEquivalent: "")
      new.submenu = Self.newFileMenu()
      new.image = Self.drawn("kitty.finder.new.file")
    }
    if !items, Self.shows("finderMenuCut", default: true), Self.cutCount > 0 {
      Self.add("粘贴 \(Self.cutCount) 项", #selector(paste(_:)), symbol: "doc.on.clipboard", to: menu)
    }
    if Self.shows("finderMenuCopyPath", default: true) {
      let copy = menu.addItem(
        withTitle: "拷贝路径", action: #selector(copyPath(_:)), keyEquivalent: "")
      copy.tag = container
      copy.image = Self.drawn("kitty.finder.copy.path")
    }
    if items, Self.shows("finderMenuCopyName", default: true) {
      Self.add("拷贝名称", #selector(copyName(_:)), symbol: "textformat", to: menu)
    }
    for (index, app) in Self.openWithApps.enumerated() {
      let item = menu.addItem(
        withTitle: Self.openTitle(app.url), action: #selector(open(_:)), keyEquivalent: "")
      item.tag = container + index
      item.image = NSWorkspace.shared.icon(forFile: app.url.path)
      item.image?.size = NSSize(width: 16, height: 16)
    }
    if items, Self.shows("finderMenuTransfer", default: true) {
      Self.add("移动到", nil, symbol: "arrowshape.turn.up.right", to: menu).submenu =
        Self.transferMenu(#selector(moveTo(_:)))
      Self.add("复制到", nil, symbol: "plus.square.on.square", to: menu).submenu =
        Self.transferMenu(#selector(copyTo(_:)))
    }
    if items, Self.shows("finderMenuCut", default: true) {
      Self.add("剪切", #selector(cut(_:)), symbol: "scissors", to: menu)
    }
    if items, Self.shows("finderMenuDeskAlias", default: false) {
      Self.add("发送替身到桌面", #selector(alias(_:)), symbol: "arrow.up.right.square", to: menu)
    }
    return menu.items.isEmpty ? nil : menu
  }

  /// 加一项带系统符号（模板图）的
  @discardableResult private static func add(
    _ title: String, _ action: Selector?, symbol: String, to menu: NSMenu
  ) -> NSMenuItem {
    let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    return item
  }

  /// 「移动到 ▸」「复制到 ▸」：常用文件夹（访达里的名字和图标），最后「选择文件夹…」
  private static func transferMenu(_ action: Selector) -> NSMenu {
    let menu = NSMenu()
    for (index, folder) in transferFolders.enumerated() {
      let path = folder.path(percentEncoded: false)
      let item = menu.addItem(
        withTitle: FileManager.default.displayName(atPath: path), action: action, keyEquivalent: "")
      item.tag = index
      item.image = NSWorkspace.shared.icon(forFile: path)
      item.image?.size = NSSize(width: 16, height: 16)
    }
    add("选择文件夹…", action, symbol: "ellipsis.circle", to: menu).tag = chooseTag
    return menu
  }

  /// 自己画的图标（Assets.xcassets/FinderIcons）：按菜单的字号（13 pt、常规）画成 1x / 2x 的模板位图再交出去——
  /// 菜单项要跨进程交给访达，本扩展资源目录里的符号到了访达那边不一定认得，位图一定认得；模板图让访达按菜单的字色、
  /// 高亮、深色模式上色
  private static func drawn(_ name: String) -> NSImage? {
    guard
      let symbol = NSImage(named: name)?.withSymbolConfiguration(
        NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
    else { return nil }
    let size = symbol.size
    let image = NSImage(size: size)
    for scale in [1.0, 2.0] {
      guard
        let rep = NSBitmapImageRep(
          bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded(.up)),
          pixelsHigh: Int((size.height * scale).rounded(.up)), bitsPerSample: 8, samplesPerPixel: 4,
          hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
          bitsPerPixel: 0)
      else { continue }
      rep.size = size
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
      symbol.draw(in: NSRect(origin: .zero, size: size))
      NSGraphicsContext.restoreGraphicsState()
      image.addRepresentation(rep)
    }
    image.isTemplate = true
    return image
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
      .image = NSImage(systemSymbolName: "character.cursor.ibeam", accessibilityDescription: nil)
    menu.addItem(withTitle: "打开模板文件夹", action: #selector(showTemplates(_:)), keyEquivalent: "")
      .image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
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

  /// 「在“终端”中打开」「在“Visual Studio Code”中打开」：照访达自己给 App 的写法（「在“照片”中打开」）
  private static func openTitle(_ app: URL) -> String {
    var name = FileManager.default.displayName(atPath: app.path)
    if name.hasSuffix(".app") { name.removeLast(4) }
    return "在“\(name)”中打开"
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

  @objc private func copyName(_ sender: AnyObject?) {
    hand("name", container: false)
  }

  @objc private func moveTo(_ sender: AnyObject?) {
    transfer("move", sender)
  }

  @objc private func copyTo(_ sender: AnyObject?) {
    transfer("copyto", sender)
  }

  /// 移动 / 复制：tag 是常用文件夹的序号（点的时候重新读一遍，对不上就响一声），选择文件夹…交给 App 弹面板（要激活）
  private func transfer(_ action: String, _ sender: AnyObject?) {
    guard let tag = (sender as? NSMenuItem)?.tag else { return }
    let to: String
    if tag == Self.chooseTag {
      to = "choose"
    } else {
      // 点的时候重新读一遍：菜单弹出来之后设置里改过列表，序号就对不上了，名字也对上才搬
      let folders = Self.transferFolders
      guard folders.indices.contains(tag),
        FileManager.default.displayName(atPath: folders[tag].path(percentEncoded: false))
          == (sender as? NSMenuItem)?.title
      else {
        NSSound.beep()
        return
      }
      to = folders[tag].path(percentEncoded: false)
    }
    hand(action, extra: [URLQueryItem(name: "to", value: to)], container: false)
  }

  @objc private func cut(_ sender: AnyObject?) {
    hand("cut", container: false)
  }

  @objc private func paste(_ sender: AnyObject?) {
    hand("paste", container: true)
  }

  @objc private func alias(_ sender: AnyObject?) {
    hand("alias", container: false)
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

  /// 交给 App。拷贝、新建文件、搬文件不激活它（菜单栏 App，激活了只会把前台从访达抢走）；用 X 打开、打开模板文件夹要激活：
  /// macOS 14 起不在前台的 App 叫别的 App 打开时，那个 App 不一定能到前面（协作式激活），这一下是用户在访达里点的，
  /// App 借着它把前台交给要打开的 App；自定义后缀、选择文件夹…要激活，框 / 面板才能直接用
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
    let chooses = extra.contains { $0.name == "to" && $0.value == "choose" }
    let activates = ["open", "suffix", "templates"].contains(action) || chooses
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
