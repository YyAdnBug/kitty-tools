// 访达扩展交过来的一次动作（第十一族「访达右键」，2026-11-08 拍板，PLAN §10「访达右键」）。扩展只画菜单（KittyToolsFinder/FinderMenu），
// 点了用 App 自己的网址把动作交过来：<App 的 bundle id>://finder?do=<动作>&key=<凭证>&…&file=/a&file=/b，动作是
// copy（拷贝路径）、name（拷贝名称）、open（app=bundle id，用 App 打开）、new（template=模板名，mine=1 是模板文件夹里的；
// file 是右键的文件夹）、suffix（自定义后缀，file 是文件夹）、templates（打开模板文件夹）、move / copyto（to=常用文件夹的路径，
// 或 choose 另选）、cut（剪切）、paste（file 是右键的文件夹）、alias（发送替身到桌面）、zip / 7z（压缩）、extract（解压到这里）、
// copy 带 style=shell 是按住 ⌥ 时的「拷贝路径（终端写法）」、name 带 style=stem 是「拷贝名称（不带扩展名）」，toomany（一次选了
// 超过上限，扩展交过来让 App 说一声，不带文件）、fixnames（修复乱码文件名）、hiddenfiles（切换隐藏文件）、hide / ext（on=1 / 0：隐藏、取消隐藏、隐藏 / 显示扩展名）、
// hash（algo=sha256 / md5 / sha1）、erase（彻底删除，先问）。
// 解析、拷贝的文字、交给别的 App 打开哪些都是纯函数（FinderLinkTests）；perform 做那一步：拷贝路径 / 名称走 Paster.write 并记进
// 剪贴板历史（mac-native §5：算本 App 生成的新文字），用 App 打开交给 NSWorkspace，新建文件交给 NewFile，整理文件交给 FileMoves，
// 压缩和解压交给 Archives，修复乱码文件名交给 NameRepair，隐藏的几样交给 FileFlags，哈希交给 FileHash。
// 谁都能打开这个网址（网页、别的 App），所以一层层挡：
// - 发送方必须是本团队签名的自家访达扩展（fromOwnExtension，2026-11-08 右键扩充拍板 A1，同 finder-menu 核对发送方签名；
//   冷启动和已在运行两种情况下，苹果事件里的发送方都是发网址的扩展本身，沙盒小程序实测）；
// - 凭证对得上（App 第一次启动时生成、存在偏好里的随机串，ensureKey；扩展从 App 的偏好里读）；
// - 功能开着、这一项在设置里开着；路径是绝对路径；要用的 App、常用文件夹在设置的列表里。
// 新建文件那边另有一层（模板路径上不认替身、不往 ~/Library 里建，见 NewFile 文件头）。

import AppKit
import OSLog
import Security
import UniformTypeIdentifiers

