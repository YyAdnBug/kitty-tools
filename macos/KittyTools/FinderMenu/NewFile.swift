// 访达右键「新建文件 ▸」（第十一族第 2 批，2026-11-08 拍板 B1，PLAN §10「访达右键」）：文件夹空白处右键，扩展列出菜单、
// 点了交给 App（FinderLink 的 do=new / suffix / templates），App 在这里建：
// - 自带五种：文本文件、Markdown、Word 文档、Excel 表格、PPT 演示文稿（Resources/new-file/，包里平铺、叫 new-file.<id>；
//   Word 是系统 textutil 转的、Excel / PPT 是手写的最小 Office Open XML，元数据都是空的）。内部认 id（就是扩展名，多语言第 8b 批），
//   建出来的文件名跟当时的界面语言（「文本文件.txt」「Text File.txt」），建好就是用户的文件。
// - 数据目录「新建文件模板」文件夹里用户放的任何文件（放什么就能建什么；扩展有这个文件夹的只读例外，列菜单用）。
// - 「自定义后缀…」：App 弹框问后缀（扩展是后台进程，弹不出窗口），建一个空的「JSON 文件.json」（英文界面「JSON File.json」）；
//   框里「以后列在「新建文件」里」默认勾着：模板文件夹里也放一个同名的空文件，已经有这个后缀的模板（含自带的）就不放。
// 拷一份到右键的那个文件夹，名字同模板，重名加「 2」；新文件的日期是现在（拷贝会带着模板的旧日期）；建不成响一声、记错误码。
// 建好后同访达的「新建文件夹」、Windows 的新建：在访达里选中它、进入改名（revealForRename，按回车要辅助功能授权；
// 按之前用辅助功能核对访达里选中的正好是新文件，对不上只选中不改名——issue #34：回车落到父文件夹上，⌘⌫ 删了整个文件夹）。
// 名字、后缀的收拾是纯函数（NewFileTests）。
// 安全（2026-11-08 评审）：凭证在偏好里，本机别的程序读得到、也能投网址过来，但它没有本 App 的文件夹授权（桌面 / 文稿 / 下载，
// 用户给过的话还有完全磁盘访问）。所以：模板只认真放在模板文件夹里的——数据目录、模板文件夹、模板本身都不能是替身（符号链接），
// 不然把模板文件夹换成指向 ~/Documents 的替身，就能借本 App 的授权把受保护的文件拷到别处；新文件不往 ~/Library 里建（别的 App
// 的数据、容器都在那里，用户也不会在那里右键新建；iCloud 云盘、网盘这两处除外，见 allowsNewFiles）；只新建、不覆盖。

import AppKit
import Carbon.HIToolbox
import ImageIO
import OSLog
import UniformTypeIdentifiers

