// 启动器的 App 目录：扫各应用程序目录下的 .app（含一层子文件夹）。名字取显示名、文件名、中文本地化名，
// 中文名再转拼音全拼 + 首字母，让「活动监视器」「huodong」「hdjsq」都能搜到（修旧版只认文件名，§11 #26）。
// 系统 App 不另写死一份、按解开符号链接后的路径去重（修旧版同一个 App 出现两行，§11 #25；
// 本机 /Applications/Safari.app 就是指向 Cryptexes 的链接）；访达不在应用程序目录里，单独加。
// 在主线程扫：本机 116 个 App 实测约 65ms（含拼音），由 LauncherModel 决定何时重扫：各目录的修改时间（signature，
// 只 stat）变了就在呼出前重扫（放进 / 删掉 .app 都会改它，体检 B31）。
// 副标题：显示名是中文时写英文文件名；否则标准目录（及其一层子文件夹）里的留空，别处的写所在位置（~/Downloads），
// 好分清同名的两份（体检 A25：以前写「应用程序」，和右侧类型「应用」重复）。
// 顺带扫系统设置的各个面板（体检 D9）：/System/Library/ExtensionKit/Extensions 里扩展点是 com.apple.Settings.extension.ui、
// Info.plist 声明了能用 x-apple.systempreferences: 打开的 .appex（15.7 上 50 个），标题是中文显示名（拼音、首字母同 App），
// 英文名也能搜；一行 = kind .url、目标「x-apple.systempreferences:<bundle id>」，副标题「系统设置」、右侧「设置」、
// 图标是系统设置 App 的，↩ 跳到那一页，记使用照网址的来。

import AppKit

enum AppCatalog {
  static let directories = [
    "/Applications", "/Applications/Utilities", "/System/Applications",
    "/System/Applications/Utilities", "/System/Cryptexes/App/System/Applications",
    NSHomeDirectory() + "/Applications",
  ]

  static let extraApps = ["/System/Library/CoreServices/Finder.app"]

  static func scan() -> [LauncherItem] {
    var seen = Set<String>()
    var items: [LauncherItem] = []
    let fileManager = FileManager.default
    func add(_ path: String) {
      // fileExists 会跟随链接：指向已删除 App 的死链接直接跳过
      guard fileManager.fileExists(atPath: path),
        seen.insert(URL(filePath: path).resolvingSymlinksInPath().path).inserted
      else { return }
      items.append(item(path: path))
    }
    func visit(_ directory: String, depth: Int) {
      for name in (try? fileManager.contentsOfDirectory(atPath: directory)) ?? [] {
        let path = directory + "/" + name
        if name.hasSuffix(".app") {
          add(path)
        } else if depth > 0, !directories.contains(path) {
          var isDirectory: ObjCBool = false
          if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue
          {
            visit(path, depth: depth - 1)  // 如 /Applications/Microsoft Office/…
          }
        }
      }
    }
    for directory in directories { visit(directory, depth: 1) }
    extraApps.forEach(add)
    return items + panes()
  }

