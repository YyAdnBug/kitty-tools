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
    let link = try #require(store.items.first { $0.text?.hasPrefix("https") == true })
    store.toggleFavorite([link.id])
    store.update([link.id]) { $0.note = "AppKit 文档" }
    let group = try #require(store.createGroup(named: "工作"))
    let meeting = try #require(store.items.first { $0.text?.hasPrefix("会议") == true })
    store.update([meeting.id]) { $0.groupID = group.id }
    let model = ClipboardPanelModel(store: store)
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
    ]
    for dark in [false, true] {
      for (name, configure) in states {
        model.reset()
        configure(model)
        try snapshot(
          ClipboardPanelView(model: model), size: NSSize(width: 680, height: 520), dark: dark,
          to: "\(out)/\(name)\(dark ? "-dark" : "").png")
      }
    }
    try renderTranslate(out)
    try snapshot(
      ClipboardTab(store: store), size: NSSize(width: 520, height: 760), dark: false,
      to: "\(out)/settings-clipboard.png")
    try snapshot(
      HotkeysTab(center: HotKeyCenter()), size: NSSize(width: 520, height: 200), dark: false,
      to: "\(out)/settings-hotkeys.png")
    try snapshot(
      GeneralTab { "" }, size: NSSize(width: 520, height: 480), dark: false,
      to: "\(out)/settings-general.png")
    for dark in [false, true] {
      try snapshot(
        AboutTab(), size: NSSize(width: 520, height: 460), dark: dark,
        to: "\(out)/settings-about\(dark ? "-dark" : "").png")
    }
    try renderSelection(out)
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
    try snapshot(
      TranslateTab(services: services), size: NSSize(width: 540, height: 600), dark: false,
      to: "\(out)/settings-translate.png")
  }

  /// 截图翻译的框选遮罩：待选（整屏轻暗 + 提示）和拖动中（选区外变暗）
  private func renderSelection(_ out: String) throws {
    let frozen = try ScreenshotTests.render([
      "The quick brown fox jumps over the lazy dog", "敏捷的棕色狐狸跳过了懒狗", "日本語のテキスト",
    ])
    let size = NSSize(width: 600, height: 180)
    for (name, selection) in [
      ("select-idle", nil), ("select-drag", CGRect(x: 10, y: 95, width: 440, height: 60)),
    ] as [(String, CGRect?)] {
      let view = SelectionView(image: frozen) { _ in }
      view.frame = NSRect(origin: .zero, size: size)
      view.selection = selection
      let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: bitmap)
      try #require(bitmap.representation(using: .png, properties: [:]))
        .write(to: URL(filePath: "\(out)/\(name).png"))
    }
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
