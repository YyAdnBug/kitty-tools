import AppKit
import Carbon.HIToolbox
import SwiftUI
import Testing
import UniformTypeIdentifiers

@testable import KittyTools

// 界面截图自检（按需启用）：在屏幕外、不激活的窗口里渲染各种状态，写成 PNG 供人 / agent 检查。
// 不会弹出面板、不抢键盘，也不需要屏幕录制权限。用法：
//   TEST_RUNNER_KITTY_SNAPSHOT_DIR=/tmp/shots xcodebuild -project macos/KittyTools.xcodeproj \
//     -scheme KittyTools test -only-testing:KittyToolsTests/SnapshotProbeTests
// 只改了一族界面时不用等整套（renderPanels 一个函数要七八分钟）：再加
//   TEST_RUNNER_KITTY_SNAPSHOT_ONLY=clip-,launcher-
// 只出文件名以这些前缀开头的图（逗号分隔；别的图跳过渲染，各种摆设照做）。
struct SnapshotProbeTests {
  nonisolated private static let directory =
    ProcessInfo.processInfo.environment["KITTY_SNAPSHOT_DIR"]
  /// 只出这些前缀的图；nil = 全出
  nonisolated private static let only =
    ProcessInfo.processInfo.environment["KITTY_SNAPSHOT_ONLY"]?.split(separator: ",").map(
      String.init)

  /// 这张图出不出（按文件名的前缀）
  nonisolated private static func wants(_ path: String) -> Bool {
    guard let only else { return true }
    let name = URL(filePath: path).lastPathComponent
    return only.contains { name.hasPrefix($0) }
  }

