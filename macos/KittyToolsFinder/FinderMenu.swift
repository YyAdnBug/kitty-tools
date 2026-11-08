// 访达扩展（第十一族「访达右键」，2026-11-08 拍板，PLAN §10「访达右键」）：在访达的右键菜单第一层加几项。
// - 选中文件 / 文件夹右键：「拷贝路径」「拷贝名称」、设置里选的每个 App 一项「在“X”中打开」（默认只有终端；叫法照访达
//   自己的「在“照片”中打开」）、「移动到 ▸」「复制到 ▸」（常用文件夹 + 选择文件夹…）、「剪切」、「压缩 ▸」（ZIP、7Z）、
//   「解压到这里」（选中的都是压缩包时）、「修复乱码文件名」（选中的有名字像乱码、还原得出来的时候）、「隐藏」/「取消隐藏」、
//   「隐藏扩展名」/「显示扩展名」（看选中的现在是什么样；读不到就当没隐藏）、「拷贝哈希 ▸」（选中的都是文件时）、
//   「发送替身到桌面」、「彻底删除…」（App 那边先问）。
// - 文件夹空白处右键：最前面「新建文件 ▸」（自带五种、模板文件夹里放的每个文件、「自定义后缀…」、「打开模板文件夹」），
//   剪切过、剪贴板还没换过时多一项「粘贴 N 项」，然后「拷贝路径」「在“X”中打开」「显示 / 隐藏 隐藏文件」，对着的是这个文件夹。
// 设置里打开「收进一个子菜单」时，这些都收进第一层的一项「Kitty Tools ▸」里（默认关、平铺）。
// 每一项在 App 设置里能单独关（App 的 FinderMenuItem；同几家成熟产品），默认开关照 2026-11-08 右键扩充拍板 A2。
// 扩展只画菜单、不碰文件（拍板 C2）：点了用 App 自己的网址把动作交给常驻菜单栏的 Kitty Tools，
// <App 的 bundle id>://finder?do=<动作>&key=<凭证>&…&file=/a，App 那边是 FinderLink（网址的写法在那边的文件头）；
// App 被退出了的话网址会把它打开。凭证、开关、「用 App 打开」的列表从 App 的偏好里读，模板文件夹只为列菜单读一下
// （Finder.entitlements 的两条只读例外，没有别的）；功能关着（或者 App 还没生成凭证）时一项都不加。
// 图标：每一项都带（没图标的项文字会和带图标的错开一截）。
// 交给访达的图一律先画成 16 pt 的 1x / 2x 小位图、按名字缓存（icon）：
// NSWorkspace 给的文件 / App 图标带着 32 种尺寸，菜单项跨进程交给访达时整个编过去——一个 App 图标 72 MB、一个文件夹图标 36 MB，
// 编一次 20–90 ms（2026-11-08 实测，右键菜单出来慢的根源）；小位图约 10 KB。扩展一起来就把菜单搭一遍（warmUp），
// 符号字体、App 的位置这些第一次要几十毫秒的先备好。我们自己的每一项都是彩色方块里一个白色符号（tile，
// 2026-11-08 用户在三种样子里选的；颜色按类分，见 Tint），「在“X”中打开」、常用文件夹、新建文件的类型用它们自己的图标。
// 拷贝路径、新建文件的符号是自己画的（icons/finder/，swift icons/build-icons.swift finder 生成到本 target 的 Assets.xcassets）。
// 看所有位置（directoryURLs 是根目录加上每个挂着的卷，挂上 / 推出时跟着换）；拿不到对着什么、废纸篓的空白处不出菜单；iCloud 云盘、网盘这类文件提供程序管的文件夹里系统不给扩展菜单。
// 要用户在 系统设置 › 通用 › 登录项与扩展 里打开它（App 设置 › 访达右键 有「去打开…」）。
// ponytail: 这个 target 用 Swift 5 语言模式（Config/Finder.xcconfig），FinderSync 加上并发标注后改回 6。

import AppKit
import FinderSync
import Security
import UniformTypeIdentifiers
import os