nonisolated enum NewFile {
  /// 随 App 的五个：id 就是扩展名，网址里交的是它（扩展那边抄了一份，FinderLinkTests 读源码比对）
  static let builtIn = ["txt", "md", "docx", "xlsx", "pptx"]
  /// 0.9.0 的扩展交的是中文文件名：App 更新之后、访达重新拉起扩展之前，旧扩展的进程还在跑，交过来的照认
  static let legacyNames = [
    "文本文件.txt": "txt", "Markdown.md": "md", "Word 文档.docx": "docx", "Excel 表格.xlsx": "xlsx",
    "PPT 演示文稿.pptx": "pptx",
  ]
  /// 包里的模板叫「new-file.<id>」（资源平铺，别和别的撞名）
  static let resourceName = "new-file"
  /// 数据目录里用户的模板文件夹（扩展的只读例外写的就是这个名字）。**永远不翻**：扩展的 entitlements、扩展里抄的路径、
  /// 用户已经放进去的模板都认这个名字
  static let folderName = "新建文件模板"

  /// 自带的那一个建出来叫什么（跟界面语言；扩展菜单里列的是同样几个名字，在它自己的目录里）
  static func fileName(of id: String) -> String {
    let title =
      switch id {
      case "txt": String(localized: "文本文件")
      case "docx": String(localized: "Word 文档")
      case "xlsx": String(localized: "Excel 表格")
      case "pptx": String(localized: "PPT 演示文稿")
      case "md": "Markdown"
      default: id
      }
    return title + "." + id
  }

  static func templatesFolder(in data: URL = AppDelegate.supportDirectory) -> URL {
    data.appending(path: folderName, directoryHint: .isDirectory)
  }

  /// 网址里交过来的模板名只能是一个文件名：不带路径、不是隐藏文件、没有 NUL
  static func isPlainName(_ name: String) -> Bool {
    !name.isEmpty && !name.contains("/") && !name.contains("\0") && !name.hasPrefix(".")
  }

  /// 没人用的名字：重名加「 2」「 3」（扩展名前面加）
  static func freeName(_ name: String, taken: (String) -> Bool) -> String {
    guard taken(name) else { return name }
    var stem = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    var number = 2
    while true {
      // 名字最长 255 个字符（APFS 按字符，FAT / HFS+ 按 UTF-16）：加了「 2」超长的，把前面截短（不然超长的名字被当成空位，
      // 建的时候才失败）
      let tail = " \(number)" + (ext.isEmpty ? "" : "." + ext)
      while !stem.isEmpty, (stem + tail).utf16.count > 255 { stem.removeLast() }
      let candidate = stem + tail
      if !taken(candidate) { return candidate }
      number += 1
    }
  }

  /// 自定义后缀：去掉两头的空白和点（「.json」「 yaml 」都行）；空的、带 / 或 : 的不要。「tar.gz」这种整个留着
  static func cleanSuffix(_ raw: String) -> String? {
    let suffix = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(["."]))
    guard !suffix.isEmpty, !suffix.contains("/"), !suffix.contains(":"), !suffix.contains("\0")
    else { return nil }
    return suffix
  }

  /// 自定义后缀建出来的名字：「JSON 文件.json」「TAR.GZ 文件.tar.gz」（英文「JSON File.json」）
  static func customName(suffix: String) -> String {
    String(
      localized: "\(suffix.uppercased()) 文件",
      comment: "访达右键「自定义后缀…」建出来的文件名（不含扩展名），%@ 是大写的后缀：JSON 文件")
      + "." + suffix
  }

  /// 已经有这个后缀的模板了（不分大小写；「tar.gz」整个比，不当成「gz」）
  static func hasTemplate(suffix: String, among names: [String]) -> Bool {
    names.contains { $0.lowercased().hasSuffix("." + suffix.lowercased()) }
  }

  // MARK: 建

  /// 用模板建一个（mine：模板文件夹里的，name 是文件名；否则随 App 的，name 是 id）。返回建好的位置
  @discardableResult @MainActor static func create(
    template name: String, mine: Bool, in folder: URL, island: Island? = nil
  )
    -> URL?
  {
    let source =
      mine
      ? templatesFolder().appending(path: name)
      : Bundle.main.url(forResource: resourceName, withExtension: name)
    let created = mine ? name : fileName(of: name)
    guard let source, FileManager.default.fileExists(atPath: source.path(percentEncoded: false))
    else {
      island?.show("找不到模板「\(created)」", detail: "模板文件夹里的它可能被删了或改了名", tone: .warning)
      return nil
    }
    guard !mine || noAliases([AppDelegate.supportDirectory, templatesFolder(), source]) else {
      island?.show("没有新建", detail: "模板文件夹里不认替身", tone: .warning)
      return nil
    }
    // ponytail: 查替身和拷贝之间有一小段空当（查完再换成替身还拷得过去），文件夹模板在主线程上一次拷完、不限大小——
    // 真碰上再改成 O_NOFOLLOW_ANY 打开再写、文件夹放到主线程外
    return place(created, in: folder, island: island) {
      try FileManager.default.copyItem(at: source, to: $0)
    }
  }

  /// 这几层没有一层是替身（符号链接），拷文件夹模板时里面的替身照原样拷成替身、不跟过去
  static func noAliases(_ urls: [URL]) -> Bool {
    urls.allSatisfy {
      (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == false
    }
  }

  /// 能不能往这个文件夹里建：不在 ~/Library 里（解开替身后比）。iCloud 云盘（~/Library/Mobile Documents/…）和网盘
  /// （~/Library/CloudStorage/…）是用户自己的文稿、照建（访达工具栏按钮主要就用在那里，2026-11-17 评审）；它们的根不算
  static func allowsNewFiles(
    in folder: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser
  )
    -> Bool
  {
    let library = home.resolvingSymlinksInPath().appending(path: "Library").path(
      percentEncoded: false)
    let path = folder.resolvingSymlinksInPath().path(percentEncoded: false)
    if ["Mobile Documents", "CloudStorage"].contains(where: {
      path.hasPrefix(library + "/" + $0 + "/") && path.count > (library + "/" + $0 + "/").count
    }) {
      return true
    }
    return path != library && !path.hasPrefix(library + "/")
  }

  /// 拷进 / 写进 folder，名字让开已有的，日期改成现在；建不成刘海岛说原因（同访达建不成时会说为什么）
  @discardableResult @MainActor private static func place(
    _ name: String, in folder: URL, island: Island?, write: (URL) throws -> Void
  ) -> URL? {
    let manager = FileManager.default
    var isDirectory: ObjCBool = false
    guard manager.fileExists(atPath: folder.path(percentEncoded: false), isDirectory: &isDirectory)
    else {
      island?.show("没有新建", detail: "这个文件夹不在了", tone: .warning)
      return nil
    }
    guard isDirectory.boolValue else {
      island?.show("没有新建", detail: "右键的不是文件夹", tone: .warning)
      return nil
    }
    guard allowsNewFiles(in: folder) else {
      island?.show("没有新建", detail: "资源库里放的是各个 App 的数据，这里不新建文件", tone: .warning)
      return nil
    }
    // 按替身本身看占没占（fileExists 会跟过去：断了的替身被当成空位，写的时候才撞上、只能响一声）
    let free = freeName(name) {
      (try? manager.attributesOfItem(atPath: folder.appending(path: $0).path(percentEncoded: false)))
        != nil
    }
    let target = folder.appending(path: free)
    do {
      try write(target)
      try? manager.setAttributes(
        [.creationDate: Date.now, .modificationDate: Date.now],
        ofItemAtPath: target.path(percentEncoded: false))
      revealForRename(target)
      return target
    } catch {
      Log.finder.error("新建文件失败：\((error as NSError).code)")
      island?.show("没能新建", detail: "\(writeProblem(error))", tone: .error)
      return nil
    }
  }

  /// 写不进去的原因（给人看）
  static func writeProblem(_ error: Error) -> String {
    switch (error as NSError).code {
    case NSFileWriteVolumeReadOnlyError: String(localized: "这个位置是只读的")
    case NSFileWriteNoPermissionError: String(localized: "没有权限写这个文件夹")
    case NSFileWriteOutOfSpaceError: String(localized: "磁盘空间不够了")
    default: String(localized: "写不进去（可能没有权限）")
    }
  }

  /// 建好后同访达的「新建文件夹」：在访达里选中它、进入改名（按一下回车）。建在桌面上的不这么做：选中桌面上的东西会
  /// 另开一个「桌面」窗口（同几家成熟产品：桌面上新建不弹窗），只建好放在那里。ponytail: 在访达窗口里打开着「桌面」文件夹
  /// 新建时也不进入改名（分不出右键的是桌面还是那个窗口，要控制访达的自动化授权）按回车要辅助功能授权，没有就只选中。
  /// **回车只在访达里有焦点的那个视图选中的正好是新文件时才按**（issue #34）：选中是访达自己过一会儿才落下的（27.0.1 实测，
  /// 访达已在前台时 0.1–0.35 秒），原来到了前台再等 0.1 秒就按，回车落在原来选中的那个上——分栏视图里焦点还在左边那一栏，
  /// 进入改名的是父文件夹，用户接着按 ⌘⌫ 删的也是它。现在每 50 ms 问一次（finderSelects），最多 4 秒；对不上就只选中、不进改名。
  /// 等多久不影响按到哪（按之前核对过）：实机自检六次里有两次 2 秒内没对上（查过的那次 3 秒后对上了），所以给 4 秒
  @MainActor static func revealForRename(_ url: URL) {
    let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    guard
      FileMoves.plainPath(url.deletingLastPathComponent().resolvingSymlinksInPath())
        != FileMoves.plainPath(desktop.resolvingSymlinksInPath())
    else { return }
    NSWorkspace.shared.activateFileViewerSelecting([url])
    guard Permissions.isAccessibilityTrusted else { return }
    let frontFinder = {
      NSWorkspace.shared.frontmostApplication.flatMap {
        $0.bundleIdentifier == "com.apple.finder" ? $0.processIdentifier : nil
      }
    }
    Task {
      let clock = ContinuousClock()
      let deadline = clock.now + .seconds(4)
      while clock.now < deadline {
        // 问完再看一眼访达还在前台、还是那一个（问的那一会儿用户可能切走了）
        if let pid = frontFinder(), await finderSelects(only: url, pid: pid), frontFinder() == pid {
          Paster.press(kVK_Return)
          return
        }
        try? await Task.sleep(for: .milliseconds(50))
      }
      Log.finder.info("新建文件：访达里选中的不是新文件，只选中、没进入改名")
    }
  }

  /// 访达此刻有焦点的那个视图里，选中的只有 url 这一个。图标、列表、分栏（有焦点的那一栏）、画廊四种视图实测（27.0.1）
  /// 结构一样：焦点元素是列表（AXList / AXOutline），选中的项（AXSelectedChildren / AXSelectedRows）往下一两层有个带 AXURL
  /// 的元素（文件引用网址，解成路径）。侧栏、搜索框、桌面拿到焦点时对不上。辅助功能跨进程读，放在主线程外（mac-native §3）
  @concurrent static func finderSelects(only url: URL, pid: pid_t) async -> Bool {
    let app = AXUIElementCreateApplication(pid)
    guard let focused = axElements(app, kAXFocusedUIElementAttribute)?.first,
      let items = axElements(focused, kAXSelectedRowsAttribute)
        ?? axElements(focused, kAXSelectedChildrenAttribute),
      // 多选的不用一个个读（选着几千个时每一轮都要读几千次）
      items.count == 1
    else { return false }
    return selectsOnly(
      url.resolvingSymlinksInPath(), items.map { fileURL(in: $0)?.resolvingSymlinksInPath() })
  }

  /// 选中的正好是这一个：多选、读不出是哪个文件的、别的文件都不算（NewFileTests 锁住）
  static func selectsOnly(_ target: URL, _ selected: [URL?]) -> Bool {
    guard selected.count == 1, let only = selected[0] else { return false }
    return FileMoves.plainPath(only) == FileMoves.plainPath(target)
  }

  /// 选中的一项是哪个文件：它自己或往下两层里第一个带 AXURL 的（列表视图是 行 › 格 › 文字框）
  private static func fileURL(in item: AXUIElement) -> URL? {
    var level = [item]
    for depth in 0...2 {
      for element in level {
        AXUIElementSetMessagingTimeout(element, 0.2)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success,
          let value, CFGetTypeID(value) == CFURLGetTypeID()
        {
          // 上面认过类型。访达给的是文件引用网址（file:///.file/id=…），解成路径
          return (value as! NSURL).filePathURL
        }
      }
      if depth < 2 { level = level.flatMap { axElements($0, kAXChildrenAttribute) ?? [] } }
    }
    return nil
  }

  /// 读一个是元素（或元素数组）的属性：单个的包成一个；每次先设超时（只管设了的那一个元素，取回来的子元素默认等 6 秒）
  private static func axElements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
    AXUIElementSetMessagingTimeout(element, 0.2)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
      let value
    else { return nil }
    if CFGetTypeID(value) == AXUIElementGetTypeID() { return [value as! AXUIElement] }
    return value as? [AXUIElement]
  }

  // MARK: 从剪贴板新建

  /// 「从剪贴板新建」（2026-11-08，同几家成熟产品）：剪贴板里是图就存成「剪贴板图片.png」，是文字就存成「剪贴板文字.txt」
  /// （UTF-8；名字跟界面语言），重名加「 2」、建好照样选中进入改名；剪贴板里是文件的那是访达 ⌘V 的事，说一声。TIFF 转 PNG 在主线程外
  @MainActor static func fromClipboard(in folder: URL, island: Island?) {
    let board = NSPasteboard.general
    let types = board.types ?? []
    // 密码管理器这类标了「隐私」的不写成文件（剪贴板历史也不记它们）
    if types.contains(.init("org.nspasteboard.ConcealedType")) {
      island?.show("没有新建", detail: "剪贴板里是密码这类隐私内容，不存成文件", tone: .warning)
      return
    }
    if types.contains(.fileURL) {
      // 可选参数里的三目只有第一个分支抽得进目录（第 8b 批实测）：先放进不是可选的 let
      let hint: LocalizedStringResource =
        FileMoves.hasCut ? "剪切的：右键空白处「粘贴」，或者按 ⌥⌘V" : "在访达里按 ⌘V 就能粘贴"
      island?.show("剪贴板里是文件", detail: hint, tone: .info)
      return
    }
    // 图和文字都有时按来源 App 给的顺序取（它把哪个放前面就是哪个）
    let image = types.firstIndex { $0 == .png || $0 == .tiff }
    let text = types.firstIndex(of: .string)
    if let text, image.map({ text < $0 }) ?? true,
      let string = board.string(forType: .string), !string.isEmpty
    {
      place(clipboardText, in: folder, island: island) {
        try Data(string.utf8).write(to: $0, options: .withoutOverwriting)
      }
      return
    }
    if let png = board.data(forType: .png) {
      place(clipboardImage, in: folder, island: island) {
        try png.write(to: $0, options: .withoutOverwriting)
      }
      return
    }
    if let tiff = board.data(forType: .tiff) {
      Task {
        guard let png = await pngData(from: tiff) else {
          island?.show("没能新建", detail: "剪贴板里的图转不成 PNG", tone: .error)
          return
        }
        place(clipboardImage, in: folder, island: island) {
          try png.write(to: $0, options: .withoutOverwriting)
        }
      }
      return
    }
    if let text = board.string(forType: .string), !text.isEmpty {
      place(clipboardText, in: folder, island: island) {
        try Data(text.utf8).write(to: $0, options: .withoutOverwriting)
      }
      return
    }
    island?.show("剪贴板里没有文字或图片", detail: "先拷贝一段文字或一张图", tone: .warning)
  }

  /// 「从剪贴板新建」建出来的文件名（跟界面语言）
  private static var clipboardText: String { String(localized: "剪贴板文字") + ".txt" }
  private static var clipboardImage: String { String(localized: "剪贴板图片") + ".png" }

  /// 图转成 PNG（ImageIO，主线程外：mac-native §3 第 1 类）；带着原图的 DPI、方向这些（不然高分屏截图在预览里大一倍）
  @concurrent nonisolated static func pngData(from data: Data) async -> Data? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetCount(source) > 0
    else { return nil }
    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        output, UTType.png.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImageFromSource(destination, source, 0, nil)
    return CGImageDestinationFinalize(destination) ? output as Data : nil
  }

  /// 打开模板文件夹（没有就建）
  @MainActor static func showTemplates() {
    let folder = templatesFolder()
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    NSWorkspace.shared.open(folder)
  }

  // MARK: 自定义后缀

  /// 弹框问后缀（FinderLink.ask），在 folder 里建一个空文件
  @MainActor static func askSuffix(in folder: URL, island: Island? = nil) {
    let field = NSTextField(
      string: UserDefaults.standard.string(forKey: Prefs.finderLastSuffix) ?? "")
    field.placeholderString = String(localized: "比如 json、yaml、tar.gz")
    field.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
    let remember = NSButton(
      checkboxWithTitle: String(localized: "以后列在「新建文件」里"), target: nil, action: nil)
    remember.state = .on
    let stack = NSStackView(views: [field, remember])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.frame = NSRect(x: 0, y: 0, width: 260, height: 52)

    let alert = NSAlert()
    alert.messageText = String(localized: "新建文件的后缀")
    alert.informativeText = String(localized: "在「\(folder.lastPathComponent)」里建一个这种后缀的空文件。")
    alert.addButton(withTitle: String(localized: "新建"))
    // Esc = 取消
    alert.addButton(withTitle: String(localized: "取消")).keyEquivalent = "\u{1b}"
    alert.accessoryView = stack
    guard FinderLink.ask(alert, focus: field) == .alertFirstButtonReturn else { return }
    guard let suffix = cleanSuffix(field.stringValue) else {
      island?.show("后缀不对", detail: "不能有 / 和 :，比如 json、tar.gz", tone: .warning)
      return
    }
    UserDefaults.standard.set(suffix, forKey: Prefs.finderLastSuffix)
    let name = customName(suffix: suffix)
    guard
      place(
        name, in: folder, island: island,
        write: { try Data().write(to: $0, options: .withoutOverwriting) })
        != nil
    else { return }
    if remember.state == .on { addTemplate(name, suffix: suffix) }
  }

  /// 模板文件夹里放一个同名的空文件（已经有这个后缀的、含自带的，就不放）
  @MainActor private static func addTemplate(_ name: String, suffix: String) {
    let folder = templatesFolder()
    let mine =
      (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)))
      ?? []
    guard !hasTemplate(suffix: suffix, among: builtIn.map(fileName(of:)) + mine) else { return }
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try? Data().write(to: folder.appending(path: name), options: .withoutOverwriting)
  }
}