  @Test(.enabled(if: directory != nil)) func renderPanels() async throws {
    let out = try #require(Self.directory)
    try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    Prefs.registerDefaults()
    // 不读本机浏览器（体检 D6 D8、第 12 批）：网站图标用下面摆的假图，启动器的浏览历史用注入的；设置 › 启动器
    // 「浏览器书签与历史」读临时目录里的假数据，「装了」的固定是 Safari、Chrome、Edge、Arc、Firefox
    let savedLocate = Browsers.locate
    let fakeHome = try Self.fakeBrowserHome()
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: fakeHome.appending(path: "Library/Safari").path)
      try? FileManager.default.removeItem(at: fakeHome)
      Browsers.home = URL.homeDirectory
      Browsers.locate = savedLocate
      BrowserHistory.shared.sources = { BrowserHistory.enabledSources() }
    }
    Browsers.home = fakeHome
    Browsers.locate = { browser in
      [
        // Safari 在 /Applications 里是个链接，LaunchServices 给的是它指向的真位置（链接的图标带角标）
        "safari": ("/Applications/Safari.app" as NSString).resolvingSymlinksInPath,
        "chrome": "/Applications/Google Chrome.app",
        "edge": "/Applications/Microsoft Edge.app", "arc": "/Applications/Arc.app",
        "firefox": "/Applications/Firefox.app",
      ][browser.id].map { URL(filePath: $0) }
    }
    SiteIcons.shared.roots = { [] }
    // 翻译服务的官网图标（第 13 批）：不联网、不碰真的缓存目录；要显示的图在设置 › 翻译那一组里直接摆假图
    ServiceIcons.shared.directory = FileManager.default.temporaryDirectory.appending(
      path: UUID().uuidString)
    ServiceIcons.shared.fetch = { _ in nil }
    let (safari, chrome, firefox) = try (
      #require(Browsers.all.first { $0.id == "safari" }),
      #require(Browsers.all.first { $0.id == "chrome" }),
      #require(Browsers.all.first { $0.id == "firefox" })
    )
    BrowserHistory.shared.sources = {
      [
        .init(browser: safari, kind: .history), .init(browser: chrome, kind: .history),
        .init(browser: firefox, kind: .firefoxBookmarks),
      ]
    }
    // Safari 先当没授权（数据目录读不了）：书签、历史都是「需要完全磁盘访问权限」
    try FileManager.default.setAttributes(
      [.posixPermissions: 0], ofItemAtPath: fakeHome.appending(path: "Library/Safari").path)
    await BrowserHistory.shared.refresh()
    for (host, letter, color) in [
      ("linux.do", "L", NSColor.systemYellow), ("github.com", "G", .black),
      ("www.google.com", "G", .systemBlue), ("www.bing.com", "b", .systemTeal),
      ("scholar.google.com", "S", .systemBlue), ("developer.apple.com", "A", .darkGray),
      ("developer.mozilla.org", "M", .black),
    ] {
      SiteIcons.shared.remember(Self.fakeFavicon(letter, color), for: host)
    }
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = try ClipboardStore(
      db: Database(path: ":memory:"), images: ImageStore(directory: dir))
    let samples: [(String, Double, String, String)] = [
      ("昨天复制的一段比较长的中文文本，用来看看单行截断在面板里的效果到底怎么样", 100000, "备忘录", "com.apple.Notes"),
      ("会议纪要：周五发布 0.1.0 预发布版，负责人 yy", 90000, "飞书", "com.electron.lark"),
      (
        "import SwiftUI\nstruct A: View {\n  var body: some View { Text(\"hi\") }\n}", 3600,
        "Xcode", "com.apple.dt.Xcode"
      ),
      ("https://developer.apple.com/documentation/appkit", 200, "Safari", "com.apple.Safari"),
      ("https://sspai.com/post/73145", 250, "微信", "com.tencent.xinWeChat"),
      (
        "{\"name\": \"kitty\", \"tags\": [1, 2], \"nested\": {\"ok\": true}}", 120, "访达",
        "com.apple.finder"
      ),
      ("#3478F6", 60, "Safari", "com.apple.Safari"),
      (
        "透镜指令条的设计说明：单列、贴在屏幕上方的键盘指令条。\n选中哪条，哪条就在原地展开成预览，"
          + "范围和筛选变成搜索框里的粉色标签。\nTab 选筛选，→ 打开动作，⌫ 删标签。视线只沿一条竖线走，"
          + "手不用离开键盘。高度按类型定死，上下键永远不改窗口高度。", 7200, "备忘录", "com.apple.Notes"
      ),
    ]
    for (text, ago, name, bundle) in samples {
      var item = ClipItem(
        kind: .text, sourceName: name, sourceBundleID: bundle,
        copiedAt: Date.now.addingTimeInterval(-ago))
      item.text = text
      store.record(item)
    }
    var file = ClipItem(
      kind: .file, sourceName: "访达", sourceBundleID: "com.apple.finder",
      copiedAt: Date.now.addingTimeInterval(-30))
    file.filePaths = ["/Applications/Safari.app", "/System/Library/CoreServices/Finder.app"]
    store.record(file)
    var notes = ClipItem(
      kind: .file, sourceName: "访达", sourceBundleID: "com.apple.finder",
      copiedAt: Date.now.addingTimeInterval(-35))
    notes.filePaths = ["/System/Applications/Notes.app"]
    store.record(notes)
    // 图片：真的写一张 PNG 进图片目录（缩略图异步读它），带识别文字
    let picture = try ScreenshotTests.render(["Lens Bar", "透镜指令条"])
    let png = try #require(
      NSBitmapImageRep(cgImage: picture).representation(using: .png, properties: [:]))
    var image = ClipItem(
      kind: .image, sourceName: "微信", sourceBundleID: "com.tencent.xinWeChat",
      copiedAt: Date.now.addingTimeInterval(-45))
    try png.write(to: store.images.url(for: image.id))
    image.image = .init(
      width: picture.width, height: picture.height, byteCount: png.count, sha256: "snapshot")
    image.ocrText = "Lens Bar\n透镜指令条\n选中哪条哪条就在原地展开"
    store.record(image)
    var snippet = ClipItem(kind: .text, copiedAt: Date.now.addingTimeInterval(-5000))
    snippet.text = "您好 {cursor}，\n附件是本周的周报，请查收。"
    snippet.isSnippet = true
    snippet.note = "邮件开头"
    store.record(snippet)
    // 屏外渲染时 .task 来不及跑：先把行图标、透镜、放大卡要用的缩略图放进缓存
    for maxPixel in [72, 720, 2400] {
      _ = await ThumbnailView.load(image.id, images: store.images, maxPixel: maxPixel)
    }
    let link = try #require(store.items.first { $0.text?.hasPrefix("https://developer") == true })
    store.toggleFavorite([link.id])
    store.update([link.id]) { $0.note = "AppKit 文档" }
    let group = try #require(store.createGroup(named: "工作"))
    store.createGroup(named: "读书笔记")
    store.createGroup(named: String(repeating: "长", count: ClipGroup.maxName))
    let meeting = try #require(store.items.first { $0.text?.hasPrefix("会议") == true })
    store.assign([meeting.id], to: group.id)
    // 普通条目也能写备注（体检 A3），行右侧显示备注
    let code = try #require(store.items.first { $0.text?.hasPrefix("import") == true })
    store.update([code.id]) { $0.note = "SwiftUI 示例" }
    let model = ClipboardPanelModel(store: store)
    // 链接预览：摆好取到的样子（不联网），另一条停在「正在取」
    var preview = LinkPreview.Entry()
    preview.metadata = LinkMetadata(
      title: "AppKit | Apple Developer Documentation", siteName: "Apple Developer")
    preview.image = NSImage(
      cgImage: try ScreenshotTests.render(["AppKit", "NSWindow · NSView"]), size: .zero)
    preview.icon = NSImage(systemSymbolName: "apple.logo", accessibilityDescription: nil)
    preview.tint = .systemGray
    preview.isLoading = false
    LinkPreview.shared.store(preview, for: try #require(URL(string: link.text ?? "")))
    LinkPreview.shared.store(
      LinkPreview.Entry(), for: try #require(URL(string: "https://sspai.com/post/73145")))
    func pick(_ m: ClipboardPanelModel, _ match: (ClipItem) -> Bool) {
      if let item = m.visibleItems.first(where: match) { m.select(item) }
    }
    // 透镜指令条（Lens Bar）：各类型的透镜、命中摘录、标签 + 筛选面板、标签待删、⌘K、多选、片段范围、对话框、空结果
    let states: [(String, (ClipboardPanelModel) -> Void)] = [
      ("list", { _ in }),
      ("lens-text", { m in pick(m) { $0.text?.hasPrefix("透镜") == true } }),
      (
        "lens-short",
        { m in
          m.sourceBundleID = "com.apple.Notes"
          pick(m) { $0.text?.hasPrefix("昨天") == true }
        }
      ),
      ("lens-code", { m in m.form = .code }),
      ("lens-json", { m in m.form = .json }),
      ("lens-color", { m in pick(m) { $0.text == "#3478F6" } }),
      ("lens-link", { m in m.scope = .favorites }),
      ("lens-link-loading", { m in pick(m) { $0.text?.hasPrefix("https://sspai") == true } }),
      ("lens-image", { m in pick(m) { $0.kind == .image } }),
      ("lens-file", { m in pick(m) { $0.kind == .file } }),
      ("search", { m in m.query = "上下键" }),
      ("search-code", { m in m.query = "swift" }),
      ("search-ocr", { m in m.query = "原地" }),
      (
        "tokens-filters",
        { m in
          m.scope = .favorites
          m.sourceBundleID = "com.apple.Safari"
          m.palette = .filters
        }
      ),
      (
        "token-armed",
        { m in
          m.kind = .text
          m.form = .code
          m.armsLastToken = true
        }
      ),
      ("actions", { m in m.showsActions = true }),
      (
        "actions-groups",
        { m in
          m.showsActions = true
          m.actionQuery = "收藏夹"
        }
      ),
      // ⌘K 分节 + 「移到收藏夹 ›」子列表（体检 C3）、按类型的动作（D1 D2）、拼音过滤（C4）
      (
        "actions-submenu",
        { m in
          m.showsActions = true
          if let groups = m.actions.first(where: { $0.id == "groups" }) { m.run(groups) }
        }
      ),
      (
        "actions-file",
        { m in
          pick(m) { $0.kind == .file }
          m.showsActions = true
        }
      ),
      (
        "actions-image",
        { m in
          pick(m) { $0.kind == .image }
          m.showsActions = true
        }
      ),
      (
        "actions-pinyin",
        { m in
          m.showsActions = true
          m.actionQuery = "fy"
        }
      ),
      ("multi", { m in m.multiSelection = Set(m.visibleItems.prefix(3).map(\.id)) }),
      // 多选底栏「收藏夹…」：同一份收藏夹列表，锚在按钮上方（体检 C3）
      (
        "multi-groups",
        { m in
          m.multiSelection = Set(m.visibleItems.prefix(3).map(\.id))
          m.palette = .groups
        }
      ),
      // 全是文件：「一起粘贴」（体检 B3）
      (
        "multi-files",
        { m in m.multiSelection = Set(m.visibleItems.filter { $0.kind == .file }.map(\.id)) }
      ),
      // 管理收藏夹（体检 A1）：键盘列表 + 新建框；删掉一个后底栏「撤销 ⌘Z」在对话框下面也能点
      ("manage-groups", { m in m.dialog = .manageGroups }),
      (
        "manage-groups-deleted",
        { m in
          m.dialog = .manageGroups
          m.toast = .undo("已删除收藏夹「旅行」")
        }
      ),
      // 取消收藏后已超过保留天数（体检 A1）
      ("toast-expiring", { m in m.toast = .undo("超过 7 天，收起面板后会被清理") }),
      // 菜单栏暂停了记录（D4）
      ("paused", { m in m.isRecordingPaused = true }),
      ("snippets", { m in m.scope = .snippets }),
      ("dialog", { m in m.dialog = .note(link.id) }),
      // 编辑（没改动时「保存」置灰、不带格式的不提丢格式）、新建片段（顶上可选的名称，体检 C2）
      ("dialog-edit", { m in m.dialog = .edit(code.id) }),
      ("dialog-new-snippet", { m in m.dialog = .newSnippet }),
      ("dialog-new-group", { m in m.dialog = .newGroup([link.id]) }),
      // ⌘P / 底栏图钉：底栏就地提示（体检 A9）
      ("toast-pinned", { m in m.toast = .message("已固定") }),
      // 含图片的多选 ⌘C 只写了第 1 条：警告，不带绿色对勾（体检 B3）
      ("toast-partial", { m in m.toast = .warning("只复制了第 1 条") }),
      ("empty-search", { m in m.query = "zzzz" }),
      (
        "snippets-empty-search",
        { m in
          m.scope = .snippets
          m.query = "zzzz"
        }
      ),
    ]
    for dark in [false, true] {
      for (name, configure) in states {
        model.reset()
        model.isRecordingPaused = false  // 不归 reset 管（App 级的开关）
        configure(model)
        try snapshot(
          ClipboardPanelView(model: model),
          size: NSSize(
            width: ClipboardPanelView.width, height: ClipboardPanelView.height(for: model)),
          dark: dark, to: "\(out)/clip-\(name)\(dark ? "-dark" : "").png")
      }
      // 滚到底：面板画出来以后再选中最后一条（选中变了才滚，见 RevealsSelection），等滚完再出图——顶上是吸顶的分组标题
      // （材质底），透镜那一行就在高亮上（2026-10-03 列表改成只画可见区附近、吸顶标题自己画）
      model.reset()
      model.isRecordingPaused = false
      try snapshot(
        ClipboardPanelView(model: model),
        size: NSSize(
          width: ClipboardPanelView.width, height: ClipboardPanelView.height(for: model)),
        dark: dark, to: "\(out)/clip-list-scrolled\(dark ? "-dark" : "").png"
      ) { _ in
        model.visibleItems.last.map(model.select)
        RunLoop.main.run(until: .now.addingTimeInterval(0.8))
      }
      // ⌘K 选到最后的「删除」（2026-10-07）：菜单画出来以后再选（选中变了才滚），整行滚进来（以前只滚出它上面的
      // 分节线），图标和字是危险色
      model.reset()
      model.isRecordingPaused = false
      model.showsActions = true
      try snapshot(
        ClipboardPanelView(model: model),
        size: NSSize(
          width: ClipboardPanelView.width, height: ClipboardPanelView.height(for: model)),
        dark: dark, to: "\(out)/clip-actions-delete\(dark ? "-dark" : "").png"
      ) { _ in
        model.actionSelection = model.filteredActions.count - 1
        RunLoop.main.run(until: .now.addingTimeInterval(0.3))
      }
      // 有新版本（2026-10-06）：底栏条数后面常驻「更新到 x」
      model.reset()
      model.isRecordingPaused = false
      try snapshot(
        ClipboardPanelView(model: model).environment(try Self.pendingUpdate()),
        size: NSSize(
          width: ClipboardPanelView.width, height: ClipboardPanelView.height(for: model)),
        dark: dark, to: "\(out)/clip-update\(dark ? "-dark" : "").png")
    }
    // 一行文本的透镜：行标题已经原样显示全的不画第二遍、只剩元信息行（很短的富文本；有搜索词时标题也不摘录、
    // 照样从头显示）；标题列放不下的一行字（≤ 60 字）还是给两行高的正文（上面的 lens-short 是正文只有一行的）。
    // 另起一个小库，不动上面那批图
    let lineStore = try ClipboardStore(
      db: Database(path: ":memory:"), images: ImageStore(directory: dir))
    let lines: [(String, Double, ClipItem.RichType?)] = [
      ("大合唱练歌", 300, .html),
      ("macos/build/Kitty Tools_0.3.0_arm64.dmg", 200, nil),
      (
        "一行字但是标题列放不下：行标题会在末尾截断，所以透镜里还是要把整句话完整地再显示一遍，这样才看得到后半句，最多两行",
        100, nil
      ),
    ]
    for (text, ago, rich) in lines {
      var item = ClipItem(
        kind: .text, sourceName: "Google Chrome", sourceBundleID: "com.google.Chrome",
        copiedAt: Date.now.addingTimeInterval(-ago))
      item.text = text
      item.richType = rich
      lineStore.record(item)
    }
    let lineModel = ClipboardPanelModel(store: lineStore)
    let lineStates: [(String, (ClipboardPanelModel) -> Void)] = [
      ("lens-wrapped", { _ in }),
      ("lens-whole", { m in pick(m) { $0.text == "大合唱练歌" } }),
      ("lens-whole-search", { m in m.query = "arm64" }),
    ]
    for dark in [false, true] {
      for (name, configure) in lineStates {
        lineModel.reset()
        configure(lineModel)
        try snapshot(
          ClipboardPanelView(model: lineModel),
          size: NSSize(
            width: ClipboardPanelView.width, height: ClipboardPanelView.height(for: lineModel)),
          dark: dark, to: "\(out)/clip-\(name)\(dark ? "-dark" : "").png")
      }
    }
    // 关掉透镜 = 纯列表（设置 › 剪贴板「显示透镜」）：在临时偏好域里关掉，不碰用户自己的设置
    let lensSuite = "kitty-snapshot-\(UUID().uuidString)"
    let noLens = try #require(UserDefaults(suiteName: lensSuite))
    defer { noLens.removePersistentDomain(forName: lensSuite) }
    noLens.set(false, forKey: Prefs.clipboardShowPreview)
    model.reset()
    try snapshot(
      ClipboardPanelView(model: model).defaultAppStorage(noLens),
      size: NSSize(
        width: ClipboardPanelView.width,
        height: ClipboardPanelView.height(for: model, showsLens: false)),
      dark: false, to: "\(out)/clip-no-lens.png")
    // 增强对比度（体检 B53）：发丝线 1 pt（分组标题线、底栏顶线、竖线、透镜里的描边），深浅色各一张
    for dark in [false, true] {
      model.reset()
      pick(model) { $0.kind == .image }
      try snapshot(
        ClipboardPanelView(model: model).environment(\._colorSchemeContrast, .increased),
        size: NSSize(
          width: ClipboardPanelView.width, height: ClipboardPanelView.height(for: model)),
        dark: dark, to: "\(out)/clip-contrast\(dark ? "-dark" : "").png")
    }
    // 换了强调色（设置 › 通用）：黄色最难（填充上的符号换深色、文字压深），石墨色看中性；
    // 只换内存里的颜色（persists: false），不写用户的偏好，试完换回原来的
    let savedAccent = Accent.shared.choice
    defer { Accent.shared.select(savedAccent, persists: false) }
    // 通用页同时摆成外观选了「深色」：最右那张缩略图的强调色描边（临时偏好域，不动用户的外观）
    let looksSuite = "kitty-snapshot-\(UUID().uuidString)"
    let looks = try #require(UserDefaults(suiteName: looksSuite))
    defer { looks.removePersistentDomain(forName: looksSuite) }
    looks.set(AppAppearance.dark.rawValue, forKey: Prefs.appearance)
    for choice in [AccentChoice.yellow, .graphite] {
      Accent.shared.select(choice, persists: false)
      for dark in [false, true] {
        model.reset()
        model.scope = .favorites
        model.palette = .filters
        try snapshot(
          ClipboardPanelView(model: model),
          size: NSSize(
            width: ClipboardPanelView.width, height: ClipboardPanelView.height(for: model)),
          dark: dark, to: "\(out)/clip-accent-\(choice.rawValue)\(dark ? "-dark" : "").png")
        try snapshot(
          GeneralTab().defaultAppStorage(looks), size: NSSize(width: 640, height: 560), dark: dark,
          to: "\(out)/settings-general-accent-\(choice.rawValue)\(dark ? "-dark" : "").png")
        // 主按钮的文字色（体检 B54）：关于页「更新并重新打开」、引导「开始使用」、速查表「完成」在亮强调色上要看得清
        let suffix = "\(choice.rawValue)\(dark ? "-dark" : "")"
        let available = Updater(
          state: .available(
            .init(
              version: "0.2.0", archive: URL(string: "https://example.com/Kitty.zip")!,
              page: Updater.releasesPage)))
        try snapshot(
          AboutTab(updater: available), size: NSSize(width: 590, height: 330), dark: dark,
          to: "\(out)/about-update-accent-\(suffix).png")
        try snapshot(
          OnboardingView(center: HotKeyCenter(), firstRun: true, screen: .tryIt),
          size: OnboardingView.size, dark: dark,
          to: "\(out)/onboarding-try-accent-\(suffix).png")
        try snapshot(
          ShortcutsSheet(), size: NSSize(width: ShortcutsSheet.width, height: 400), dark: dark,
          to: "\(out)/shortcuts-accent-\(suffix).png")
      }
    }
    Accent.shared.select(savedAccent, persists: false)
    // ⌘Y 放大预览 = 完整检查器：代码（放大的字）、链接（大头图）、图片（带识别文字）、多个文件（网格）、JSON（默认美化）、
    // 颜色（大色块 + 四行色值），按各自的理想尺寸；页脚第 3 个胶囊按类型（打开 / 钉到屏幕 / 在访达中显示 / 原文，体检 D2）
    let quickLooks: [(String, (ClipItem) -> Bool)] = [
      ("quicklook-code", { $0.text?.hasPrefix("import") == true }),
      ("quicklook-json", { $0.text?.hasPrefix("{\"name") == true }),
      ("quicklook-link", { $0.text?.hasPrefix("https://developer") == true }),
      ("quicklook-image", { $0.kind == .image }),
      ("quicklook-files", { $0.kind == .file }),
      ("quicklook-color", { $0.text == "#3478F6" }),
    ]
    for (name, match) in quickLooks {
      model.reset()
      let item = try #require(model.visibleItems.first { match($0) })
      model.select(item)
      model.showsQuickLookContent = true
      let size = QuickLookView.idealSize(for: item, form: model.contentForm(of: item))
      for dark in [false, true] {
        try snapshot(
          QuickLookView(model: model) { _ in }, size: size, dark: dark,
          to: "\(out)/\(name)\(dark ? "-dark" : "").png")
      }
    }
    // 屏幕放不下原尺寸的竖图（像手机截图）：窗口按图片的比例缩，到了最小宽度后图片比图片区窄，在里面居中
    // （原来跟着宽×高胶囊贴在右上角）。另起一个小库，不动上面那批图
    let tallStore = try ClipboardStore(
      db: Database(path: ":memory:"), images: ImageStore(directory: dir))
    let tallPicture = try ScreenshotTests.render([
      "祝福祖国", "满天星辰缅怀版", "", "前奏 · 还有 18 秒", "都说你的花朵真红火", "都说你的果实真丰硕",
      "都说你的土地真肥沃", "都说你的道路真宽阔", "祖国我的祖国", "", "0:03 ———— 3:18", "⏮  ⏸  ⏭",
    ])
    let tallPNG = try #require(
      NSBitmapImageRep(cgImage: tallPicture).representation(using: .png, properties: [:]))
    var tall = ClipItem(kind: .image, sourceName: "微信", sourceBundleID: "com.tencent.xinWeChat")
    try tallPNG.write(to: tallStore.images.url(for: tall.id))
    tall.image = .init(
      width: tallPicture.width, height: tallPicture.height, byteCount: tallPNG.count,
      sha256: "snapshot-tall")
    tall.ocrText = "祝福祖国\n满天星辰缅怀版\n前奏 · 还有 18 秒"
    tallStore.record(tall)
    _ = await ThumbnailView.load(tall.id, images: tallStore.images, maxPixel: 2400)
    let tallModel = ClipboardPanelModel(store: tallStore)
    tallModel.select(tall)
    tallModel.showsQuickLookContent = true
    let tallSize = QuickLookView.idealSize(
      for: tall, form: nil, within: NSSize(width: 1360, height: 700))
    for dark in [false, true] {
      try snapshot(
        QuickLookView(model: tallModel) { _ in }, size: tallSize, dark: dark,
        to: "\(out)/quicklook-image-fit\(dark ? "-dark" : "").png")
    }
    // 拖出去时指针下的预览（体检 D3）：这一行画在窗口底色的卡上（深浅按 App 外观，这里两种都画）
    let dragged: [(String, ClipItem?)] = [
      ("drag-preview-link", store.items.first { $0.text?.hasPrefix("https://developer") == true }),
      ("drag-preview-image", store.items.first { $0.kind == .image }),
    ]
    for (name, found) in dragged {
      let item = try #require(found)
      for dark in [false, true] {
        let image = try #require(
          ClipDrag.preview(
            item, form: model.contentForm(of: item), images: store.images,
            colorScheme: dark ? .dark : .light))
        let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        try #require(bitmap.representation(using: .png, properties: [:]))
          .write(to: URL(filePath: "\(out)/clip-\(name)\(dark ? "-dark" : "").png"))
      }
    }
    try renderTranslate(out)
    // 设置窗：侧栏 + 页头 + 各页表单（关于是品牌页），深色看几页；欢迎引导的每一步
    let hotKeys = HotKeyCenter()
    hotKeys.failures[.launcher] = OSStatus(eventInternalErr)  // 快捷键页 / 引导里的橙字（不真注册）
    // 读用户的服务列表来画，但传进去的一份不写回偏好（画的时候输入框会把绑定写一遍）
    let services = TranslateServiceStore(services: TranslateServiceStore().services)
    let history = try HistoryStore(db: Database(path: ":memory:"))
    let speaker = Speaker()
    let pages: (SettingsPage) -> AnyView = { page in
      switch page {
      case .general:
        AnyView(
          GeneralTab(
            transfer: SettingsTransfer(services: services, clipboard: store, history: history)))
      case .clipboard: AnyView(ClipboardTab(store: store))
      case .launcher: AnyView(LauncherTab())
      case .launchpad: AnyView(LaunchpadTab())
      case .screenshot: AnyView(ScreenshotTab(shots: nil))
      case .record: AnyView(RecordTab())
      case .notes: AnyView(NotesTab {})
      // 自带的三个状态（固定的列表：不读用户改过的那份）
      case .statusScreen: AnyView(StatusScreenTab(fixed: StatusPreset.builtIn))
      // 私有接口在不在按固定的「都在」画（图不跟着机器变）
      case .dockPreview: AnyView(DockPreviewTab(missing: []))
      case .translate:
        AnyView(TranslateTab(services: services, history: history, speaker: speaker))
      case .hotkeys: AnyView(HotkeysTab(center: hotKeys))
      case .about: AnyView(AboutTab(updater: Updater()))
      }
    }
    let navigation = SettingsNavigation(defaults: nil)  // 换页不写用户的偏好
    for (page, dark) in SettingsPage.allCases.map({ ($0, false) }) + [
      (.general, true), (.about, true), (.clipboard, true), (.hotkeys, true),
    ] {
      navigation.page = page
      try snapshot(
        SettingsRoot(navigation: navigation, page: pages) { AnyView(EmptyView()) },
        size: NSSize(width: 780, height: 600), dark: dark,
        to: "\(out)/settings-\(page.rawValue)\(dark ? "-dark" : "").png")
    }
    // 关于页的应用内更新：有新版本（强调色按钮）、正在更新（还不知道下了多少 / 下载到 42% / 下完在装）、已是最新、检查失败
    let release = Updater.Release(
      version: "0.2.0", archive: URL(string: "https://example.com/Kitty.zip")!,
      page: Updater.releasesPage)
    let updateStates: [(String, Updater.State, Bool, Double?)] = [
      ("available", .available(release), false, nil),
      ("available", .available(release), true, nil),
      ("installing", .installing(release), false, nil),
      ("downloading", .installing(release), false, 0.42),
      ("downloading", .installing(release), true, 0.42),
      ("downloaded", .installing(release), false, 1), ("latest", .upToDate, false, nil),
      ("failed", .failed("检查更新失败：网络连接已中断。"), false, nil),
    ]
    navigation.page = .about
    for (name, state, dark, progress) in updateStates {
      let updater = Updater(state: state, progress: progress)
      try snapshot(
        SettingsRoot(navigation: navigation) { page in
          page == .about ? AnyView(AboutTab(updater: updater)) : pages(page)
        } onboarding: {
          AnyView(EmptyView())
        },
        size: NSSize(width: 780, height: 600), dark: dark,
        to: "\(out)/settings-about-update-\(name)\(dark ? "-dark" : "").png")
    }
    // 设置 › 截图选过文件夹（体检 A28）：文件夹图标 + 访达里的名字 +「恢复默认」；常驻缩略图关着（D18）。
    // 设置 › 录制（2026-10-03 从截图页拆出来）同一份偏好：「保存到」也是那个文件夹；录屏组（录屏第 2 批）60 fps、倒数 5 秒、
    // 不显示光标；录音组（录音第 6 批）来源「两者」、「按快捷键后立即开始录音」开着（手测反馈第 3 批；默认的样子在下面
    // -default 那两张）。临时偏好域和临时文件夹，不改用户的快速保存位置
    let shotSuite = "kitty-snapshot-\(UUID().uuidString)"
    let shotPrefs = try #require(UserDefaults(suiteName: shotSuite))
    let inbox = FileManager.default.temporaryDirectory.appending(path: "kitty-snapshot/截图收件箱")
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    defer {
      shotPrefs.removePersistentDomain(forName: shotSuite)
      try? FileManager.default.removeItem(at: inbox.deletingLastPathComponent())
    }
    shotPrefs.set(inbox.path, forKey: Prefs.screenshotSaveDirectory)
    shotPrefs.set(false, forKey: Prefs.screenshotShelf)
    shotPrefs.set(60, forKey: Prefs.screenRecordFrameRate)
    shotPrefs.set(5, forKey: Prefs.screenRecordCountdown)
    shotPrefs.set(false, forKey: Prefs.screenRecordShowsCursor)
    shotPrefs.set(AudioRecorder.Source.both.rawValue, forKey: Prefs.audioRecordSource)
    shotPrefs.set(true, forKey: Prefs.audioRecordStartsImmediately)
    for dark in [false, true] {
      try snapshot(
        ScreenshotTab(shots: nil).defaultAppStorage(shotPrefs),
        size: NSSize(width: 640, height: 720),
        dark: dark, to: "\(out)/settings-screenshot-custom\(dark ? "-dark" : "").png")
      try snapshot(
        RecordTab().defaultAppStorage(shotPrefs), size: NSSize(width: 640, height: 860),
        dark: dark, to: "\(out)/settings-record-custom\(dark ? "-dark" : "").png")
    }
    // 录制页的默认样子：没选过文件夹、30 fps、倒数 3 秒，录音来源麦克风、「按快捷键后立即开始录音」关。空的临时偏好域
    let recordSuite = "kitty-snapshot-\(UUID().uuidString)"
    let recordPrefs = try #require(UserDefaults(suiteName: recordSuite))
    defer { recordPrefs.removePersistentDomain(forName: recordSuite) }
    for dark in [false, true] {
      try snapshot(
        RecordTab().defaultAppStorage(recordPrefs), size: NSSize(width: 640, height: 860),
        dark: dark, to: "\(out)/settings-record-default\(dark ? "-dark" : "").png")
    }
    // 设置 › 通用「菜单栏」（第 9 批 M1 M2）：显示 + 彩色、隐藏（图标样式置灰），各出深色；临时偏好域，不动用户的菜单栏图标
    let barSuite = "kitty-snapshot-\(UUID().uuidString)"
    let barPrefs = try #require(UserDefaults(suiteName: barSuite))
    defer { barPrefs.removePersistentDomain(forName: barSuite) }
    barPrefs.set(StatusItem.IconStyle.color.rawValue, forKey: Prefs.statusItemStyle)
    for (name, visible) in [("shown", true), ("hidden", false)] {
      barPrefs.set(visible, forKey: Prefs.statusItemVisible)
      for dark in [false, true] {
        try snapshot(
          GeneralTab().defaultAppStorage(barPrefs), size: NSSize(width: 640, height: 720),
          dark: dark, to: "\(out)/settings-general-menubar-\(name)\(dark ? "-dark" : "").png")
      }
    }
    // 设置 › 通用拉长看到底的「权限」组（录屏第 4 批加了麦克风一行，状态是本机真实的授权）和最后的「导出与导入」；临时偏好域
    let permissionSuite = "kitty-snapshot-\(UUID().uuidString)"
    let permissionPrefs = try #require(UserDefaults(suiteName: permissionSuite))
    defer { permissionPrefs.removePersistentDomain(forName: permissionSuite) }
    for dark in [false, true] {
      try snapshot(
        GeneralTab(
          transfer: SettingsTransfer(services: services, clipboard: store, history: history)
        )
        .defaultAppStorage(permissionPrefs),
        size: NSSize(width: 640, height: 1200), dark: dark,
        to: "\(out)/settings-general-permissions\(dark ? "-dark" : "").png")
    }
    try renderTransfer(out)
    // 菜单栏上的两种图标（浅色 / 深色菜单栏各一张，右边放大 5 倍）；彩色图的 @2x 位图另存原图
    for dark in [false, true] {
      try snapshot(
        StatusIconProbe(), size: NSSize(width: 260, height: 124), dark: dark,
        to: "\(out)/status-icons\(dark ? "-dark" : "").png")
    }
    let colorRep = try #require(StatusItem.colorIcon.representations.last as? NSBitmapImageRep)
    try #require(colorRep.representation(using: .png, properties: [:]))
      .write(to: URL(filePath: "\(out)/status-icon-color@2x.png"))
    // 最小窗口（contentMinSize 700 × 460）下的通用页：外观缩略图、强调色两排放得下
    navigation.page = .general
    try snapshot(
      SettingsRoot(navigation: navigation, page: pages) { AnyView(EmptyView()) },
      size: NSSize(width: 700, height: 460), dark: false, to: "\(out)/settings-general-min.png")
    // 快捷键页拉长看到底（最后的速查表入口），「划词翻译」那一行摆成正在录制（只改外观，不装按键监听）
    navigation.page = .hotkeys
    hotKeys.recording = .selectionTranslate
    for dark in [false, true] {
      try snapshot(
        SettingsRoot(navigation: navigation, page: pages) { AnyView(EmptyView()) },
        size: NSSize(width: 780, height: 1000), dark: dark,
        to: "\(out)/settings-hotkeys-recording\(dark ? "-dark" : "").png")
    }
    hotKeys.recording = nil
    // 剪贴板页拉长看到底：保留普通历史一行、默认粘贴为纯文本、排除的 App 列表（图标 + 名字，体检 A4 A5 A11）
    navigation.page = .clipboard
    for dark in [false, true] {
      try snapshot(
        SettingsRoot(navigation: navigation, page: pages) { AnyView(EmptyView()) },
        size: NSSize(width: 780, height: 1500), dark: dark,
        to: "\(out)/settings-clipboard-full\(dark ? "-dark" : "").png")
    }
    // 侧栏选中是自绘的（SettingsWindow 文件头）：屏外窗口永远不是 key，上面那些都是后台的中性样子。这里用环境摆成
    // key，再把原生行强制成强调态（key 窗口里系统就这么标），看原生高亮确实没画、只剩自绘那块。
    // 跟随系统（本机「多色」= 品牌粉）和黄色（字换深色），深浅色各一张
    navigation.page = .clipboard
    for choice in [AccentChoice.system, .yellow] {
      Accent.shared.select(choice, persists: false)
      for dark in [false, true] {
        try snapshot(
          SettingsRoot(navigation: navigation, page: pages) { AnyView(EmptyView()) }
            .environment(\.controlActiveState, .key),
          size: NSSize(width: 780, height: 600), dark: dark,
          to: "\(out)/settings-sidebar-key-\(choice.rawValue)\(dark ? "-dark" : "").png",
          prepare: Self.emphasizeTableRows)
      }
    }
    Accent.shared.select(savedAccent, persists: false)
    // 设置 › 翻译 / 启动器的有序列表（N12）：整页拉长看到列表和「+ −」，外加一个详情页（不改用户的偏好和钥匙串）。
    // 网页搜索用临时的偏好域摆出各种状态：兜底、重复关键词（橙色）、网址 / 路径快捷链接、刚新建还没填的
    let suite = "kitty-snapshot-\(UUID().uuidString)"
    let engines = try #require(UserDefaults(suiteName: suite))
    defer { engines.removePersistentDomain(forName: suite) }
    engines.set(
      SearchEngineDetail.encode(
        WebSearch.defaults.prefix(3) + [
          SearchEngine(
            id: "scholar", name: "Google 学术", keyword: "g",
            urlTemplate: "https://scholar.google.com/scholar?q={query}", enabled: false),
          SearchEngine(
            id: "docs", name: "Apple 开发文档", keyword: "doc",
            urlTemplate: "https://developer.apple.com/documentation", enabled: false),
          SearchEngine(
            id: "downloads", name: "下载", keyword: "", urlTemplate: "~/Downloads", enabled: false),
          SearchEngine(id: "new", name: "", keyword: "", urlTemplate: "https://", enabled: false),
        ]), forKey: Prefs.launcherWebSearchEngines)
    for dark in [false, true] {
      let suffix = dark ? "-dark" : ""
      try snapshot(
        TranslateTab(services: services, history: history, speaker: speaker)
          .environment(navigation),
        size: NSSize(width: 590, height: 1720), dark: dark,
        to: "\(out)/settings-translate-list\(suffix).png")
      try snapshot(
        TranslateServiceDetail(store: services, id: TranslateService.Kind.deepl.rawValue),
        size: NSSize(width: 590, height: 460), dark: dark,
        to: "\(out)/settings-translate-detail\(suffix).png")
      try snapshot(
        LauncherTab().defaultAppStorage(engines).environment(navigation),
        size: NSSize(width: 590, height: 1400),
        dark: dark, to: "\(out)/settings-launcher-list\(suffix).png")
      try snapshot(
        SearchEngineDetail(id: "scholar").defaultAppStorage(engines),
        size: NSSize(width: 590, height: 400), dark: dark,
        to: "\(out)/settings-launcher-detail\(suffix).png")
    }
    // 设置 › 翻译服务的 logo（第 13 批）：DeepSeek 按地址认、Kimi 按名字认（内置 logo），OpenCode 和「公司网关」是
    // 自动取的官网图标（注入假图：满版带底色的裁圆角、透明底的垫白底留 14%），本机模型没有图标（色块首字母）；旁边是
    // 内置的智谱（满版）和 DeepL（垫白底）对照尺寸、圆角和留白
    ServiceIcons.shared.remember(Self.fakeSiteIcon("O", background: .black), for: "opencode.ai")
    ServiceIcons.shared.remember(Self.fakeSiteIcon("G", background: nil), for: "example.com")
    let aiService = { (name: String, baseURL: String, model: String) -> TranslateService in
      var service = TranslateService.newAI()
      service.name = name
      service.baseURL = baseURL
      service.model = model
      service.isEnabled = true
      return service
    }
    let logoServices = TranslateServiceStore(services: [
      .zhipu, TranslateService.builtin(.deepl),
      aiService("DeepSeek", "https://api.deepseek.com", "deepseek-chat"),
      aiService("Kimi（公司代理）", "https://llm.corp-proxy.cn/v1", "kimi-k2"),
      aiService("OpenCode", "https://opencode.ai/zen/go", "qwen3-coder"),
      aiService("公司网关", "https://llm.example.com/v1", "gpt-oss-120b"),
      aiService("本机模型", "http://127.0.0.1:8000/v1", "qwen3"),
    ])
    for dark in [false, true] {
      try snapshot(
        TranslateTab(services: logoServices, history: history, speaker: speaker)
          .environment(navigation),
        size: NSSize(width: 590, height: 1720), dark: dark,
        to: "\(out)/settings-translate-logos\(dark ? "-dark" : "").png")
    }
    // 设置 › 启动器「浏览器书签与历史」（第 12 批）：只列装了的五家；Safari 没授权（橙字 + 去授权 + 说明）、
    // Chrome 书签和历史都读到、Edge 关着、Arc 没有书签文件（橙字）、Firefox 书签读到（历史关着写它搜什么）。
    // 再给 Safari 授权（数据目录能读了）看「已读到 N 条」
    let browserSuite = "kitty-snapshot-\(UUID().uuidString)"
    let browserPrefs = try #require(UserDefaults(suiteName: browserSuite))
    defer { browserPrefs.removePersistentDomain(forName: browserSuite) }
    browserPrefs.set("safari\nchrome\narc\nfirefox", forKey: Prefs.launcherBrowserBookmarks)
    browserPrefs.set("safari\nchrome", forKey: Prefs.launcherBrowserHistory)
    for dark in [false, true] {
      try snapshot(
        LauncherTab().defaultAppStorage(browserPrefs).environment(navigation),
        size: NSSize(width: 590, height: 900), dark: dark,
        to: "\(out)/settings-launcher-browsers\(dark ? "-dark" : "").png")
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: fakeHome.appending(path: "Library/Safari").path)
    await BrowserHistory.shared.refresh()
    try snapshot(
      LauncherTab().defaultAppStorage(browserPrefs).environment(navigation),
      size: NSSize(width: 590, height: 900), dark: false,
      to: "\(out)/settings-launcher-browsers-granted.png")
    // 快捷键速查表（N11）：默认大小的设置窗里 sheet 的尺寸（停在第一类、深色）；左栏每一类各出一张拉长的看全，
    // 搜索中（跨类列出对上的行）、什么都没搜到各一张
    let sheetHeight = ShortcutsButton.sheetHeight(available: 600 - 52)
    let sheetSize = NSSize(width: ShortcutsSheet.width, height: sheetHeight)
    for (name, dark) in [("shortcuts", false), ("shortcuts-dark", true)] {
      try snapshot(ShortcutsSheet(), size: sheetSize, dark: dark, to: "\(out)/\(name).png")
    }
    for page in ShortcutsSheet.sections(ShortcutsSheet.groups) {
      try snapshot(
        ShortcutsSheet(page: page), size: NSSize(width: ShortcutsSheet.width, height: 2400),
        dark: false, to: "\(out)/shortcuts-\(page.rawValue).png")
    }
    for (name, query) in [("shortcuts-search", "删除"), ("shortcuts-search-empty", "没有这种键")] {
      try snapshot(
        ShortcutsSheet(query: query), size: sheetSize, dark: false, to: "\(out)/\(name).png")
    }
    // 增强对比度（体检 B53）：速查表、通用页的发丝线 1 pt
    try snapshot(
      ShortcutsSheet().environment(\._colorSchemeContrast, .increased),
      size: sheetSize, dark: false,
      to: "\(out)/shortcuts-contrast.png")
    try snapshot(
      GeneralTab().environment(\._colorSchemeContrast, .increased),
      size: NSSize(width: 640, height: 560), dark: true,
      to: "\(out)/settings-general-contrast-dark.png")
    // 欢迎引导（N14）：第一屏（全部功能）、第二屏「授权」、第三屏「按一下试试」（两行已按过），各出深色
    for (name, screen) in [
      ("welcome", OnboardingView.Screen.welcome), ("permissions", .permissions), ("try", .tryIt),
    ] {
      for dark in [false, true] {
        try snapshot(
          OnboardingView(
            center: hotKeys, firstRun: true, screen: screen, tried: [.clipboard, .screenshot]),
          size: OnboardingView.size, dark: dark,
          to: "\(out)/onboarding-\(name)\(dark ? "-dark" : "").png")
      }
    }
    try renderSelection(out)
    // 常驻缩略图：存过（文件夹角标）、悬停（拷贝 / 存储 + 四角圆钮）
    let shot = try ScreenshotTests.render(["The quick brown fox", "敏捷的棕色狐狸"])
    for (name, badge, hovered) in [
      ("shelf", FlyCard.Badge.saved(URL(filePath: "/Users/me/Desktop/a.png")), false),
      ("shelf-hover", .saved(URL(filePath: "/Users/me/Desktop/a.png")), true),
    ] {
      let card = ShelfCard(
        image: shot, scale: 2, source: CGRect(x: 0, y: 0, width: 600, height: 120),
        rect: CGRect(x: 0, y: 0, width: 200, height: 40 * 2), badge: badge, screen: nil,
        panel: NSPanel(), shelf: ShotShelf())
      card.isHovered = hovered
      try snapshot(
        ShelfCardView(card: card),
        size: NSSize(width: 200 + ShotShelf.margin * 2, height: 80 + ShotShelf.margin * 2),
        dark: false, to: "\(out)/\(name).png")
    }
    try renderScrollCapture(out)
    try renderAnnotateOverlay(out)
    try renderShotHistory(out)
    try await renderLauncher(out)
    // 刘海岛：刘海屏的下巴（成功 / 进行中）、无刘海屏的胶囊（取色色块 / 错误）
    let notch = Island.Geometry.notch(width: 200, height: 32)
    let islands: [(String, Island.Content, Island.Geometry)] = [
      (
        "island-copied",
        .init(
          title: "已复制", detail: "https://example.com/kitty-tools", tone: .success,
          symbol: "checkmark.circle.fill", leading: .tone), notch
      ),
      (
        "island-progress",
        .init(
          title: "翻译中…", detail: "再按一次快捷键取消", tone: .progress,
          symbol: "character.bubble.fill", leading: .tone), notch
      ),
      // 录音第 6 批：录系统声音停下后导出 m4a 超过 1 s 的进度
      (
        "island-audio-export",
        .init(
          title: "正在存储录音…", detail: nil, tone: .progress, symbol: "waveform.circle.fill",
          leading: .tone), notch
      ),
      // 录屏录音第 7 批：视频卡「转成 GIF」的进度（超过 60 s 的说只转前 60 秒）；第二轮体检 R3：后面带百分比
      (
        "island-gif-progress",
        .init(
          title: "正在转成 GIF…", detail: ShelfCard.progressDetail(37, note: "只转前 60 秒"),
          tone: .progress, symbol: ShelfCard.gifIslandSymbol, leading: .tone, fraction: 0.37),
        notch
      ),
      // 更新包下载（2026-10-13）：知道下了多少，标题后面多一条细进度条（上面转 GIF、压缩的两张同样）；无刘海屏的胶囊再出一张
      (
        "island-update-progress",
        .init(
          title: Updater.installingTitle("0.5.0"), detail: Updater.installingDetail(0.42),
          tone: .progress, symbol: "arrow.down.circle.fill", leading: .tone, fraction: 0.42), notch
      ),
      (
        "island-update-progress-capsule",
        .init(
          title: Updater.installingTitle("0.5.0"), detail: Updater.installingDetail(1),
          tone: .progress, symbol: "arrow.down.circle.fill", leading: .tone, fraction: 1),
        .capsule(menuBar: 24)
      ),
      // 第二轮体检 R1：视频卡「压缩」的进度；R3：识字慢的时候先出「识别中」
      (
        "island-compress-progress",
        .init(
          title: "正在压缩…", detail: ShelfCard.progressDetail(37), tone: .progress,
          symbol: ShelfCard.compressIslandSymbol, leading: .tone, fraction: 0.37), notch
      ),
      (
        "island-recognizing",
        .init(
          title: "识别中…", detail: nil, tone: .progress, symbol: "ellipsis.circle.fill",
          leading: .tone), notch
      ),
      (
        "island-color",
        .init(
          title: "已复制色值", detail: "#3478F6", tone: .success, symbol: "checkmark.circle.fill",
          leading: .color(.systemBlue)), .capsule(menuBar: 24)
      ),
      (
        "island-error",
        .init(
          title: "翻译失败", detail: "网络超时，请重试", tone: .error,
          symbol: "exclamationmark.circle.fill", leading: .tone), .capsule(menuBar: 24)
      ),
      // 视觉对齐第 3 批：没有圆底变体的符号由岛垫语气色圆（成功 = 绿底白符号）、警告默认的橙三角、
      // 警告 + 宽的裸符号（键盘缩进橙圆里，不出圆）
      (
        "island-bare",
        .init(
          title: "已存为片段", detail: "git rebase -i HEAD~3", tone: .success,
          symbol: "text.badge.star", leading: .tone), notch
      ),
      (
        "island-warning",
        .init(
          title: "已复制到剪贴板", detail: "授权辅助功能后才能直接粘贴", tone: .warning,
          symbol: "exclamationmark.triangle.fill", leading: .tone), notch
      ),
      (
        "island-warning-bare",
        .init(
          title: "有 2 个快捷键没注册上", detail: "到 设置 › 快捷键 里看原因、换一个组合", tone: .warning,
          symbol: "keyboard", leading: .tone), .capsule(menuBar: 24)
      ),
    ]
    for (name, content, geometry) in islands {
      try snapshot(
        IslandView(island: Island(showing: content, geometry: geometry)),
        size: geometry.windowSize, dark: false, to: "\(out)/\(name).png")
    }
    // 能交互（2026-10-26）：带按钮的收着时主按钮露在行尾；悬停后长成卡片——完整详情最多 4 行，按钮在第一行（主按钮白底、
    // 在 × 左边）。长错误、两个按钮、没按钮只有 ×、无刘海屏的卡片各一张
    let longError =
      "服务器返回 429：请求太频繁，请稍后再试。智谱 glm-4-flash 已经重试过 2 次，还是不行的话可以到 设置 › 翻译 里换一个服务，或者填上自己的密钥。"
    let interactive: [(String, Island.Content, Island.Geometry, [String], Bool)] = [
      (
        "island-action",
        .init(
          title: "已删除 3 条", detail: "剪贴板历史", tone: .info, symbol: "trash.circle.fill",
          leading: .tone), notch, ["撤销"], false
      ),
      (
        "island-expanded-error",
        .init(
          title: "翻译失败", detail: longError, tone: .error,
          symbol: "exclamationmark.circle.fill", leading: .tone), notch, ["重试"], true
      ),
      (
        "island-expanded-saved",
        .init(
          title: "已保存", detail: "截屏 2026-10-26 14.32.08.png", tone: .success,
          symbol: "checkmark.circle.fill", leading: .color(.systemTeal)), notch,
        ["在访达中显示", "打开"], true
      ),
      (
        "island-expanded-bare",
        .init(
          title: "已复制", detail: "https://example.com/kitty-tools", tone: .success,
          symbol: "checkmark.circle.fill", leading: .tone), notch, [], true
      ),
      (
        "island-expanded-capsule",
        .init(
          title: "需要「屏幕录制」授权", detail: "截图翻译要用，授权后可能要重新打开本 App", tone: .warning,
          symbol: "exclamationmark.triangle.fill", leading: .tone), .capsule(menuBar: 24),
        ["打开系统设置"], true
      ),
    ]
    for (name, content, geometry, titles, expanded) in interactive {
      let island = Island(
        showing: content, geometry: geometry, actions: titles.map { Island.Action($0) {} },
        expanded: expanded)
      try snapshot(
        IslandView(island: island), size: geometry.windowSize, dark: false, to: "\(out)/\(name).png"
      )
    }
    // 那一张（点刘海 / 快捷键叫出来，2026-10-26）：一排快捷动作 + 最近的提示（带打开类按钮的、截图缩略图前导、错误）；
    // 无刘海屏上是圆角卡片、还没有提示时的空样子；指针停在刘海上时鼓起一点
    let quick = HotKeyAction.islandShortcuts.map { Island.Action($0.title, symbol: $0.symbol) {} }
    let records = [
      Island.Record(
        content: .init(
          title: "已保存到「桌面」", detail: "截屏 2026-10-26 14.32.08.png", tone: .success,
          symbol: "checkmark.circle.fill", leading: .color(.systemTeal)),
        actions: [.reveal(URL(filePath: "/tmp/a.png"))], at: .now.addingTimeInterval(-40)),
      Island.Record(
        content: .init(
          title: "已复制", detail: "https://example.com/kitty-tools", tone: .success,
          symbol: "checkmark.circle.fill", leading: .tone), actions: [],
        at: .now.addingTimeInterval(-300)),
      Island.Record(
        content: .init(
          title: "翻译失败", detail: longError, tone: .error, symbol: "exclamationmark.circle.fill",
          leading: .tone), actions: [], at: .now.addingTimeInterval(-1500)),
      Island.Record(
        content: .init(
          title: "需要「屏幕录制」授权", detail: "截图翻译要用，授权后可能要重新打开本 App", tone: .warning,
          symbol: "exclamationmark.triangle.fill", leading: .tone),
        actions: [.settings(for: .screenRecording)], at: .now.addingTimeInterval(-4000)),
    ]
    let boards: [(String, Island.Geometry, [Island.Record])] = [
      ("island-board", notch, records), ("island-board-capsule", .capsule(menuBar: 24), records),
      ("island-board-empty", notch, []),
    ]
    for (name, geometry, list) in boards {
      let island = Island(showing: nil, geometry: geometry, board: list, quickActions: quick)
      try snapshot(
        IslandView(island: island), size: geometry.windowSize, dark: false,
        to: "\(out)/\(name).png")
    }
    try snapshot(
      IslandView(island: Island(showing: nil, geometry: notch, peeking: true)),
      size: notch.windowSize, dark: false, to: "\(out)/island-peek.png")
    // 黄色强调色：信息 / 进行中的底是强调色，上面的符号要换深色（Style.onBrand）才看得见——岛垫的圆底、自带圆底的各一张。
    // 只换内存里的颜色，不写偏好
    Accent.shared.select(.yellow, persists: false)
    let onYellow: [(String, String, String?, Island.Tone, String)] = [
      ("island-accent-yellow", "已关闭全部钉图", "3 张", .info, "pin.slash"),
      ("island-accent-yellow-progress", "识别中…", nil, .progress, "ellipsis.circle.fill"),
    ]
    for (name, title, detail, tone, symbol) in onYellow {
      try snapshot(
        IslandView(
          island: Island(
            showing: .init(
              title: title, detail: detail, tone: tone, symbol: symbol, leading: .tone),
            geometry: notch)),
        size: notch.windowSize, dark: false, to: "\(out)/\(name).png")
    }
    Accent.shared.select(savedAccent, persists: false)
  }

  /// 状态屏（PLAN §10）：一块 1200 × 800 的屏，底下垫着假桌面（不透明的两种样式看不到它）。单独一个测试函数：
  /// 改状态屏时只跑它（几秒钟），不用等整套 renderPanels——
  ///   -only-testing:'KittyToolsTests/SnapshotProbeTests/statusScreen()'
  /// 熄屏（纯黑，什么都不显示）、熄屏碰了一下（只浮出退出提示）、告示（提示浮着）、透出（HUD 底板，进度环按住到一半）、
  /// 透出的增强对比度（次要文字提一档）、自己加的状态（不带图标、两行标题、长说明）。进入时刻固定，图里的时间不随运行变。
  /// 图标是表情的静止画面（第 5 批；这几张是动画关着 / 减弱动态效果时的样子，也是帧还没解好时的样子）。另有：
  /// 眼睛从底边探出来的两张（提示开着 / 被设置关掉）和从另外三条边探出来的三张（status-screen-eyes-*）、出场摆在三个时刻（透出样式：底板淡入、表情落下、标题逐字浮现、
  /// 说明和小字还没出）和长标题折两行时的一刻、做着动画但出场已经播完的（该和不做动画的一样：status-screen-dim 一对、
  /// 长标题的 status-screen-sign-long 一对）。2026-10-11：小字精确到秒（图里是 1 小时 23 分 05 秒）、定了自动结束的
  /// 倒数（status-screen-sign-countdown）、退出密码的输入框三张（刚打开、6 位打了 2 位、刚输错；熄屏样式上一张）
  @Test(.enabled(if: directory != nil)) func statusScreen() throws {
    let out = try #require(Self.directory)
    try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    let desktop = try ScreenshotSnapshotTests.desktop()
    let presets = StatusPreset.builtIn
    let startedAt = try #require(
      Calendar.current.date(
        from: DateComponents(year: 2026, month: 10, day: 10, hour: 14, minute: 2)))
    func shot(
      _ name: String, _ preset: StatusPreset, hint: Bool = false, held: Double = 0,
      contrast: ColorSchemeContrast = .standard, eyes: StatusScreen.Peek? = nil,
      animates: Bool = false,
      entrance: Double = .infinity, elapsed: Int = 83 * 60 + 5, asking: Passcode? = nil
    ) throws {
      let screen = StatusScreen(
        showing: preset, startedAt: startedAt, elapsed: elapsed, showsHint: hint, held: held,
        peek: eyes, animates: animates, entrance: entrance, asking: asking)
      try snapshot(
        ZStack {
          Image(decorative: desktop, scale: 2)
          StatusScreenView(screen: screen)
        }
        .environment(\._colorSchemeContrast, contrast),
        size: NSSize(width: 1200, height: 800), dark: false, to: "\(out)/\(name).png")
    }
    try shot("status-screen-blackout", presets[0])
    try shot("status-screen-blackout-hint", presets[0], hint: true)
    try shot("status-screen-sign", presets[2], hint: true)
    try shot("status-screen-dim", presets[1], hint: true, held: 0.5)
    try shot("status-screen-dim-contrast", presets[1], hint: true, contrast: .increased)
    let custom = StatusPreset(
      id: "custom", title: "正在导出年度报告的全部视频素材，请不要合上盖子", detail: "预计下午四点半结束，有事打我手机；这台电脑不要断电、不要拔硬盘",
      symbol: "", style: .dim, power: .displayOn, autoEndMinutes: 0)
    try shot("status-screen-dim-long", custom)
    // 有人碰了键盘鼠标（Z17a）：屏幕边上探出一双眼睛（图里是静止画面，真机上会动；这两张摆在底边）；
    // 退出提示被设置关掉时眼睛照冒
    try shot(
      "status-screen-sign-eyes", presets[2], hint: true, eyes: .init(edge: .bottom, along: 0.72),
      animates: true)
    try shot(
      "status-screen-dim-eyes-no-hint", presets[1], eyes: .init(edge: .bottom, along: 0.2),
      animates: true)
    // 2026-10-12：眼睛从四条边里随机的一处探出来（没人碰时也隔一阵自己冒），沿着边整条都可能——另外三条边各一张：
    // 顶边是倒着的、左右是横着的，都露八成；再摆两个极端：贴着角（左边最上头）、底边正中时提示浮出来压在它上面
    let spots: [(String, StatusScreen.Peek.Edge, CGFloat)] = [
      ("top", .top, 0.3), ("left", .left, 0.6), ("right", .right, 0.35), ("corner", .left, 1),
    ]
    for (name, edge, along) in spots {
      try shot(
        "status-screen-eyes-\(name)", presets[1], eyes: .init(edge: edge, along: along),
        animates: true)
    }
    try shot(
      "status-screen-eyes-middle-hint", presets[2], hint: true,
      eyes: .init(edge: .bottom, along: 0.5), animates: true)
    // 出场（Z16a）摆在三个时刻
    for (name, time) in [("start", 0.08), ("mid", 0.2), ("late", 0.42)] {
      try shot("status-screen-entrance-\(name)", presets[1], animates: true, entrance: time)
    }
    // 长标题折成两行、缩小了字号：逐字浮现跟着折行走（带表情的告示样式）
    var long = custom
    long.symbol = "rocket"
    long.style = .sign
    try shot("status-screen-entrance-long", long, animates: true, entrance: 0.7)
    // 做着动画、出场播完：标题走的是逐字的渲染器，该和不做动画的看不出差别（短标题、折两行又缩了字号的长标题各一对）
    try shot("status-screen-dim-animated", presets[1], hint: true, held: 0.5, animates: true)
    try shot("status-screen-sign-long", long)
    try shot("status-screen-sign-long-animated", long, animates: true)
    // 定了自动结束的状态：小字是倒数（进入 28 秒，还剩 4 分 32 秒）
    var timed = presets[2]
    timed.autoEndMinutes = 5
    try shot("status-screen-sign-countdown", timed, elapsed: 28)
    // 做着动画的会话里小字是图层版（Shell/Ticker.swift）：该和上面那张、和 status-screen-dim 的小字对得上
    try shot("status-screen-sign-countdown-animated", timed, animates: true, elapsed: 28)
    // 退出密码的输入框（设了密码、按住满了之后，占着退出提示的位置）：4 位刚打开、6 位打了 2 位、8 位刚输错；熄屏样式上一张
    try shot("status-screen-passcode", presets[2], asking: Passcode("1234"))
    try shot("status-screen-passcode-typing", presets[1], asking: Passcode("123456", typed: 2))
    try shot("status-screen-passcode-wrong", presets[1], asking: Passcode("12345678", misses: 1))
    try shot("status-screen-blackout-passcode", presets[0], asking: Passcode("1234", typed: 3))
    // 本身是深色的两个表情（开会的人影、黑猫）在纯黑的告示上
    for emoji in ["busts", "black-cat"] {
      var dark = presets[2]
      dark.symbol = emoji
      try shot("status-screen-sign-\(emoji)", dark)
    }
  }

  /// 设置 › 状态屏（PLAN §10 第 2 批）。单独一个测试函数：改这一页、速查表页头或快捷键页那一行时只跑它（十来秒）——
  ///   -only-testing:'KittyToolsTests/SnapshotProbeTests/statusScreenSettings()'
  /// 列表是固定的一份（StatusScreenTab / StatusPresetDetail 的 fixed：只画，不读不写用户的偏好，也不建临时偏好域）：
  /// 自带三个 + 自己加的两个（不带图标的、标题顶到 30 字的）。出：整页浅色 / 深色、满 20 个（「+」置灰、列表下面说原因）、
  /// 推进到详情的整页、「改一个状态」的详情三种样式（透出的预览垫着示意桌面；浅色 / 深色）、草稿有问题时的橙字、只剩一个时删除置灰、
  /// 速查表的新页头（跳转胶囊两行）和拉长的全表（看「状态屏」那一组）、快捷键页（「进入排在最前面的状态」那一行）。
  /// 第 5 批：列表行和详情页页头是表情的静止画面（没选的是家族色块）、详情页的图标格子是「无」+ 16 个表情、
  /// 页里多了「动画」一组（「告示上的动画」开关）、关于页最底下那行素材出处
  @Test(.enabled(if: directory != nil)) func statusScreenSettings() throws {
    let out = try #require(Self.directory)
    try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    Prefs.registerDefaults()
    var meeting = StatusPreset.new(id: "meeting")
    meeting.title = "开会中"
    meeting.detail = "三点回来"
    meeting.power = .displayOn
    meeting.autoEndMinutes = 60
    var export = StatusPreset.new(id: "export")
    export.title = "正在导出年度报告的全部视频素材，请不要合上盖子也不要拔电源"
    export.detail = "预计下午四点半结束，有事打我手机"
    export.symbol = "rocket"
    export.style = .dim
    let list = StatusPreset.sanitized(StatusPreset.builtIn + [meeting, export])
    let navigation = SettingsNavigation(defaults: nil)  // 换页不写用户的偏好
    let hotKeys = HotKeyCenter()
    func root(_ presets: [StatusPreset]) -> some View {
      SettingsRoot(navigation: navigation) { page in
        page == .hotkeys
          ? AnyView(HotkeysTab(center: hotKeys)) : AnyView(StatusScreenTab(fixed: presets))
      } onboarding: {
        AnyView(EmptyView())
      }
    }
    navigation.page = .statusScreen
    for dark in [false, true] {
      try snapshot(
        root(list), size: NSSize(width: 780, height: 980), dark: dark,
        to: "\(out)/settings-status-screen\(dark ? "-dark" : "").png")
    }
    // 最小窗口（700 × 460）：页头那句说明、列表行不被截坏
    try snapshot(
      root(list), size: NSSize(width: 700, height: 460), dark: false,
      to: "\(out)/settings-status-screen-min.png")
    // 已经设了退出密码：那一行只剩「移除」（没设的样子在上面几张的最下面一组里）
    try snapshot(
      StatusScreenTab(fixed: list, fixedPasscode: true).environment(navigation),
      size: NSSize(width: 590, height: 1040), dark: false,
      to: "\(out)/settings-status-passcode-set.png")
    let full = (1...StatusPreset.maxCount).map { index in
      var preset = StatusPreset.new(id: "p\(index)")
      preset.title = "状态 \(index)"
      return preset
    }
    try snapshot(
      root(full), size: NSSize(width: 780, height: 1420), dark: false,
      to: "\(out)/settings-status-screen-full.png")
    // 从列表推进到详情（真的 NavigationStack，和点一行一样走 navigation.path）：页头换成详情页自己的
    navigation.path = ["busy"]
    try snapshot(
      root(list), size: NSSize(width: 780, height: 760), dark: false,
      to: "\(out)/settings-status-screen-pushed.png")
    navigation.path = []
    // 详情：透出（预览垫示意桌面）、熄屏（预览纯黑）、告示、自己加的长标题；深色一张
    for (name, id, dark) in [
      ("dim", "busy", false), ("dim-dark", "busy", true), ("blackout", "clean", false),
      ("sign", "back", false), ("long", "export", false), ("plain", "meeting", false),
    ] {
      try snapshot(
        StatusPresetDetail(id: id, fixed: list), size: NSSize(width: 590, height: 940), dark: dark,
        to: "\(out)/settings-status-detail-\(name).png")
    }
    // 视觉对齐 E8：颜色很深的两个表情（开会、黑猫）当小图标时深色外观下垫浅底、浅色不垫——列表行、详情页页头和
    // 图标格子里选中的那一格
    var talk = meeting
    talk.id = "talk"
    talk.symbol = "busts"
    var cat = StatusPreset.new(id: "cat")
    cat.title = "猫在键盘上"
    cat.symbol = "black-cat"
    for dark in [false, true] {
      try snapshot(
        StatusScreenTab(fixed: [talk, cat] + StatusPreset.builtIn).environment(navigation),
        size: NSSize(width: 590, height: 360), dark: dark,
        to: "\(out)/settings-status-plate\(dark ? "-dark" : "").png")
      try snapshot(
        StatusPresetDetail(id: "cat", fixed: [talk, cat]), size: NSSize(width: 590, height: 360),
        dark: dark, to: "\(out)/settings-status-detail-plate\(dark ? "-dark" : "").png")
    }
    // 输入框里的标题超了 30 字（没收拾过的一份，等于正在改的草稿）：页头的摘要换成橙色说明。
    // 这张图里预览也是超长的标题——真用的时候存着的那份收拾过，预览只到 30 字
    var overlong = export
    overlong.title += "，谢谢配合"
    try snapshot(
      StatusPresetDetail(id: "export", fixed: [overlong] + StatusPreset.builtIn),
      size: NSSize(width: 590, height: 940), dark: false,
      to: "\(out)/settings-status-detail-problem.png")
    // 只剩一个：删除置灰，下面说至少留一个
    try snapshot(
      StatusPresetDetail(id: "clean", fixed: [StatusPreset.builtIn[0]]),
      size: NSSize(width: 590, height: 940), dark: false,
      to: "\(out)/settings-status-detail-only.png")
    // 速查表：从状态屏页点开（停在状态屏那一类），默认大小的设置窗里的 sheet
    let sheetHeight = ShortcutsButton.sheetHeight(available: 600 - 52)
    for (name, dark) in [("shortcuts-status", false), ("shortcuts-status-dark", true)] {
      try snapshot(
        ShortcutsSheet(page: .statusScreen),
        size: NSSize(width: ShortcutsSheet.width, height: sheetHeight), dark: dark,
        to: "\(out)/\(name).png")
    }
    // 快捷键页拉长看到底：最后一节「状态屏」那一行
    navigation.page = .hotkeys
    try snapshot(
      root(list), size: NSSize(width: 780, height: 1000), dark: false,
      to: "\(out)/settings-status-hotkeys.png")
    // 关于页的「未来计划」（2026-10-18）：品牌区下面、更新日志上面那一节，拉高看全（roadmap.json 空了时没有这一节：
    // 2026-10-23 起都做完了，图里是品牌区接着更新日志）
    for dark in [false, true] {
      try snapshot(
        AboutTab(), size: NSSize(width: 590, height: 900), dark: dark,
        to: "\(out)/settings-about-roadmap\(dark ? "-dark" : "").png")
    }
    // 关于页最底下那行素材出处：滚到底再拍
    for dark in [false, true] {
      try snapshot(
        AboutTab(), size: NSSize(width: 590, height: 420), dark: dark,
        to: "\(out)/settings-about-credits\(dark ? "-dark" : "").png"
      ) { root in
        @MainActor func scrollView(in view: NSView) -> NSScrollView? {
          if let scroll = view as? NSScrollView { return scroll }
          for subview in view.subviews {
            if let found = scrollView(in: subview) { return found }
          }
          return nil
        }
        guard let scroll = scrollView(in: root), let document = scroll.documentView else { return }
        document.scroll(NSPoint(x: 0, y: document.bounds.height - scroll.contentSize.height))
      }
    }
  }

  /// 选状态的面板（PLAN §10 第 4 批，Z13a Z14a）。单独一个测试函数：改这块面板时只跑它（十来秒）——
  ///   -only-testing:'KittyToolsTests/SnapshotProbeTests/statusPicker()'
  /// 卡片里的图标是表情的静止画面（第 5 批：卡片不动）。
  /// 面板的大小取排版算出来的（和真面板一样）。出：自带的 3 个状态浅 / 深色（选中第二张）、7 个折成两行（选中第二行的、
  /// 鼠标停在第一张上、有不带图标和标题很长的）、只有 1 个（面板不窄于两格）、20 个在矮屏上（卡片那一块滚动，默认选中
  /// 最后一张：一出来就滚到它）、设置 › 状态屏（多了「进入」那一组）、启动器里搜「状态屏」出来的那几行（表情当图标）；
  /// 放大（Z14a）的起点和半路：一块 1200 × 800 的「屏」正中摆着面板，真的状态屏画面铺满整屏、图层设上
  /// StatusScreenPanel.zoomStart 算的变换——起点那张里它正好盖住选中的卡片（面板真用的时候这一刻已经收起，这里留着对位置）
  @Test(.enabled(if: directory != nil)) func statusPicker() throws {
    let out = try #require(Self.directory)
    try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    Prefs.registerDefaults()
    func shot(_ name: String, _ model: StatusPickerModel, dark: Bool = false) throws {
      try snapshot(
        StatusPickerView(model: model), size: model.layout.size, dark: dark,
        to: "\(out)/\(name).png")
    }
    let builtIn = StatusPreset.builtIn
    for dark in [false, true] {
      try shot(
        "status-picker\(dark ? "-dark" : "")", StatusPickerModel(presets: builtIn, selection: 1),
        dark: dark)
    }
    var meeting = StatusPreset.new(id: "meeting")
    meeting.title = "开会中"
    meeting.detail = "三点回来"
    var export = StatusPreset.new(id: "export")
    export.title = "正在导出年度报告的全部视频素材，请不要合上盖子也不要拔电源"
    export.symbol = "rocket"
    export.style = .dim
    var lunch = StatusPreset.new(id: "lunch")
    lunch.title = "吃饭去了"
    lunch.symbol = "hot-beverage"
    var night = StatusPreset.new(id: "night")
    night.title = "夜里跑训练"
    night.symbol = "sleeping-face"
    night.style = .blackout
    let seven = StatusPreset.sanitized(builtIn + [meeting, export, lunch, night])
    try shot("status-picker-two-rows", StatusPickerModel(presets: seven, selection: 5, hovered: 0))
    try shot("status-picker-one", StatusPickerModel(presets: [builtIn[2]]))
    let full = (1...StatusPreset.maxCount).map { index in
      var preset = StatusPreset.new(id: "p\(index)")
      preset.title = "状态 \(index)"
      preset.symbol = StatusEmoji.ids[index % StatusEmoji.ids.count]
      preset.style = StatusPreset.Look.allCases[index % 3]
      return preset
    }
    try shot(
      "status-picker-scrolled",
      StatusPickerModel(presets: full, selection: full.count - 1, maxHeight: 700))
    // 设置 › 状态屏：列表下面多了「进入」一组（开关读的是注册的默认值：关）
    let navigation = SettingsNavigation(defaults: nil)
    navigation.page = .statusScreen
    try snapshot(
      SettingsRoot(navigation: navigation) { _ in
        AnyView(StatusScreenTab(fixed: builtIn))
      } onboarding: {
        AnyView(EmptyView())
      }, size: NSSize(width: 780, height: 820), dark: false,
      to: "\(out)/settings-status-screen-enter.png")
    // 启动器里的状态行（搜「状态屏」）：图标是各自的表情，没选的是家族色块里「只有几行字」的符号
    let launcher = LauncherModel(
      usage: try LauncherUsage(db: Database(path: ":memory:")), apps: [])
    launcher.boundHotKey = { $0.defaultHotKey }
    launcher.engines = { [] }
    launcher.actionState = { .init(statusPresets: Array(seven.prefix(5))) }
    launcher.query = "状态屏"
    try snapshot(
      LauncherPanelView(model: launcher),
      size: NSSize(width: 720, height: LauncherPanelView.height(for: launcher)), dark: false,
      to: "\(out)/launcher-status-presets.png")

    // 放大：屏外窗口里叠三层——假桌面、面板（摆在正中）、铺满的状态屏画面（图层按 zoomStart 缩到选中的卡片上）
    let desktop = try ScreenshotSnapshotTests.desktop()
    let model = StatusPickerModel(presets: builtIn, selection: 1)
    let screenSize = NSSize(width: 1200, height: 800)
    let window = NSWindow(
      contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: screenSize),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .aqua)
    let root = NSView(frame: NSRect(origin: .zero, size: screenSize))
    root.wantsLayer = true
    let backdrop = NSHostingView(rootView: Image(decorative: desktop, scale: 2))
    backdrop.frame = root.bounds
    let pickerFrame = NSRect(
      x: (screenSize.width - model.layout.size.width) / 2,
      y: (screenSize.height - model.layout.size.height) / 2, width: model.layout.size.width,
      height: model.layout.size.height)
    let picker = NSHostingView(
      rootView: StatusPickerView(model: model)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(.rect(cornerRadius: Style.Radius.panel, style: .continuous)))
    picker.frame = pickerFrame
    let startedAt = try #require(
      Calendar.current.date(
        from: DateComponents(year: 2026, month: 10, day: 10, hour: 14, minute: 2)))
    let screen = NSHostingView(
      rootView: StatusScreenView(
        screen: StatusScreen(showing: builtIn[1], startedAt: startedAt, elapsed: 0)))
    screen.sizingOptions = []
    screen.wantsLayer = true
    screen.frame = root.bounds
    for view in [backdrop, picker, screen] { root.addSubview(view) }
    window.contentView = root
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    for _ in 0..<5 { RunLoop.main.run(until: Date.now.addingTimeInterval(0.1)) }
    // 选中的卡片的位置：画面报上来的是 SwiftUI 的 global 坐标（窗口内容区、原点左上；真面板里内容铺满窗口，
    // 所以就是面板里的位置，OverlayPanel.screenRect 再换成屏幕坐标）→ 这块「屏」的坐标（原点左下）
    let reported = try #require(model.cardFrames[1])
    let card = CGRect(
      x: reported.minX, y: screenSize.height - reported.maxY, width: reported.width,
      height: reported.height)
    // 报的是放大了 4% 之后的那一圈里面的卡片；它在面板的第二格里
    #expect(abs(reported.width - StatusPicker.card.width * StatusPicker.selectedScale) < 0.5)
    let cellLeft =
      pickerFrame.minX + StatusPicker.inset + StatusPicker.cell.width + StatusPicker.gap
    #expect(abs(reported.midX - (cellLeft + StatusPicker.cell.width / 2)) < 0.5)
    let layer = try #require(screen.layer)
    let start = StatusScreenPanel.zoomStart(from: card, to: screen.frame, about: layer.position)
    func grown(_ progress: CGFloat, to name: String) throws {
      // 半路：各分量在起点和原位之间线性取（弹簧走到这个进度时的样子）
      let lerp = { (from: CGFloat, to: CGFloat) in from + (to - from) * progress }
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      layer.setAffineTransform(
        CGAffineTransform(
          a: lerp(start.a, 1), b: 0, c: 0, d: lerp(start.d, 1), tx: lerp(start.tx, 0),
          ty: lerp(start.ty, 0)))
      layer.cornerRadius = lerp(Style.Radius.card / start.a, 0)
      layer.masksToBounds = true
      CATransaction.commit()
      picker.isHidden = progress > 0
      RunLoop.main.run(until: Date.now.addingTimeInterval(0.1))
      let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
      root.cacheDisplay(in: root.bounds, to: bitmap)
      try #require(bitmap.representation(using: .png, properties: [:]))
        .write(to: URL(filePath: "\(out)/\(name).png"))
    }
    try grown(0, to: "status-picker-grow-start")
    try grown(0.5, to: "status-picker-grow-half")
    try grown(1, to: "status-picker-grow-end")
  }

  /// 翻译浮窗：空态、结果（没有「翻译」按钮）、原文改过（弹出「翻译 ↩」）、复制即译状态胶囊 + 固定、
  /// 替换原文、查词、历史（分组 + 选中第三条 + 范围胶囊）、收藏范围、空历史、提示、长译文（卡内滚动 + 渐隐，
  /// 默认和 140% 字号）；「⋯」菜单是 NSMenu，屏外画不出来
  /// 便签（PLAN §10「便签」第 2 批）。单独一个测试函数：改便签的界面时只跑它（半分钟）——
  ///   -only-testing:'KittyToolsTests/SnapshotProbeTests/notes()'
  /// 便签都在内存库里（不碰用户的便签库和偏好），文件名都以 notes- 开头。出：
  /// 快速记一条——空的、有草稿（目的地一排纸色圆点）、选了已有的便签（浅 / 深）、打了十几行（到 8 行封顶、在框里滚）、
  /// 存不了时底栏的原因；
  /// 全部便签窗口——有便签（浅 / 深，各选一条不同纸色的）、最小窗口、还没有便签、搜索无结果、归档是空的、最近删除
  /// （只读）、正文到上限时底下那行警告、带标题栏和工具栏的真窗口（摆在屏外）；8 种纸色两套并排；
  /// 设置 › 便签（浅 / 深）、快捷键页的「便签」一节、速查表（页头的跳转胶囊 5 + 4，和拉长的全表）、
  /// 启动器里搜「便签」出来的三行；
  /// 第 6 批 Markdown（notes-window-markdown*、notes-markdown-paper-*）——标记都藏着的（浅 / 深）、光标所在的行
  /// 露出标记的（正文里的一行、标题那一行、选了几行）、四档字号、开关关掉的、8 种纸色两套各一张小图
  @Test(.enabled(if: directory != nil)) func notes() throws {
    let out = try #require(Self.directory)
    try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    Prefs.registerDefaults()
    let now = Date.now
    func library() throws -> (store: NoteStore, ids: [String]) {
      let store = try NoteStore(db: Database(path: ":memory:"))
      // 倒着建：新建的排最前，建完就是下面这个顺序；颜色接着轮（6 条 6 种）
      let entries: [(title: String, body: String, ago: TimeInterval)] = [
        ("", "周五前交的东西\n☐ 周报\n☐ 报销单\n☑ 订会议室\n下午三点和设计过一遍首页的改动，记得带上数据。", 180),
        ("读书笔记", "「慢慢来，比较快」这句话放在重构上也成立：先把现有的行为用测试钉住，再一小步一小步地挪。", 3600 * 2),
        ("", "wifi 密码 kitty-2026", 3600 * 26),
        ("想法", "", 86_400 * 3),
        ("", "一条很长很长的标题，长到列表里的这一行放不下，后面要用省略号收住，看它和右边的时间挤不挤在一起", 86_400 * 9),
        ("", "Groceries: milk, eggs, bread", 86_400 * 40),
      ]
      for entry in entries.reversed() {
        store.create(body: entry.body, title: entry.title, now: now.addingTimeInterval(-entry.ago))
      }
      return (store, store.active.map(\.id))
    }

    // MARK: 快速记一条
    func capture(_ name: String, _ model: NoteCaptureModel, dark: Bool = false) throws {
      try snapshot(
        NoteCaptureView(model: model),
        size: NSSize(width: Style.listPanelWidth, height: model.height), dark: dark,
        to: "\(out)/notes-capture-\(name).png")
    }
    try capture("empty", NoteCaptureModel(store: try NoteStore(db: Database(path: ":memory:"))))
    let (store, ids) = try library()
    store.setPinned(true, of: ids[1])
    let draft = NoteCaptureModel(store: store)
    draft.draft = "下周一上午十点牙医\n带上上次的片子"
    try capture("draft", draft)
    // 新便签的标题：填了的、只填了标题的（「记下」亮着）
    let titled = NoteCaptureModel(store: store)
    titled.title = "周五的牙医"
    titled.draft = "上午十点，带上上次的片子"
    try capture("title", titled)
    let titleOnly = NoteCaptureModel(store: store)
    titleOnly.title = "只有标题的一条"
    try capture("title-only", titleOnly)
    try capture("title-only-dark", titleOnly, dark: true)
    for dark in [false, true] {
      let target = NoteCaptureModel(store: store)
      target.select(2)
      target.draft = "第 3 章：先加测试，再动代码"
      try capture("target\(dark ? "-dark" : "")", target, dark: dark)
    }
    let hovering = NoteCaptureModel(store: store)
    hovering.draft = "鼠标停在第四个圆点上"
    hovering.hovered = 4
    try capture("hover", hovering)
    let long = NoteCaptureModel(store: store)
    long.draft = (1...14).map { "第 \($0) 行：打到第九行起在框里滚" }.joined(separator: "\n")
    try capture("long", long)
    // 存不了：接在一条快到上限的便签后面
    let full = try NoteStore(db: Database(path: ":memory:"))
    full.create(body: String(repeating: "满", count: Note.maxBodyBytes / 3 - 2), title: "攒了一年的流水账")
    let refused = NoteCaptureModel(store: full)
    refused.select(1)
    refused.draft = "再记一句就超过上限了"
    #expect(refused.save() == .tooLong)
    try capture("too-long", refused)

    // MARK: 全部便签窗口
    let windowSize = NSSize(width: 940, height: 580)
    func window(
      _ name: String, _ model: NotesWindowModel, size: NSSize = windowSize, dark: Bool = false,
      prepare: ((NSView) -> Void)? = nil
    ) throws {
      // 这一组是列表视图（便签墙是下面的 notes-wall-*）
      model.layout = .list
      try snapshot(
        NotesWindowView(model: model), size: size, dark: dark,
        to: "\(out)/notes-window-\(name).png", prepare: prepare)
    }
    let model = NotesWindowModel(store: store)
    try window("list", model)
    model.selection = ids[1]
    try window("list-dark", model, dark: true)
    model.selection = ids[4]
    try window("min", model, size: NSSize(width: 720, height: 420))
    model.selection = ids[3]
    try window("blank-body", model)
    model.selection = ids[0]
    model.overflowed()
    try window("over-limit", model)
    model.query = "找不到的词"
    try window("search-empty", model)
    model.query = "周"
    try window("search", model)
    model.query = ""
    model.scope = .archive
    try window("archive-empty", model)
    model.scope = .trash
    try window("trash-empty", model)
    store.delete(ids[2], now: now.addingTimeInterval(-86_400 * 12))
    store.delete(ids[5], now: now.addingTimeInterval(-600))
    store.setArchived(true, of: ids[4])
    model.scope = .all
    model.scope = .trash
    for dark in [false, true] { try window("trash\(dark ? "-dark" : "")", model, dark: dark) }
    model.scope = .archive
    try window("archive", model)
    try window("empty", NotesWindowModel(store: try NoteStore(db: Database(path: ":memory:"))))

    // 第 5 批：任务——没做完 / 做完的（划线、变淡）、缩进的、做完的一长行折行、和普通行混排；列表行上的进度
    // （没做完的、全做完的）；四档字号各一张（方框和字的大小、行距）
    let tasks = try NoteStore(db: Database(path: ":memory:"))
    tasks.create(body: "☑ 都做完了\n☑ 这条也是", title: "全做完的", now: now.addingTimeInterval(-7200))
    tasks.create(body: "只有字，没有任务", now: now.addingTimeInterval(-3600))
    let todo = tasks.create(
      body:
        "周五前交的东西 Abc\n☐ 周报 Report\n☑ 订会议室 Done\n  ☐ 缩进的子任务\n  ☑ 做完的子任务\n"
        + "☑ 一条做完的很长的任务，长到一行放不下要折到第二行，看划线和变淡是不是整段都有、行距是不是还一样\n"
        + "☐ 报销单\n- 普通的列表项\n下午三点和设计过一遍首页的改动 plain line。",
      now: now.addingTimeInterval(-120))
    let tasksModel = NotesWindowModel(store: tasks)
    tasksModel.selection = todo.id
    for dark in [false, true] {
      try window("tasks\(dark ? "-dark" : "")", tasksModel, dark: dark)
    }
    for size in Prefs.notesFontSizeChoices where size != 15 {
      let suite = "kitty-snapshot-notes-size-\(UUID().uuidString)"
      let sized = try #require(UserDefaults(suiteName: suite))
      defer { sized.removePersistentDomain(forName: suite) }
      sized.set(size, forKey: Prefs.notesFontSize)
      try snapshot(
        NotesWindowView(model: tasksModel).defaultAppStorage(sized), size: windowSize,
        dark: false, to: "\(out)/notes-window-tasks-\(size).png")
    }

    // 第 6 批：Markdown——标记都藏着的（浅 / 深）、光标所在的行露出标记的（一行、选了几行）、四档字号、
    // 开关关掉的（原样显示，任务照常）、8 种纸色两套各一张（光标在第一行：露出来的标记、引用的竖线、代码的底）
    let markdown = try NoteStore(db: Database(path: ":memory:"))
    let styled = markdown.create(body: Self.markdownSample, now: now.addingTimeInterval(-90))
    let markdownModel = NotesWindowModel(store: markdown)
    markdownModel.selection = styled.id
    let sample = Self.markdownSample as NSString
    for dark in [false, true] {
      let suffix = dark ? "-dark" : ""
      try window("markdown\(suffix)", markdownModel, dark: dark)
      try window(
        "markdown-caret\(suffix)", markdownModel, dark: dark,
        prepare: Self.reveal(NSRange(location: sample.range(of: "粗体").location, length: 0)))
    }
    try window(
      "markdown-selection", markdownModel,
      prepare: Self.reveal(
        NSRange(
          location: sample.range(of: "项目主页").location,
          length: sample.range(of: "第二行引用").location - sample.range(of: "项目主页").location)))
    try window("markdown-heading-caret", markdownModel, prepare: Self.reveal(NSRange()))
    for size in Prefs.notesFontSizeChoices where size != 15 {
      let suite = "kitty-snapshot-notes-markdown-\(UUID().uuidString)"
      let sized = try #require(UserDefaults(suiteName: suite))
      defer { sized.removePersistentDomain(forName: suite) }
      sized.set(size, forKey: Prefs.notesFontSize)
      try snapshot(
        NotesWindowView(model: markdownModel).defaultAppStorage(sized), size: windowSize,
        dark: false, to: "\(out)/notes-window-markdown-\(size).png")
    }
    let plainSuite = "kitty-snapshot-notes-markdown-off-\(UUID().uuidString)"
    let plain = try #require(UserDefaults(suiteName: plainSuite))
    defer { plain.removePersistentDomain(forName: plainSuite) }
    plain.set(false, forKey: Prefs.notesMarkdown)
    try snapshot(
      NotesWindowView(model: markdownModel).defaultAppStorage(plain), size: windowSize,
      dark: false, to: "\(out)/notes-window-markdown-off.png")
    // 8 种预设之后是 4 种自定义的（便签未来计划 B2：浅蓝原样当纸、深蓝提亮、纯红、灰），文件名 custom-0…3
    let customs = [0xC2DFF8, 0x203040, 0xFF0000, 0x808080].map(Note.custom(rgb:))
    for (index, color) in (Array(0..<Note.colorCount) + customs).enumerated() {
      var note = Note(
        id: "纸色\(index)", body: Self.markdownPaperSample, createdAt: now, modifiedAt: now)
      note.color = color
      let name = index < Note.colorCount ? "\(index)" : "custom-\(index - Note.colorCount)"
      for dark in [false, true] {
        try snapshot(
          NoteBodyField(note: note, fontSize: 15, margin: 14, setBody: { _ in }, onOverflow: {})
            .background(NotePaper.of(color: color).paper),
          size: NSSize(width: 330, height: 300), dark: dark,
          to: "\(out)/notes-markdown-paper-\(name)\(dark ? "-dark" : "").png",
          prepare: Self.reveal(NSRange(location: 4, length: 0)))
      }
    }

    // 第 8 批之后的一轮：块格式（标题 1–3、引用、有序 / 无序列表、代码块）和合并成一段的颜色。
    // 「格式」子菜单展开的样子系统菜单在屏外画不出来，改成看正文
    for dark in [false, true] {
      let note = Note(
        id: "合并格式", body: Self.mergedFormatSample, createdAt: now, modifiedAt: now)
      try snapshot(
        NoteBodyField(note: note, fontSize: 15, margin: 14, setBody: { _ in }, onOverflow: {})
          .background(NotePaper.all[0].paper),
        size: NSSize(width: 360, height: 420), dark: dark,
        to: "\(out)/notes-markdown-merged\(dark ? "-dark" : "").png")
    }

    // 第 7 批：行内图片——正文里一张图（浅 / 深）、行内图和字同行、选中带把手、文件找不到的占位框。
    // 图片是测试现画的（输出目录下的 notes-images/，不进仓库）；缩略图第一次画的时候才开始解，所以同一个名字出两次
    // （第一次画的是纸色，第二次才是图）
    let imageDirectory = URL(filePath: "\(out)/notes-images")
    try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
    let imageStore = NoteImageStore(directory: imageDirectory)
    func addImage(_ width: Int, _ height: Int, _ ext: String = "png") throws -> NoteImages.Image {
      let id = UUID()
      let url = imageDirectory.appending(path: "\(id.uuidString).\(ext)")
      try NoteImageFixture.data(type: ext == "png" ? .png : .jpeg, width: width, height: height)
        .write(to: url)
      let size = try #require(NoteImageStore.readSize(at: url))
      let image = NoteImages.Image(id: id, ext: ext, width: nil)
      imageStore.remember(NoteImageStore.Stored(image: image, size: size))
      return image
    }
    let photo = try addImage(600, 300)
    let small = try addImage(160, 120)
    let missing = NoteImages.Image(id: UUID(), ext: "png", width: nil)
    let imageNotes = try NoteStore(db: Database(path: ":memory:"))
    imageNotes.images = imageStore
    let alone = imageNotes.create(
      body: "图片这一行\n\(NoteImages.token(photo))\n图片下面的一行字",
      now: now.addingTimeInterval(-60))
    let inLine = imageNotes.create(
      body:
        // 图和字同一行的**不放在第一行**（2026-10-17 用户真机报：第一行看不出来，往下的图片行上的字被推到行外面）
        "图和字同一行\n前面\(NoteImages.token(NoteImages.Image(id: small.id, ext: small.ext, width: 120)))后面还有字，看图和字是不是坐在同一条基线上\n"
        + "\(NoteImages.token(NoteImages.Image(id: small.id, ext: small.ext, width: 80)))12312323123\n最后一行",
      now: now.addingTimeInterval(-120))
    let broken = imageNotes.create(
      body: "文件找不到的：\n\(NoteImages.token(missing))", now: now.addingTimeInterval(-180))
    let imageModel = NotesWindowModel(store: imageNotes)
    func imageTokenRange(_ body: String) -> NSRange {
      NoteImages.matches(in: body as NSString).first?.range ?? NSRange()
    }
    for dark in [false, true] {
      let suffix = dark ? "-dark" : ""
      imageModel.selection = alone.id
      for _ in 0..<2 { try window("image\(suffix)", imageModel, dark: dark) }
      imageModel.selection = inLine.id
      for _ in 0..<2 { try window("image-inline\(suffix)", imageModel, dark: dark) }
    }
    imageModel.selection = broken.id
    for _ in 0..<2 {
      try window(
        "image-missing", imageModel,
        prepare: { root in
          guard let editor = NotesWindow.editor(in: root),
            let manager = editor.layoutManager, let container = editor.textContainer
          else { return }
          // 这一条便签的正文先排出来（图按行片段宽量尺寸；调试输出已经删掉）
          manager.ensureLayout(for: container)
        })
    }
    // 选中：一圈描边 + 右下角的拖动把手
    imageModel.selection = alone.id
    for _ in 0..<2 {
      // 编辑器里图片就是一个字：存的形式里令牌开头的位置就是那个附件字符的位置
      try window(
        "image-selected", imageModel,
        prepare: Self.reveal(NSRange(location: imageTokenRange(alone.body).location, length: 1)))
    }

    // 2026-10-16 评审后：比正文宽的图（F3：缩到可用宽、不压上一行）、图后面接着打长字折行（F16②：折出来的行
    // 是正文行高）、深色的选中描边和占位框
    let wide = try addImage(1440, 900)
    let wideNote = imageNotes.create(
      body: "宽图这一行\n\(NoteImages.token(wide))\n后面的一行字", now: now.addingTimeInterval(-240))
    let wrapped = imageNotes.create(
      body: "\(NoteImages.token(photo)) " + String(repeating: "图后面接着打的一长串字，", count: 12),
      now: now.addingTimeInterval(-300))
    imageModel.selection = wideNote.id
    for dark in [false, true] {
      let suffix = dark ? "-dark" : ""
      for _ in 0..<2 { try window("image-wide\(suffix)", imageModel, dark: dark) }
    }
    imageModel.selection = wrapped.id
    for _ in 0..<2 { try window("image-wrapped", imageModel) }
    imageModel.selection = alone.id
    try window(
      "image-selected-dark", imageModel, dark: true,
      prepare: Self.reveal(NSRange(location: imageTokenRange(alone.body).location, length: 1)))
    imageModel.selection = broken.id
    for _ in 0..<2 { try window("image-missing-dark", imageModel, dark: true) }
    // 便签未来计划 D2：裁切层（锁 4:3：左右两边压暗）浅深各一、窗口最小时一张
    func crop(_ root: NSView) {
      guard let editor = NotesWindow.editor(in: root), let container = editor.textContainer
      else { return }
      editor.layoutManager?.ensureLayout(for: container)
      editor.beginImageCrop(at: imageTokenRange(alone.body).location)
      editor.imageCrop?.choose(ratioAt: 3)
    }
    imageModel.selection = alone.id
    for dark in [false, true] {
      for _ in 0..<2 {
        try window("image-crop\(dark ? "-dark" : "")", imageModel, dark: dark, prepare: crop)
      }
    }
    for _ in 0..<2 {
      try window("image-crop-min", imageModel, size: NotesWindow.minSize, prepare: crop)
    }

    // 手测反馈第 4 批：行距三档（标题、正文折行、任务、列表、引用、代码块混排；标准档就是 spacing-standard）、
    // 代码块（光标不在块里 / 在块里，浅深）、空的正文的占位和第一个字对齐（placeholder：占位 + 同一个位置打了字的
    // 另一条，两张对着看）
    let mixed = try NoteStore(db: Database(path: ":memory:"))
    let mix = mixed.create(body: Self.spacingSample, now: now.addingTimeInterval(-60))
    let mixModel = NotesWindowModel(store: mixed)
    mixModel.layout = .list
    mixModel.selection = mix.id
    let mixText = Self.spacingSample as NSString
    for spacing in NoteStyles.Spacing.allCases {
      let suite = "kitty-snapshot-notes-spacing-\(UUID().uuidString)"
      let spaced = try #require(UserDefaults(suiteName: suite))
      defer { spaced.removePersistentDomain(forName: suite) }
      spaced.set(spacing.rawValue, forKey: Prefs.notesLineSpacing)
      try snapshot(
        NotesWindowView(model: mixModel).defaultAppStorage(spaced), size: windowSize,
        dark: false, to: "\(out)/notes-window-spacing-\(spacing.rawValue).png")
    }
    for dark in [false, true] {
      let suffix = dark ? "-dark" : ""
      try window("code\(suffix)", mixModel, dark: dark)
      try window(
        "code-caret\(suffix)", mixModel, dark: dark,
        prepare: Self.reveal(NSRange(location: mixText.range(of: "let total").location, length: 0)))
    }
    try window(
      "spacing-heading-caret", mixModel,
      prepare: Self.reveal(NSRange(location: mixText.range(of: "待办").location, length: 0)))
    let placeholder = try NoteStore(db: Database(path: ":memory:"))
    let typed = placeholder.create(body: "写点什么…", title: "打了字的", now: now.addingTimeInterval(-30))
    let empty = placeholder.create(body: "", title: "空的", now: now)
    let placeholderModel = NotesWindowModel(store: placeholder)
    for (name, id) in [("placeholder", empty.id), ("placeholder-typed", typed.id)] {
      placeholderModel.selection = id
      try window(name, placeholderModel)
    }

    // 手测反馈第 3 批：正文的滚动条。系统「根据鼠标或触控板自动」连着鼠标时是常显的老式滚动条：强制成老式的出图。
    // 挂在图层树里的滚动条由系统的图层画，屏外出图拍不到轨道——前后对照另出一张 notes-scroller-legacy-compare：
    // 不挂层的纸上并排画系统原样的老式滚动条（左，改之前：一条浅色的轨道）和 NoteScroller（右，只有滑块）
    let tall = try NoteStore(db: Database(path: ":memory:"))
    let longNote = tall.create(
      body: (1...40).map { "第 \($0) 行：内容超出正文框，右边该有滚动条" }.joined(separator: "\n"),
      title: "很长的一条", now: now.addingTimeInterval(-60))
    let longModel = NotesWindowModel(store: tall)
    longModel.selection = longNote.id
    func legacy() -> (NSView) -> Void {
      { root in
        guard let scroll = NotesWindow.editor(in: root)?.enclosingScrollView else { return }
        scroll.scrollerStyle = .legacy
        scroll.tile()
      }
    }
    for dark in [false, true] {
      try window("scroller-legacy\(dark ? "-dark" : "")", longModel, dark: dark, prepare: legacy())
    }
    for dark in [false, true] where Self.wants("\(out)/notes-scroller-legacy-compare.png") {
      let paper = PaperFill(color: NotePaper.all[0].paperColor)
      paper.frame = NSRect(x: 0, y: 0, width: 100, height: 240)
      paper.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
      for (index, scroller) in [NSScroller(), NoteScroller()].enumerated() {
        scroller.scrollerStyle = .legacy
        scroller.frame = NSRect(
          x: 20 + 45 * CGFloat(index), y: 10,
          width: NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy), height: 220)
        scroller.isEnabled = true
        scroller.knobProportion = 0.3
        scroller.doubleValue = 0.2
        paper.addSubview(scroller)
      }
      let bitmap = try #require(paper.bitmapImageRepForCachingDisplay(in: paper.bounds))
      paper.cacheDisplay(in: paper.bounds, to: bitmap)
      try #require(bitmap.representation(using: .png, properties: [:])).write(
        to: URL(filePath: "\(out)/notes-scroller-legacy-compare\(dark ? "-dark" : "").png"))
    }

    // 带标题栏的真窗口：工具栏只有它有（上面那些是内容区）。摆在屏外，连标题栏一起出图
    model.scope = .all
    for (trash, wall) in [(false, false), (true, false), (false, true)]
    where Self.wants("\(out)/notes-window-toolbar.png")
      || (wall && Self.wants("\(out)/notes-wall-toolbar.png"))
    {
      model.scope = trash ? .trash : .all
      model.layout = wall ? .wall : .list
      let titled = OffscreenTitledWindow(
        contentViewController: .windowContent(NotesWindowView(model: model)))
      titled.title = HotKeyAction.noteAll.title  // 同 NotesWindow.init（标题的桥接要等第一次变化）
      titled.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
      titled.toolbarStyle = .unified
      titled.appearance = NSAppearance(named: .aqua)
      titled.setContentSize(windowSize)
      titled.setFrameOrigin(NSPoint(x: -20000, y: -20000))
      titled.orderFront(nil)
      defer { titled.orderOut(nil) }
      #expect(titled.screen == nil)  // 没被挪进屏幕里
      for _ in 0..<8 { RunLoop.main.run(until: Date.now.addingTimeInterval(0.1)) }
      let frame = try #require(titled.contentView?.superview)
      let bitmap = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
      frame.cacheDisplay(in: frame.bounds, to: bitmap)
      try #require(bitmap.representation(using: .png, properties: [:])).write(
        to: URL(
          filePath: wall
            ? "\(out)/notes-wall-toolbar.png"
            : "\(out)/notes-window-toolbar\(trash ? "-trash" : "").png"))
      // 工具栏上的项：和右键菜单同名
      let labels = titled.toolbar?.items.map(\.label) ?? []
      print("notes toolbar (\(trash ? "trash" : "all")):", labels)
    }

    // 2026-10-15 便签墙（notes-wall-*）：默认的显示方式。卡片高随内容、按宽度排几列（窄 2 / 默认 3 / 宽 5 列）、
    // 固定的一段在前、带任务和 Markdown 的、选中的（中性的选中底、立正）、拖着 / 鼠标停着时抬起来的那一张（单独出：
    // 悬停是追踪区报的，屏外摆不出来）、编辑卡开着（浅深、最近删除里只读的）、空状态、没搜到、8 种纸色两套
    let wallStore = try NoteStore(db: Database(path: ":memory:"))
    wallStore.images = imageStore
    let wallEntries: [(title: String, body: String, ago: TimeInterval)] = [
      ("", "周五前交的东西\n☐ 周报\n☐ 报销单\n☑ 订会议室\n☑ 交房租\n下午三点和设计过一遍首页的改动。", 180),
      ("读书笔记", "「慢慢来，比较快」这句话放在重构上也成立：先把现有的行为用测试钉住，再一小步一小步地挪。", 3600 * 2),
      ("", "wifi 密码 kitty-2026", 3600 * 26),
      (
        "发布清单",
        "## 打包前\n- 改版本号，补**更新日志**\n- 跑一遍 `build-dmg.sh`\n> 不公证，说明里写上「仍要打开」\n```\nmacos/build-dmg.sh\n```\n## 之后\n- 打 tag、传两个文件",
        3600 * 5
      ),
      ("想法", "", 86_400 * 3),
      (
        "", "Groceries: milk, eggs, bread, *two* kinds of cheese and some ~~cookies~~ fruit",
        86_400 * 4
      ),
      (
        "会议纪要 10/14",
        "参加的人：设计、前端、我\n结论：\n1. 首页的卡片改成两列\n2. 搜索框挪到顶上\n3. 下周三之前给出第二版\n剩下的问题：空状态的插画还没定，先用符号顶着；深色模式下的阴影要再看一遍；动效的曲线按现有的几条，不新造。还有一些很长很长的备注写在这里，看它在卡片底下截断渐隐的样子。再多写几行凑一凑高度，再多写几行凑一凑高度。",
        86_400 * 6
      ),
      ("", "一条很长很长的标题，长到卡片上一行放不下，要折到第二行，再长就在第二行末尾用省略号收住，看看是什么样子", 86_400 * 9),
      ("周末", "☐ 洗车\n☐ 买花", 86_400 * 12),
      ("", "电话 138-0000-0000（快递）", 86_400 * 20),
    ]
    for entry in wallEntries.reversed() {
      wallStore.create(
        body: entry.body, title: entry.title, now: now.addingTimeInterval(-entry.ago))
    }
    let wallIDs = wallStore.active.map(\.id)
    wallStore.setPinned(true, of: wallIDs[1])
    wallStore.setPinned(true, of: wallIDs[3])
    func wall(
      _ name: String, _ model: NotesWindowModel, size: NSSize = windowSize, dark: Bool = false
    ) throws {
      model.layout = .wall
      try snapshot(
        NotesWindowView(model: model), size: size, dark: dark, to: "\(out)/notes-wall-\(name).png")
    }
    let wallModel = NotesWindowModel(store: wallStore)
    for dark in [false, true] { try wall(dark ? "dark" : "light", wallModel, dark: dark) }
    // 第 7 批：卡片顶上那张缩略图（单独一面墙：两张卡片都在可见区里）
    let wallImages = try NoteStore(db: Database(path: ":memory:"))
    wallImages.images = imageStore
    wallImages.create(
      body: "这张有图：\n\(NoteImages.token(photo))\n下面还有一行字", now: now)
    wallImages.create(body: "这张没有图\n就是一行普通的字", now: now.addingTimeInterval(-60))
    // 墙卡片那张缩略图先在后台解好：屏外出图时 .task 的那一轮状态更新来不及回来（画的是纸色）
    let scale = NSScreen.main?.backingScaleFactor ?? 2
    let wallPixel = NoteImageThumbnails.pixel(
      for: CGSize(width: NoteWall.textWidth, height: NoteImageLayout.thumbnailMaxHeight),
      scale: scale)
    let wallKey = NoteImageThumbnails.key(photo.id, pixel: wallPixel)
    _ = NoteImageThumbnails.image(
      for: imageStore.url(for: photo.id, ext: photo.ext), id: photo.id, maxPixel: wallPixel,
      ready: {})
    for _ in 0..<200 where NoteImageThumbnails.peek(key: wallKey) == nil {
      RunLoop.main.run(until: Date.now.addingTimeInterval(0.02))
    }
    #expect(NoteImageThumbnails.peek(key: wallKey) != nil, "缩略图该解好了")
    let wallImageModel = NotesWindowModel(store: wallImages)
    for dark in [false, true] {
      // 缩略图在第一次画的时候才开始解：同一个名字出两次，第二次才是图（第一次画的是纸色）
      for _ in 0..<2 { try wall("image\(dark ? "-dark" : "")", wallImageModel, dark: dark) }
    }
    try wall("narrow", wallModel, size: NSSize(width: 720, height: 420))
    try wall("wide", wallModel, size: NSSize(width: 1280, height: 760))
    try wall("wide-dark", wallModel, size: NSSize(width: 1280, height: 760), dark: true)
    wallModel.selection = wallIDs[6]
    try wall("selected", wallModel)
    // 拖着 / 鼠标停着：立正、放大一点、往上抬、阴影加深
    for dark in [false, true] where Self.wants("\(out)/notes-wall-lifted.png") {
      let note = try #require(wallStore.note(wallIDs[0]))
      let card = wallStore.wallCard(of: note, markdown: true)
      try snapshot(
        HStack(spacing: 40) {
          WallCard(
            note: note, card: card, summary: wallStore.summary(of: note), tilt: -1.6,
            isSelected: false, isDragged: false
          )
          .frame(width: NoteWall.cardWidth, height: card.height)
          WallCard(
            note: note, card: card, summary: wallStore.summary(of: note), tilt: -1.6,
            isSelected: false, isDragged: true
          )
          .frame(width: NoteWall.cardWidth, height: card.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor)),
        size: NSSize(width: 600, height: card.height + 80), dark: dark,
        to: "\(out)/notes-wall-lifted\(dark ? "-dark" : "").png")
    }
    // 编辑卡开着：后面一层暗、中央是列表右栏那一套编辑区
    wallModel.open(wallIDs[3], focus: false)
    for dark in [false, true] { try wall("open\(dark ? "-dark" : "")", wallModel, dark: dark) }
    try wall("open-narrow", wallModel, size: NSSize(width: 720, height: 420))
    wallModel.collapse()
    // 最近删除：卡片只读，打开的编辑卡也是，右下角「放回」「永久删除…」
    wallStore.delete(wallIDs[5], now: now.addingTimeInterval(-3600))
    wallStore.delete(wallIDs[8], now: now.addingTimeInterval(-86_400 * 3))
    wallModel.scope = .trash
    try wall("trash", wallModel)
    wallModel.open(wallIDs[5], focus: false)
    try wall("trash-open", wallModel)
    wallModel.scope = .all
    wallModel.query = "找不到的词"
    try wall("search-empty", wallModel)
    wallModel.query = ""
    try wall("empty", NotesWindowModel(store: try NoteStore(db: Database(path: ":memory:"))))
    // 8 种纸色两套：每种一张
    let papers = try NoteStore(db: Database(path: ":memory:"))
    for (index, paper) in NotePaper.all.enumerated().reversed() {
      let note = papers.create(
        body: "\(paper.name)色的便签\n☐ 一条任务\n☑ 做完的任务\n**粗体** 和 `代码`\n> 一行引用",
        now: now.addingTimeInterval(-Double(index) * 600))
      papers.setColor(index, of: note.id, now: now.addingTimeInterval(-Double(index) * 600))
    }
    for dark in [false, true] {
      try wall(
        "papers\(dark ? "-dark" : "")", NotesWindowModel(store: papers),
        size: NSSize(width: 1080, height: 640), dark: dark)
    }

    // 第 8 批：任务的五种状态、六种文字颜色（浅 / 深、叠在粗体 / 链接 / 引用 / 标题里、光标那一行露出标记）、
    // 便签墙卡片上的颜色和状态
    let states = try NoteStore(db: Database(path: ":memory:"))
    let five = states.create(
      body:
        "周五前交的东西\n☐ 待办\n◧ 进行中\n▣ 紧急\n☑ 完成（划掉、变淡）\n☒ 取消（划掉、变淡）\n"
        + "☐ 一个很长很长的任务，长到一行放不下要折到第二行，看方框和后面的字是不是还对得齐",
      title: "五种状态", now: now.addingTimeInterval(-120))
    let stateModel = NotesWindowModel(store: states)
    stateModel.selection = five.id
    for dark in [false, true] {
      try window("states\(dark ? "-dark" : "")", stateModel, dark: dark)
    }
    let colorful = states.create(
      body:
        "[红]{red} [橙]{orange} [绿]{green} [蓝]{blue} [紫]{purple} [灰]{gray}\n"
        + "[**粗体也红**]{red} [[链接也蓝](https://a.b)]{blue} [引用里的绿]{green}\n"
        + "# [标题里的紫]{purple}\n> [引用里的橙]{orange} 和普通字\n"
        + "默认颜色的字",
      title: "文字颜色", now: now.addingTimeInterval(-60))
    let colorModel = NotesWindowModel(store: states)
    colorModel.selection = colorful.id
    for dark in [false, true] {
      try window("colors\(dark ? "-dark" : "")", colorModel, dark: dark)
    }
    // 光标在上了色的那一行：`[` 和 `]{red}` 露出来（屏外的窗口不当 key，直接告诉编辑器）
    try window(
      "colors-caret", colorModel,
      prepare: Self.reveal(
        NSRange(
          location: (colorful.body as NSString).range(of: "红").location, length: 0)))
    let stateWallModel = NotesWindowModel(store: states)
    stateWallModel.layout = .wall
    stateWallModel.selection = five.id
    try snapshot(
      NotesWindowView(model: stateWallModel), size: NSSize(width: 940, height: 640), dark: false,
      to: "\(out)/notes-wall-colors-states.png")

    // 8 种纸色两套并排：纸、色条、墨、次要的字、圆点
    for dark in [false, true] {
      try snapshot(
        NotePaperProbe(), size: NSSize(width: 880, height: 150), dark: dark,
        to: "\(out)/notes-papers\(dark ? "-dark" : "").png")
    }

    // MARK: 设置、快捷键、速查表、启动器
    let navigation = SettingsNavigation(defaults: nil)  // 换页不写用户的偏好
    let hotKeys = HotKeyCenter()
    let settings = SettingsRoot(navigation: navigation) { page in
      page == .hotkeys
        ? AnyView(HotkeysTab(center: hotKeys))
        : AnyView(NotesTab(openNotes: {}, notes: { states }))
    } onboarding: {
      AnyView(EmptyView())
    }
    navigation.page = .notes
    for dark in [false, true] {
      try snapshot(
        settings, size: NSSize(width: 780, height: 600), dark: dark,
        to: "\(out)/notes-settings\(dark ? "-dark" : "").png")
    }
    try snapshot(
      settings, size: NSSize(width: 700, height: 460), dark: false,
      to: "\(out)/notes-settings-min.png")
    // 第 8 批：「数据」那组的两行导出 / 导入（便签能用时按钮才亮；窗口拉高看全）
    try snapshot(
      SettingsRoot(navigation: navigation) { page in
        page == .hotkeys
          ? AnyView(HotkeysTab(center: hotKeys))
          : AnyView(NotesTab(openNotes: {}, notes: { states }))
      } onboarding: {
        AnyView(EmptyView())
      },
      size: NSSize(width: 640, height: 1320), dark: false,
      to: "\(out)/notes-settings-data.png")
    navigation.page = .hotkeys
    try snapshot(
      settings, size: NSSize(width: 780, height: 1120), dark: false,
      to: "\(out)/notes-settings-hotkeys.png")
    // 速查表从便签页点开：停在便签那一类（默认大小的 sheet，另出一张拉长的看全四组）
    let sheetHeight = ShortcutsButton.sheetHeight(available: 600 - 52)
    for (name, height, dark) in [
      ("shortcuts", sheetHeight, false), ("shortcuts-dark", sheetHeight, true),
      ("shortcuts-full", 3200, false),
    ] {
      try snapshot(
        ShortcutsSheet(page: .notes), size: NSSize(width: ShortcutsSheet.width, height: height),
        dark: dark, to: "\(out)/notes-\(name).png")
    }
    let launcher = LauncherModel(
      usage: try LauncherUsage(db: Database(path: ":memory:")), apps: [])
    launcher.boundHotKey = { $0.defaultHotKey }
    launcher.engines = { [] }
    launcher.query = "便签"
    for dark in [false, true] {
      try snapshot(
        LauncherPanelView(model: launcher),
        size: NSSize(width: 720, height: LauncherPanelView.height(for: launcher)), dark: dark,
        to: "\(out)/notes-launcher\(dark ? "-dark" : "").png")
    }
  }

  /// 便签第 3 批「屏幕边缘那叠」（文件名都以 notes-deck- 开头；只跑这一个函数约一分钟）：药丸（1 / 6 / 20 条，左右两边）、
  /// 扇出的一列（两种样式 × 三档大小、「+N」和它展开后、固定的、长标题和中英混排、鼠标停着的、左边、深色）、预览卡、
  /// 打开的便签（四种大小、浅深、左边、固定、操作菜单和颜色那一级、打到上限、空白的）、设置 › 便签「屏幕边缘」一组
  /// （总开关开和关、深色、只有一块屏），另有一张全部便签窗口（编辑区抽成共用件之后和第 2 批的图逐像素对）；
  /// 第 6 批 Markdown：打开的便签（open-markdown*：标记藏着的 / 光标行露着的，浅深、左边特大）、预览卡和标签上
  /// 不带标记的标题（preview-markdown）
  @Test(.enabled(if: directory != nil)) func notesDeck() throws {
    let out = try #require(Self.directory)
    try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    Prefs.registerDefaults()
    let now = Date.now
    typealias Entry = (title: String, body: String, ago: TimeInterval)
    // 和 notes() 里那 6 条一样（全部便签窗口那张图要和第 2 批的对得上）
    let six: [Entry] = [
      ("", "周五前交的东西\n☐ 周报\n☐ 报销单\n☑ 订会议室\n下午三点和设计过一遍首页的改动，记得带上数据。", 180),
      ("读书笔记", "「慢慢来，比较快」这句话放在重构上也成立：先把现有的行为用测试钉住，再一小步一小步地挪。", 3600 * 2),
      ("", "wifi 密码 kitty-2026", 3600 * 26),
      ("想法", "", 86_400 * 3),
      ("", "一条很长很长的标题，长到列表里的这一行放不下，后面要用省略号收住，看它和右边的时间挤不挤在一起", 86_400 * 9),
      ("", "Groceries: milk, eggs, bread", 86_400 * 40),
    ]
    func library(_ entries: [Entry]) throws -> (store: NoteStore, ids: [String]) {
      let store = try NoteStore(db: Database(path: ":memory:"))
      // 倒着建：新建的排最前，建完就是 entries 的顺序；颜色接着轮
      for entry in entries.reversed() {
        store.create(body: entry.body, title: entry.title, now: now.addingTimeInterval(-entry.ago))
      }
      return (store, store.active.map(\.id))
    }
    func many(_ count: Int) -> [Entry] {
      (1...count).map { ("第 \($0) 条", "内容 \($0)", Double($0) * 60) }
    }

    // MARK: 药丸（图层画的：放在一块灰底上出图，贴着它那一侧）
    for (name, count, edge, hidden) in [
      ("1", 1, NoteDeckOptions.Edge.right, false), ("6", 6, .right, false),
      ("20", 20, .right, false), ("6-left", 6, .left, false), ("6-large", 6, .right, false),
      ("hidden", 6, .right, true),
    ] where Self.wants("\(out)/notes-deck-pill-\(name).png") {
      var options = NoteDeckOptions()
      options.hidesPill = hidden
      if name == "6-large" { options.size = .large }
      let far = NoteDeckScreen(
        name: "", frame: CGRect(x: -30000, y: -30000, width: 1440, height: 900),
        visibleFrame: CGRect(x: -30000, y: -30000, width: 1440, height: 875))
      let pill = NoteDeckPill()
      let frame = NoteDeckLayout.pillFrame(on: far, edge: edge, count: count, options: options)
      pill.update(
        frame: frame, edge: edge, colors: (0..<count).map { $0 % Note.colorCount },
        options: options)
      let size = NSSize(width: 60, height: frame.height + 24)
      let backdrop = NSView(frame: NSRect(origin: .zero, size: size))
      backdrop.wantsLayer = true
      backdrop.layer?.backgroundColor = NSColor(white: 0.55, alpha: 1).cgColor
      let view = try #require(pill.panel.contentView)
      view.frame.origin = NSPoint(x: edge == .right ? size.width - frame.width : 0, y: 12)
      backdrop.addSubview(view)
      try renderLayers(
        backdrop, size: size, dark: false, configure: { _ in },
        to: "\(out)/notes-deck-pill-\(name).png")
    }

    // MARK: 那叠（透明的面板：垫一块像桌面的底出图）
    func deck(
      _ name: String, _ store: NoteStore, options: NoteDeckOptions = NoteDeckOptions(),
      edge: NoteDeckOptions.Edge = .right, dark: Bool = false, height: CGFloat = 860,
      setup: (NoteDeckModel) -> Void = { _ in }, prepare: ((NSView) -> Void)? = nil
    ) throws {
      let screen = NoteDeckScreen(
        name: "", frame: CGRect(x: 0, y: 0, width: 1440, height: height + 25),
        visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: height))
      let frame = NoteDeckLayout.panelFrame(on: screen, edge: edge, options: options)
      let pill = NoteDeckLayout.pillFrame(
        on: screen, edge: edge, count: store.active.count, options: options)
      let model = NoteDeckModel(store: store)
      model.options = options
      model.edge = edge
      model.panelSize = frame.size
      model.pillCenter = frame.maxY - pill.midY
      model.setRevealed(true)
      model.send(.pillEntered(optionDown: false, allowed: true))
      setup(model)
      try snapshot(
        NoteDeckView(model: model).background(Color(white: dark ? 0.22 : 0.80)),
        size: frame.size, dark: dark, to: "\(out)/notes-deck-\(name).png", prepare: prepare)
    }
    let (store, ids) = try library(six)
    store.setPinned(true, of: ids[1])
    for style in NoteDeckOptions.TabStyle.allCases {
      for size in NoteDeckOptions.Size.allCases {
        var options = NoteDeckOptions()
        options.style = style
        options.size = size
        try deck("fan-\(style.rawValue)-\(size.rawValue)", store, options: options)
      }
    }
    try deck("fan-dark", store, dark: true)
    try deck("fan-left", store, edge: .left)
    var quiet = NoteDeckOptions()
    quiet.showsPreview = false
    try deck("fan-hover", store, options: quiet) { $0.hover(ids[2], true) }
    var chips = NoteDeckOptions()
    chips.style = .chips
    try deck("fan-chips-dark", store, options: chips, dark: true)
    // 中英混排、表情、很短的标题；一条的时候
    let mixed = try library([
      ("买 milk 和 eggs", "", 60), ("🙂 周末", "", 120), ("TODO", "", 180), ("2026 计划 v2", "", 240),
      ("好", "", 300),
    ])
    mixed.store.setPinned(true, of: mixed.ids[0])
    mixed.store.setPinned(true, of: mixed.ids[4])
    try deck("fan-mixed", mixed.store)
    var large = NoteDeckOptions()
    large.size = .large
    try deck("fan-mixed-large", mixed.store, options: large)
    try deck("fan-one", try library(many(1)).store)
    // 「+N」和它展开之后（30 条放不下：在视口里滚）；矮屏幕上压短
    let thirty = try library(many(30)).store
    try deck("fan-more", thirty)
    try deck("fan-all", thirty) { $0.send(.showAll) }
    try deck("fan-all-chips", thirty, options: chips) { $0.send(.showAll) }
    try deck("fan-short-screen", store, height: 600)
    try deck("fan-tiny-screen", store, height: 380)
    // 拖着第一张往下挪过两格：别的让位
    try deck("fan-dragging", store) { model in
      let step = model.layout.step
      model.dragChanged(ids[0], by: step * 1.7)
    }

    // 预览卡
    try deck("preview", store) { $0.setPreview(ids[1]) }
    try deck("preview-dark", store, dark: true) { $0.setPreview(ids[0]) }
    try deck("preview-blank-left", store, edge: .left) { $0.setPreview(ids[3]) }
    try deck("preview-last", store) { $0.setPreview(ids[4]) }

    // 打开的便签：四种大小、浅深、左边
    for size in NoteDeckOptions.NoteSize.allCases {
      var options = NoteDeckOptions()
      options.noteSize = size
      try deck("open-\(size.rawValue)", store, options: options) { $0.tapTab(ids[0]) }
    }
    try deck("open-dark", store, dark: true) { $0.tapTab(ids[1]) }
    try deck("open-left", store, edge: .left) { $0.tapTab(ids[2]) }
    try deck("open-left-dark", store, edge: .left, dark: true) { $0.tapTab(ids[4]) }
    try deck("open-pinned", store) { $0.tapTab(ids[1]) }
    try deck("open-blank", store) { $0.tapTab(ids[3]) }
    try deck("open-last", store) { $0.tapTab(ids[4]) }
    try deck("open-chips", store, options: chips) { $0.tapTab(ids[2]) }
    var bigDeck = NoteDeckOptions()
    bigDeck.size = .large
    bigDeck.noteSize = .large
    try deck("open-large-deck", store, options: bigDeck) { $0.tapTab(ids[1]) }
    try deck("open-menu", store) { model in
      model.tapTab(ids[1])
      model.toggleMenu()
    }
    try deck("open-menu-dark", store, dark: true) { model in
      model.tapTab(ids[0])
      model.toggleMenu()
    }
    try deck("open-menu-colors", store) { model in
      model.tapTab(ids[0])
      model.toggleMenu(fromDot: true)
    }
    try deck("open-menu-colors-left", store, edge: .left) { model in
      model.tapTab(ids[2])
      model.toggleMenu()
      model.run(model.menuItems[1])
    }
    try deck("open-over-limit", store) { model in
      model.tapTab(ids[0])
      model.overflowed()
    }
    try deck("open-short-screen", store, height: 360) { $0.tapTab(ids[0]) }
    // 第 7 批：行内图片——标签 / 预览卡上写「[图片]」，打开的便签里按图画（浅深各一次；缩略图第一次画时才解，
    // 同一个名字出两次，第二次才是图）
    let deckImageDirectory = URL(filePath: "\(out)/notes-images")
    try FileManager.default.createDirectory(
      at: deckImageDirectory, withIntermediateDirectories: true)
    let deckImages = NoteImageStore(directory: deckImageDirectory)
    let photoID = UUID()
    let photoURL = deckImageDirectory.appending(path: "\(photoID.uuidString).png")
    try NoteImageFixture.data(type: .png, width: 480, height: 240).write(to: photoURL)
    let photo = NoteImages.Image(id: photoID, ext: "png", width: nil)
    deckImages.remember(
      NoteImageStore.Stored(
        image: photo, size: try #require(NoteImageStore.readSize(at: photoURL))))
    let withImage = try library([
      ("", "这张有图：\n\(NoteImages.token(photo))\n下面还有一行字", 60),
      ("", "没有图的一条", 120),
    ])
    withImage.store.images = deckImages
    try deck("image-preview", withImage.store) { $0.setPreview(withImage.ids[0]) }
    // 整条便签只有一张图：标签和预览卡上写「[图片]」（第一行是图时标题取不到别的字）
    let onlyImage = try library([
      ("", "\(NoteImages.token(photo))", 60),
      ("", "没有图的一条", 120),
    ])
    onlyImage.store.images = deckImages
    try deck("image-tab", onlyImage.store) { $0.setPreview(onlyImage.ids[0]) }
    var imageDeck = NoteDeckOptions()
    imageDeck.noteSize = .extraLarge
    for dark in [false, true] {
      for _ in 0..<2 {
        try deck(
          "image-open\(dark ? "-dark" : "")", withImage.store, options: imageDeck, dark: dark
        ) { $0.tapTab(withImage.ids[0]) }
      }
    }
    // 便签开着时点「+N」：列出全部，便签留在原处
    try deck("open-all", thirty) { model in
      model.tapTab(model.tabs[1].id)
      model.send(.showAll)
    }
    // 没存上（把表挪走，之后的写都失败）：底下那行小字换成警告；全部便签窗口同一份
    let broken = try Database(path: ":memory:")
    let unsaved = try NoteStore(db: broken)
    let stuck = unsaved.create(body: "这几个字还没落下盘", title: "没存上的便签")
    try broken.execute("ALTER TABLE notes RENAME TO parked")
    unsaved.setPinned(true, of: stuck.id)
    #expect(unsaved.saveProblem != nil)
    try deck("open-unsaved", unsaved) { $0.tapTab(stuck.id) }
    try snapshot(
      NotesWindowView(model: Self.listModel(unsaved)),
      size: NSSize(width: 940, height: 580), dark: false, to: "\(out)/notes-deck-window-unsaved.png"
    )
    // 预览卡：只有一行字的便签（标题就是它）不另写「没有更多内容」；「+N」三四位数不折行
    let oneLine = try library([
      ("", "只有这一行字，稍微长一点，看它在预览卡里折到第二行第三行是什么样子，再长就截断了", 60),
      ("自己起的标题", "", 120),
    ])
    try deck("preview-title-only", oneLine.store) { $0.setPreview(oneLine.ids[0]) }
    try deck("preview-titled-blank", oneLine.store) { $0.setPreview(oneLine.ids[1]) }
    try deck("fan-more-thousands", try library(many(1205)).store)

    // 第 5 批：打开的便签里的任务（没做完 / 做完的、缩进、长行）、头部的「任务」钮、操作菜单里的「任务」，
    // 预览卡上的进度
    let todo = try library([
      (
        "",
        "周五前交的东西\n☐ 周报\n☑ 订会议室\n  ☐ 缩进的子任务\n☑ 一条做完的很长的任务，长到一行放不下要折到第二行\n☐ 报销单\n普通的一行",
        60
      ),
      ("全做完的", "☑ 一\n☑ 二", 120),
    ])
    for dark in [false, true] {
      try deck("open-tasks\(dark ? "-dark" : "")", todo.store, dark: dark) {
        $0.tapTab(todo.ids[0])
      }
    }
    try deck("open-tasks-menu", todo.store) { model in
      model.tapTab(todo.ids[0])
      model.toggleMenu()
    }
    try deck("preview-tasks", todo.store) { $0.setPreview(todo.ids[0]) }
    try deck("preview-tasks-done-dark", todo.store, dark: true) { $0.setPreview(todo.ids[1]) }

    // 第 8 批：那叠里打开的便签里有五种状态和六种颜色
    let colorsDeck = try library([
      (
        "",
        "☐ 待办\n◧ 进行中\n▣ 紧急\n☑ 完成\n☒ 取消\n[红]{red} [蓝]{blue} 普通",
        60
      )
    ])
    for dark in [false, true] {
      try deck("open-colors\(dark ? "-dark" : "")", colorsDeck.store, dark: dark) {
        $0.tapTab(colorsDeck.ids[0])
      }
    }

    // 第 6 批：打开的便签里的 Markdown——标记都藏着的（刚打开、还没当 key 的样子；浅 / 深、左边、特大）、
    // 光标所在的行露出标记的；标签和预览卡上的标题、摘要不带标记
    let written = try library([
      ("", Self.markdownSample, 60), ("", "**粗体的** 第一行 `code`\n- [链接](https://a.b) 的字", 120),
    ])
    for dark in [false, true] {
      let suffix = dark ? "-dark" : ""
      try deck("open-markdown\(suffix)", written.store, dark: dark) { $0.tapTab(written.ids[0]) }
      try deck(
        "open-markdown-caret\(suffix)", written.store, dark: dark,
        setup: { $0.tapTab(written.ids[0]) },
        prepare: Self.reveal(
          NSRange(
            location: (Self.markdownSample as NSString).range(of: "粗体").location, length: 0)))
    }
    var roomy = NoteDeckOptions()
    roomy.noteSize = .extraLarge
    try deck("open-markdown-xl-left", written.store, options: roomy, edge: .left) {
      $0.tapTab(written.ids[0])
    }
    try deck("preview-markdown", written.store) { $0.setPreview(written.ids[1]) }

    // MARK: 设置 › 便签「屏幕边缘」
    let onSuite = "kitty-snapshot-notes-deck-on-\(UUID().uuidString)"
    let offSuite = "kitty-snapshot-notes-deck-off-\(UUID().uuidString)"
    let on = try #require(UserDefaults(suiteName: onSuite))
    let off = try #require(UserDefaults(suiteName: offSuite))
    defer {
      on.removePersistentDomain(forName: onSuite)
      off.removePersistentDomain(forName: offSuite)
    }
    off.set(false, forKey: Prefs.notesDeckEnabled)
    let displays = ["内建视网膜显示器", "DELL U2720Q"]
    let tabSize = NSSize(width: 640, height: 1320)
    for dark in [false, true] {
      try snapshot(
        NotesTab(openNotes: {}, displays: displays).defaultAppStorage(on), size: tabSize,
        dark: dark, to: "\(out)/notes-deck-settings\(dark ? "-dark" : "").png")
    }
    try snapshot(
      NotesTab(openNotes: {}, displays: displays).defaultAppStorage(off), size: tabSize,
      dark: false, to: "\(out)/notes-deck-settings-off.png")
    on.set(true, forKey: Prefs.notesDeckAlwaysFanned)
    on.set(true, forKey: Prefs.notesDeckOpensOnHover)
    on.set("chosen", forKey: Prefs.notesDeckDisplay)
    on.set(displays[1], forKey: Prefs.notesDeckChosenDisplay)
    try snapshot(
      NotesTab(openNotes: {}, displays: displays).defaultAppStorage(on), size: tabSize,
      dark: false, to: "\(out)/notes-deck-settings-always.png")
    try snapshot(
      NotesTab(openNotes: {}, displays: ["内建视网膜显示器"]).defaultAppStorage(off),
      size: tabSize, dark: false, to: "\(out)/notes-deck-settings-one-display.png")

    // 全部便签窗口：编辑区抽成了两边共用的（Notes/NoteFields.swift），样子不该变——和第 2 批的 notes-window-list.png 对
    try snapshot(
      NotesWindowView(model: Self.listModel(store)), size: NSSize(width: 940, height: 580),
      dark: false, to: "\(out)/notes-deck-window-check.png")
  }

  /// 便签第 4 批「浮动便签」（文件名都以 notes-float- 开头；只跑这一个函数约半分钟）：浮动便签本身——和那叠里打开的
  /// 便签是同一个视图（NoteSheet），所以这里看的是它铺满一扇窗口时的样子：浅深、固定 / 没固定、8 种纸色两套（都在
  /// 最小尺寸上）、拉大、标签在右边（那叠在左边缘时）、标签宽一档、操作菜单和颜色那一级（平时的大小、最小尺寸时在
  /// 菜单里滚）、屏幕边缘没有那叠时菜单里那一项的名字、带任务和 Markdown 的、空白的；那叠里浮着那条的标签上的记号、
  /// 被拖出去的那一刻那叠的样子；设置 › 便签页脚的那句话。
  /// 浮动便签是单独的窗口，阴影是系统画的（图里没有）：出图时四周垫一圈灰底，看得见圆角和描边
  @Test(.enabled(if: directory != nil)) func notesFloat() throws {
    let out = try #require(Self.directory)
    try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    Prefs.registerDefaults()
    let now = Date.now
    typealias Entry = (title: String, body: String, ago: TimeInterval)
    func library(_ entries: [Entry]) throws -> (store: NoteStore, ids: [String]) {
      let store = try NoteStore(db: Database(path: ":memory:"))
      for entry in entries.reversed() {
        store.create(body: entry.body, title: entry.title, now: now.addingTimeInterval(-entry.ago))
      }
      return (store, store.active.map(\.id))
    }
    let notes: [Entry] = [
      ("", "周五前交的东西\n☐ 周报\n☐ 报销单\n☑ 订会议室\n下午三点和设计过一遍首页的改动，记得带上数据。", 180),
      ("读书笔记", "「慢慢来，比较快」这句话放在重构上也成立：先把现有的行为用测试钉住，再一小步一小步地挪。", 3600 * 2),
      ("", "wifi 密码 kitty-2026", 3600 * 26),
      ("想法", "", 86_400 * 3),
      ("", "一条很长很长的标题，长到列表里的这一行放不下，后面要用省略号收住，看它和右边的时间挤不挤在一起", 86_400 * 9),
      ("", "Groceries: milk, eggs, bread", 86_400 * 40),
      ("", Self.markdownSample, 86_400 * 41),
      ("买 milk 和 eggs", "第八种纸色", 86_400 * 42),
    ]
    let (store, ids) = try library(notes)
    store.setPinned(true, of: ids[1])
    let medium = NoteDeckOptions.NoteSize.medium.size
    let minimum = NoteFloatLayout.minSize

    // MARK: 浮动便签（一扇窗口那么大；四周垫 24 的灰底）
    func float(
      _ name: String, _ id: String, size: CGSize = medium, dark: Bool = false,
      onLeading: Bool = true, scale: CGFloat = 1, edgeShown: Bool = true,
      setup: (NoteFloatModel) -> Void = { _ in }, prepare: ((NSView) -> Void)? = nil
    ) throws {
      let model = NoteFloatModel(store: store)
      model.tabOnLeading = onLeading
      model.metrics = NoteDeckMetrics(scale: scale)
      model.edgeShown = edgeShown
      model.send(.float(id))
      setup(model)
      let margin: CGFloat = 24
      try snapshot(
        NoteFloatView(model: model).frame(width: size.width, height: size.height).padding(margin)
          .background(Color(white: dark ? 0.22 : 0.80)),
        size: NSSize(width: size.width + 2 * margin, height: size.height + 2 * margin),
        dark: dark, to: "\(out)/notes-float-\(name).png", prepare: prepare)
    }
    for dark in [false, true] {
      let suffix = dark ? "-dark" : ""
      try float("open\(suffix)", ids[0], dark: dark)
      try float("pinned\(suffix)", ids[1], dark: dark)
      // 8 种纸色，都拉到最小：头部的圆点、标题、四个钮排得下，正文和小字还在
      for (index, id) in ids.enumerated() {
        try float("paper-\(index)\(suffix)", id, size: minimum, dark: dark)
      }
      try float("menu\(suffix)", ids[1], dark: dark) { $0.toggleMenu() }
    }
    try float("large", ids[0], size: CGSize(width: 680, height: 560))
    try float("tall-narrow", ids[4], size: CGSize(width: minimum.width, height: 520))
    try float("wide-short", ids[1], size: CGSize(width: 700, height: minimum.height))
    try float("tab-right", ids[2], onLeading: false)
    try float("tab-right-dark", ids[1], dark: true, onLeading: false) { $0.toggleMenu() }
    try float("tab-wide", ids[1], scale: 1.25)
    try float("tab-narrow-min", ids[4], size: minimum, scale: 0.85)
    try float("blank", ids[3])
    // 操作菜单：屏幕边缘没有那叠时那一项叫「取消浮动」；颜色那一级（从「⋯」进、从圆点点开）
    try float("menu-no-edge", ids[0], edgeShown: false) { $0.toggleMenu() }
    try float("menu-colors", ids[0]) { model in
      model.toggleMenu()
      model.run(model.menuItems[1])
    }
    try float("menu-dot", ids[2]) { $0.toggleMenu(fromDot: true) }
    // 最小尺寸时的菜单：放不下的在菜单里滚，不出便签；标签最宽那一档时颜色菜单也在便签里
    try float("min-menu", ids[1], size: minimum) { $0.toggleMenu() }
    try float("min-menu-dark", ids[0], size: minimum, dark: true) { $0.toggleMenu() }
    try float("min-menu-dot-wide-tab", ids[2], size: minimum, scale: 1.25) {
      $0.toggleMenu(fromDot: true)
    }
    try float("min-menu-tab-right", ids[2], size: minimum, onLeading: false) { $0.toggleMenu() }
    try float("over-limit", ids[0]) { $0.overflowed() }
    // 自定义纸色（便签未来计划 B2 / B4）：推出来的纸、色条、墨，深浅各一；颜色那一级多一节自定义的和「其他颜色…」
    let custom = store.create(body: "挑的浅色就是纸本身\n☐ 待办\n☑ 做完\n> 引用", now: now)
    for (index, rgb) in [0xC2DFF8, 0x203040, 0xFF0000, 0x808080].enumerated() {
      store.setColor(Note.custom(rgb: rgb), of: custom.id)
      try float("custom-\(index)", custom.id)
      try float("custom-\(index)-dark", custom.id, dark: true)
    }
    try float("menu-custom-colors", custom.id) { model in
      model.recentColors = { [0xFFE0F0, 0xB4E8D0] }
      model.toggleMenu(fromDot: true)
    }
    // 截完删掉：后面那叠的几张图用的是同一个库，别让它多出一张标签
    store.erase(custom.id)
    // 裁切层（便签未来计划 D2）在最小的浮动便签里：底下那一排（比例、取消、完成）排得下，图按剩下的地方放。
    // 图是现画的（输出目录下的 notes-images/）；缩略图第一次画的时候才开始解，所以出两次。截完同样删掉
    let cropDirectory = URL(filePath: "\(out)/notes-images")
    try FileManager.default.createDirectory(at: cropDirectory, withIntermediateDirectories: true)
    let cropImages = NoteImageStore(directory: cropDirectory)
    store.images = cropImages
    let cropPhoto = NoteImages.Image(id: UUID(), ext: "png", width: nil)
    let cropURL = cropImages.url(for: cropPhoto.id, ext: "png")
    try NoteImageFixture.data(type: .png, width: 480, height: 240).write(to: cropURL)
    cropImages.remember(
      .init(image: cropPhoto, size: try #require(NoteImageStore.readSize(at: cropURL))))
    let cropNote = store.create(body: "\(NoteImages.token(cropPhoto))\n裁切", now: now)
    for _ in 0..<2 {
      try float(
        "crop-min", cropNote.id, size: minimum,
        prepare: { root in
          guard let editor = NotesWindow.editor(in: root), let container = editor.textContainer
          else { return }
          editor.layoutManager?.ensureLayout(for: container)
          editor.beginImageCrop(at: 0)
          editor.imageCrop?.choose(ratioAt: 2)
        })
    }
    store.erase(cropNote.id)
    store.images = nil
    // 带 Markdown 的：标记都藏着的、光标所在的行露着的（屏外的窗口不真的当 key，直接告诉编辑器）
    try float("markdown", ids[6], size: CGSize(width: 520, height: 460))
    try float(
      "markdown-caret-dark", ids[6], size: CGSize(width: 520, height: 460), dark: true,
      prepare: Self.reveal(
        NSRange(location: (Self.markdownSample as NSString).range(of: "粗体").location, length: 0)))

    // MARK: 那叠这边：浮着那条的标签上的记号（色条色的竖条，不探出来）；被拖出去的那一刻（那一份看不见、标签缩回去）
    func deck(
      _ name: String, options: NoteDeckOptions = NoteDeckOptions(),
      edge: NoteDeckOptions.Edge = .right, dark: Bool = false,
      setup: (NoteDeckModel) -> Void
    ) throws {
      let screen = NoteDeckScreen(
        name: "", frame: CGRect(x: 0, y: 0, width: 1440, height: 885),
        visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 860))
      let frame = NoteDeckLayout.panelFrame(on: screen, edge: edge, options: options)
      let pill = NoteDeckLayout.pillFrame(
        on: screen, edge: edge, count: store.active.count, options: options)
      let model = NoteDeckModel(store: store)
      model.options = options
      model.edge = edge
      model.panelSize = frame.size
      model.pillCenter = frame.maxY - pill.midY
      model.setRevealed(true)
      model.send(.pillEntered(optionDown: false, allowed: true))
      setup(model)
      try snapshot(
        NoteDeckView(model: model).background(Color(white: dark ? 0.22 : 0.80)),
        size: frame.size, dark: dark, to: "\(out)/notes-float-deck-\(name).png")
    }
    try deck("tab") { $0.floated([ids[2]]) }
    // 同时浮几张（便签未来计划 C）：两条标签都带竖条
    try deck("tab-two") { $0.floated([ids[1], ids[2]]) }
    try deck("tab-left-dark", edge: .left, dark: true) { $0.floated([ids[1]]) }
    var chips = NoteDeckOptions()
    chips.style = .chips
    try deck("tab-chips", options: chips) { $0.floated([ids[2]]) }
    // 浮着一条的同时在那叠里开着另一条
    try deck("tab-with-open") { model in
      model.floated([ids[2]])
      model.tapTab(ids[0])
    }
    // 被拖出去的那一刻：它在那叠里的那一份看不见了（还在视图树里），它的标签缩回去、带着「浮着」的记号
    try deck("lifted") { model in
      model.tapTab(ids[0])
      model.gripChanged(at: CGPoint(x: 900, y: 500))
      model.gripChanged(at: CGPoint(x: 800, y: 500))
      model.floated([ids[0]])
    }

    // MARK: 设置 › 便签「屏幕边缘」页脚多的那句话
    let suite = "kitty-snapshot-notes-float-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try snapshot(
      NotesTab(openNotes: {}, displays: ["内建视网膜显示器"]).defaultAppStorage(defaults),
      size: NSSize(width: 640, height: 1320), dark: false, to: "\(out)/notes-float-settings.png")
  }

  private func renderTranslate(_ out: String) throws {
    // 历史：今天两条（一条收藏）、昨天一条、三天前两条，按天分组
    let history = try HistoryStore(db: Database(path: ":memory:"))
    let day: TimeInterval = 86_400
    let samples: [(String, String, Lang, TimeInterval, Bool)] = [
      ("The quick brown fox jumps over the lazy dog", "敏捷的棕色狐狸跳过了懒狗", .zhHans, 60, false),
      ("会议纪要", "Meeting minutes", .en, 120, true),
      ("serendipity", "意外发现珍奇事物的本领", .zhHans, day, true),
      ("Ship it", "发布吧", .zhHans, day * 3, false),
      ("请帮我 review 一下这个 PR", "Please help me review this PR", .en, day * 3 + 60, false),
    ]
    for (source, result, target, ago, favorite) in samples {
      history.restore(
        .init(
          id: UUID(), source: source, target: target, result: result, service: "智谱",
          createdAt: .now.addingTimeInterval(-ago), favorite: favorite))
    }
    // 读用户的服务列表来画，但传进去的一份不写回偏好（画的时候输入框会把绑定写一遍）
    let services = TranslateServiceStore(services: TranslateServiceStore().services)
    let coordinator = TranslateCoordinator(services: services, history: history)
    let speaker = Speaker()
    let zhipu = TranslateService.zhipu
    var gpt = TranslateService.newAI()
    gpt.name = "GPT-4o mini"
    gpt.model = "gpt-4o-mini"
    var claude = TranslateService.newAI()
    claude.name = "Claude"
    claude.aiProtocol = .anthropic
    var deepseek = TranslateService.newAI()
    deepseek.name = "DeepSeek"
    deepseek.model = "deepseek-chat"
    let states: [(String, (TranslateCoordinator) -> Void)] = [
      ("translate-empty", { _ in }),
      (
        "translate-cards",
        { c in
          c.sourceText =
            "SwiftUI provides views, controls, and layout structures for declaring your app's user interface."
          c.detected = .en
          c.target = .zhHans
          c.translatedSource = c.sourceText
          c.cards = [
            .init(service: zhipu, state: .done("SwiftUI 提供了视图、控件和布局结构，用来**声明**应用的用户界面。")),
            .init(service: gpt, state: .running("SwiftUI 提供视图、控件以及")),
            .init(service: claude, state: .failed(.config("密钥无效或没有权限"))),
          ]
        }
      ),
      // 体检第 4 批：思考中（骨架上的「思考中」扫光）、截断（正文 + 一行说明）、配置类（橙、只给打开设置）、
      // 网络 / 服务类（红、重试；自建 AI 另给打开设置）
      (
        "translate-card-states",
        { c in
          c.sourceText = "Explain the difference between a process and a thread."
          c.detected = .en
          c.target = .zhHans
          c.translatedSource = c.sourceText
          c.cards = [
            .init(service: zhipu, state: .running("")),
            .init(service: gpt, state: .truncated("进程是操作系统分配资源的基本单位，线程是 CPU 调度的基本单位。一个进程可以包含多个线程")),
            .init(service: claude, state: .failed(.config("App ID 或密钥不对"))),
            .init(service: .builtin(.baidu), state: .failed(TranslateError(message: "请求太频繁，稍后再试"))),
            .init(
              service: deepseek,
              state: .failed(TranslateError(message: "连不上服务地址", kind: .network))),
          ]
        }
      ),
      // 划词没取到文字：占位换成说明（体检 A16）
      ("translate-missed-selection", { c in c.beginInput(missedSelection: true) }),
      // 原文改过、还没重译：原文框右下角弹出「翻译 ↩」
      (
        "translate-edited",
        { c in
          c.sourceText = "SwiftUI provides views and controls."
          c.translatedSource = "SwiftUI provides views."
          c.detected = .en
          c.target = .zhHans
          c.cards = [.init(service: zhipu, state: .done("SwiftUI 提供视图。"))]
        }
      ),
      (
        "translate-replace",
        { c in
          c.sourceText = "Ship it"
          c.detected = .en
          c.target = .zhHans
          c.translatedSource = c.sourceText
          c.replaceSource = TranslateCoordinator.ReplaceSource(text: "Ship it", pid: 1)
          c.cards = [
            .init(service: zhipu, state: .done("发布吧")), .init(service: gpt, state: .done("上线")),
          ]
        }
      ),
      (
        "translate-word",
        { c in
          c.sourceText = "run"
          c.translatedSource = c.sourceText
          c.detected = .en
          c.target = .zhHans
          c.dictionary = WordLookup.parse(WordLookupTests.run, query: "run")
          c.cards = [
            .init(
              service: zhipu,
              state: .done(
                "美 /rʌn/ 英 /rʌn/\nv. 跑；运转；经营；竞选\nn. 跑步；一段时间；连续\n例：I run every morning. 我每天早上跑步。")
            )
          ]
        }
      ),
      (
        "translate-history",
        { c in
          c.sourceText = "serendipity"
          c.translatedSource = c.sourceText
          c.showsHistory = true
          c.historyList.select(c.historyList.entries[2])
        }
      ),
      (
        "translate-history-favorites",
        { c in
          c.showsHistory = true
          c.historyList.favoritesOnly = true
        }
      ),
      // 历史 ⌘K（体检 C6）：第一级、进了「导出 ›」的子列表
      (
        "translate-history-menu",
        { c in
          c.showsHistory = true
          c.historyList.select(c.historyList.entries[1])
          c.historyList.showsActions = true
        }
      ),
      (
        "translate-history-menu-export",
        { c in
          c.showsHistory = true
          c.historyList.showsActions = true
          c.historyList.actionSelection = 5
          _ = c.handleHistoryCommand(#selector(NSResponder.insertNewline(_:)))
        }
      ),
      ("translate-notice", { c in c.showNotice("划词翻译需要「辅助功能」授权", permission: .accessibility) }),
      ("translate-screenshot-empty", { c in c.showNotice("没有识别到文字，可以把选区框大一些再试") }),
    ]
    for dark in [false, true] {
      for (name, configure) in states {
        coordinator.beginInput()
        configure(coordinator)
        // 焦点像 present() 那样给原文框（焦点环）；历史开着时焦点在它自己抢走的搜索框
        try snapshot(
          TranslatePanelView(coordinator: coordinator, speaker: speaker)
            .background { if !coordinator.showsHistory { InitialFocusProbe() } },
          size: NSSize(width: 420, height: name == "translate-card-states" ? 720 : 560), dark: dark,
          to: "\(out)/\(name)\(dark ? "-dark" : "").png")
      }
    }
    // 卡片表面（体检 B17）：降低透明度时卡片底 windowBackground 0.9、错误卡仍是红底；增强对比度时描边 1 pt
    let cardsState = try #require(states.first { $0.0 == "translate-cards" }).1
    for dark in [false, true] {
      coordinator.beginInput()
      cardsState(coordinator)
      try snapshot(
        TranslatePanelView(coordinator: coordinator, speaker: speaker)
          .environment(\._accessibilityReduceTransparency, true),
        size: NSSize(width: 420, height: 560), dark: dark,
        to: "\(out)/translate-cards-reduce-transparency\(dark ? "-dark" : "").png")
      try snapshot(
        TranslatePanelView(coordinator: coordinator, speaker: speaker)
          .environment(\._colorSchemeContrast, .increased),
        size: NSSize(width: 420, height: 560), dark: dark,
        to: "\(out)/translate-cards-contrast\(dark ? "-dark" : "").png")
    }
    // 长译文：每张卡正文最多 8 行、在卡片里滚动（完成的从开头看、底部渐隐；生成中的跟着末尾）；
    // 字号 140% 再拍一张，看上限跟着字号走。浮窗高度按内容估的（屏外拿不到 resize 回调）
    let long = """
      SwiftUI 用声明式的方式描述界面：你只需要写出界面在某个状态下应该是什么样子，状态一变，框架就会自动更新对应的视图。\
      视图是轻量的值类型，组合起来很便宜，所以可以放心地把大界面拆成许多小视图。\
      布局由父视图提议尺寸、子视图自己决定大小，再由父视图摆放位置，三步走完。
      数据流方面，@State 管视图自己的状态，@Binding 把状态的读写权交给子视图，@Observable 的模型对象则在多个视图之间共享；\
      只有真正读到的属性变化时，视图才会重新计算。动画可以挂在某个值上，也可以用 withAnimation 包住一次状态修改。\
      在 macOS 上，SwiftUI 还能和 AppKit 混用：NSHostingView 把 SwiftUI 视图放进 AppKit 窗口，NSViewRepresentable 反过来把 AppKit 视图包进 SwiftUI。
      """
    coordinator.beginInput()
    coordinator.sourceText =
      "SwiftUI lets you describe your interface declaratively: say what it should look like for a state, and the framework keeps it up to date."
    coordinator.translatedSource = coordinator.sourceText
    coordinator.detected = .en
    coordinator.target = .zhHans
    coordinator.cards = [
      .init(service: zhipu, state: .done(long)),
      .init(service: gpt, state: .running(String(long.prefix(long.count * 3 / 4)))),
    ]
    let largeName = "KittyToolsSnapshot.\(UUID().uuidString)"
    let large = try #require(UserDefaults(suiteName: largeName))
    defer { large.removePersistentDomain(forName: largeName) }
    large.set(1.4, forKey: Prefs.translateFontScale)
    for dark in [false, true] {
      let suffix = dark ? "-dark" : ""
      try snapshot(
        TranslatePanelView(coordinator: coordinator, speaker: speaker),
        size: NSSize(width: 420, height: 640), dark: dark,
        to: "\(out)/translate-long\(suffix).png")
      try snapshot(
        TranslatePanelView(coordinator: coordinator, speaker: speaker).defaultAppStorage(large),
        size: NSSize(width: 420, height: 760), dark: dark,
        to: "\(out)/translate-long-large\(suffix).png")
    }
    // 复制即译开着（顶栏品牌粉状态胶囊）+ 固定（粉色图钉）：偏好放进临时的 suite，不碰 dev 版的真实设置
    let suiteName = "KittyToolsSnapshot.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: suiteName))
    defer { suite.removePersistentDomain(forName: suiteName) }
    suite.set(true, forKey: Prefs.translateCopyToTranslate)
    suite.set(true, forKey: Prefs.floatingPinned)
    coordinator.beginInput()
    coordinator.sourceText = "Copy anything and it translates itself."
    coordinator.translatedSource = coordinator.sourceText
    coordinator.detected = .en
    coordinator.target = .zhHans
    coordinator.cards = [.init(service: zhipu, state: .done("复制任何内容，它都会自己翻译。"))]
    // 空历史：另一个空库
    let empty = TranslateCoordinator(
      services: services, history: try HistoryStore(db: Database(path: ":memory:")))
    empty.showsHistory = true
    for dark in [false, true] {
      let suffix = dark ? "-dark" : ""
      try snapshot(
        TranslatePanelView(coordinator: coordinator, speaker: speaker).defaultAppStorage(suite),
        size: NSSize(width: 420, height: 360), dark: dark,
        to: "\(out)/translate-copy-to-translate\(suffix).png")
      // 拖到最窄 360：两个胶囊一起收掉「自动」标签
      try snapshot(
        TranslatePanelView(coordinator: coordinator, speaker: speaker).defaultAppStorage(suite),
        size: NSSize(width: 360, height: 200), dark: dark,
        to: "\(out)/translate-copy-to-translate-narrow\(suffix).png")
      try snapshot(
        TranslatePanelView(coordinator: empty, speaker: speaker),
        size: NSSize(width: 420, height: 560), dark: dark,
        to: "\(out)/translate-history-empty\(suffix).png")
    }
    // 服务身份：官方 logo（满版 / 垫白底）和还没有 logo 的色块首字母，18 pt 一排 + 36 pt 一排
    var gemini = TranslateService.newAI()
    gemini.name = "Gemini"
    // 第 13 批的各家厂商（按名字认）
    let vendors = AIVendor.allCases.filter { ![.zhipu, .gemini, .anthropic, .openai].contains($0) }
      .map { vendor in
        var service = TranslateService.newAI()
        service.name = vendor.rawValue
        return service
      }
    let everyService =
      TranslateService.Kind.allCases.filter { $0 != .ai }.map(TranslateService.builtin) + [
        claude, gemini, gpt,
      ] + vendors
    let tiles = VStack(alignment: .leading, spacing: 12) {
      ForEach([18.0, 36.0], id: \.self) { size in
        HStack(spacing: size / 2) {
          ForEach(everyService, id: \.id) { ServiceTile(service: $0, size: size) }
        }
      }
    }
    .padding(16)
    for dark in [false, true] {
      try snapshot(
        tiles, size: NSSize(width: 1180, height: 110), dark: dark,
        to: "\(out)/translate-logos\(dark ? "-dark" : "").png")
    }
  }

  /// 设置 › 启动器的假浏览器数据（临时目录当主目录）：Safari 书签 plist + History.db、Chrome 书签 JSON + History、
  /// Firefox places.sqlite；Arc 只有空的数据目录（没有书签文件）
  static func fakeBrowserHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory.appending(
      path: "kitty-snapshot-browsers-\(UUID().uuidString)")
    let support = home.appending(path: "Library/Application Support")
    let directories = [
      "Library/Safari", "Library/Application Support/Google/Chrome/Default",
      "Library/Application Support/Arc/User Data/Default",
      "Library/Application Support/Firefox/Profiles/x.default-release",
    ]
    for directory in directories {
      try FileManager.default.createDirectory(
        at: home.appending(path: directory), withIntermediateDirectories: true)
    }
    let leaves = [
      ("Apple", "https://www.apple.com/"), ("Swift", "https://swift.org/"),
      ("WWDC", "https://developer.apple.com/wwdc/"),
    ].map {
      ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": $1, "URIDictionary": ["title": $0]]
    }
    try PropertyListSerialization.data(
      fromPropertyList: ["WebBookmarkType": "WebBookmarkTypeList", "Children": leaves],
      format: .binary, options: 0
    ).write(to: home.appending(path: "Library/Safari/Bookmarks.plist"))
    try BrowsersTests.makeSafariHistory(
      Database(path: home.appending(path: "Library/Safari/History.db").path))
    let json = """
      {"roots": {"bookmark_bar": {"type": "folder", "children": [
        {"type": "url", "name": "GitHub", "url": "https://github.com/"},
        {"type": "url", "name": "linux.do", "url": "https://linux.do/"}]}}}
      """
    try Data(json.utf8).write(to: support.appending(path: "Google/Chrome/Default/Bookmarks"))
    let history = try Database(path: support.appending(path: "Google/Chrome/Default/History").path)
    try history.execute(
      "CREATE TABLE urls(url LONGVARCHAR, title LONGVARCHAR, visit_count INTEGER, typed_count INTEGER, last_visit_time INTEGER, hidden INTEGER)"
    )
    for index in 0..<3 {
      try history.execute(
        "INSERT INTO urls VALUES (?, 'x', 2, 0, ?, 0)",
        ["https://example.com/\(index)", 13_435_000_000_000_000 + index])
    }
    try BrowsersTests.makeFirefoxPlaces(
      Database(
        path: support.appending(path: "Firefox/Profiles/x.default-release/places.sqlite").path))
    return home
  }

  /// 截图自检用的假网站图标：圆角色块里一个字母（不读本机浏览器）
  /// 假的官网图标（128 px）：有底色 = 满版方块，没有 = 透明底上一个品牌色字母
  private static func fakeSiteIcon(_ letter: String, background: NSColor?) -> CGImage {
    let image = NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
      if let background {
        background.setFill()
        rect.fill()
      }
      let text = NSAttributedString(
        string: letter,
        attributes: [
          .font: NSFont.systemFont(ofSize: 96, weight: .heavy),
          .foregroundColor: background == nil ? NSColor.systemIndigo : NSColor.white,
        ])
      let size = text.size()
      text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
      return true
    }
    var rect = NSRect(x: 0, y: 0, width: 128, height: 128)
    return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
  }

  private static func fakeFavicon(_ letter: String, _ color: NSColor) -> NSImage {
    NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
      color.setFill()
      NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7).fill()
      let text = NSAttributedString(
        string: letter,
        attributes: [
          .font: NSFont.systemFont(ofSize: 20, weight: .bold), .foregroundColor: NSColor.white,
        ])
      let size = text.size()
      text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
      return true
    }
  }

  /// 启动器：空查询的收藏 + 常用（底栏种类 + 主动作 ↩ + 操作 ⌘K）、⌘K 动作菜单（App、网址）、搜索结果（中文名 / 拼音）、
  /// 没有结果、cb / fy 那一行、选中的内置动作带全局快捷键键帽、中文输入法打的算式、底栏「已从常用中移除 · 撤销」；
  /// 文件搜索（结果、最近的文件、find 按住 ⌘、只输 1 个字母、文件的 ⌘K，结果是假的、不查 Spotlight）；深浅色
  private func renderLauncher(_ out: String) async throws {
    let usage = try LauncherUsage(db: Database(path: ":memory:"))
    let apps = [
      "/System/Applications/Calculator.app", "/System/Applications/Utilities/Activity Monitor.app",
      "/System/Applications/Utilities/Terminal.app", "/System/Applications/Notes.app",
      "/System/Applications/System Settings.app",
    ].map(AppCatalog.item(path:))
    let model = LauncherModel(usage: usage, apps: apps)
    model.boundHotKey = { $0.defaultHotKey }  // 不读本机设置，键帽固定是默认键
    // 「用 X 打开」：固定两个浏览器 / 两个编辑器（不问本机的 LaunchServices）；fy 的释义固定一句
    model.browsers = {
      ["/Applications/Safari.app", "/Applications/Google Chrome.app"].map { URL(filePath: $0) }
    }
    model.applications = { _ in
      [
        (URL(filePath: "/System/Applications/TextEdit.app"), true),
        (URL(filePath: "/System/Applications/Preview.app"), false),
      ]
    }
    model.lookUp = { _ in "used as a greeting or to begin a phone conversation" }
    let linux = LauncherItem(
      kind: .url, target: "https://linux.do/latest", title: "linux.do/latest", subtitle: "")
    for (item, times) in [(apps[1], 3), (linux, 5), (LauncherItem.actions()[0], 1), (apps[2], 2)] {
      for _ in 0..<times { usage.record(item, query: "") }
    }
    // 收藏：备忘录、linux.do（空查询上面一组「收藏」，下面「常用」补足）
    usage.toggleFavorite(apps[3])
    usage.toggleFavorite(linux)
    for dark in [false, true] {
      for (name, query) in [
        ("launcher-recent", ""), ("launcher-search", "huo"), ("launcher-empty", "zzzz"),
        ("launcher-calc", "12*3+1"), ("launcher-calc-cn", "（1,299+1）×3"),
        ("launcher-prompt", "gh"), ("launcher-alternate", "swift ui"), ("launcher-actions", ""),
        ("launcher-actions-url", ""), ("launcher-actions-short", "截图"),
        ("launcher-cb", "cb 发票抬头"), ("launcher-hotkey", "截图"), ("launcher-fy", "fy hello"),
        // 内置动作里的「暂停记录剪贴板」（和菜单栏同一份：剪贴板家族色、副标题写开没开）
        ("launcher-builtins", "剪贴板"),
      ] {
        model.query = query
        await model.definitionLookup()
        model.alternate = name == "launcher-alternate" ? .control : .none
        // 动作菜单那张选中「常用」里的 App（有 ⌘↩ ⌘C ⇥ ⌘D ⌘⌫ 这些替代动作），url 那张选中收藏的网址；
        // short 那张看面板撑高到放得下菜单
        if name == "launcher-actions" { model.selection = 2 }
        if name == "launcher-actions-url" { model.selection = 1 }
        model.showsActions = name.hasPrefix("launcher-actions")
        try snapshot(
          LauncherPanelView(model: model),
          size: NSSize(width: 720, height: LauncherPanelView.height(for: model)),
          dark: dark,
          to: "\(out)/\(name)\(dark ? "-dark" : "").png")
      }
      // 「常用」里 ⌘⌫ 移除一项：底栏换成「已从常用中移除 · 撤销 ⌘Z」，拍完撤回
      model.query = ""
      model.selection = 3
      if let item = model.selectedItem { model.forget(item) }
      try snapshot(
        LauncherPanelView(model: model),
        size: NSSize(width: 720, height: LauncherPanelView.height(for: model)), dark: dark,
        to: "\(out)/launcher-notice-undo\(dark ? "-dark" : "").png")
      model.undoForget()
      // 有新版本（2026-10-06）：底栏种类后面常驻「更新到 x」
      try snapshot(
        LauncherPanelView(model: model).environment(try Self.pendingUpdate()),
        size: NSSize(width: 720, height: LauncherPanelView.height(for: model)), dark: dark,
        to: "\(out)/launcher-update\(dark ? "-dark" : "").png")
    }
    let home = NSHomeDirectory()
    func hit(_ path: String, _ type: String, daysAgo: Double) -> FileSearch.Hit {
      FileSearch.Hit(
        path: home + path, name: (path as NSString).lastPathComponent, contentType: type,
        date: .now.addingTimeInterval(-daysAgo * 86_400))
    }
    let found = [
      hit("/Documents/工作/季度报告汇总.md", "net.daringfireball.markdown", daysAgo: 1),
      hit("/Documents/报告", "public.folder", daysAgo: 3),
      hit("/Downloads/年度报告 2025.pdf", "com.adobe.pdf", daysAgo: 2),
      hit("/Desktop/报告模板.key", "com.apple.keynote.key", daysAgo: 9),
      hit(
        "/Library/Mobile Documents/com~apple~CloudDocs/周报/2026/09/第 39 周工作报告（终版）.docx",
        "org.openxmlformats.wordprocessingml.document", daysAgo: 5),
    ]
    let recent = [
      hit("/Downloads/Kitty Tools_0.1.0_arm64.dmg", "com.apple.disk-image-udif", daysAgo: 0),
      hit("/Downloads/report.html", "public.html", daysAgo: 1),
      hit("/Desktop/notes.md", "net.daringfireball.markdown", daysAgo: 2),
      hit("/Documents/Projects", "public.folder", daysAgo: 4),
    ]
    for dark in [false, true] {
      for (name, query, hits) in [
        ("launcher-files", "open 报告", found), ("launcher-files-recent", " ", recent),
        ("launcher-files-find", "find 报告", found), ("launcher-files-short", "open a", []),
        ("launcher-files-actions", "open 报告", found),
      ] {
        model.query = query
        // 最近的文件那张带上最后一行的授权提示
        model.folderHint =
          name == "launcher-files-recent" ? FileSearch.accessHint(denied: nil) : nil
        if let request = model.fileRequest, !request.isTooShort {
          model.showFiles(hits, for: request)
        }
        model.alternate = name == "launcher-files-find" ? .command : .none
        // 文件的 ⌘K：快速查看、打开方式（默认的标「默认」）、移到废纸篓（体检 C7）
        model.showsActions = name == "launcher-files-actions"
        try snapshot(
          LauncherPanelView(model: model),
          size: NSSize(width: 720, height: LauncherPanelView.height(for: model)),
          dark: dark,
          to: "\(out)/\(name)\(dark ? "-dark" : "").png")
      }
    }
    // 系统命令：固定命令（screen 搜到屏保 / 锁屏）、上膛（清倒废纸篓按了一下）、quit 的补全提示、
    // quit 列正在运行的 App（按住 ⌘ 看强制退出）、eject 列宗卷。执行是默认的空 perform，不会真做
    model.folderHint = nil
    model.commandTargets = { verb in
      verb == .eject
        ? [
          LauncherItem(
            kind: .path, target: "/Volumes/Kitty Tools", title: "Kitty Tools",
            subtitle: "/Volumes/Kitty Tools", contentType: .volume)
        ]
        : [apps[3], apps[0], apps[2]]
    }
    for dark in [false, true] {
      for (name, query) in [
        ("launcher-system", "screen"), ("launcher-system-armed", "emptytrash"),
        ("launcher-quit-prompt", "quit"), ("launcher-quit", "quit "),
        ("launcher-quit-force", "quit "),
        ("launcher-eject", "eject "),
      ] {
        model.query = query
        if name == "launcher-system-armed", let first = model.results.first { model.execute(first) }
        model.alternate = name == "launcher-quit-force" ? .command : .none
        try snapshot(
          LauncherPanelView(model: model),
          size: NSSize(width: 720, height: LauncherPanelView.height(for: model)),
          dark: dark,
          to: "\(out)/\(name)\(dark ? "-dark" : "").png")
      }
    }
    model.alternate = .none
    try await renderLauncherBatch6(out, usage: usage, apps: apps)
    try renderLauncherFollow(out)
  }

  /// 第 10 批：结果多时连按 ↓ 列表跟着滚。40 行结果，窗口出来后逐下按 ↓ 到第 30 行（每下只隔 0.03 s，比滚动动画短：
  /// 以前会有窗口停在半路，见 ListReveal 的补滚），出图时第 30 行（「项目 31」）完整在列表里、带高亮，底下留一格内缩；
  /// 再按 ↑ 回到第 0 行：列表回到顶部。reset：按到第 30 行后输入没有结果的词（列表换成「没有匹配」）再改回来，
  /// 重建的列表从顶上开始、第 0 行带高亮（评审：ScrollPosition 在面板上，不复位会停在旧 y）
  private func renderLauncherFollow(_ out: String) throws {
    let apps = (1...40).map { index in
      LauncherItem(
        kind: .app, target: "/Applications/项目 \(index).app", title: "项目 \(index)",
        subtitle: "", names: [LauncherMatch.fold("项目 \(index)"), "xiangmu"])
    }
    let model = LauncherModel(
      usage: try LauncherUsage(db: Database(path: ":memory:")), apps: apps)
    model.boundHotKey = { $0.defaultHotKey }
    // 没有搜索引擎：搜不到时没有网页搜索兜底行，列表整个换成「没有匹配」（reset 要的就是这个）
    model.engines = { [] }
    func press(_ selector: Selector, times: Int) {
      for _ in 0..<times {
        _ = model.handleCommand(selector)
        RunLoop.main.run(until: Date.now.addingTimeInterval(0.03))
      }
      RunLoop.main.run(until: Date.now.addingTimeInterval(0.8))
    }
    for dark in [false, true] {
      for (name, up) in [
        ("launcher-follow", 0), ("launcher-follow-top", 30), ("launcher-follow-reset", 0),
      ] {
        model.query = ""
        model.query = "xiangmu"
        try snapshot(
          LauncherPanelView(model: model),
          size: NSSize(width: 720, height: LauncherPanelView.height(for: model)), dark: dark,
          to: "\(out)/\(name)\(dark ? "-dark" : "").png"
        ) { _ in
          press(#selector(NSResponder.moveDown(_:)), times: 30)
          press(#selector(NSResponder.moveUp(_:)), times: up)
          guard name == "launcher-follow-reset" else { return }
          model.query = "zqzqzq"
          #expect(model.results.isEmpty)
          RunLoop.main.run(until: Date.now.addingTimeInterval(0.3))
          model.query = "xiangmu"
          RunLoop.main.run(until: Date.now.addingTimeInterval(0.8))
        }
      }
    }
  }

  /// 体检第 6 批：单位换算 / 进制 / 千分位（带 ⌘K 的复制项）、系统设置面板、浏览历史（排在用过的网址后面，网站图标是
  /// 开头摆的假图）、kill 列后台进程（按端口、⌘↩ 上膛）、port 列在监听的端口（补全提示、按端口号筛、⌘↩ 上膛）。
  /// 进程、历史都是注入的，不跑 ps、不读 Chrome
  private func renderLauncherBatch6(_ out: String, usage: LauncherUsage, apps: [LauncherItem])
    async throws
  {
    usage.record(
      LauncherItem(kind: .url, target: "https://github.com/", title: "GitHub", subtitle: ""),
      query: "")
    let model = LauncherModel(usage: usage, apps: apps + AppCatalog.panes())
    model.boundHotKey = { $0.defaultHotKey }
    model.historyItems = {
      BrowserHistory.items([
        .init(
          url: "https://github.com/trending", title: "Trending repositories on GitHub today",
          visitedAt: .now - 7200),
        .init(
          url: "https://github.com/apple/swift/pulls", title: "Pull requests · apple/swift",
          visitedAt: .now - 3 * 86_400),
        .init(
          url: "https://developer.mozilla.org/en-US/docs/Web/CSS/grid",
          title: "grid - CSS: Cascading Style Sheets | MDN", visitedAt: .now - 86_400),
      ])
    }
    let home = NSHomeDirectory()
    model.processTargets = { verb in
      let node = "/opt/homebrew/bin/node"
      guard verb == .port else {
        return Processes.items(
          [
            .init(pid: 4321, memory: 312 << 20, path: node),
            .init(pid: 5173, memory: 180 << 20, path: node),
            .init(
              pid: 902, memory: 96 << 20, path: "/Users/me/.pyenv/versions/3.12.4/bin/python3.12"
            ),
            .init(
              pid: 1474, memory: 64 << 20,
              path: "/Applications/Clash Verge.app/Contents/MacOS/clash-verge"),
            .init(pid: 387, memory: 8 << 20, path: "/usr/sbin/cfprefsd"),
          ], ports: [4321: [3000], 5173: [5173], 902: [8000, 8001]], excluding: [])
      }
      // 三个同名的 node 靠工作目录分开；控制中心的工作目录是根目录（不写）；微信是程序坞里的 App（装了就是它的图标）
      return Processes.portItems(
        [
          .init(pid: 4321, memory: 0, path: node), .init(pid: 5173, memory: 0, path: node),
          .init(pid: 5190, memory: 0, path: node),
          .init(pid: 902, memory: 0, path: "/Users/me/.pyenv/versions/3.12.4/bin/python3.12"),
          .init(
            pid: 417, memory: 0,
            path: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter"),
          .init(
            pid: 621, memory: 0,
            path: "/Applications/Postgres.app/Contents/Versions/18/bin/postgres"),
          .init(pid: 1885, memory: 0, path: "/Applications/WeChat.app/Contents/MacOS/WeChat"),
        ],
        ports: [
          4321: [3000], 5173: [5173], 5190: [5174], 902: [8000], 417: [5000, 7000], 621: [5432],
          1885: [14013],
        ],
        directories: [
          4321: home + "/Codes/class-reunion/apps/server",
          5173: home + "/Codes/class-reunion/apps/web",
          5190: home + "/Codes/class-reunion/apps/admin", 902: home + "/Codes/notes-api",
          417: "/", 621: home + "/Library/Application Support/Postgres/var-18",
        ], apps: [1885: .init(path: "/Applications/WeChat.app", name: "微信")])
    }
    for dark in [false, true] {
      for (name, query) in [
        ("launcher-units", "10 km to mi"), ("launcher-units-cn", "30 摄氏度 转 华氏度"),
        ("launcher-radix", "255 in hex"), ("launcher-calc-group", "1234567*3"),
        ("launcher-actions-calc", "0xff+1"), ("launcher-settings", "蓝牙"),
        ("launcher-settings-privacy", "yinsi"), ("launcher-history", "git"),
        ("launcher-kill", "kill "), ("launcher-kill-port", "kill :3000"),
        ("launcher-kill-force", "kill no"), ("launcher-port-prompt", "port"),
        ("launcher-port", "port "), ("launcher-port-filter", "port 5"),
        ("launcher-port-force", "port 3000"), ("launcher-port-app", "port 微信"),
      ] {
        model.query = query
        await model.processLookup()
        model.showsActions = name == "launcher-actions-calc"
        if ["launcher-kill-force", "launcher-port-force"].contains(name),
          let first = model.results.first
        {
          model.commandReturn(first)
        }
        try snapshot(
          LauncherPanelView(model: model),
          size: NSSize(width: 720, height: LauncherPanelView.height(for: model)),
          dark: dark,
          to: "\(out)/\(name)\(dark ? "-dark" : "").png")
      }
    }
  }

  /// 框选遮罩：截图翻译的待选（整屏轻暗 + 提示）和拖动中（选区外变暗），截图的悬停窗口 + 放大镜、拖动中（尺寸）、
  /// 调整（手柄 + 工具栏，深浅色）。图层要在窗口里显示过才有内容，所以放进屏外窗口再 render
  private func renderSelection(_ out: String) throws {
    let frozen = try ScreenshotTests.render([
      "The quick brown fox jumps over the lazy dog", "敏捷的棕色狐狸跳过了懒狗", "日本語のテキスト",
    ])
    let translate: [(String, (SelectionView) -> Void)] = [
      ("select-idle", { _ in }),
      ("select-drag", { $0.selection = CGRect(x: 10, y: 95, width: 440, height: 60) }),
      // 翻译 / 识字的放大镜：只有格子，没有色值那张卡（2026-10-26）
      ("select-loupe", { $0.mouse = CGPoint(x: 300, y: 110) }),
    ]
    for (name, configure) in translate {
      try renderLayers(
        SelectionView(
          image: frozen,
          session: SelectionSession(mode: .quick, hint: "拖动框选要翻译的文字　Esc 取消")),
        size: NSSize(width: 600, height: 180), dark: false, configure: configure,
        to: "\(out)/\(name).png")
    }
    let desktop = try ScreenshotTests.render([
      "Finder  File  Edit  View", "The quick brown fox jumps over the lazy dog", "敏捷的棕色狐狸跳过了懒狗",
      "日本語のテキスト", "한국어 텍스트", "Привет мир", "Hello World", "#3478F6",
    ])
    let windows = [
      CGRect(x: 40, y: 250, width: 360, height: 130), CGRect(x: 0, y: 0, width: 600, height: 480),
    ]
    let selection = CGRect(x: 60, y: 200, width: 300, height: 150)
    // 四种标注各一个，选中蓝色箭头（样式栏显示它的颜色和粗细），当前工具是矩形
    let annotate: (SelectionView) -> Void = { view in
      view.select(selection)
      let arrow = Annotation(
        shape: .arrow(from: CGPoint(x: 240, y: 230), to: CGPoint(x: 330, y: 300)),
        style: .init(color: .blue, weight: .medium))
      view.annotations = [
        Annotation(shape: .rectangle(CGRect(x: 76, y: 282, width: 130, height: 40))),
        Annotation(shape: .mosaic(CGRect(x: 70, y: 206, width: 150, height: 34))),
        Annotation(
          shape: .text("看这里", origin: CGPoint(x: 230, y: 345)),
          style: .init(color: .red, weight: .large)),
        arrow,
      ]
      view.tool = .rectangle
      view.selectedAnnotation = arrow.id
    }
    let capture: [(String, Bool, (SelectionView) -> Void)] = [
      ("capture-hover", false, { $0.mouse = CGPoint(x: 150, y: 330) }),
      (
        "capture-crosshair", false,
        {
          $0.mouse = CGPoint(x: 150.4, y: 330.6)
          if let command = NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 55)
          {
            $0.flagsChanged(with: command)
          }
        }
      ),
      (
        "capture-draw", false,
        {
          $0.selection = selection
          $0.mouse = CGPoint(x: selection.maxX, y: selection.minY)
        }
      ),
      ("capture-adjust", false, { $0.select(selection) }),
      ("capture-adjust-dark", true, { $0.select(selection) }),
      ("capture-annotate", false, annotate),
      ("capture-annotate-dark", true, annotate),
      (
        "capture-text", false,
        {
          $0.select(selection)
          $0.tool = .text
          $0.beginEditing(at: CGPoint(x: 90, y: 340))
          ($0.window?.firstResponder as? NSTextView)?.insertText(
            "输入中的文字", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
      ),
    ]
    for (name, dark, configure) in capture {
      try renderLayers(
        SelectionView(
          image: desktop, windows: windows,
          session: SelectionSession(mode: .capture, lastRegion: .zero)),
        size: NSSize(width: 600, height: 480), dark: dark, configure: configure,
        to: "\(out)/\(name).png")
    }
  }

  /// 长截图面板：刚开始（还没预览）、拼了一段（预览 + 尺寸）、对不上（橙色提示）、自动滚动中，深浅色
  /// 长图标注窗口的画布：长图上画了矩形、箭头、序号，选中的那条带虚线框和手柄（工具栏是 HUD 皮肤，
  /// 和长截图面板一样在 macOS 26 起的玻璃下渲染出来是空白，这里只出画布）
  /// 截图历史窗口（历史第 2 批）：空的、有几条（按天分组、选中一条出右边的预览）、搜不到，深浅各一张
  private func renderShotHistory(_ out: String) throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "kitty-shot-history-shots")
    try? FileManager.default.removeItem(at: root)
    let history = try ShotHistory(
      db: Database(path: ":memory:"), directory: root.appending(path: "shots"))
    defer { try? FileManager.default.removeItem(at: root) }
    let model = ShotHistoryModel(history: history)
    for dark in [false, true] {
      try snapshot(
        ShotHistoryView(model: model), size: NSSize(width: 900, height: 560), dark: dark,
        to: "\(out)/shot-history-empty\(dark ? "-dark" : "").png")
    }
    // 摆几条（图不写盘：缩略图读不到就画种类符号，网格的排法一样看得出来）
    let now = Date.now
    let made: [(ShotHistory.Kind, Double, String?)] = [
      (.shot, 0, "Safari"), (.scroll, 0.02, "Chrome"), (.shot, 0.05, "Xcode"),
      (.video, 1.1, "Keynote"), (.audio, 1.2, nil), (.gif, 2.3, "Safari"),
    ]
    var items: [ShotHistory.Item] = []
    for (kind, daysAgo, source) in made {
      items.append(
        ShotHistory.Item(
          id: UUID(), kind: kind, createdAt: now.addingTimeInterval(-daysAgo * 86400),
          pixelSize: CGSize(width: 1600, height: 1000), scale: 2, source: source,
          savedPath: kind == .shot ? nil : "/tmp/\(kind.rawValue).mov",
          annotations: kind == .shot
            ? [Annotation(shape: .rectangle(CGRect(x: 1, y: 2, width: 3, height: 4)))] : [],
          bytes: 1024))
    }
    history.seed(items)
    model.selection = items.first?.id
    for dark in [false, true] {
      try snapshot(
        ShotHistoryView(model: model), size: NSSize(width: 900, height: 560), dark: dark,
        to: "\(out)/shot-history\(dark ? "-dark" : "").png")
    }
    model.selection = nil
    model.search = "找不到的东西"
    try snapshot(
      ShotHistoryView(model: model), size: NSSize(width: 900, height: 560), dark: false,
      to: "\(out)/shot-history-nothing.png")
  }

  private func renderAnnotateOverlay(_ out: String) throws {
    let page = try ScreenshotTests.render([
      "The quick brown fox jumps over the lazy dog", "敏捷的棕色狐狸跳过了懒狗", "日本語のテキスト",
      "한국어 텍스트", "Привет мир", "Hello World", "第七行", "第八行",
    ])
    let long = try #require(page.cropping(to: CGRect(x: 0, y: 0, width: 1200, height: 1600)))
    let canvas = ScrollCanvas(image: long, scale: 2)
    let rectangle = Annotation(
      shape: .rectangle(CGRect(x: 40, y: 560, width: 300, height: 90)),
      style: Annotation.Style(color: .red, weight: .medium))
    canvas.annotations = [
      rectangle,
      Annotation(
        shape: .arrow(from: CGPoint(x: 460, y: 420), to: CGPoint(x: 340, y: 540)),
        style: Annotation.Style(color: .red, weight: .medium)),
      Annotation(
        shape: .counter(1, center: CGPoint(x: 70, y: 700)),
        style: Annotation.Style(color: .blue, weight: .medium)),
    ]
    canvas.selectedAnnotation = rectangle.id
    canvas.layoutSubtreeIfNeeded()
    let shown = CGRect(x: 0, y: 380, width: 600, height: 400)
    let bitmap = try #require(canvas.bitmapImageRepForCachingDisplay(in: shown))
    canvas.cacheDisplay(in: shown, to: bitmap)
    try #require(bitmap.representation(using: .png, properties: [:]))
      .write(to: URL(filePath: "\(out)/scroll-editor-canvas.png"))
  }

  private func renderScrollCapture(_ out: String) throws {
    let page = try ScreenshotTests.render([
      "The quick brown fox jumps over the lazy dog", "敏捷的棕色狐狸跳过了懒狗", "日本語のテキスト",
      "한국어 텍스트", "Привет мир", "Hello World", "第七行", "第八行",
    ])
    let first = try #require(page.cropping(to: CGRect(x: 0, y: 0, width: 1200, height: 480)))
    var stitcher = try #require(
      ScrollStitcher(first: first, scrollbarWidth: 32, maxHeight: 30_000))
    let opening = stitcher  // 刚开始：预览里是第一帧
    _ = stitcher.add(
      try #require(page.cropping(to: CGRect(x: 0, y: 360, width: 1200, height: 480))))
    var states: [(String, Bool, (ScrollCaptureHUD) -> Void)] = [
      (
        "scroll-start", false,
        {
          $0.show("在选区里滚动，或按空格自动滚动", width: 1200, height: 480)
          $0.updatePreview(stitcher: opening, scale: 2)
        }
      ),
      (
        "scroll-preview", false,
        {
          $0.show(
            "在选区里滚动，或按空格自动滚动", width: stitcher.width, height: stitcher.outputHeight)
          $0.updatePreview(stitcher: stitcher, scale: 2)
        }
      ),
      (
        "scroll-lost", false,
        {
          $0.show(
            "对不上了：往回滚一点，再慢慢滚", tone: .lost, width: stitcher.width,
            height: stitcher.outputHeight)
          $0.updatePreview(stitcher: stitcher, scale: 2)
        }
      ),
      (
        "scroll-auto-dark", true,
        {
          $0.isAutoScrolling = true
          $0.show(
            ScrollCapture.status(notice: nil, isFull: false, isLost: false, isAutoScrolling: true)
              .text, width: stitcher.width, height: stitcher.outputHeight)
          $0.updatePreview(stitcher: stitcher, scale: 2)
        }
      ),
    ]
    // 浏览态（滚轮往回看长图、右边一条位置指示条）：长图要比预览框高，所以另拼一张窄的
    let narrowFirst = try #require(page.cropping(to: CGRect(x: 0, y: 0, width: 400, height: 480)))
    let narrowNext = try #require(page.cropping(to: CGRect(x: 0, y: 360, width: 400, height: 480)))
    var narrow = try #require(
      ScrollStitcher(first: narrowFirst, scrollbarWidth: 32, maxHeight: 30_000))
    _ = narrow.add(narrowNext)
    let browsing = narrow
    states.append(
      (
        "scroll-browse", false,
        {
          $0.browseFrom = browsing.rows.lowerBound + 120
          $0.show(
            ScrollCapture.status(
              notice: nil, isFull: false, isLost: false, isAutoScrolling: false, isBrowsing: true
            ).text, width: browsing.width, height: browsing.outputHeight)
          $0.updatePreview(stitcher: browsing, scale: 2)
        }
      ))
    // 正常结束（到底 / 到顶 / 最长）不变橙（体检 B42），深浅色；缺授权是橙字（不抖）
    for (name, dark, status) in [
      (
        "scroll-full", false,
        ScrollCapture.status(notice: nil, isFull: true, isLost: false, isAutoScrolling: false)
      ),
      (
        "scroll-full-dark", true,
        ScrollCapture.status(notice: nil, isFull: true, isLost: false, isAutoScrolling: false)
      ),
      (
        "scroll-permission", false,
        ScrollCapture.Status(text: "自动滚动需要「辅助功能」授权，授权后点 ▶ 开始", tone: .warning)
      ),
    ] {
      states.append(
        (
          name, dark,
          {
            $0.show(
              status.text, tone: status.tone, width: stitcher.width, height: stitcher.outputHeight)
            $0.updatePreview(stitcher: stitcher, scale: 2)
          }
        ))
    }
    for (name, dark, configure) in states {
      let hud = ScrollCaptureHUD()
      try renderLayers(
        hud, size: NSSize(width: ScrollCaptureHUD.width, height: 360), dark: dark,
        configure: { _ in }, prepare: { configure(hud) }, to: "\(out)/\(name).png")
    }
  }

  private func renderLayers(
    _ view: NSView, size: NSSize, dark: Bool, configure: (SelectionView) -> Void,
    prepare: () -> Void = {}, to path: String
  ) throws {
    let window = NSWindow(
      contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    view.wantsLayer = true
    window.contentView = view
    if let view = view as? SelectionView { configure(view) }
    window.orderFront(nil)
    window.layoutIfNeeded()
    prepare()  // 布局之后再设（预览按自己的实际大小出图）
    for _ in 0..<5 { RunLoop.main.run(until: Date.now.addingTimeInterval(0.1)) }
    let scale = 2
    let bitmap = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale,
        pixelsHigh: Int(size.height) * scale, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap)).cgContext
    context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    try #require(view.layer).render(in: context)
    try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(filePath: path))
    window.orderOut(nil)
  }

  /// 把视图树里表格的每一行摆成强调态（key 窗口里第一响应者表格的样子）
  private static func emphasizeTableRows(_ view: NSView) {
    if let table = view as? NSTableView {
      for row in 0..<table.numberOfRows {
        table.rowView(atRow: row, makeIfNecessary: false)?.isEmphasized = true
      }
    }
    view.subviews.forEach(emphasizeTableRows)
  }

  /// 摆成「发现了新版本」的 Updater（面板底栏的「更新到 x」从环境里取它）
  private static func pendingUpdate() throws -> Updater {
    Updater(
      state: .available(
        .init(
          version: "0.4.0", archive: try #require(URL(string: "https://example.com/Kitty.zip")),
          page: Updater.releasesPage)))
  }

  /// 设置 › 通用「导出与导入」的两张表单（2026-10-07）：导出（默认、勾了「包含密钥」露出密码框、一条片段和生词都没有时
  /// 那两类停用）、导入（带密钥的文件，文件里的保留天数比本机短、新打开了退出时清空 → 橙字提醒）。设置、快捷键读临时偏好域，
  /// 片段、收藏、生词本在内存库里，密钥是假的，不读钥匙串
  private func renderTransfer(_ out: String) throws {
    let suite = "kitty-snapshot-\(UUID().uuidString)"
    let prefs = try #require(UserDefaults(suiteName: suite))
    defer { prefs.removePersistentDomain(forName: suite) }
    prefs.set(AppAppearance.dark.rawValue, forKey: Prefs.appearance)
    prefs.set(1, forKey: Prefs.clipboardRetentionDays)
    prefs.set(true, forKey: Prefs.clipboardClearOnQuit)
    prefs.set(true, forKey: Prefs.translateCopyToTranslate)
    prefs.set(
      HotKeyAction.stored(HotKey(keyCode: kVK_ANSI_V, modifiers: cmdKey | shiftKey)),
      forKey: HotKeyAction.clipboard.prefsKey)
    prefs.set(HotKeyAction.stored(nil), forKey: HotKeyAction.recognizeText.prefsKey)
    var deepseek = TranslateService.newAI()
    deepseek.id = "ai:1a2b3c4d"
    deepseek.name = "DeepSeek"
    deepseek.baseURL = "https://api.deepseek.com/v1"
    var ollama = TranslateService.newAI()
    ollama.id = "ai:5e6f7a8b"
    ollama.name = "Ollama"
    ollama.baseURL = "http://127.0.0.1:11434/v1"
    let services = TranslateServiceStore(services: [.zhipu, deepseek, ollama, .builtin(.deepl)])
    // 片段、收藏（一条在收藏夹里、一张图片不进文件）、生词本
    let clipboard = try ClipboardStore(
      db: Database(path: ":memory:"),
      images: ImageStore(
        directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)))
    clipboard.saveSnippet("此致\n{date}")
    var link = ClipItem(kind: .text)
    link.text = "https://developer.apple.com/documentation"
    link.favorite = true
    clipboard.record(link)
    clipboard.assign([link.id], to: try #require(clipboard.createGroup(named: "工作")).id)
    var picture = ClipItem(kind: .image)
    picture.image = .init(width: 4, height: 4, byteCount: 16, sha256: "snapshot-transfer")
    picture.ocrText = ""
    picture.favorite = true
    clipboard.record(picture)
    let history = try HistoryStore(db: Database(path: ":memory:"))
    for (word, meaning) in [("serendipity", "意外发现美好事物的运气"), ("ephemeral", "短暂的")] {
      history.setFavorite(source: word, target: .zhHans, result: meaning, service: "智谱", true)
    }
    // 便签：两条没删的（一条归档了）、一条在「最近删除」里（不进文件）
    let notes = try NoteStore(db: Database(path: ":memory:"))
    notes.create(body: "买菜\n☐ 牛奶")
    notes.setArchived(true, of: notes.create(body: "去年的总结").id)
    notes.delete(notes.create(body: "删掉的").id)
    let transfer = SettingsTransfer(
      services: services, clipboard: clipboard, history: history, notes: { notes })
    let moment = Date(timeIntervalSince1970: 1_760_000_000)
    var archive = SettingsArchive.capture(
      from: prefs, domainName: suite, services: services.services, clips: clipboard.items,
      groups: clipboard.groups, words: history.search("", favoritesOnly: true, limit: 0),
      notes: notes.exportable, version: "0.3.2", now: moment)
    let secrets = ["zhipu.apiKey": "假的", "ai:1a2b3c4d.apiKey": "假的"]
    for dark in [false, true] {
      let suffix = dark ? "-dark" : ""
      try snapshot(
        ExportSheet(archive: archive, secrets: secrets, island: nil, skippedImages: 1),
        size: NSSize(width: 460, height: 590), dark: dark,
        to: "\(out)/settings-transfer-export\(suffix).png")
      try snapshot(
        ExportSheet(
          archive: archive, secrets: secrets, island: nil, skippedImages: 1,
          includesSecrets: true),
        size: NSSize(width: 460, height: 690), dark: dark,
        to: "\(out)/settings-transfer-export-secrets\(suffix).png")
    }
    // 一条片段、收藏、生词、便签都没有：那三类不勾、停用
    try snapshot(
      ExportSheet(
        archive: .capture(
          from: prefs, domainName: suite, services: services.services, notes: [],
          version: "0.3.2", now: moment), secrets: [:], island: nil),
      size: NSSize(width: 460, height: 570), dark: false,
      to: "\(out)/settings-transfer-export-empty.png")
    // 便签这次运行里不可用：导出表单上那一行停用、说明原因；导入表单上说会跳过
    try snapshot(
      ExportSheet(
        archive: .capture(
          from: prefs, domainName: suite, services: services.services, clips: clipboard.items,
          groups: clipboard.groups, notes: nil, version: "0.3.2", now: moment),
        secrets: [:], island: nil),
      size: NSSize(width: 460, height: 570), dark: false,
      to: "\(out)/settings-transfer-export-no-notes.png")
    try snapshot(
      ImportSheet(
        archive: archive,
        transfer: SettingsTransfer(services: services, clipboard: clipboard, history: history),
        island: nil),
      size: NSSize(width: 460, height: 810), dark: false,
      to: "\(out)/settings-transfer-import-no-notes.png")
    try archive.seal(secrets, password: "只在截图自检里用")
    for dark in [false, true] {
      try snapshot(
        ImportSheet(archive: archive, transfer: transfer, island: nil),
        size: NSSize(width: 460, height: 810), dark: dark,
        to: "\(out)/settings-transfer-import\(dark ? "-dark" : "").png")
    }
    // 自己填的地址多于 8 个：放进定高的框里滚（不省略），其中一个长得离谱的主机名掐头留尾
    var many = SettingsArchive(version: "0.3.2", exportedAt: archive.exportedAt)
    many.translateServices = (0..<12).map { index in
      var service = TranslateService.newAI()
      service.name = "服务 \(index)"
      service.baseURL =
        index == 2
        ? "https://" + String(repeating: "very-long-subdomain.", count: 6) + "example.com/v1"
        : "https://api\(index).example.com/v1"
      return service
    }
    try snapshot(
      ImportSheet(archive: many, transfer: transfer, island: nil),
      size: NSSize(width: 460, height: 460), dark: false,
      to: "\(out)/settings-transfer-import-hosts.png")

    // 每天自动备份（2026-10-08）：通用页最后一组多出来的三行。临时目录里摆今天、昨天、三天前各一份和一份「导入前」
    let backups = FileManager.default.temporaryDirectory.appending(
      path: "kitty-snapshot-backups-\(UUID().uuidString)")
    let cloud = backups.appending(path: "Kitty 备份")
    try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: backups) }
    archive.secrets = nil
    let payload = try archive.encoded()
    for days in [0, 1, 3] {
      try SettingsBackup.store(
        payload, kind: .daily, in: backups, creates: false,
        now: Date.now.addingTimeInterval(TimeInterval(-86_400 * days)))
    }
    try SettingsBackup.store(payload, kind: .beforeImport, in: backups, creates: false)
    var backedUp = transfer
    backedUp.backupFolder = backups
    let backupSuite = "kitty-snapshot-\(UUID().uuidString)"
    let backupPrefs = try #require(UserDefaults(suiteName: backupSuite))
    defer { backupPrefs.removePersistentDomain(forName: backupSuite) }
    let section = { (dark: Bool, name: String) in
      try self.snapshot(
        Form { TransferSection(transfer: backedUp) }.formStyle(.grouped)
          .defaultAppStorage(backupPrefs),
        size: NSSize(width: 640, height: 460), dark: dark,
        to: "\(out)/settings-transfer-\(name)\(dark ? "-dark" : "").png")
    }
    // 默认：开着、没另选文件夹
    for dark in [false, true] { try section(dark, "backup") }
    // 另选了文件夹：名字是选的时候存下的，说明里带这台电脑的编号
    backupPrefs.set(cloud.path, forKey: Prefs.settingsBackupFolder)
    backupPrefs.set("Kitty 备份", forKey: Prefs.settingsBackupFolderName)
    backupPrefs.set("3F9A", forKey: Prefs.settingsBackupID)
    for dark in [false, true] { try section(dark, "backup-folder") }
    // 两处橙字：本机那份有一类太多没带；另存的那份今天没存过去
    backupPrefs.set("片段与收藏太多，自动备份里没带，可以手动导出", forKey: Prefs.settingsBackupProblem)
    backupPrefs.set(
      SettingsBackup.describe(SettingsBackup.Failure.missingFolder),
      forKey: Prefs.settingsBackupFolderProblem)
    try section(false, "backup-problem")
    // 关着：已有的备份还能恢复，「另存一份到」不显示，橙字也不显示
    backupPrefs.set(false, forKey: Prefs.settingsBackupEnabled)
    try section(false, "backup-off")
    backupPrefs.removeObject(forKey: Prefs.settingsBackupEnabled)
    // 从备份恢复：同一张导入表单，页头和主按钮换说法，不提醒「信不信得过」
    let copy = try #require(SettingsBackup.list(in: backups).first { $0.kind == .daily })
    for dark in [false, true] {
      try snapshot(
        ImportSheet(
          archive: try SettingsArchive.read(contentsOf: copy.url), transfer: backedUp,
          island: nil, origin: SettingsBackup.source(of: copy)
        )
        .defaultAppStorage(backupPrefs),
        size: NSSize(width: 460, height: 670), dark: dark,
        to: "\(out)/settings-transfer-restore\(dark ? "-dark" : "").png")
    }
  }

  /// 便签第 6 批的样例：各种 Markdown 的写法、和任务叠着的、不该变样的
  private static let markdownSample = """
    # 周会纪要
    ## 要点：**重点**和 `code`
    正文里有 **粗体**、*斜体*、~~删掉的~~、`行内代码` 和 ***又粗又斜***，snake_case_name 和 2 * 3 * 4 不变样。
    链接：[项目主页](https://example.com/kitty) 和 [本地文件](file:///tmp/a)，图片 ![图](a.png) 原样。
    > 引用的一段话，长一点看折行之后左边的竖线和缩进对不对，再长一点再长一点再长一点。
    > 第二行引用里的 *斜体*
    - 无序列表 **粗**
    - 第二项 `code`
    ☐ 任务里的 **粗体** 和 [链接](https://example.com)
    ☑ 做完的 **粗体**、`代码` 和 [链接](https://example.com)
    ### 三级标题
    #### 四级标题 Heading
    ##### 五级标题
    普通的一行收尾，\\*转义的星号\\* 照常显示。
    """

  /// 第 8 批之后的一轮：块格式和合并成一段的颜色（截图 notes-markdown-merged*）
  private static let mergedFormatSample = """
    # 一级标题
    ## 二级标题
    ### 三级标题
    > 引用的一段，**粗体** 和 *斜体* 留着。
    - 无序列表 **粗**
    1. 有序列表这一轮没有样式
    正文里颜色合成一段：[12312323123]{red}，后面是普通字。
    ```swift
    let merged = true
    ```
    收尾一行。
    """

  /// 手测反馈第 4 批的样例：行距三档、代码块（标题、正文折行、任务、列表、引用、代码块混排）
  private static let spacingSample = """
    # 周会纪要
    上周的事情都做完了，这周把发布前的检查过一遍。这一段长一点，折一行看看折行之后的行距舒不舒服，看着累不累。
    ## 待办
    ☐ 周报 **周五前**交
    ☑ 订会议室
    - 列表项一
    - 列表项二 `code`
    > 引用的一段话：先把现有的行为用测试钉住，再一小步一小步地挪。
    > 第二行引用
    ### 代码
    ```swift
    let total = items.reduce(0) { $0 + $1.price }
    print("**不是粗体**", total)  // ☐ 不是任务
    ```
    收尾的一行，[链接](https://example.com) 照常。
    """

  /// 每种纸色各看一眼的短样例（光标在第一行：露出来的标记有多淡；引用里带一段代码：它用墨色；最后一个代码块：块的底、
  /// 带语言名的围栏行在每种纸上读不读得出）
  private static let markdownPaperSample = """
    ## 标题 **粗** *斜*
    正文 **粗体** *斜体* ~~删除~~ `code` [链接](https://a.b)
    > 引用的话 `code`
    - 列表项
    ☑ 做完的 **粗**
    ☐ 没做完的 `code`
    ```swift
    let total = price * 3
    ```
    """

  /// 把图里的正文框摆成「拿着焦点、窗口是 key、选区在 selection」的样子：选区碰到的行露出 Markdown 的标记。
  /// 屏外的窗口不真的当 key：直接告诉编辑器（NoteTextView.keyChanged）
  /// 列表视图的全部便签窗口（便签墙是默认的；这几张图是拿来和列表视图的图对的）
  private static func listModel(_ store: NoteStore) -> NotesWindowModel {
    let model = NotesWindowModel(store: store)
    model.layout = .list
    return model
  }

  private static func reveal(_ selection: NSRange) -> (NSView) -> Void {
    { root in
      guard let editor = NotesWindow.editor(in: root) else { return }
      editor.window?.makeFirstResponder(editor)
      editor.keyChanged(true)
      editor.setSelectedRange(selection)
    }
  }

  /// prepare：布局完、出图前对窗口内容做点手脚（比如 emphasizeTableRows）
  /// 启动台（第八族，2026-10-18，SPEC §10.5）：第一页、第二页、搜索中、文件夹打开、抖动模式（带 ✕）、拖动中、
  /// 设置页；浅色 / 深色各一份，图以 launchpad- 开头，出到 TEST_RUNNER_KITTY_SNAPSHOT_DIR。
  /// 用本机真实的 App 目录（图标是真的），只把其中一个摆成「App Store 装的」好让抖动模式出 ✕。
  @Test(.enabled(if: directory != nil)) func launchpad() throws {
    let out = try #require(Self.directory)
    try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    let real = LaunchpadCatalog.load()
    guard real.count >= 10 else { return }
    let apps = real.prefix(14).enumerated().map { index, app in
      LaunchpadProjectApp(
        id: app.id, ref: app.ref, item: app.item, url: app.url, isSystem: app.isSystem,
        inUtilities: app.inUtilities, isAppStore: index == 2, category: app.category)
    }
    let folder = LaunchpadFolder(
      name: "工具", pages: [[apps[3].ref, apps[4].ref, apps[5].ref]])
    var tiles = apps.prefix(3).map { LaunchpadTile.app($0.ref) }
    tiles.append(.folder(folder))
    tiles += apps.dropFirst(6).map { LaunchpadTile.app($0.ref) }
    // 一页 9 个（好让第二页真的有东西：真机上默认一页 35 个）
    let layout = LaunchpadLayout(pages: LaunchpadLayout.paginate(tiles, capacity: 9))
    let size = NSSize(width: 1280, height: 800)
    // 背景用本机主屏现在的壁纸（只读文件，同 LaunchpadWallpaper；拿不到就是没壁纸的那种样子）
    let wallpaper = NSScreen.main
      .flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
      .flatMap { LaunchpadWallpaper.load(url: $0, maxPixel: 1280) }
      .flatMap { LaunchpadWallpaper.render(source: $0, width: 640, height: 400) }
    func board() -> LaunchpadModel {
      let model = LaunchpadModel(
        layout: layout, catalog: Array(apps), icons: LaunchpadIcons(), columns: 7, rows: 5,
        screenSize: size, dragTiming: .immediate)
      model.wallpaper = wallpaper
      return model
    }
    for dark in [false, true] {
      let suffix = dark ? "-dark" : ""
      try snapshot(
        LaunchpadView(model: board()), size: size, dark: dark,
        to: "\(out)/launchpad-page1\(suffix).png")
      let second = board()
      second.go(to: 1)
      try snapshot(
        LaunchpadView(model: second), size: size, dark: dark,
        to: "\(out)/launchpad-page2\(suffix).png")
      let search = board()
      search.query = apps[0].name
      try snapshot(
        LaunchpadView(model: search), size: size, dark: dark,
        to: "\(out)/launchpad-search\(suffix).png")
      // 点过搜索框、还没打字：放大镜 + 「搜索」挪到左边（插入点屏外画不出来），「搜索」两个字要和上一张打的字对齐
      let engaged = board()
      engaged.searchClicked()
      try snapshot(
        LaunchpadView(model: engaged), size: size, dark: dark,
        to: "\(out)/launchpad-search-engaged\(suffix).png")
      let open = board()
      open.openFolder(folder.id)
      try snapshot(
        LaunchpadView(model: open), size: size, dark: dark,
        to: "\(out)/launchpad-folder\(suffix).png")
      let jiggle = board()
      jiggle.enterJiggle()
      try snapshot(
        LaunchpadView(model: jiggle), size: size, dark: dark,
        to: "\(out)/launchpad-jiggle\(suffix).png")
      let drag = board()
      drag.beginDrag(
        tile: .app(apps[1].ref), appID: apps[1].ref.id, folder: nil,
        at: CGPoint(x: 300, y: 400))
      drag.updateDrag(location: CGPoint(x: 520, y: 430), pageWidth: size.width)
      try snapshot(
        LaunchpadView(model: drag), size: size, dark: dark,
        to: "\(out)/launchpad-drag\(suffix).png")
    }
    // 停在另一个图标中心够久：目标后面长出合成底板，拿着的那份放大、不抖（2026-10-18 交互对齐）
    let combine = board()
    combine.gridFrames[0] = CGRect(
      x: 0, y: combine.metrics.gridTop, width: size.width, height: combine.metrics.gridHeight)
    let target = try #require(combine.cellCenter(page: 0, index: 0))
    let source = try #require(combine.cellCenter(page: 0, index: 1))
    combine.beginDrag(
      tile: .app(apps[1].ref), appID: apps[1].ref.id, folder: nil, at: source, origin: source)
    combine.updateDrag(location: CGPoint(x: target.x + 6, y: target.y + 4), pageWidth: size.width)
    combine.armCombineForTesting()
    try snapshot(
      LaunchpadView(model: combine), size: size, dark: true,
      to: "\(out)/launchpad-combine-dark.png")
    // 拿不到壁纸（视频 / 航拍壁纸）：退回系统毛玻璃
    let plain = board()
    plain.wallpaper = nil
    try snapshot(
      LaunchpadView(model: plain), size: size, dark: true,
      to: "\(out)/launchpad-nowallpaper-dark.png")
    // 满页：7 × 5 全部放满，看第 3–5 行和底下的页点（F30）
    if real.count >= 35 {
      let fullApps = real.prefix(35).map {
        LaunchpadProjectApp(
          id: $0.id, ref: $0.ref, item: $0.item, url: $0.url, isSystem: $0.isSystem,
          inUtilities: $0.inUtilities, isAppStore: false, category: $0.category)
      }
      let fullLayout = LaunchpadLayout(
        pages: LaunchpadLayout.paginate(fullApps.map { .app($0.ref) }, capacity: 35))
      let fullModel = LaunchpadModel(
        layout: fullLayout, catalog: fullApps, icons: LaunchpadIcons(), columns: 7, rows: 5,
        screenSize: size)
      fullModel.wallpaper = wallpaper
      try snapshot(
        LaunchpadView(model: fullModel), size: size, dark: false,
        to: "\(out)/launchpad-full.png")
    }
    // 跨页拖动：源在第 1 页，翻到第 2 页，让位空位画在第 2 页的落点（F18）
    let across = board()
    across.go(to: 1)
    across.beginDrag(
      tile: .app(apps[0].ref), appID: apps[0].ref.id, folder: nil,
      at: CGPoint(x: 200, y: 300))
    across.updateDrag(location: CGPoint(x: 700, y: 500), pageWidth: size.width)
    try snapshot(
      LaunchpadView(model: across), size: size, dark: true,
      to: "\(out)/launchpad-page2-gap-dark.png")
    // 文件夹按新的 7 × 5 一页画，内容只有两行时面板收短（F10 / F34）
    let many = LaunchpadFolder(
      name: "更多工具", pages: [Array(apps.prefix(10).map(\.ref))])
    let manyLayout = LaunchpadLayout(pages: [[.folder(many)]])
    let manyModel = LaunchpadModel(
      layout: manyLayout, catalog: Array(apps), icons: LaunchpadIcons(), columns: 7, rows: 5,
      screenSize: size)
    manyModel.wallpaper = wallpaper
    manyModel.openFolder(many.id)
    try snapshot(
      LaunchpadView(model: manyModel), size: size, dark: true,
      to: "\(out)/launchpad-folder-wide-dark.png")
    let navigation = SettingsNavigation(defaults: nil)
    navigation.page = .launchpad
    try snapshot(
      SettingsRoot(navigation: navigation) { page in
        page == .launchpad ? AnyView(LaunchpadTab()) : AnyView(EmptyView())
      } onboarding: {
        AnyView(EmptyView())
      },
      size: NSSize(width: 780, height: 1120), dark: false, to: "\(out)/launchpad-settings.png")
  }

  /// 功能开关（Shell/Feature.swift，2026-10-21）：设置 › 通用最上面的「功能」一组（全开、关了剪贴板和翻译；浅 / 深），
  /// 关着的剪贴板页（第一组「启用剪贴板」，下面变灰，保留天数、清空那几项不灰）、关着的启动台页。十几秒，图以 features- 开头。
  /// 开关读的是临时偏好域（defaultAppStorage），不写用户的偏好
  @Test(.enabled(if: directory != nil)) func features() throws {
    let out = try #require(Self.directory)
    try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    Prefs.registerDefaults()
    let name = "kitty-snapshot-features-\(UUID().uuidString)"
    let prefs = try #require(UserDefaults(suiteName: name))
    defer { prefs.removePersistentDomain(forName: name) }
    let images = FileManager.default.temporaryDirectory.appending(path: name)
    defer { try? FileManager.default.removeItem(at: images) }
    let store = try ClipboardStore(
      db: Database(path: ":memory:"), images: ImageStore(directory: images))
    let navigation = SettingsNavigation(defaults: nil)  // 换页不写用户的偏好
    func root() -> some View {
      SettingsRoot(navigation: navigation) { page in
        switch page {
        case .clipboard: AnyView(ClipboardTab(store: store).defaultAppStorage(prefs))
        case .launchpad: AnyView(LaunchpadTab().defaultAppStorage(prefs))
        default: AnyView(GeneralTab().defaultAppStorage(prefs))
        }
      } onboarding: {
        AnyView(EmptyView())
      }
    }
    navigation.page = .general
    for dark in [false, true] {
      try snapshot(
        root(), size: NSSize(width: 780, height: 760), dark: dark,
        to: "\(out)/features-general\(dark ? "-dark" : "").png")
    }
    prefs.set(false, forKey: Feature.clipboard.prefsKey)
    prefs.set(false, forKey: Feature.translate.prefsKey)
    prefs.set(false, forKey: Feature.launchpad.prefsKey)
    try snapshot(
      root(), size: NSSize(width: 780, height: 760), dark: false,
      to: "\(out)/features-general-off.png")
    navigation.page = .clipboard
    for dark in [false, true] {
      try snapshot(
        root(), size: NSSize(width: 780, height: 1100), dark: dark,
        to: "\(out)/features-clipboard-off\(dark ? "-dark" : "").png")
    }
    navigation.page = .launchpad
    try snapshot(
      root(), size: NSSize(width: 780, height: 1120), dark: false,
      to: "\(out)/features-launchpad-off.png")
  }

  /// 设置 › 通用「同步」（2026-10-23，SyncSection）：没开、第一轮还没完 / 第一轮就停了、好了（两台别的 Mac、还在下载几个；
  /// 浅 / 深）、还没有别的 Mac、等确认（刹车）、停了（文件夹不在、写不进去）、便签关着。几秒，图以 sync- 开头。
  /// 同步接的是内存库和临时偏好域（便签的功能开关也读它），状态直接设，不碰真的文件夹和偏好
  @Test(.enabled(if: directory != nil)) func sync() throws {
    let out = try #require(Self.directory)
    try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    Prefs.registerDefaults()
    let name = "kitty-snapshot-sync-\(UUID().uuidString)"
    let prefs = try #require(UserDefaults(suiteName: name))
    defer { prefs.removePersistentDomain(forName: name) }
    let store = try NoteStore(db: Database(path: ":memory:"))
    let size = NSSize(width: 640, height: 1000)
    func section(_ prepare: (NoteSyncer) -> Void = { _ in }) -> some View {
      let syncer = NoteSyncer(store: store, defaults: prefs)
      prepare(syncer)
      return Form { SyncSection(syncer: syncer) }.formStyle(.grouped).defaultAppStorage(prefs)
    }
    try snapshot(section(), size: size, dark: false, to: "\(out)/sync-off.png")
    prefs.set(
      SyncSection.iCloudDrive.appending(path: "Kitty Tools 便签").path,
      forKey: Prefs.notesSyncFolder)
    prefs.set("库", forKey: Prefs.notesSyncLibrary)
    let now = Date.now
    let air = NoteSyncDisk.Peer(id: "1", name: "MacBook Air", seen: now.addingTimeInterval(-300))
    let imac = NoteSyncDisk.Peer(id: "2", name: "iMac", seen: now.addingTimeInterval(-86_400 * 1.2))
    let states: [(String, (NoteSyncer) -> Void)] = [
      ("first", { $0.status = .syncing }),
      ("first-stopped", { $0.status = .stopped(.downloading) }),
      (
        "idle",
        {
          $0.status = .idle
          $0.lastSync = now.addingTimeInterval(-120)
          $0.downloading = 3
          $0.peers = [air, imac]
        }
      ),
      (
        "alone",
        {
          $0.status = .idle
          $0.lastSync = now
        }
      ),
      (
        "waiting",
        {
          $0.status = .waiting(trashing: 8)
          $0.lastSync = now.addingTimeInterval(-40)
          $0.peers = [air]
        }
      ),
      (
        "missing",
        {
          $0.status = .stopped(.missingFolder)
          $0.lastSync = now.addingTimeInterval(-3600 * 5)
          $0.peers = [air]
        }
      ),
      (
        "failed",
        {
          $0.status = .stopped(.failed("文件“2C1F7A.md”无法存储，因为卷是只读的。"))
          $0.lastSync = now.addingTimeInterval(-600)
          $0.peers = [air]
        }
      ),
    ]
    for (state, prepare) in states {
      for dark in state == "idle" ? [false, true] : [false] {
        try snapshot(
          section(prepare), size: size, dark: dark,
          to: "\(out)/sync-\(state)\(dark ? "-dark" : "").png")
      }
    }
    // 在通用页里的位置（导出与导入上面）、便签关着时
    let general = NoteSyncer(store: store, defaults: prefs)
    general.status = .idle
    general.lastSync = now.addingTimeInterval(-120)
    general.peers = [air]
    try snapshot(
      GeneralTab(sync: general).defaultAppStorage(prefs), size: NSSize(width: 640, height: 1500),
      dark: false, to: "\(out)/sync-general.png")
    prefs.set(false, forKey: Feature.notes.prefsKey)
    try snapshot(
      section {
        $0.status = .off
        $0.lastSync = now.addingTimeInterval(-3600)
      }, size: size, dark: false, to: "\(out)/sync-notes-off.png")
  }

  /// 程序坞预览（第九族第 2 批）：面板（程序坞在下面 / 左边、窗口多到要滚、没有屏幕录制授权、长标题），浅深各一份；
  /// 设置 › 程序坞预览（私有接口都在 / 缺几个）。图以 dock-preview- 开头（设置页是 settings-dock-preview-）。悬停的样子
  /// （浅灰底、抬起、✕）是视图自己的状态，屏外摆不出来，看真机
  @Test(.enabled(if: directory != nil)) func dockPreview() throws {
    let out = try #require(Self.directory)
    try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    Prefs.registerDefaults()
    // /Applications/Safari.app 是链接，直接取图标会带替身的小箭头
    let icon = NSWorkspace.shared.icon(
      forFile: URL(filePath: "/Applications/Safari.app").resolvingSymlinksInPath().path)
    /// 假的窗口画面：浅色底、一条标题栏、几块内容
    func shot(_ size: CGSize, tint: NSColor) throws -> CGImage {
      let width = Int(size.width) * 2
      let height = Int(size.height) * 2
      let context = try #require(
        CGContext(
          data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue))
      context.setFillColor(NSColor(white: 0.97, alpha: 1).cgColor)
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
      context.setFillColor(NSColor(white: 0.88, alpha: 1).cgColor)
      context.fill(CGRect(x: 0, y: height - 28, width: width, height: 28))
      context.setFillColor(tint.cgColor)
      context.fill(CGRect(x: 24, y: height - 120, width: width / 2, height: 40))
      context.setFillColor(NSColor(white: 0.8, alpha: 1).cgColor)
      for row in 0..<4 {
        context.fill(CGRect(x: 24, y: height - 170 - row * 30, width: width * 2 / 3, height: 12))
      }
      return try #require(context.makeImage())
    }
    func model(
      _ windows: [DockWindow], edge: DockPreviewLayout.Edge = .bottom, along: CGFloat = 1400,
      thumbnails: Bool = true, imaged: Set<CGWindowID>? = nil, hovered: CGWindowID? = nil
    ) throws -> DockPreviewModel {
      let model = DockPreviewModel()
      model.appName = "Safari"
      model.appIcon = icon
      model.edge = edge
      model.showsThumbnails = thumbnails
      model.plan = DockPreviewLayout.plan(
        windows.map(\.size), edge: edge, along: along, across: 860, compact: !thumbnails)
      model.windows = Array(windows.prefix(model.plan.thumbs.count))
      model.closable = Set(windows.filter { $0.state != .elsewhere }.map(\.id))
      model.hovered = hovered
      if thumbnails {
        let tints: [NSColor] = [.systemBlue, .systemPink, .systemGreen, .systemOrange]
        for (index, window) in model.windows.enumerated() where imaged?.contains(window.id) ?? true
        {
          model.images[window.id] = try shot(window.size, tint: tints[index % tints.count])
        }
      }
      return model
    }
    let three = [
      DockWindow(id: 11, title: "起始页", state: .shown, size: CGSize(width: 1440, height: 900)),
      DockWindow(
        id: 12, title: "kitty-tools · GitHub", state: .elsewhere,
        size: CGSize(width: 1280, height: 800)),
      DockWindow(
        id: 13, title: "Apple 开发者文档：ScreenCaptureKit 与窗口截图的最佳做法", state: .minimized,
        size: CGSize(width: 1000, height: 1000)),
    ]
    func render(_ model: DockPreviewModel, _ name: String, dark: Bool) throws {
      try snapshot(
        DockPreviewView(model: model), size: model.plan.panel, dark: dark,
        to: "\(out)/dock-preview-\(name)\(dark ? "-dark" : "").png")
    }
    for dark in [false, true] {
      // 第一扇悬停着（浅灰底、抬起、✕），第二扇在别的桌面、还没截到图（图标位）
      try render(model(three, imaged: [11, 13], hovered: 11), "bottom", dark: dark)
      try render(model(three, edge: .left, along: 800, hovered: 13), "left", dark: dark)
      try render(model(three, thumbnails: false), "no-recording", dark: dark)
    }
    let many = (1...14).map {
      DockWindow(
        id: CGWindowID(100 + $0), title: "文稿 \($0)", state: $0 == 14 ? .hidden : .shown,
        size: CGSize(width: 1200, height: 800))
    }
    // 窗口多到一排放不下：缩到最小再换行
    try render(model(many, along: 1100), "crowded", dark: false)
    try render(
      model([
        DockWindow(id: 1, title: "", state: .elsewhere, size: CGSize(width: 900, height: 2000))
      ]), "single-untitled", dark: false)

    let navigation = SettingsNavigation(defaults: nil)  // 换页不写用户的偏好
    navigation.page = .dockPreview
    for (missing, suffix) in [
      ([String](), ""), (["CGSCopySpacesForWindows", "SLPSPostEventRecordTo"], "-missing"),
    ] {
      for dark in [false, true] where suffix.isEmpty || !dark {
        try snapshot(
          SettingsRoot(navigation: navigation) { _ in
            AnyView(DockPreviewTab(missing: missing))
          } onboarding: {
            AnyView(EmptyView())
          },
          size: NSSize(width: 780, height: 560), dark: dark,
          to: "\(out)/settings-dock-preview\(suffix)\(dark ? "-dark" : "").png")
      }
    }
  }

  private func snapshot(
    _ view: some View, size: NSSize, dark: Bool, to path: String,
    prepare: ((NSView) -> Void)? = nil
  ) throws {
    guard Self.wants(path) else { return }
    let window = NSWindow(
      contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
    background.material = .popover
    background.state = .active
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    host.frame = background.bounds
    background.addSubview(host)
    window.contentView = background
    window.orderFront(nil)
    for _ in 0..<5 { RunLoop.main.run(until: Date.now.addingTimeInterval(0.1)) }
    if let prepare {
      prepare(background)
      RunLoop.main.run(until: Date.now.addingTimeInterval(0.1))
    }
    let bitmap = try #require(background.bitmapImageRepForCachingDisplay(in: background.bounds))
    background.cacheDisplay(in: background.bounds, to: bitmap)
    try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(filePath: path))
    window.orderOut(nil)
  }
}