/// 交给 App 失败这类记一笔（扩展没有界面，Console 里按 subsystem 看）
private let log = Logger(subsystem: "com.yy.kitty-tools.native", category: "finder")

/// 名字像不像乱码、还原成什么：App 的 NameRepair 原样抄过来（FinderLinkTests 逐字比对 BEGIN / END 之间）
// BEGIN NameRepair
nonisolated enum NameRepair {
  /// 名字像乱码、能还原成中日韩文字时给出还原后的名字；不像、还原不了是 nil
  static func repair(_ name: String) -> String? {
    let name = name.precomposedStringWithCanonicalMapping
    guard !name.unicodeScalars.contains(where: isCJK) else { return nil }
    var runs: [Int] = []
    var current = 0
    for scalar in name.unicodeScalars {
      if scalar.isASCII {
        if current > 0 { runs.append(current) }
        current = 0
      } else {
        current += 1
      }
    }
    if current > 0 { runs.append(current) }
    for (wrong, right, unit) in tries
    where runs.contains(where: { $0 >= 2 * unit }) && runs.allSatisfy({ $0 % unit == 0 }) {
      guard let bytes = name.data(using: wrong),
        right == .utf8 || String(data: bytes, encoding: .utf8) == nil,
        let fixed = String(data: bytes, encoding: right), fixed != name, looksRight(fixed)
      else { continue }
      return fixed
    }
    return nil
  }

  /// 还原出来的像样：有中日韩文字，非 ASCII 的全是中日韩文字和全角符号，没有控制字符、/、:
  private static func looksRight(_ name: String) -> Bool {
    let scalars = name.unicodeScalars
    return scalars.contains(where: isCJK)
      && scalars.allSatisfy { $0.isASCII ? $0.value >= 0x20 && $0 != "/" && $0 != ":" : isCJK($0) }
  }

  /// 中日韩文字、假名、谚文、中日韩标点、全角符号
  private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x3000...0x303F, 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF,
      0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x2FA1F:
      true
    default: false
    }
  }

  private static func encoding(_ cf: CFStringEncodings) -> String.Encoding {
    String.Encoding(
      rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cf.rawValue)))
  }

  /// 依次试：（被当成的错编码，本来的编码，一个字几个错字）。UTF-8 校验更严，先试；中文这一路按 GB2312（EUC-CN）读
  private static let tries: [(String.Encoding, String.Encoding, Int)] = {
    let gb2312 = encoding(.EUC_CN)
    let cp437 = encoding(.dosLatinUS)
    return [
      (.windowsCP1252, .utf8, 3), (.isoLatin1, .utf8, 3), (.macOSRoman, .utf8, 3),
      (cp437, gb2312, 2), (.macOSRoman, gb2312, 2), (.windowsCP1252, gb2312, 2),
      (.isoLatin1, gb2312, 2),
    ]
  }()
}
// END NameRepair

final class FinderMenu: FIFinderSync {
  /// App 的 id：扩展的 id 是 App 的 id 加 .finder（Debug、Release 各认各的），App 拿它当网址的 scheme
  private static let appID =
    (Bundle.main.bundleIdentifier.map { ($0 as NSString).deletingPathExtension })
    ?? "com.yy.kitty-tools.native"

  /// App 的偏好（只读例外）。ponytail: 下面三个键名和默认值、网址的写法、maxFiles 抄的 App 的 Feature.finderMenu.prefsKey
  /// （defaultOn 是关）、Prefs.finderMenuKey、Prefs.finderOpenWithApps、FinderLink，那边改了这里跟着改（FinderLinkTests 读这个文件比对）
  private static let appDefaults = UserDefaults(suiteName: appID)

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

  /// 「拷贝哈希 ▸」的几种（tag 是序号；ponytail: 抄的 App 的 FileHash.Kind，FinderLinkTests 比对）
  private static let hashes = [("sha256", "SHA-256"), ("md5", "MD5"), ("sha1", "SHA-1")]

