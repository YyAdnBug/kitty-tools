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
struct SnapshotProbeTests {
  nonisolated private static let directory =
    ProcessInfo.processInfo.environment["KITTY_SNAPSHOT_DIR"]

  @Test(.enabled(if: directory != nil)) func renderPanels() async throws {
    let out = try #require(Self.directory)
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
          size: NSSize(width: 580, height: 480), dark: dark,
          to: "\(out)/onboarding-try-accent-\(suffix).png")
        try snapshot(
          ShortcutsSheet(), size: NSSize(width: 560, height: 400), dark: dark,
          to: "\(out)/shortcuts-accent-\(suffix).png")
      }
    }
    Accent.shared.select(savedAccent, persists: false)
    // ⌘Y 放大预览 = 完整检查器：代码（放大的字）、链接（大头图）、图片（带识别文字）、多个文件（网格）、JSON（默认美化），
    // 按各自的理想尺寸；页脚第 3 个胶囊按类型（打开 / 钉到屏幕 / 在访达中显示 / 原文，体检 D2）
    let quickLooks: [(String, (ClipItem) -> Bool)] = [
      ("quicklook-code", { $0.text?.hasPrefix("import") == true }),
      ("quicklook-json", { $0.text?.hasPrefix("{\"name") == true }),
      ("quicklook-link", { $0.text?.hasPrefix("https://developer") == true }),
      ("quicklook-image", { $0.kind == .image }),
      ("quicklook-files", { $0.kind == .file }),
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
      case .screenshot: AnyView(ScreenshotTab())
      case .record: AnyView(RecordTab())
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
    // 关于页的应用内更新：有新版本（强调色按钮）、正在更新、已是最新、检查失败
    let release = Updater.Release(
      version: "0.2.0", archive: URL(string: "https://example.com/Kitty.zip")!,
      page: Updater.releasesPage)
    let updateStates: [(String, Updater.State, Bool)] = [
      ("available", .available(release), false), ("available", .available(release), true),
      ("installing", .installing(release), false), ("latest", .upToDate, false),
      ("failed", .failed("检查更新失败：网络连接已中断。"), false),
    ]
    navigation.page = .about
    for (name, state, dark) in updateStates {
      let updater = Updater(state: state)
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
        ScreenshotTab().defaultAppStorage(shotPrefs), size: NSSize(width: 640, height: 720),
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
    // 设置 › 启动器「浏览器书签与历史」（第 12 批）：只列装了的五家；Safari 没授权（橙字 + 去授权… + 说明）、
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
    // 快捷键速查表（N11）：默认大小的设置窗里 sheet 的尺寸，另出一张拉长的看全部分组
    let sheetHeight = ShortcutsButton.sheetHeight(available: 600 - 52)
    for (name, height, dark) in [
      ("shortcuts", sheetHeight, false), ("shortcuts-dark", sheetHeight, true),
      ("shortcuts-full", 5400, false),
    ] {
      try snapshot(
        ShortcutsSheet(), size: NSSize(width: 560, height: height), dark: dark,
        to: "\(out)/\(name).png")
    }
    // 增强对比度（体检 B53）：速查表、通用页的发丝线 1 pt
    try snapshot(
      ShortcutsSheet().environment(\._colorSchemeContrast, .increased),
      size: NSSize(width: 560, height: sheetHeight), dark: false,
      to: "\(out)/shortcuts-contrast.png")
    try snapshot(
      GeneralTab().environment(\._colorSchemeContrast, .increased),
      size: NSSize(width: 640, height: 560), dark: true,
      to: "\(out)/settings-general-contrast-dark.png")
    // 欢迎引导（N14）：第一屏、第二屏「按一下试试」（两行已按过），各出深色
    for (name, screen) in [("welcome", OnboardingView.Screen.welcome), ("try", .tryIt)] {
      for dark in [false, true] {
        try snapshot(
          OnboardingView(
            center: hotKeys, firstRun: true, screen: screen, tried: [.clipboard, .screenshot]),
          size: NSSize(width: 580, height: 480), dark: dark,
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
          tone: .progress, symbol: ShelfCard.gifIslandSymbol, leading: .tone), notch
      ),
      // 第二轮体检 R1：视频卡「压缩」的进度；R3：识字慢的时候先出「识别中」
      (
        "island-compress-progress",
        .init(
          title: "正在压缩…", detail: ShelfCard.progressDetail(37), tone: .progress,
          symbol: ShelfCard.compressIslandSymbol, leading: .tone), notch
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
    ]
    for (name, content, geometry) in islands {
      try snapshot(
        IslandView(island: Island(showing: content, geometry: geometry)),
        size: geometry.windowSize, dark: false, to: "\(out)/\(name).png")
    }
  }

  /// 翻译浮窗：空态、结果（没有「翻译」按钮）、原文改过（弹出「翻译 ↩」）、复制即译状态胶囊 + 固定、
  /// 替换原文、查词、历史（分组 + 选中第三条 + 范围胶囊）、收藏范围、空历史、提示、长译文（卡内滚动 + 渐隐，
  /// 默认和 140% 字号）；「⋯」菜单是 NSMenu，屏外画不出来
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
          c.replaceSource = (1, "Ship it")
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

  /// 启动器：空查询的收藏 + 常用（底栏种类 + 主动作 ↩ + 动作 ⌘K）、⌘K 动作菜单（App、网址）、搜索结果（中文名 / 拼音）、
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
  /// 开头摆的假图）、kill 列后台进程（按端口、⌘↩ 上膛）。进程、历史都是注入的，不跑 ps、不读 Chrome
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
    model.processTargets = {
      Processes.items(
        [
          .init(pid: 4321, memory: 312 << 20, path: "/opt/homebrew/bin/node"),
          .init(pid: 5173, memory: 180 << 20, path: "/opt/homebrew/bin/node"),
          .init(
            pid: 902, memory: 96 << 20, path: "/Users/me/.pyenv/versions/3.12.4/bin/python3.12"),
          .init(
            pid: 1474, memory: 64 << 20,
            path: "/Applications/Clash Verge.app/Contents/MacOS/clash-verge"),
          .init(pid: 387, memory: 8 << 20, path: "/usr/sbin/cfprefsd"),
        ], ports: [4321: [3000], 5173: [5173], 902: [8000, 8001]], excluding: [])
    }
    for dark in [false, true] {
      for (name, query) in [
        ("launcher-units", "10 km to mi"), ("launcher-units-cn", "30 摄氏度 转 华氏度"),
        ("launcher-radix", "255 in hex"), ("launcher-calc-group", "1234567*3"),
        ("launcher-actions-calc", "0xff+1"), ("launcher-settings", "蓝牙"),
        ("launcher-settings-privacy", "yinsi"), ("launcher-history", "git"),
        ("launcher-kill", "kill "), ("launcher-kill-port", "kill :3000"),
        ("launcher-kill-force", "kill no"),
      ] {
        model.query = query
        await model.processLookup()
        model.showsActions = name == "launcher-actions-calc"
        if name == "launcher-kill-force", let first = model.results.first {
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
  private func renderScrollCapture(_ out: String) throws {
    let page = try ScreenshotTests.render([
      "The quick brown fox jumps over the lazy dog", "敏捷的棕色狐狸跳过了懒狗", "日本語のテキスト",
      "한국어 텍스트", "Привет мир", "Hello World", "第七行", "第八行",
    ])
    let first = try #require(page.cropping(to: CGRect(x: 0, y: 0, width: 1200, height: 480)))
    var stitcher = try #require(
      ScrollStitcher(first: first, scrollbarWidth: 32, maxHeight: 30_000))
    _ = stitcher.add(
      try #require(page.cropping(to: CGRect(x: 0, y: 360, width: 1200, height: 480))))
    var states: [(String, Bool, (ScrollCaptureHUD) -> Void)] = [
      (
        "scroll-start", false,
        { $0.show("在选区里滚动，或按空格自动滚动", width: 1200, height: 480) }
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
            "自动滚动中：按空格或移开鼠标停止", width: stitcher.width, height: stitcher.outputHeight
          )
          $0.updatePreview(stitcher: stitcher, scale: 2)
        }
      ),
    ]
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
    let transfer = SettingsTransfer(services: services, clipboard: clipboard, history: history)
    let moment = Date(timeIntervalSince1970: 1_760_000_000)
    var archive = SettingsArchive.capture(
      from: prefs, domainName: suite, services: services.services, clips: clipboard.items,
      groups: clipboard.groups, words: history.search("", favoritesOnly: true, limit: 0),
      version: "0.3.2", now: moment)
    let secrets = ["zhipu.apiKey": "假的", "ai:1a2b3c4d.apiKey": "假的"]
    for dark in [false, true] {
      let suffix = dark ? "-dark" : ""
      try snapshot(
        ExportSheet(archive: archive, secrets: secrets, island: nil, skippedImages: 1),
        size: NSSize(width: 460, height: 540), dark: dark,
        to: "\(out)/settings-transfer-export\(suffix).png")
      try snapshot(
        ExportSheet(
          archive: archive, secrets: secrets, island: nil, skippedImages: 1,
          includesSecrets: true),
        size: NSSize(width: 460, height: 640), dark: dark,
        to: "\(out)/settings-transfer-export-secrets\(suffix).png")
    }
    // 一条片段、收藏、生词都没有：那两类不勾、停用
    try snapshot(
      ExportSheet(
        archive: .capture(
          from: prefs, domainName: suite, services: services.services, version: "0.3.2",
          now: moment), secrets: [:], island: nil),
      size: NSSize(width: 460, height: 520), dark: false,
      to: "\(out)/settings-transfer-export-empty.png")
    try archive.seal(secrets, password: "只在截图自检里用")
    for dark in [false, true] {
      try snapshot(
        ImportSheet(archive: archive, transfer: transfer, island: nil),
        size: NSSize(width: 460, height: 760), dark: dark,
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
  }

  /// prepare：布局完、出图前对窗口内容做点手脚（比如 emphasizeTableRows）
  private func snapshot(
    _ view: some View, size: NSSize, dark: Bool, to path: String,
    prepare: ((NSView) -> Void)? = nil
  ) throws {
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
