// 脚本命令从哪来（2026-11-07 拍板 A1 D1 D2，PLAN §10「脚本命令」）：数据目录里的默认文件夹 scripts，加上自己添加的文件夹
// （Prefs.scriptFolders，这台电脑自己的路径，不注册默认值、不导出；只读，不往里写，不扫子文件夹），最后是随 App 带的
// 自带脚本（Resources/scripts/script-*.sh，打进包里是平铺的；只读、跟着 App 更新，「命令」表里能关、能复制一份出来改）。
// 自己的排在自带的前面：同一个关键词时用自己的。
// 每次呼出启动器在主线程外重读一遍（几个小文件的开头，几毫秒；另加的文件夹可能在网络盘、同步盘上，碰它的都不在主线程，
// mac-native §3），读完换上、通知启动器按新的重搜；读的时候再要不重复起。读不成的记下原因（设置页列出来）。
// ponytail: 每次呼出都整个重读，不比修改时间；脚本多到几百个、或文件夹在很慢的网络盘上时，改成按文件夹修改时间 + 文件修改时间认。

import AppKit
import UniformTypeIdentifiers

@Observable final class ScriptLibrary {
  nonisolated struct Problem: Hashable, Sendable {
    let path: String
    let problem: ScriptCommand.Problem
  }

  nonisolated struct Scan: Sendable {
    var scripts: [ScriptCommand] = []
    var problems: [Problem] = []
  }

  private(set) var scripts: [ScriptCommand] = []
  private(set) var problems: [Problem] = []
  /// 读过一遍了（设置页在第一遍读完之前不说「没有脚本」）
  private(set) var isLoaded = false
  /// 换上新读的之后（启动器开着时重搜）
  @ObservationIgnored var onChange: () -> Void = {}
  @ObservationIgnored private var task: Task<Void, Never>?
  /// 读的时候又要读（刚添加了文件夹、导入、确认过）：这一遍读完再读一遍
  @ObservationIgnored private var needsAnother = false

  init() {}

  /// 截图自检：固定的脚本和问题，不读文件夹
  init(scripts: [ScriptCommand], problems: [Problem] = []) {
    self.scripts = scripts
    self.problems = problems
    isLoaded = true
  }

  /// 默认文件夹：数据目录里的 scripts（不弹文件夹授权框；设置页给「在访达中打开」）
  nonisolated static var defaultFolder: URL {
    AppDelegate.supportDirectory.appending(path: "scripts", directoryHint: .isDirectory)
  }

  /// 自己添加的文件夹（换行分隔的路径）
  static var addedFolders: [URL] {
    (UserDefaults.standard.string(forKey: Prefs.scriptFolders) ?? "")
      .split(whereSeparator: \.isNewline).map {
        URL(filePath: String($0), directoryHint: .isDirectory)
      }
  }

  static var folders: [URL] { [defaultFolder] + addedFolders }

  /// 自带脚本的文件名前缀（打进包里和别的资源平铺在一起）
  nonisolated static let bundledPrefix = "script-"

  /// 包里的自带脚本：资源目录里 script- 开头、.sh 结尾的（App 跑着时不会变，列一次）
  nonisolated static let bundledFiles: [URL] = {
    guard let resources = Bundle.main.resourceURL,
      let names = try? FileManager.default.contentsOfDirectory(atPath: resources.path)
    else { return [] }
    return names.filter { $0.hasPrefix(bundledPrefix) && $0.hasSuffix(".sh") }.sorted()
      .map { resources.appending(path: $0) }
  }()

  /// 重读（在主线程外）；正在读就不重复起
  func refresh(folders: [URL] = ScriptLibrary.folders, bundled: [URL] = ScriptLibrary.bundledFiles)
  {
    guard task == nil else {
      needsAnother = true
      return
    }
    task = Task {
      let scan = await Self.scan(folders, bundled: bundled)
      task = nil
      defer {
        if needsAnother {
          needsAnother = false
          refresh()
        }
      }
      let changed = scan.scripts != scripts || scan.problems != problems
      scripts = scan.scripts
      problems = scan.problems
      isLoaded = true
      if changed { onChange() }
    }
  }

  /// 等这一遍读完（单测）
  func loading() async { await task?.value }