/// 截图自检：一块纸色的底（不挂层，里面的滚动条照自己的 draw 画）
private final class PaperFill: NSView {
  let color: NSColor

  init(color: NSColor) {
    self.color = color
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) { nil }

  override func draw(_ dirtyRect: NSRect) {
    color.setFill()
    dirtyRect.fill()
  }
}

/// 截图自检：有标题栏的窗口摆在屏外（系统默认会把它挪回屏幕里）
private final class OffscreenTitledWindow: NSWindow {
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }
}

/// 截图自检：8 种纸色一排——纸上写名字（墨）、一行次要的字、顶上色条、角上圆点
private struct NotePaperProbe: View {
  var body: some View {
    HStack(spacing: 10) {
      ForEach(Array(NotePaper.all.enumerated()), id: \.offset) { _, paper in
        VStack(alignment: .leading, spacing: 6) {
          paper.strip.frame(height: 3)
          VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
              NoteDot(paper: paper)
              NoteDot(paper: paper, size: 18)
              Image(nsImage: paper.swatch())
            }
            Text(paper.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(paper.ink)
            Text("买菜 milk 123").font(.system(size: 13)).foregroundStyle(paper.ink)
            Text("改于 今天 09:12").font(.system(size: 11)).foregroundStyle(paper.secondaryInk)
          }
          .padding(.horizontal, 8)
          Spacer(minLength: 0)
        }
        .frame(width: 98, height: 118)
        .background(paper.paper)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// 截图自检：菜单栏上的两种图标。上面一条 24 pt 高的「菜单栏」里 1:1 摆着单色（模板图，跟着深浅着色）和彩色，
/// 下面放大 5 倍看像素（不插值）
private struct StatusIconProbe: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 0) {
        ForEach(StatusItem.IconStyle.allCases) { style in
          if let image = style.image { Image(nsImage: image).frame(width: 24, height: 24) }
        }
        Text("9月29日 周二 10:24").font(.system(size: 13)).padding(.leading, 8)
      }
      .padding(.horizontal, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.bar)
      HStack(alignment: .bottom, spacing: 16) {
        ForEach(StatusItem.IconStyle.allCases) { style in
          if let image = style.image {
            Image(nsImage: image).resizable().interpolation(.none)
              .frame(width: image.size.width * 5, height: image.size.height * 5)
          }
        }
      }
      .padding(.horizontal, 12)
    }
  }
}

/// 截图自检：挂进窗口后晚一拍把焦点给窗口的主输入框（同 OverlayPanel.present()），看翻译原文框的焦点环
private struct InitialFocusProbe: NSViewRepresentable {
  func makeNSView(context: Context) -> Probe { Probe() }
  func updateNSView(_ view: Probe, context: Context) {}

  final class Probe: NSView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      // 用 run loop 延后（测试在主队列里嵌套跑 run loop，Task 等不到）
      perform(#selector(focus), with: nil, afterDelay: 0)
    }

    @objc private func focus() {
      window?.makeFirstResponder(window?.initialFirstResponder)
    }
  }
}