  /// 「解压到这里」认的扩展名（ponytail: 抄的 App 的 Archives.suffixes，FinderLinkTests 比对）
  private static let archiveSuffixes = [
    ".zip", ".7z", ".tar", ".tar.gz", ".tgz", ".tar.xz", ".txz", ".tar.bz2", ".tbz", ".tbz2",
  ]

  private static func isArchive(_ url: URL) -> Bool {
    let name = url.lastPathComponent.lowercased()
    return archiveSuffixes.contains { name.hasSuffix($0) && name.count > $0.count }
  }

  /// 设置里选的 App（bundle id，这台 Mac 上找得到的）。找过的记着（问一次 LaunchServices 要几毫秒），App 被删了再找
  private static var openWithApps: [(id: String, url: URL)] {
    (appDefaults?.stringArray(forKey: "finderOpenWithApps") ?? ["com.apple.Terminal"])
      .compactMap { id in
        if let url = appURLs[id], FileManager.default.fileExists(atPath: url.path) {
          return (id, url)
        }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        appURLs[id] = url
        return url.map { (id, $0) }
      }
  }
  private static var appURLs: [String: URL] = [:]

  override init() {
    super.init()
    Self.watchVolumes()
    Task { @MainActor in Self.warmUp() }
  }

  private static var watching = false