  /// 读几个文件夹：每个文件只读开头（ScriptCommand.headerBytes），不进子文件夹；同一个文件出现两次（添加了默认文件夹
  /// 自己、符号链接）只算一次。按文件名排
  @concurrent static func scan(_ folders: [URL], bundled: [URL] = []) async -> Scan {
    var scan = Scan()
    var seen = Set<String>()
    let manager = FileManager.default
    for folder in folders {
      guard
        let files = try? manager.contentsOfDirectory(
          at: folder, includingPropertiesForKeys: [.isRegularFileKey],
          options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
      else { continue }
      for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        // 符号链接看它指向的（别的工具装脚本常用链接）
        let target = file.resolvingSymlinksInPath()
        guard (try? target.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        else { continue }
        let path = target.path
        guard seen.insert(path).inserted else { continue }
        guard let head = readHead(file) else {
          scan.problems.append(Problem(path: file.path, problem: .unreadable))
          continue
        }
        switch ScriptCommand.parse(head, path: file.path) {
        case .success(var script):
          script.isDownloaded = ScriptRunner.isDownloaded(file)
          scan.scripts.append(script)
        case .failure(let problem): scan.problems.append(Problem(path: file.path, problem: problem))
        case nil: break
        }
      }
    }
    // 自带的：随 App 签过名，不看下载标记
    for file in bundled {
      guard let head = readHead(file),
        case .success(var script)? = ScriptCommand.parse(head, path: file.path)
      else { continue }
      script.isBundled = true
      scan.scripts.append(script)
    }
    return scan
  }

  private nonisolated static func readHead(_ file: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: ScriptCommand.headerBytes) else { return nil }
    return String(decoding: data, as: UTF8.self)
  }
}

// MARK: 设置页用的：文件夹、新建、导入（拍板 A1 A2）

extension ScriptLibrary {
  /// 默认文件夹（不在就建）：设置页「在访达中打开」「新建脚本」「导入」都往这里放
  @discardableResult static func ensureDefaultFolder() -> URL {
    try? FileManager.default.createDirectory(at: defaultFolder, withIntermediateDirectories: true)
    return defaultFolder
  }

  /// 加一个文件夹（已经有的不重复）
  static func addFolder(_ url: URL) {
    let path = url.path(percentEncoded: false)
    var paths = addedFolders.map { $0.path(percentEncoded: false) }
    guard !paths.contains(path), path != defaultFolder.path(percentEncoded: false) else { return }
    paths.append(path)
    UserDefaults.standard.set(paths.joined(separator: "\n"), forKey: Prefs.scriptFolders)
  }

  static func removeFolder(_ url: URL) {
    let paths = addedFolders.map { $0.path(percentEncoded: false) }
      .filter { $0 != url.path(percentEncoded: false) }
    UserDefaults.standard.set(paths.joined(separator: "\n"), forKey: Prefs.scriptFolders)
  }

