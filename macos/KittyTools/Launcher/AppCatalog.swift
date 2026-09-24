// 启动器的 App 目录：扫各应用程序目录下的 .app（含一层子文件夹）。名字取显示名、文件名、中文本地化名，
// 中文名再转拼音全拼 + 首字母，让「活动监视器」「huodong」「hdjsq」都能搜到（修旧版只认文件名，§11 #26）。
// 系统 App 不另写死一份、按解开符号链接后的路径去重（修旧版同一个 App 出现两行，§11 #25；
// 本机 /Applications/Safari.app 就是指向 Cryptexes 的链接）；访达不在应用程序目录里，单独加。
// 在主线程扫：本机 116 个 App 实测约 65ms（含拼音），由 LauncherModel 决定何时重扫。

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
    return items
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
      subtitle: fileName != title ? fileName : "应用程序",
      names: names.reduce(into: []) { if !$0.contains($1) { $0.append($1) } },
      // 显示名常是中文（「活」），英文缩写要从文件名取（Activity Monitor → am）
      initials: [
        LauncherMatch.initials(display), LauncherMatch.initials(fileName), pinyin?.initials,
      ]
      .compactMap { $0 }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } })
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