  static func item(path: String) -> LauncherItem {
    let fileName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    // 访达开着「显示所有扩展名」时 displayName 带 .app
    var display = FileManager.default.displayName(atPath: path)
    if display.hasSuffix(".app") { display = String(display.dropLast(4)) }
    let chinese = chineseName(URL(filePath: path))
    let title = chinese ?? display
    let pinyin = chinese.flatMap(Self.pinyin)
    let names = [title, display, fileName, pinyin?.full].compactMap { $0.map(LauncherMatch.fold) }
    return LauncherItem(
      kind: .app, target: path, title: title,
      // 本 App 界面是简体中文，displayName 往往已是中文名：副标题用文件名（多为英文原名）
      subtitle: fileName != title ? fileName : location(of: path),
      names: names.reduce(into: []) { if !$0.contains($1) { $0.append($1) } },
      // 显示名常是中文（「活」），英文缩写要从文件名取（Activity Monitor → am）
      initials: [
        LauncherMatch.initials(display), LauncherMatch.initials(fileName), pinyin?.initials,
      ]
      .compactMap { $0 }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } })
  }

  /// App 不在标准目录（应用程序目录及其一层子文件夹、访达所在处）时的位置（~ 缩写的父目录）；在标准目录里是空的
  static func location(of path: String) -> String {
    let parent = (path as NSString).deletingLastPathComponent
    let standard = directories + extraApps.map { ($0 as NSString).deletingLastPathComponent }
    guard !standard.contains(parent),
      !directories.contains((parent as NSString).deletingLastPathComponent)
    else { return "" }
    return (parent as NSString).abbreviatingWithTildeInPath
  }

  /// 各应用程序目录的修改时间（只 stat，微秒级）：往目录里放进、删掉 .app 都会改它。
  /// 子文件夹里升级、改名不改顶层的，由 LauncherModel 的 5 分钟兜底重扫接住
  static func signature(of directories: [String] = directories) -> [Date?] {
    directories.map {
      (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date
    }
  }

  /// 简体中文显示名：系统 App 在 InfoPlist.loctable（表里混着非字符串的项，要逐个取），
  /// 第三方 App 在 zh_CN / zh-Hans.lproj/InfoPlist.strings
  static func chineseName(_ bundle: URL) -> String? {
    let resources = bundle.appending(path: "Contents/Resources")
    let keys = ["zh_CN", "zh-Hans", "zh_Hans", "zh-CN"]
    if let data = try? Data(contentsOf: resources.appending(path: "InfoPlist.loctable")),
      let table = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any]
    {
      for key in keys {
        if let strings = table[key] as? [String: String],
          let name = strings["CFBundleDisplayName"] ?? strings["CFBundleName"]
        {
          return name
        }
      }
    }
    for key in keys {
      let url = resources.appending(path: "\(key).lproj/InfoPlist.strings")
      if let strings = NSDictionary(contentsOf: url) as? [String: String],
        let name = strings["CFBundleDisplayName"] ?? strings["CFBundleName"]
      {
        return name
      }
    }
    return nil
  }

  // MARK: 系统设置面板（体检 D9）

  static let settingsDirectory = "/System/Library/ExtensionKit/Extensions"
  static let settingsScheme = "x-apple.systempreferences:"
  static let systemSettingsPath = "/System/Applications/System Settings.app"

  /// 只在特定情况下才出现的面板（跟进事项、连着耳机时、课程进度、接了游戏控制器、有光驱）：平时打开是空的，不列。
  /// ponytail: 按名单排除，系统加了新的这类面板顶多多一行；要准就得照 Info.plist 的 representations 谓词判断
  static let conditionalPanes: Set<String> = [
    "com.apple.FollowUpSettings.FollowUpSettingsExtension", "com.apple.HeadphoneSettings",
    "com.apple.ClassKit-Settings.extension", "com.apple.Game-Controller-Settings.extension",
    "com.apple.CD-DVD-Settings.extension",
  ]

  /// 是扫出来的面板（按目录认，不按网址开头：用户自己建的 x-apple.systempreferences: 快捷链接、直接输入打开过的
  /// 这类网址仍是普通网址，能复制、收藏还原得出来）
  static func isSettingsPane(_ target: String) -> Bool {
    paneCache?.targets.contains(target) == true
  }

  /// 面板只在系统更新时变：按目录的修改时间缓存，App 目录重扫时不跟着重读（50 个 .appex 的字符串表，
  /// Debug 构建实测约 57 ms）
  private static var paneCache: (modified: Date?, items: [LauncherItem], targets: Set<String>)?

  /// 系统设置面板（缓存的）；单测、截图自检也走这里，isSettingsPane 才认得它们
  static func panes() -> [LauncherItem] {
    let modified = signature(of: [settingsDirectory]).first ?? nil
    if let paneCache, paneCache.modified == modified { return paneCache.items }
    let items = settingsPanes()
    paneCache = (modified, items, Set(items.map(\.target)))
    return items
  }

  static func settingsPanes(in directory: String = settingsDirectory) -> [LauncherItem] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
    return names.filter { $0.hasSuffix(".appex") }.sorted()
      .compactMap { settingsPane(URL(filePath: directory + "/" + $0)) }
  }

  /// 一个 .appex：是系统设置面板、能用网址打开、有中文名才算
  static func settingsPane(_ bundle: URL) -> LauncherItem? {
    let contents = bundle.appending(path: "Contents")
    guard let data = try? Data(contentsOf: contents.appending(path: "Info.plist")),
      let info = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any],
      let id = info["CFBundleIdentifier"] as? String, !conditionalPanes.contains(id),
      let extensionInfo = info["EXAppExtensionAttributes"] as? [String: Any],
      extensionInfo["EXExtensionPointIdentifier"] as? String == "com.apple.Settings.extension.ui",
      let attributes = extensionInfo["SettingsExtensionAttributes"] as? [String: Any],
      attributes["allowsXAppleSystemPreferencesURLScheme"] as? Bool == true
    else { return nil }
    let strings = loctable(contents.appending(path: "Resources/InfoPlist.loctable"))
    func name(_ language: String) -> String? {
      strings[language].flatMap { $0["CFBundleDisplayName"] ?? $0["CFBundleName"] } as? String
    }
    // 电池这类按机型叫法不同的（「电池」/「能耗」）：显示名在 representations 的 sidebar-name 里，都能搜，
    // 没有中文显示名时两个一起当标题
    let keys = (attributes["representations"] as? [[String: Any]] ?? [])
      .compactMap { $0["sidebar-name"] as? String }
    let localizable =
      keys.isEmpty ? [:] : loctable(contents.appending(path: "Resources/Localizable.loctable"))
    let sidebar = keys.compactMap { localizable["zh_CN"]?[$0] as? String }
      .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    guard
      let chinese = ["zh_CN", "zh-Hans", "zh_Hans"].lazy.compactMap(name).first
        ?? (sidebar.isEmpty ? nil : sidebar.joined(separator: " / "))
    else { return nil }
    let english = name("en") ?? info["CFBundleDisplayName"] as? String ?? ""
    let pinyin = ([chinese] + sidebar).compactMap(Self.pinyin)
    // 「Wi‑Fi」里是不断行连字符：另存一份只留字母数字的，搜 wifi 也能到
    let compact = english.filter { $0.isLetter || $0.isNumber }
    let names = ([chinese] + sidebar + [english, compact] + pinyin.map(\.full))
      .filter { !$0.isEmpty }.map(LauncherMatch.fold)
    return LauncherItem(
      kind: .url, target: settingsScheme + id, title: chinese, subtitle: "系统设置",
      names: names.reduce(into: []) { if !$0.contains($1) { $0.append($1) } },
      initials: ([LauncherMatch.initials(english)] + pinyin.map(\.initials)).filter { !$0.isEmpty })
  }

  /// .loctable：各语言的字符串表合在一个 plist 里（语言 → 键 → 字符串），读一次查多个键
  private static func loctable(_ url: URL) -> [String: [String: Any]] {
    guard let data = try? Data(contentsOf: url),
      let table = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any]
    else { return [:] }
    return table.compactMapValues { $0 as? [String: Any] }
  }

  /// 含汉字才转：「活动监视器」→ (huodongjianshiqi, hdjsq)；夹着的英文词原样保留。
  /// ponytail: 多音字取系统默认读音，偶尔会错（如「行」），真碰到再加别名
  static func pinyin(_ text: String) -> (full: String, initials: String)? {
    guard text.contains(/\p{Han}/),
      let latin = text.applyingTransform(.mandarinToLatin, reverse: false)?
        .applyingTransform(.stripDiacritics, reverse: false)
    else { return nil }
    let syllables = LauncherMatch.fold(latin).split(whereSeparator: \.isWhitespace)
    return (syllables.joined(), String(syllables.compactMap(\.first)))
  }
}