  /// 文件夹里一个还没用过的名字：「新脚本.sh」「新脚本 2.sh」…
  nonisolated static func freeURL(in folder: URL, name: String) -> URL {
    let base = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    var url = folder.appending(path: name)
    var index = 2
    while FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
      url = folder.appending(path: ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)")
      index += 1
    }
    return url
  }

  /// 「新建脚本」的模板：开头几行写清楚每个字段怎么写，照着改就行
  static let template = """
    #!/bin/zsh
    # @kitty.title 新脚本
    # @kitty.keyword hello
    # @kitty.mode island
    # @kitty.description 这一行写它是做什么的
    #
    # mode：island 岛上显示最后一行、paste 粘贴、copy 复制、full 启动器里看全部输出、list 每行一条结果（标题⇥副标题）、none 不显示
    # 要参数就加一行「# @kitty.argument1 城市」，在启动器里输入「hello 空格 北京」，「北京」在 $1 里
    # 要先确认再跑就加一行「# @kitty.confirm 再按 ↩ 清空下载文件夹」
    # 在启动器里出现的就是上面写的名字和关键词，保存后下次呼出启动器就能用

    echo "你好，$(id -un)"

    """

  /// 新建一个脚本（模板），返回它的位置
  static func newScript() -> URL? {
    let url = freeURL(in: ensureDefaultFolder(), name: "新脚本.sh")
    do {
      try template.write(to: url, atomically: true, encoding: .utf8)
      return url
    } catch {
      return nil
    }
  }

  /// 剪贴板里的一段文字是不是一个脚本（AI 给回来的）：去掉两头空白和 Markdown 代码块的 ``` 围栏，第一行是 #! 才算。
  /// 纯函数，配单测
  nonisolated static func scriptText(fromClipboard text: String) -> String? {
    var lines = text.trimmingCharacters(in: .whitespacesAndNewlines)
      .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    if lines.first?.hasPrefix("```") == true { lines.removeFirst() }
    if lines.last?.hasPrefix("```") == true { lines.removeLast() }
    let script = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return script.hasPrefix("#!") ? script + "\n" : nil
  }

  /// 从剪贴板新建时起的文件名：关键词.sh，没写关键词用「新脚本.sh」（只留字母、数字、短横线、下划线）
  nonisolated static func suggestedName(for text: String) -> String {
    var keyword = ""
    if case .success(let script)? = ScriptCommand.parse(text, path: "/x.sh") {
      keyword = script.keyword ?? ""
    }
    let safe = keyword.filter {
      $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
    }
    return safe.isEmpty ? "新脚本.sh" : safe + ".sh"
  }

  /// 存一段确认过的脚本文字（从剪贴板新建）：默认文件夹里起一个没用过的名字
  static func save(_ text: String, name: String) -> URL? {
    let url = freeURL(in: ensureDefaultFolder(), name: name)
    return (try? text.write(to: url, atomically: true, encoding: .utf8)) == nil ? nil : url
  }

  /// 「新建脚本」：照模板建一个、用编辑器打开（设置里的按钮、启动器里的命令同一个）
  static func newScriptAndEdit() -> URL? {
    guard let url = newScript() else { return nil }
    edit(url.path(percentEncoded: false))
    return url
  }

  /// 导入（看过全文、点了「导入」）：复制进默认文件夹（重名的加数字），去掉下载标记（已经看过了）；在主线程外做
  /// （拖进来的文件可能在网络盘上）
  @concurrent static func importScript(_ source: URL, into folder: URL) async -> URL? {
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let target = freeURL(in: folder, name: source.lastPathComponent)
    do {
      try FileManager.default.copyItem(at: source, to: target)
    } catch {
      return nil
    }
    var url = target
    var values = URLResourceValues()
    values.quarantineProperties = nil
    try? url.setResourceValues(values)
    return target
  }

  /// 自带的复制一份到默认文件夹（去掉 script- 前缀），用文本编辑器打开；返回复制出来的位置
  static func copyBundled(_ script: ScriptCommand) -> URL? {
    let name = String(script.fileName.dropFirst(bundledPrefix.count))
    let url = freeURL(in: ensureDefaultFolder(), name: name.isEmpty ? script.fileName : name)
    guard (try? FileManager.default.copyItem(at: URL(filePath: script.path), to: url)) != nil
    else { return nil }
    // 从下载的 DMG 装的 App，包里的文件可能带着隔离标记；复制出来的是自己的，不用再看一眼
    var copy = url
    var values = URLResourceValues()
    values.quarantineProperties = nil
    try? copy.setResourceValues(values)
    edit(url.path(percentEncoded: false))
    return url
  }

  /// 打开脚本给人改：用默认的纯文本编辑器（不按 .sh 的默认 App 开——那可能是终端，一开就跑了）
  static func edit(_ path: String) {
    let url = URL(filePath: path)
    guard let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText) else {
      return NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    NSWorkspace.shared.open(
      [url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration()
    ) { _, _ in }
  }
}

extension LauncherItem {
  /// 脚本命令的一行（拍板 C1）：标题、别名、包名、拼音都搜得到；副标题写 description，没有就写包名或所在文件夹的名字
  /// （默认文件夹写「我的脚本」）；命令家族紫的色块，头部写了图标的用它的。要参数的（B2）Tab / ↩ 补「别名 空格」
  /// （没有别名补标题）
  static func script(_ script: ScriptCommand, alias: String?) -> LauncherItem {
    let pinyin = AppCatalog.pinyin(script.title)
    let folder =
      script.isBundled
      ? "自带"
      : script.folder == ScriptLibrary.defaultFolder.path(percentEncoded: false).trimmingSuffix("/")
        ? "我的脚本" : (script.folder as NSString).lastPathComponent
    var item = LauncherItem(
      kind: .script, target: script.path, title: script.title,
      subtitle: script.summary ?? script.package ?? folder,
      names: [script.title, alias, script.package, pinyin?.full].compactMap {
        $0.map(LauncherMatch.fold)
      },
      initials: [LauncherMatch.initials(script.title), pinyin?.initials].compactMap { $0 },
      completion: script.takesInput ? (alias ?? script.title) + " " : nil)
    item.scriptIcon = script.icon
    item.scriptIconDark = script.iconDark
    return item
  }
}

extension String {
  fileprivate func trimmingSuffix(_ suffix: String) -> String {
    hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
  }
}

extension LauncherItem {
  /// 列表脚本给出的结果行（含「正在运行…」那一行）是不是这条脚本的
  nonisolated func isResult(of script: ScriptCommand) -> Bool {
    kind == .scriptResult && target.hasPrefix(script.path + "\n")
  }
}
