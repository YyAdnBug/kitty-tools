import AppKit
import SwiftUI
import Testing

@testable import KittyTools

// 界面截图自检（按需启用）：在屏幕外、不激活的窗口里渲染各种状态，写成 PNG 供人 / agent 检查。
// 不会弹出面板、不抢键盘，也不需要屏幕录制权限。用法：
//   TEST_RUNNER_KITTY_SNAPSHOT_DIR=/tmp/shots xcodebuild -project macos/KittyTools.xcodeproj \
//     -scheme KittyTools test -only-testing:KittyToolsTests/SnapshotProbeTests
struct SnapshotProbeTests {
  nonisolated private static let directory =
    ProcessInfo.processInfo.environment["KITTY_SNAPSHOT_DIR"]

  @Test(.enabled(if: directory != nil)) func renderPanels() throws {
    let out = try #require(Self.directory)
    Prefs.registerDefaults()
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
    let link = try #require(store.items.first { $0.text?.hasPrefix("https://developer") == true })
    store.toggleFavorite([link.id])
    store.update([link.id]) { $0.note = "AppKit 文档" }
    let group = try #require(store.createGroup(named: "工作"))
    let meeting = try #require(store.items.first { $0.text?.hasPrefix("会议") == true })
    store.update([meeting.id]) { $0.groupID = group.id }
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
    let states: [(String, (ClipboardPanelModel) -> Void)] = [
      ("list", { _ in }),
      ("json", { m in m.select(m.visibleItems.first { $0.text?.hasPrefix("{") == true }!) }),
      ("search", { m in m.query = "swift" }),
      ("multi", { m in m.multiSelection = Set(m.visibleItems.prefix(3).map(\.id)) }),
      ("dialog", { m in m.dialog = .note(link.id) }),
      (
        "filtered",
        { m in
          m.kind = .text
          m.form = .code
        }
      ),
      ("empty-snippets", { m in m.scope = .snippets }),
      ("color", { m in m.select(m.visibleItems.first { $0.text == "#3478F6" }!) }),
      ("link", { m in m.select(link) }),
      (
        "link-loading",
        { m in
          m.select(m.visibleItems.first { $0.text?.hasPrefix("https://sspai") == true }!)
        }
      ),
      ("actions", { m in m.showsActions = true }),
    ]
    for dark in [false, true] {
      for (name, configure) in states {
        model.reset()
        configure(model)
        try snapshot(
          ClipboardPanelView(model: model), size: NSSize(width: 760, height: 480), dark: dark,
          to: "\(out)/\(name)\(dark ? "-dark" : "").png")
      }
    }
    // ⌘Y 放大预览：代码（放大的字）、链接（大头图），按各自的理想尺寸
    for (name, prefix) in [("quicklook-code", "import"), ("quicklook-link", "https://developer")] {
      model.reset()
      let item = try #require(model.visibleItems.first { $0.text?.hasPrefix(prefix) == true })
      model.select(item)
      model.showsQuickLookContent = true
      let size = QuickLookView.idealSize(for: item, form: model.contentForm(of: item))
      for dark in [false, true] {
        try snapshot(
          QuickLookView(model: model) { _ in }, size: size, dark: dark,
          to: "\(out)/\(name)\(dark ? "-dark" : "").png")
      }
    }
    try renderTranslate(out)
    // 设置窗：侧栏 + 页头 + 各页表单（关于是品牌页），深色看两页；欢迎引导的每一步
    let hotKeys = HotKeyCenter()
    let services = TranslateServiceStore()
    let history = try HistoryStore(db: Database(path: ":memory:"))
    let speaker = Speaker()
    let pages: (SettingsPage) -> AnyView = { page in
      switch page {
      case .general: AnyView(GeneralTab(importer: LegacyImportTask { "" }))
      case .clipboard: AnyView(ClipboardTab(store: store))
      case .launcher: AnyView(LauncherTab())
      case .screenshot: AnyView(ScreenshotTab())
      case .translate:
        AnyView(TranslateTab(services: services, history: history, speaker: speaker))
      case .hotkeys: AnyView(HotkeysTab(center: hotKeys))
      case .about: AnyView(AboutTab())
      }
    }
    let navigation = SettingsNavigation()
    let savedPage = navigation.page
    for (page, dark) in SettingsPage.allCases.map({ ($0, false) }) + [
      (.about, true), (.clipboard, true),
    ] {
      navigation.page = page
      try snapshot(
        SettingsRoot(navigation: navigation, page: pages) { AnyView(EmptyView()) },
        size: NSSize(width: 780, height: 600), dark: dark,
        to: "\(out)/settings-\(page.rawValue)\(dark ? "-dark" : "").png")
    }
    navigation.page = savedPage  // 别把自检摆的页写进用户偏好
    for step in OnboardingView.Step.allCases {
      try snapshot(
        OnboardingView(importer: LegacyImportTask { "" }, step: step),
        size: NSSize(width: 580, height: 460), dark: step == .welcome,
        to: "\(out)/onboarding-\(step.rawValue).png")
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
    try renderLauncher(out)
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

  private func renderTranslate(_ out: String) throws {
    let history = try HistoryStore(db: Database(path: ":memory:"))
    history.add(
      source: "The quick brown fox", target: .zhHans, result: "敏捷的棕色狐狸", service: "智谱", limit: 0)
    history.add(source: "会议纪要", target: .en, result: "Meeting minutes", service: "智谱", limit: 0)
    let services = TranslateServiceStore()
    let coordinator = TranslateCoordinator(services: services, history: history)
    let speaker = Speaker()
    let zhipu = TranslateService.zhipu
    var gpt = TranslateService.newAI()
    gpt.name = "GPT-4o mini"
    gpt.model = "gpt-4o-mini"
    var claude = TranslateService.newAI()
    claude.name = "Claude"
    claude.aiProtocol = .anthropic
    let states: [(String, (TranslateCoordinator) -> Void)] = [
      ("translate-empty", { _ in }),
      (
        "translate-cards",
        { c in
          c.sourceText =
            "SwiftUI provides views, controls, and layout structures for declaring your app's user interface."
          c.detected = .en
          c.target = .zhHans
          c.cards = [
            .init(service: zhipu, state: .done("SwiftUI 提供了视图、控件和布局结构，用来**声明**应用的用户界面。")),
            .init(service: gpt, state: .running("SwiftUI 提供视图、控件以及")),
            .init(service: claude, state: .failed("密钥无效或没有权限")),
          ]
        }
      ),
      (
        "translate-replace",
        { c in
          c.sourceText = "Ship it"
          c.detected = .en
          c.target = .zhHans
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
      ("translate-history", { c in c.showsHistory = true }),
      ("translate-notice", { c in c.showNotice("划词翻译需要「辅助功能」授权", permission: .accessibility) }),
      ("translate-screenshot-empty", { c in c.showNotice("没有识别到文字，可以把选区框大一些再试") }),
    ]
    for dark in [false, true] {
      for (name, configure) in states {
        coordinator.beginInput()
        configure(coordinator)
        try snapshot(
          TranslatePanelView(coordinator: coordinator, speaker: speaker),
          size: NSSize(width: 420, height: 560), dark: dark,
          to: "\(out)/\(name)\(dark ? "-dark" : "").png")
      }
    }
    // 服务身份：官方 logo（满版 / 垫白底）和还没有 logo 的色块首字母，18 pt 一排 + 36 pt 一排
    var gemini = TranslateService.newAI()
    gemini.name = "Gemini"
    let everyService =
      TranslateService.Kind.allCases.filter { $0 != .ai }.map(TranslateService.builtin) + [
        claude, gemini, gpt,
      ]
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
        tiles, size: NSSize(width: 640, height: 110), dark: dark,
        to: "\(out)/translate-logos\(dark ? "-dark" : "").png")
    }
  }

  /// 启动器：最近使用、搜索结果（中文名 / 拼音）、没有结果；文件搜索（结果、最近的文件、find 按住 ⌘、
  /// 只输 1 个字母，结果是假的、不查 Spotlight）；深浅色
  private func renderLauncher(_ out: String) throws {
    let usage = try LauncherUsage(db: Database(path: ":memory:"))
    let apps = [
      "/System/Applications/Calculator.app", "/System/Applications/Utilities/Activity Monitor.app",
      "/System/Applications/Utilities/Terminal.app", "/System/Applications/Notes.app",
      "/System/Applications/System Settings.app",
    ].map(AppCatalog.item(path:))
    let model = LauncherModel(usage: usage, apps: apps)
    let linux = LauncherItem(
      kind: .url, target: "https://linux.do/latest", title: "linux.do/latest", subtitle: "")
    for (item, times) in [(apps[1], 3), (linux, 5), (LauncherItem.actions[0], 1), (apps[2], 2)] {
      for _ in 0..<times { usage.record(item, query: "") }
    }
    for dark in [false, true] {
      for (name, query) in [
        ("launcher-recent", ""), ("launcher-search", "huo"), ("launcher-empty", "zzzz"),
        ("launcher-calc", "12*3+1"), ("launcher-prompt", "gh"), ("launcher-alternate", "swift ui"),
      ] {
        model.query = query
        model.alternate = name == "launcher-alternate" ? .control : .none
        try snapshot(
          LauncherPanelView(model: model),
          size: NSSize(width: 720, height: LauncherPanelView.height(for: model)),
          dark: dark,
          to: "\(out)/\(name)\(dark ? "-dark" : "").png")
      }
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
      hit("/Downloads/Kitty Tools Native_0.1.0_arm64.dmg", "com.apple.disk-image-udif", daysAgo: 0),
      hit("/Downloads/report.html", "public.html", daysAgo: 1),
      hit("/Desktop/notes.md", "net.daringfireball.markdown", daysAgo: 2),
      hit("/Documents/Projects", "public.folder", daysAgo: 4),
    ]
    for dark in [false, true] {
      for (name, query, hits) in [
        ("launcher-files", "open 报告", found), ("launcher-files-recent", " ", recent),
        ("launcher-files-find", "find 报告", found), ("launcher-files-short", "open a", []),
      ] {
        model.query = query
        // 最近的文件那张带上最后一行的授权提示
        model.folderHint =
          name == "launcher-files-recent" ? FileSearch.accessHint(denied: nil) : nil
        if let request = model.fileRequest, !request.isTooShort {
          model.showFiles(hits, for: request)
        }
        model.alternate = name == "launcher-files-find" ? .command : .none
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
    let states: [(String, Bool, (ScrollCaptureHUD) -> Void)] = [
      (
        "scroll-start", false,
        { $0.show("在选区里滚动，或按空格自动滚动", warning: false, width: 1200, height: 480) }
      ),
      (
        "scroll-preview", false,
        {
          $0.show(
            "在选区里滚动，或按空格自动滚动", warning: false, width: stitcher.width, height: stitcher.outputHeight)
          $0.updatePreview(stitcher: stitcher, scale: 2)
        }
      ),
      (
        "scroll-lost", false,
        {
          $0.show(
            "对不上了：往回滚一点，再慢慢滚", warning: true, width: stitcher.width, height: stitcher.outputHeight)
          $0.updatePreview(stitcher: stitcher, scale: 2)
        }
      ),
      (
        "scroll-auto-dark", true,
        {
          $0.isAutoScrolling = true
          $0.show(
            "自动滚动中：按空格或移开鼠标停止", warning: false, width: stitcher.width, height: stitcher.outputHeight
          )
          $0.updatePreview(stitcher: stitcher, scale: 2)
        }
      ),
    ]
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

  private func snapshot(_ view: some View, size: NSSize, dark: Bool, to path: String) throws {
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
    let bitmap = try #require(background.bitmapImageRepForCachingDisplay(in: background.bounds))
    background.cacheDisplay(in: background.bounds, to: bitmap)
    try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(filePath: path))
    window.orderOut(nil)
  }
}
