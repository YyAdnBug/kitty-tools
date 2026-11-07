// 脚本命令从哪来（2026-11-07 拍板 A1，PLAN §10「脚本命令」）：数据目录里的默认文件夹 scripts，加上自己添加的文件夹
// （Prefs.scriptFolders，这台电脑自己的路径，不注册默认值、不导出；只读，不往里写，不扫子文件夹）。
// 每次呼出启动器在主线程外重读一遍（几个小文件的开头，几毫秒；另加的文件夹可能在网络盘、同步盘上，碰它的都不在主线程，
// mac-native §3），读完换上、通知启动器按新的重搜；读的时候再要不重复起。读不成的记下原因（设置页列出来）。
// ponytail: 每次呼出都整个重读，不比修改时间；脚本多到几百个、或文件夹在很慢的网络盘上时，改成按文件夹修改时间 + 文件修改时间认。

import AppKit

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

  /// 重读（在主线程外）；正在读就不重复起
  func refresh(folders: [URL] = ScriptLibrary.folders) {
    guard task == nil else { return }
    task = Task {
      let scan = await Self.scan(folders)
      task = nil
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
  @concurrent static func scan(_ folders: [URL]) async -> Scan {
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
        guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        else { continue }
        let path = file.resolvingSymlinksInPath().path
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
    return scan
  }

  private nonisolated static func readHead(_ file: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: ScriptCommand.headerBytes) else { return nil }
    return String(decoding: data, as: UTF8.self)
  }
}

extension LauncherItem {
  /// 脚本命令的一行（拍板 C1）：标题、关键词、包名、拼音都搜得到；副标题写 description，没有就写包名或所在文件夹的名字
  /// （默认文件夹写「我的脚本」）；命令家族紫的色块，头部写了图标的用它的
  static func script(_ script: ScriptCommand) -> LauncherItem {
    let pinyin = AppCatalog.pinyin(script.title)
    let folder =
      script.folder == ScriptLibrary.defaultFolder.path(percentEncoded: false).trimmingSuffix("/")
      ? "我的脚本" : (script.folder as NSString).lastPathComponent
    var item = LauncherItem(
      kind: .script, target: script.path, title: script.title,
      subtitle: script.summary ?? script.package ?? folder,
      names: [script.title, script.keyword, script.package, pinyin?.full].compactMap {
        $0.map(LauncherMatch.fold)
      },
      initials: [LauncherMatch.initials(script.title), pinyin?.initials].compactMap { $0 })
    item.scriptIcon = script.icon
    return item
  }
}

extension String {
  fileprivate func trimmingSuffix(_ suffix: String) -> String {
    hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
  }
}

/// 脚本头部写的图片图标（同文件夹里的 png 这类）：第一次要画时在主线程外读（文件夹可能在网络盘上），读到了换上、按路径记着；
/// 读不出来的不再试（这次运行里）
@Observable final class ScriptIcons {
  static let shared = ScriptIcons()
  private(set) var images: [String: NSImage] = [:]
  @ObservationIgnored private var requested: Set<String> = []

  func image(_ path: String) -> NSImage? {
    if let image = images[path] { return image }
    if requested.insert(path).inserted {
      Task {
        if let data = await Self.read(path), let image = NSImage(data: data) {
          images[path] = image
        }
      }
    }
    return nil
  }

  /// 图标最多 2 MB
  @concurrent private static func read(_ path: String) async -> Data? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    return (try? handle.read(upToCount: 2 << 20)) ?? nil
  }
}
