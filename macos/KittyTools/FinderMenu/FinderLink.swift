// 访达扩展交过来的一次动作（第十一族「访达右键」，2026-11-08 拍板，PLAN §10「访达右键」）。扩展只画菜单（KittyToolsFinder/FinderMenu），
// 点了用 App 自己的网址把动作交过来：<App 的 bundle id>://finder?do=<动作>&key=<凭证>&…&file=/a&file=/b，动作是
// copy（拷贝路径）、open（app=bundle id，用 App 打开）、new（template=模板名，mine=1 是模板文件夹里的；file 是右键的文件夹）、
// suffix（自定义后缀，file 是文件夹）、templates（打开模板文件夹）。
// 解析、拷贝的文字、交给别的 App 打开哪些都是纯函数（FinderLinkTests）；perform 做那一步：拷贝路径走 Paster.write 并记进剪贴板历史
// （mac-native §5：路径算本 App 生成的新文字），用 App 打开交给 NSWorkspace，新建文件交给 NewFile。
// 谁都能打开这个网址（网页、别的 App）：功能关着、凭证对不上、路径不是绝对路径、要用的 App 不在设置的列表里，一律不认、什么都不做。
// 凭证是 App 第一次启动时生成、存在偏好里的随机串（ensureKey），扩展从 App 的偏好里读（沙盒的只读例外）；挡的是网页。
// 本机别的程序读得到凭证，所以这里做的事不能借本 App 的授权（桌面 / 文稿 / 下载、完全磁盘访问）做到它自己做不到的：
// 拷贝路径只是文字；用 App 打开交给的是用户设置里的 App，会被运行的文件只交给编辑器；新建文件见 NewFile 文件头。

import AppKit
import OSLog
import UniformTypeIdentifiers