  /// 看的位置：根目录和每个挂着的卷（只给根目录的话，U 盘、磁盘映像、网络盘上可能没有菜单，开源的访达扩展都另外补上卷）；
  /// 挂上、推出时跟着换
  private static func watchVolumes() {
    let update = {
      let volumes =
        FileManager.default.mountedVolumeURLs(
          includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
      FIFinderSyncController.default().directoryURLs = Set([URL(filePath: "/")] + volumes)
    }
    update()
    guard !watching else { return }
    watching = true
    for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
      NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) {
        _ in update()
      }
    }
  }

  /// 扩展刚起来：把两种菜单各搭一遍（不交出去），第一次右键时图标、符号字体、App 的位置都已经备好
  private static func warmUp() {
    _ = grouped(build(container: 0, selected: []))
    _ = grouped(build(container: containerTag, selected: []))
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
    let clock = ContinuousClock()
    let start = clock.now
    // 拿不到对着什么（搜索结果、「最近使用」的空白处这类）就不出菜单：出了点了也没反应。废纸篓的空白处也不出
    // （新建、粘贴到废纸篓里没意义）
    let controller = FIFinderSyncController.default()
    let selected = container == 0 ? controller.selectedItemURLs() ?? [] : []
    if container == 0 {
      guard !selected.isEmpty else { return nil }
    } else {
      guard let target = controller.targetedURL(), !Self.inTrash(target) else { return nil }
    }
    let menu = Self.grouped(Self.build(container: container, selected: selected))
    // 手测量耗时：log stream --level debug --predicate 'subsystem == "com.yy.kitty-tools.native"'
    let elapsed = (clock.now - start) / .milliseconds(1)
    log.debug("菜单搭好用了 \(elapsed, format: .fixed(precision: 1)) ms")
    return menu.items.isEmpty ? nil : menu
  }

  /// 在不在废纸篓里（主目录的 .Trash，别的卷上的 .Trashes）
  private static func inTrash(_ url: URL) -> Bool {
    let path = url.standardizedFileURL.path(percentEncoded: false)
    return path.contains("/.Trashes/") || path.hasSuffix("/.Trashes")
      || home.map { path == $0 + "/.Trash" || path.hasPrefix($0 + "/.Trash/") } == true
  }

  /// 设置里选了「收进一个子菜单」（App 的 Prefs.finderMenuGrouped，默认关）：第一层只放一项「Kitty Tools ▸」
  private static func grouped(_ menu: NSMenu) -> NSMenu {
    guard shows("finderMenuGrouped", default: false), !menu.items.isEmpty else { return menu }
    let outer = NSMenu()
    let group = outer.addItem(withTitle: "Kitty Tools", action: nil, keyEquivalent: "")
    group.image = tile("pawprint.fill", color: Tint.brand)
    group.submenu = menu
    return outer
  }

  /// 搭菜单。不加分隔线：macOS 26 上扩展菜单里的分隔线会画成一行空白（2026-09 开发者论坛，没解答）
  private static func build(container: Int, selected: [URL]) -> NSMenu {
    let menu = NSMenu()
    let items = container == 0
    if !items, Self.shows("finderMenuNewFile", default: true) {
      let new = menu.addItem(withTitle: "新建文件", action: nil, keyEquivalent: "")
      new.submenu = Self.newFileMenu()
      new.image = Self.tile("kitty.finder.new.file", custom: true, color: Tint.create)
    }
    if !items, Self.shows("finderMenuCut", default: true), Self.cutCount > 0 {
      Self.add(
        "粘贴 \(Self.cutCount) 项", #selector(paste(_:)), symbol: "doc.on.clipboard.fill",
        color: Tint.organize, to: menu)
    }
    if Self.shows("finderMenuCopyPath", default: true) {
      let copy = menu.addItem(
        withTitle: "拷贝路径", action: #selector(copyPath(_:)), keyEquivalent: "")
      copy.tag = container
      copy.image = Self.tile("kitty.finder.copy.path", custom: true, color: Tint.copy)
    }
    if items, Self.shows("finderMenuCopyName", default: true) {
      Self.add(
        "拷贝名称", #selector(copyName(_:)), symbol: "textformat", color: Tint.copy, to: menu)
    }
    if Self.shows("finderMenuHash", default: false), !selected.isEmpty,
      !selected.contains(where: \.hasDirectoryPath)
    {
      let kinds = NSMenu()
      for (index, kind) in Self.hashes.enumerated() {
        kinds.addItem(withTitle: kind.1, action: #selector(copyHash(_:)), keyEquivalent: "").tag =
          index
      }
      Self.add("拷贝哈希", nil, symbol: "number", color: Tint.hash, to: menu).submenu = kinds
    }
    for (index, app) in Self.openWithApps.enumerated() {
      let item = menu.addItem(
        withTitle: Self.openTitle(app.url), action: #selector(open(_:)), keyEquivalent: "")
      item.tag = container + index
      item.image = Self.fileIcon(app.url.path)
    }
    if items, Self.shows("finderMenuTransfer", default: true) {
      Self.add(
        "移动到", nil, symbol: "arrowshape.turn.up.right.fill", color: Tint.organize, to: menu
      ).submenu =
        Self.transferMenu(#selector(moveTo(_:)))
      Self.add(
        "复制到", nil, symbol: "plus.square.fill.on.square.fill", color: Tint.organize, to: menu
      ).submenu =
        Self.transferMenu(#selector(copyTo(_:)))
    }
    if items, Self.shows("finderMenuCut", default: true) {
      Self.add("剪切", #selector(cut(_:)), symbol: "scissors", color: Tint.organize, to: menu)
    }
    if items, Self.shows("finderMenuCompress", default: true) {
      let formats = NSMenu()
      formats.addItem(withTitle: "ZIP", action: #selector(compressZip(_:)), keyEquivalent: "")
      formats.addItem(withTitle: "7Z", action: #selector(compress7z(_:)), keyEquivalent: "")
      Self.add("压缩", nil, symbol: "doc.zipper", color: Tint.archive, to: menu).submenu = formats
    }
    if Self.shows("finderMenuExtract", default: true), !selected.isEmpty,
      selected.allSatisfy({ Self.isArchive($0) })
    {
      Self.add(
        "解压到这里", #selector(extract(_:)), symbol: "archivebox.fill", color: Tint.archive,
        to: menu)
    }
    if Self.shows("finderMenuFixNames", default: true),
      selected.contains(where: { NameRepair.repair($0.lastPathComponent) != nil })
    {
      Self.add(
        "修复乱码文件名", #selector(fixNames(_:)), symbol: "wand.and.stars", color: Tint.repair,
        to: menu)
    }
    if Self.shows("finderMenuHide", default: false) {
      Self.addHideItems(for: selected, to: menu)
    }
    if items, Self.shows("finderMenuDeskAlias", default: false) {
      Self.add("发送替身到桌面", #selector(alias(_:)), symbol: "link", color: Tint.alias, to: menu)
    }
    if !items, Self.shows("finderMenuShowHidden", default: false) {
      let toggle = Self.add(
        "显示 / 隐藏 隐藏文件", #selector(toggleHidden(_:)), symbol: "eye.fill", color: Tint.hide,
        to: menu)
      toggle.tag = container
    }
    if items, Self.shows("finderMenuErase", default: false) {
      Self.add(
        "彻底删除…", #selector(erase(_:)), symbol: "trash.slash.fill", color: Tint.erase, to: menu)
    }
    return menu
  }

  /// 「隐藏」/「取消隐藏」（点开头的本来就隐藏，不算）和「隐藏扩展名」/「显示扩展名」（有扩展名的才算）：
  /// 都已经是那样了才出反过来的那个
  private static func addHideItems(for selected: [URL], to menu: NSMenu) {
    let flag = { (url: URL, key: URLResourceKey) in
      (try? url.resourceValues(forKeys: [key]))?.allValues[key] as? Bool == true
    }
    let plain = selected.filter { !$0.lastPathComponent.hasPrefix(".") }
    if !plain.isEmpty {
      let hidden = plain.allSatisfy { flag($0, .isHiddenKey) }
      add(
        hidden ? "取消隐藏" : "隐藏",
        hidden ? #selector(FinderMenu.unhideItems(_:)) : #selector(FinderMenu.hideItems(_:)),
        symbol: hidden ? "eye.fill" : "eye.slash.fill", color: Tint.hide, to: menu)
    }
    let named = selected.filter { !$0.pathExtension.isEmpty }
    if !named.isEmpty {
      let hidden = named.allSatisfy { flag($0, .hasHiddenExtensionKey) }
      add(
        hidden ? "显示扩展名" : "隐藏扩展名",
        hidden
          ? #selector(FinderMenu.showExtensions(_:)) : #selector(FinderMenu.hideExtensions(_:)),
        symbol: "textformat.abc", color: Tint.hide, to: menu)
    }
  }

  /// 加一项，图标是 color 的方块里一个白色的系统符号
  @discardableResult private static func add(
    _ title: String, _ action: Selector?, symbol: String, color: NSColor, to menu: NSMenu
  ) -> NSMenuItem {
    let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
    item.image = tile(symbol, color: color)
    return item
  }

  /// 每一类的颜色（彩色方块，2026-11-08 用户在三种样子里选的 A：方块里白色符号，访达高亮那一行的蓝底上也看得清；
  /// 彩色符号直接压在蓝底上看不清）。取浅色外观下的系统色，画成位图后深浅色都用这一份
  private enum Tint {
    static let brand = rgb(255, 77, 126)  // 收起来的「Kitty Tools ▸」：品牌粉（AccentColor）
    static let copy = rgb(0, 122, 255)  // 拷贝：蓝
    static let create = rgb(52, 199, 89)  // 新建：绿
    static let organize = rgb(255, 149, 0)  // 移动、复制、剪切、粘贴：橙
    static let archive = rgb(162, 132, 94)  // 压缩、解压：棕
    static let repair = rgb(175, 82, 222)  // 修复乱码：紫
    static let hash = rgb(48, 176, 199)  // 哈希：青
    static let hide = rgb(142, 142, 147)  // 隐藏、扩展名、选择文件夹：灰
    static let alias = rgb(88, 86, 214)  // 替身：靛
    static let erase = rgb(255, 59, 48)  // 彻底删除：红

    static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
      NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
    }
  }

  /// 彩色方块图标（16 pt、圆角 4、上浅下深的渐变、一道很淡的描边），中间白色符号（9.5 pt 半粗；自己画的只有一种粗细，大一号；太宽的缩进 11 pt 见方）；
  /// custom：自己画的符号（Assets.xcassets/FinderIcons），否则是系统符号。画成位图、按名字缓存
  private static func tile(_ name: String, custom: Bool = false, color: NSColor) -> NSImage? {
    icon("tile:" + name) {
      let source =
        custom
        ? NSImage(named: name) : NSImage(systemSymbolName: name, accessibilityDescription: nil)
      guard
        let glyph = source?.withSymbolConfiguration(
          NSImage.SymbolConfiguration(pointSize: custom ? 10.5 : 9.5, weight: .semibold)
            .applying(.init(paletteColors: [.white])))
      else { return nil }
      let size = NSSize(width: 16, height: 16)
      let art = NSImage(size: size, flipped: false) { rect in
        let shape = NSBezierPath(
          roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: 4, yRadius: 4)
        NSGradient(
          starting: color.blended(withFraction: 0.18, of: .white) ?? color,
          ending: color.blended(withFraction: 0.08, of: .black) ?? color)?
          .draw(in: shape, angle: -90)
        NSColor.black.withAlphaComponent(0.12).setStroke()
        shape.lineWidth = 0.5
        shape.stroke()
        let fit = min(1, 11 / max(glyph.size.width, glyph.size.height, 1))
        let width = glyph.size.width * fit
        let height = glyph.size.height * fit
        glyph.draw(
          in: NSRect(
            x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height))
        return true
      }
      return bitmap(art, size: size, template: false)
    }
  }

  /// 画好的小位图，按名字缓存（见文件头：交出去的图越小越快）
  private static var icons: [String: NSImage] = [:]
  private static func icon(_ key: String, make: () -> NSImage?) -> NSImage? {
    if let cached = icons[key] { return cached }
    let made = make()
    icons[key] = made
    return made
  }

  /// 常用文件夹在访达里的名字（按路径记着：文件夹在卡住的网络盘上时，不让每次右键都等它；点的时候也用这一份对标题）
  private static var names: [String: String] = [:]
  private static func displayName(_ path: String) -> String {
    if let name = names[path] { return name }
    let name = FileManager.default.displayName(atPath: path)
    names[path] = name
    return name
  }

  /// 文件、文件夹、App 的图标：画成 16 pt 的小位图（按路径缓存）
  private static func fileIcon(_ path: String) -> NSImage? {
    icon("file:" + path) {
      bitmap(
        NSWorkspace.shared.icon(forFile: path), size: NSSize(width: 16, height: 16), template: false
      )
    }
  }

  /// 画成 1x、2x 两张位图的图
  private static func bitmap(_ source: NSImage, size: NSSize, template: Bool) -> NSImage {
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
      source.draw(in: NSRect(origin: .zero, size: size))
      NSGraphicsContext.restoreGraphicsState()
      image.addRepresentation(rep)
    }
    image.isTemplate = template
    return image
  }

  /// 「移动到 ▸」「复制到 ▸」：常用文件夹（访达里的名字和图标），最后「选择文件夹…」
  private static func transferMenu(_ action: Selector) -> NSMenu {
    let menu = NSMenu()
    for (index, folder) in transferFolders.enumerated() {
      let path = folder.path(percentEncoded: false)
      let item = menu.addItem(
        withTitle: displayName(path), action: action, keyEquivalent: "")
      item.tag = index
      item.image = fileIcon(path)
    }
    add("选择文件夹…", action, symbol: "ellipsis", color: Tint.hide, to: menu).tag = chooseTag
    return menu
  }

  /// 「新建文件 ▸」：自带五种（图标按类型取）、模板文件夹里的（图标按文件取）、自定义后缀、打开模板文件夹
  private static func newFileMenu() -> NSMenu {
    let menu = NSMenu()
    let add = { (title: String, tag: Int, icon: NSImage?) in
      let item = menu.addItem(withTitle: title, action: #selector(create(_:)), keyEquivalent: "")
      item.tag = tag
      item.image = icon
    }
    for (index, name) in builtIn.enumerated() {
      let ext = (name as NSString).pathExtension
      add(
        (name as NSString).deletingPathExtension, index,
        icon("type:" + ext) {
          bitmap(
            NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data),
            size: NSSize(width: 16, height: 16), template: false)
        })
    }
    let mine = myTemplates
    for (index, title) in titles(mine).enumerated() {
      add(title, mineTag + index, fileIcon(mine[index].path))
    }
    menu.addItem(withTitle: "自定义后缀…", action: #selector(createCustom(_:)), keyEquivalent: "")
      .image = tile("character.cursor.ibeam", color: Tint.create)
    menu.addItem(withTitle: "打开模板文件夹", action: #selector(showTemplates(_:)), keyEquivalent: "")
      .image = icon("type:folder") {
        bitmap(
          NSWorkspace.shared.icon(for: .folder), size: NSSize(width: 16, height: 16),
          template: false)
      }
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
        Self.displayName(folders[tag].path(percentEncoded: false))
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

  @objc private func copyHash(_ sender: AnyObject?) {
    guard let tag = (sender as? NSMenuItem)?.tag, Self.hashes.indices.contains(tag) else { return }
    hand(
      "hash", extra: [URLQueryItem(name: "algo", value: Self.hashes[tag].0)], container: false)
  }

  @objc private func hideItems(_ sender: AnyObject?) {
    hand("hide", extra: [URLQueryItem(name: "on", value: "1")], container: false)
  }

  @objc private func unhideItems(_ sender: AnyObject?) {
    hand("hide", extra: [URLQueryItem(name: "on", value: "0")], container: false)
  }

  @objc private func hideExtensions(_ sender: AnyObject?) {
    hand("ext", extra: [URLQueryItem(name: "on", value: "1")], container: false)
  }

  @objc private func showExtensions(_ sender: AnyObject?) {
    hand("ext", extra: [URLQueryItem(name: "on", value: "0")], container: false)
  }

  @objc private func toggleHidden(_ sender: AnyObject?) {
    hand("hiddenfiles", container: true)
  }

  /// 确认框由 App 弹：要激活 App，框才能直接用键盘
  @objc private func erase(_ sender: AnyObject?) {
    hand("erase", container: false)
  }

  @objc private func compressZip(_ sender: AnyObject?) {
    hand("zip", container: false)
  }

  @objc private func compress7z(_ sender: AnyObject?) {
    hand("7z", container: false)
  }

  @objc private func extract(_ sender: AnyObject?) {
    hand("extract", container: false)
  }

  @objc private func fixNames(_ sender: AnyObject?) {
    hand("fixnames", container: false)
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
  /// 投给哪一份 App：正在运行的那一份（同 id、本团队签名）；没在运行才投给包着这个扩展的那份。机器上有两份时（挂着新版的
  /// 磁盘映像），系统用的可能是另一份里的扩展：投给它的话会再起一个进程，它让位给正在运行的那份时这次动作就丢了（评审实测）。
  /// 核对不了签名（沙盒里查不了那个进程）就照旧投给包着扩展的那份
  private static var target: URL {
    let text =
      "identifier \"\(appID)\" and anchor apple generic and certificate leaf[subject.OU] = \"HTX9F4KG39\""
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
      let requirement
    else { return appURL }
    for app in NSRunningApplication.runningApplications(withBundleIdentifier: appID) {
      var code: SecCode?
      guard let url = app.bundleURL,
        SecCodeCopyGuestWithAttributes(
          nil, [kSecGuestAttributePid: app.processIdentifier] as CFDictionary, [], &code)
          == errSecSuccess,
        let code, SecCodeCheckValidity(code, [], requirement) == errSecSuccess
      else { continue }
      return url
    }
    return appURL
  }

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
    let activates = ["open", "suffix", "templates", "erase"].contains(action) || chooses
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = activates
    // 沙盒里也能直接投给指定的 App，前提是它登记了这个 scheme（App 的 CFBundleURLTypes；没登记的系统回
    // kLSAppDoesNotClaimTypeErr，2026-11-08 用沙盒里的小程序实测）。不退回按 scheme 找：那样会被别的 App 截走，
    // 第一次其实送到了的话还会做两遍。只记错误码：错误说明里带着网址（凭证和路径）
    NSWorkspace.shared.open([url], withApplicationAt: Self.target, configuration: configuration) {
      _, error in
      if let error { log.error("交给 App 失败：\((error as NSError).code)") }
    }
  }
}