nonisolated struct FinderLink: Equatable {
  enum Action: Equatable {
    /// shell：终端里能直接用的写法（要加引号的加单引号，几个用空格连起来）
    case copyPaths(shell: Bool)
    /// stem：不带扩展名
    case copyNames(stem: Bool)
    /// 扩展里一次选了超过 maxFiles 个
    case tooMany
    /// 交给这个 App 打开（bundle id）
    case open(app: String)
    /// 用模板在 files 那一个文件夹里新建（mine：模板文件夹里的，否则随 App 的 NewFile.builtIn）
    case newFile(template: String, mine: Bool)
    /// 问后缀、在 files 那一个文件夹里建空文件
    case customSuffix
    /// 打开模板文件夹
    case showTemplates
    /// 移动 / 复制到 to；to 是 nil = 弹面板另选
    case transfer(move: Bool, to: URL?)
    case cut
    /// 把剪切的移进 files 那一个文件夹
    case paste
    case aliasToDesktop
    case compress(Archives.Format)
    case extract
    case fixNames
    case toggleHiddenFiles
    case setHidden(Bool)
    case setExtensionHidden(Bool)
    case copyHash(FileHash.Kind)
    case erase

    /// 对应设置里的哪一项（nil：不归哪一项管，「在“X”中打开」跟着 App 列表）
    var item: FinderMenuItem? {
      switch self {
      case .copyPaths: .copyPath
      case .copyNames: .copyName
      case .open, .tooMany: nil
      case .newFile, .customSuffix, .showTemplates: .newFile
      case .transfer: .transfer
      case .cut, .paste: .cut
      case .aliasToDesktop: .deskAlias
      case .compress: .compress
      case .extract: .extract
      case .fixNames: .fixNames
      case .toggleHiddenFiles: .showHidden
      case .setHidden, .setExtensionHidden: .hide
      case .copyHash: .hash
      case .erase: .erase
      }
    }
  }

  let action: Action
  let files: [URL]

  static let host = "finder"
  /// 一次最多这么多个：访达里全选几万个文件再右键，网址长得离谱，拷贝的字也没人要
  static let maxFiles = 2000

  /// 解析网址；scheme 是本 App 的 bundle id，key 是偏好里的凭证，apps 是设置里「用 App 打开」的列表，folders 是常用文件夹
  static func parse(
    _ url: URL, scheme: String, key: String?, apps: [String], folders: [URL] = []
  ) -> FinderLink? {
    guard url.scheme?.caseInsensitiveCompare(scheme) == .orderedSame, url.host() == host,
      let key, !key.isEmpty,
      let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
    else { return nil }
    func one(_ name: String) -> String? {
      let values = items.filter { $0.name == name }
      return values.count == 1 ? values[0].value : nil
    }
    let paths = items.filter { $0.name == "file" }.compactMap(\.value)
    // 路径里不能有「.」「..」这一段：比路径时会被化简掉，确认框上的名字和真删的对不上（访达也不会给这种）
    guard one("key") == key, paths.count <= maxFiles,
      paths.allSatisfy({
        $0.hasPrefix("/") && !$0.contains("\0")
          && !$0.split(separator: "/").contains { $0 == "." || $0 == ".." }
      })
    else { return nil }
    let files = paths.map { URL(filePath: $0) }
    let action: Action
    switch one("do") {
    case "copy" where !files.isEmpty:
      action = .copyPaths(shell: one("style") == "shell")
    case "name" where !files.isEmpty:
      action = .copyNames(stem: one("style") == "stem")
    case "toomany" where files.isEmpty:
      action = .tooMany
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
    case let verb? where (verb == "move" || verb == "copyto") && !files.isEmpty:
      guard let to = one("to") else { return nil }
      if to == "choose" {
        action = .transfer(move: verb == "move", to: nil)
      } else {
        // 只认设置里的常用文件夹（按展开后的路径比）
        let wanted = FileMoves.plainPath(URL(filePath: to))
        guard let folder = folders.first(where: { FileMoves.plainPath($0) == wanted }) else {
          return nil
        }
        action = .transfer(move: verb == "move", to: folder)
      }
    case "cut" where !files.isEmpty:
      action = .cut
    case "paste" where files.count == 1:
      action = .paste
    case "alias" where !files.isEmpty:
      action = .aliasToDesktop
    case "zip" where !files.isEmpty:
      action = .compress(.zip)
    case "7z" where !files.isEmpty:
      action = .compress(.sevenZip)
    case "extract" where !files.isEmpty:
      action = .extract
    case "fixnames" where !files.isEmpty:
      action = .fixNames
    case "hiddenfiles":
      action = .toggleHiddenFiles
    case let verb? where (verb == "hide" || verb == "ext") && !files.isEmpty:
      guard let on = one("on"), on == "1" || on == "0" else { return nil }
      action = verb == "hide" ? .setHidden(on == "1") : .setExtensionHidden(on == "1")
    case "hash" where !files.isEmpty:
      guard let kind = one("algo").flatMap(FileHash.Kind.init(rawValue:)) else { return nil }
      action = .copyHash(kind)
    case "erase" where !files.isEmpty:
      action = .erase
    default:
      return nil
    }
    return FinderLink(action: action, files: files)
  }

  /// 「拷贝路径」写什么：一个一行
  static func pathText(_ files: [URL]) -> String {
    files.map { $0.path(percentEncoded: false) }.joined(separator: "\n")
  }

  /// 「拷贝名称」写什么：带扩展名，一个一行；stem：去掉扩展名（文件夹照原名，「项目 v1.2」不截）
  static func nameText(
    _ files: [URL], stem: Bool = false, isDirectory: (URL) -> Bool = { _ in false }
  )
    -> String
  {
    files.map {
      stem && !isDirectory($0) ? $0.deletingPathExtension().lastPathComponent : $0.lastPathComponent
    }.joined(separator: "\n")
  }

  /// 「拷贝路径（终端写法）」：只有字母、数字和 / . _ - + @ % : , = 的原样，别的整段加单引号（里面的单引号写成 '\''），
  /// 几个用空格连起来——粘进终端就是几个参数（同 shell 自己的写法）
  static func shellText(_ files: [URL]) -> String {
    let plain = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+@%:,=")
    return files.map { file in
      let path = file.path(percentEncoded: false)
      return !path.isEmpty && path.allSatisfy(plain.contains)
        ? path : "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }.joined(separator: " ")
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

  /// 设置里加 App 时先列出来的常用终端和编辑器（装了的才列；bundle id）
  static let knownTools = [
    "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
    "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm", "com.microsoft.VSCode",
    "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed",
    "com.sublimetext.4", "com.panic.Nova", "com.barebones.bbedit", "com.apple.dt.Xcode",
    "com.jetbrains.intellij", "com.jetbrains.pycharm", "com.jetbrains.WebStorm",
    "com.apple.TextEdit",
  ]

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

  // MARK: 发送方

  /// 发这个网址的是不是自家的访达扩展：苹果事件里带着发送方的审计令牌，按它找到那个进程、核对签名
  @MainActor static func fromOwnExtension(_ event: NSAppleEventDescriptor?) -> Bool {
    guard let id = Bundle.main.bundleIdentifier,
      let token = event?.attributeDescriptor(forKeyword: AEKeyword(keySenderAuditTokenAttr))?.data
    else { return false }
    return signed(auditToken: token, as: id + ".finder")
  }

  /// 这个审计令牌对应的进程是本团队签名、id 是 identifier 的（同 Updater.requirement 的写法）
  static func signed(auditToken: Data, as identifier: String) -> Bool {
    var code: SecCode?
    guard
      SecCodeCopyGuestWithAttributes(
        nil, [kSecGuestAttributeAudit: auditToken] as CFDictionary, [], &code) == errSecSuccess,
      let code
    else { return false }
    var requirement: SecRequirement?
    let text =
      "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"HTX9F4KG39\""
    guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
      let requirement
    else { return false }
    return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
  }

  // MARK: 弹框

  /// 正在弹着：再来一次（框落在后面时用户又点了一回）不再弹第二个
  @MainActor private static var asking = false

  /// 弹一个框（自定义后缀、zip 的密码；扩展是后台进程，框在 App 里弹），focus 是一打开就能输入的那个框。照 FilePanel：
  /// macOS 27 上激活常被系统驳回、框会开在访达后面，所以框弹出来后提到 .modalPanel 这一层、拿到最前；关了把前台还给原来的
  /// App。已经弹着一个时是 nil
  @MainActor static func ask(_ alert: NSAlert, focus: NSView) -> NSApplication.ModalResponse? {
    guard !asking else { return nil }
    asking = true
    defer { asking = false }
    alert.window.initialFirstResponder = focus
    let me = NSRunningApplication.current.processIdentifier
    let front = NSWorkspace.shared.frontmostApplication
    let previous = front?.processIdentifier == me ? nil : front
    NSApp.activate()
    if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
    // runModal 开始之后再提层级（之前设的会被它改回去）；模态循环里排队的块在主线程上跑
    let window = alert.window
    RunLoop.main.perform(inModes: [.modalPanel]) {
      MainActor.assumeIsolated {
        window.level = .modalPanel
        window.orderFrontRegardless()
        window.makeKey()
      }
    }
    let response = alert.runModal()
    // 原来就是本 App 在前面（扩展唤起 App 时先激活了它）：框都是从访达右键来的，还给访达
    (previous
      ?? NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)?
      .activate()
    return response
  }

  // MARK: 做

  /// App 收到网址（AppDelegate.application(_:open:)，发送方已经核对过）：认得出来就做，认不出来什么都不做
  @MainActor static func perform(_ url: URL, island: Island?) {
    // 发送方已经核对过是自家扩展：认不出来多半是菜单弹出来之后设置改过（列表、开关），说一声（不只是什么都不做）
    guard Feature.finderMenu.isOn,
      let link = parse(
        url, scheme: Bundle.main.bundleIdentifier ?? "",
        key: UserDefaults.standard.string(forKey: Prefs.finderMenuKey), apps: openWithApps,
        folders: FileMoves.folders),
      link.action.item?.isOn != false
    else {
      island?.show("这一项没做成", detail: "设置刚改过的话，再右键一次", tone: .warning)
      return
    }
    switch link.action {
    case .copyPaths(let shell):
      Paster.write(string: shell ? shellText(link.files) : pathText(link.files), record: true)
      // 拷贝是转一手交给本 App 做的，访达那边看不出成没成：说一声（同几家成熟产品拷完的提示）
      island?.show(shell ? "已拷贝终端写法的路径" : "已拷贝路径", detail: copiedDetail(link.files))
    case .copyNames(let stem):
      let text = nameText(link.files, stem: stem) {
        (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
      }
      Paster.write(string: text, record: true)
      island?.show(
        "已拷贝名称", detail: link.files.count == 1 ? text : "\(link.files.count) 个名称")
    case .tooMany:
      island?.show("一次最多 \(maxFiles) 项", detail: "少选一些再右键", tone: .warning)
    case .open(let id):
      guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
        island?.show("找不到要打开的 App", detail: "它可能被删掉或挪走了", tone: .warning)
        return
      }
      let existing = link.files.filter { FileManager.default.fileExists(atPath: $0.path) }
      guard !existing.isEmpty else {
        island?.show("选中的东西不在了", detail: "可能刚被移走或删掉", tone: .warning)
        return
      }
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
      NewFile.create(template: name, mine: mine, in: link.files[0], island: island)
    case .customSuffix:
      NewFile.askSuffix(in: link.files[0], island: island)
    case .showTemplates:
      NewFile.showTemplates()
    case .transfer(let move, let folder?):
      FileMoves.transfer(link.files, to: folder, move: move, island: island)
    case .transfer(let move, nil):
      FileMoves.chooseAndTransfer(link.files, move: move, island: island)
    case .cut:
      FileMoves.cut(link.files, island: island)
    case .paste:
      FileMoves.paste(into: link.files[0], island: island)
    case .aliasToDesktop:
      FileMoves.aliasToDesktop(link.files, island: island)
    case .compress(let format):
      Archives.compress(link.files, format: format, island: island)
    case .extract:
      Archives.extract(link.files, island: island)
    case .fixNames:
      NameRepair.fix(link.files, island: island)
    case .toggleHiddenFiles:
      FileFlags.toggleHiddenFiles(island: island)
    case .setHidden(let hidden):
      FileFlags.setHidden(link.files, hidden, island: island)
    case .setExtensionHidden(let hidden):
      FileFlags.setExtensionHidden(link.files, hidden, island: island)
    case .copyHash(let kind):
      FileHash.copy(link.files, kind: kind, island: island)
    case .erase:
      FileMoves.erase(link.files, island: island)
    }
  }
}