nonisolated struct FinderLink: Equatable {
  enum Action: Equatable {
    case copyPaths
    /// 交给这个 App 打开（bundle id）
    case open(app: String)
    /// 用模板在 files 那一个文件夹里新建（mine：模板文件夹里的，否则随 App 的 NewFile.builtIn）
    case newFile(template: String, mine: Bool)
    /// 问后缀、在 files 那一个文件夹里建空文件
    case customSuffix
    /// 打开模板文件夹
    case showTemplates
  }

  let action: Action
  let files: [URL]

  static let host = "finder"
  /// 一次最多这么多个：访达里全选几万个文件再右键，网址长得离谱，拷贝的字也没人要
  static let maxFiles = 2000

  /// 解析网址；scheme 是本 App 的 bundle id，key 是偏好里的凭证，apps 是设置里「用 App 打开」的列表
  static func parse(_ url: URL, scheme: String, key: String?, apps: [String]) -> FinderLink? {
    guard url.scheme?.caseInsensitiveCompare(scheme) == .orderedSame, url.host() == host,
      let key, !key.isEmpty,
      let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
    else { return nil }
    func one(_ name: String) -> String? {
      let values = items.filter { $0.name == name }
      return values.count == 1 ? values[0].value : nil
    }
    let paths = items.filter { $0.name == "file" }.compactMap(\.value)
    guard one("key") == key, paths.count <= maxFiles,
      paths.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") })
    else { return nil }
    let files = paths.map { URL(filePath: $0) }
    let action: Action
    switch one("do") {
    case "copy" where !files.isEmpty:
      action = .copyPaths
    case "open" where !files.isEmpty:
      guard let app = one("app"), apps.contains(app) else { return nil }
      action = .open(app: app)
    case "new" where files.count == 1:
      let mine = one("mine") == "1"
      guard let name = one("template"), NewFile.isPlainName(name),
        mine || NewFile.builtIn.contains(name)
      else { return nil }
      action = .newFile(template: name, mine: mine)
    case "suffix" where files.count == 1:
      action = .customSuffix
    case "templates" where files.isEmpty:
      action = .showTemplates
    default:
      return nil
    }
    return FinderLink(action: action, files: files)
  }

  /// 「拷贝路径」写什么：一个一行
  static func pathText(_ files: [URL]) -> String {
    files.map { $0.path(percentEncoded: false) }.joined(separator: "\n")
  }

  /// 交给 App 打开哪些：文件夹原样给；文件给那个 App 认得的（系统登记的它能开的类型），认不得的改给所在的文件夹，
  /// 几个落到同一个文件夹只给一次；不是编辑器的（终端这类）只给第一个——选了几十个文件时不弹出一串终端窗口
  /// （同 OpenInTerminal：终端只取第一个、编辑器全给）。**交过去就会被运行的文件**（runs：脚本、可执行文件、终端的配置——终端登记了
  /// .command、.tool、没有扩展名的可执行文件和 .terminal，给它就跑；.sh 它没登记）只交给编辑器（appEdits：这个 App
  /// 能开纯文本，同 ScriptLibrary.editor 的白名单），别的 App 拿到的是所在的文件夹：右键「用终端打开」是想在那里开终端
  static func targets(
    _ files: [URL], isDirectory: (URL) -> Bool, opens: (URL) -> Bool, runs: (URL) -> Bool,
    appEdits: Bool
  ) -> [URL] {
    var targets: [URL] = []
    for file in files {
      // 所在文件夹按路径取（deletingLastPathComponent 会带上结尾的「/」，和选中的同一个文件夹比不上、给两次）
      let parent = (file.path(percentEncoded: false) as NSString).deletingLastPathComponent
      let whole = isDirectory(file) || (opens(file) && (appEdits || !runs(file)))
      let target = whole ? file : URL(filePath: parent)
      if !targets.contains(target) { targets.append(target) }
      if !appEdits { break }
    }
    return targets
  }

  /// 第一次启动时生成凭证（已经有了就不动）。这台电脑自己的、不注册默认值：不跟着导出 / 导入、同步走
  @MainActor static func ensureKey(_ defaults: UserDefaults = .standard) {
    guard defaults.string(forKey: Prefs.finderMenuKey)?.isEmpty != false else { return }
    defaults.set(UUID().uuidString, forKey: Prefs.finderMenuKey)
  }

  /// 交过去会被运行的：脚本、可执行文件、终端的配置文件（里面能写启动时跑的命令）
  static func runs(_ type: UTType?) -> Bool {
    guard let type else { return false }
    return type.conforms(to: .script) || type.conforms(to: .executable)
      || type.identifier == "com.apple.terminal.settings"
  }

  /// 设置里「用 App 打开」的列表（bundle id；没存过是只有终端）
  @MainActor static var openWithApps: [String] {
    UserDefaults.standard.stringArray(forKey: Prefs.finderOpenWithApps)
      ?? Prefs.finderOpenWithDefault
  }

  /// 「拷贝路径」之后刘海岛上那一句的小字：一个是路径（主目录写成 ~），几个是「N 个路径」
  static func copiedDetail(_ files: [URL]) -> String {
    files.count == 1
      ? (files[0].path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
      : "\(files.count) 个路径"
  }

  /// 这个动作对应的那一项在设置里关着（扩展的菜单里已经没有它，这里再挡一次）
  @MainActor static func isHidden(_ action: Action) -> Bool {
    let key: String? =
      switch action {
      case .copyPaths: Prefs.finderMenuCopyPath
      case .newFile, .customSuffix, .showTemplates: Prefs.finderMenuNewFile
      case .open: nil
      }
    return key.map { UserDefaults.standard.object(forKey: $0) as? Bool == false } ?? false
  }

  /// App 收到网址（AppDelegate.application(_:open:)）：认得出来就做，认不出来什么都不做
  @MainActor static func perform(_ url: URL, island: Island?) {
    guard Feature.finderMenu.isOn,
      let link = parse(
        url, scheme: Bundle.main.bundleIdentifier ?? "",
        key: UserDefaults.standard.string(forKey: Prefs.finderMenuKey), apps: openWithApps),
      !isHidden(link.action)
    else { return }
    switch link.action {
    case .copyPaths:
      Paster.write(string: pathText(link.files), record: true)
      // 拷贝是转一手交给本 App 做的，访达那边看不出成没成：说一声（同几家成熟产品拷完的提示）
      island?.show("已拷贝路径", detail: copiedDetail(link.files))
    case .open(let id):
      guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
      let existing = link.files.filter { FileManager.default.fileExists(atPath: $0.path) }
      guard !existing.isEmpty else { return }
      let same = { (other: URL) in other.standardizedFileURL == app.standardizedFileURL }
      let targets = targets(
        existing,
        isDirectory: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true },
        opens: { NSWorkspace.shared.urlsForApplications(toOpen: $0).contains(where: same) },
        runs: { runs((try? $0.resourceValues(forKeys: [.contentTypeKey]))?.contentType) },
        appEdits: NSWorkspace.shared.urlsForApplications(toOpen: .plainText).contains(where: same))
      NSWorkspace.shared.open(targets, withApplicationAt: app, configuration: .init()) { _, error in
        // 只记错误码：错误说明里带着路径
        if let error { Log.finder.error("用 App 打开失败：\((error as NSError).code)") }
      }
    case .newFile(let name, let mine):
      NewFile.create(template: name, mine: mine, in: link.files[0])
    case .customSuffix:
      NewFile.askSuffix(in: link.files[0])
    case .showTemplates:
      NewFile.showTemplates()
    }
  }
}
