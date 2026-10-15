// 便签「点另一条」的屏外量测（手测反馈第 3 批，2026-10-15；按需开，平时不跑）。用户报「便签多的时候点着切换卡」：
// 300 条便签（正文 1–5 KB，带标题、粗体、代码、链接、引用、列表和任务），在屏外的全部便签窗口、屏幕边缘那叠（平时的
// 5 张、「+N」展开成 300 张）里来回点另一条，量两样：
//   - 墙上时间：从改选中到右边那条的正文框建好、排完版；
//   - 主线程 CPU：改选中之后 0.2 秒里主线程实际花了多少（CLOCK_THREAD_CPUTIME_ID：跑环空等不算）。
// 另把几块单独量：列表要的推导（标题、摘要、任务进度）300 条一遍、左边列表的数据（NotesWindowModel.notes）一次、
// 正文编辑器建一个（TextKit 栈 + 整篇样式 + 排版），和打一个字时列表跟着重画花多少。
// 窗口摆在屏外、不当 key、不激活本 App；库在内存里，偏好用临时域。屏外的窗口系统不画图层（MemoryProbeTests 文件头
// 第 4 个坑）：画的那一下不在数里，量的是主线程上的更新、布局和排版。Debug 构建（-Onone）：自己的 Swift 代码比正式版慢几倍，
// 系统框架不受影响——前后对比看同一种构建。
//   TEST_RUNNER_KITTY_NOTES_PROBE=1 xcodebuild -project macos/KittyTools.xcodeproj -scheme KittyTools \
//     test -only-testing:'KittyToolsTests/NotesProbeTests/switching()'
// 结果打在测试的输出里（grep「notes-probe」）。要看主线程忙在哪：另加 TEST_RUNNER_KITTY_NOTES_PROBE_LOOP=window / deck /
// deck-all / editor / pin，只把那一件来回做 10 秒，输出里有「notes-probe loop pid N」，这时 `sample N 6` 拍下来。
// 2026-10-15 改之前、改之后的数（Debug 和 -O 两种构建）在 PLAN §10「便签」的「手测反馈第 3 批」。

import AppKit
import SwiftUI
import Testing

@testable import KittyTools

struct NotesProbeTests {
  /// 第 index 条的正文：1–5 KB，一样的几种行轮着来
  private static func body(_ index: Int) -> String {
    let lines = [
      "## 第 \(index) 条便签里的小标题",
      "这是一段 **粗体** 和 *斜体*，还有 `inline code` 和 [链接](https://example.com/\(index))。",
      "> 引用的一行话，长一点让它折行：慢慢来，比较快，先把现有的行为钉住再挪。",
      "- 列表里的一项 item",
      "☐ 没做完的任务 \(index)",
      "☑ 做完的任务",
      "普通的一行文字，中英混排 mixed text with some words \(index)。",
    ]
    let target = 1024 * (1 + index % 5)
    var body = "第 \(index) 条便签\n"
    var line = 0
    while body.utf8.count < target {
      body += lines[line % lines.count] + "\n"
      line += 1
    }
    return body
  }

  private static func ms(_ duration: Duration) -> Double {
    Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1000
  }

  /// 主线程（这个线程）到现在用了多少 CPU（毫秒）
  private static func cpu() -> Double {
    Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e6
  }

  /// 跑 times 遍取中位数（毫秒）
  private static func median(_ times: Int, _ body: () -> Void) -> Double {
    let clock = ContinuousClock()
    let samples = (0..<times).map { _ in ms(clock.measure(body)) }.sorted()
    return samples[samples.count / 2]
  }

  private static func spin(_ seconds: TimeInterval) {
    let end = Date.now.addingTimeInterval(seconds)
    while Date.now < end {
      RunLoop.main.run(mode: .default, before: .now.addingTimeInterval(0.001))
    }
  }

  /// 做一件事（change），之后 0.2 秒里每 1 ms 转一下跑环：ready() 第一次为真的墙上时间（排版补齐、画一遍算在里面）、
  /// 这 0.2 秒里主线程的 CPU
  private static func timed(_ change: () -> Void, ready: () -> NoteTextView?) -> (
    wall: Double, cpu: Double
  ) {
    let clock = ContinuousClock()
    let start = clock.now
    let cpu0 = cpu()
    change()
    var wall = Double.infinity
    while clock.now - start < .milliseconds(200) {
      RunLoop.main.run(mode: .default, before: .now.addingTimeInterval(0.001))
      if wall == .infinity, let editor = ready() {
        if let layout = editor.layoutManager, let container = editor.textContainer {
          layout.ensureLayout(for: container)
        }
        editor.window?.displayIfNeeded()
        wall = ms(clock.now - start)
      }
    }
    return (wall, cpu() - cpu0)
  }

  private static func report(_ name: String, _ samples: [(wall: Double, cpu: Double)]) {
    let walls = samples.map(\.wall).sorted()
    let cpus = samples.map(\.cpu).sorted()
    let wall =
      walls.last == .infinity
      ? ""
      : "墙上 中位 \(String(format: "%.1f", walls[walls.count / 2])) ms"
        + "（最多 \(String(format: "%.1f", walls.last ?? 0))），"
    print(
      "notes-probe \(name): \(wall)主线程 CPU 中位 "
        + "\(String(format: "%.1f", cpus[cpus.count / 2])) ms（最多 \(String(format: "%.1f", cpus.last ?? 0))）"
    )
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["KITTY_NOTES_PROBE"] != nil))
  func switching() throws {
    let store = try NoteStore(db: Database(path: ":memory:"))
    let t0 = Date(timeIntervalSince1970: 1_760_000_000)
    for index in (0..<300).reversed() {
      store.create(body: Self.body(index), now: t0.addingTimeInterval(Double(300 - index)))
    }
    let notes = store.active
    let ids = notes.map(\.id)
    print(
      "notes-probe 便签 \(notes.count) 条，正文共 \(notes.reduce(0) { $0 + $1.body.utf8.count } / 1024) KB"
    )

    // 单独的几块
    let derive = Self.median(5) {
      for note in notes { _ = (note.displayTitle, note.preview, note.taskProgress) }
    }
    print("notes-probe 推导 300 条（标题 + 摘要 + 任务进度）：\(String(format: "%.2f", derive)) ms")
    _ = notes.map { store.summary(of: $0) }
    let summaries = Self.median(5) { for note in notes { _ = store.summary(of: note) } }
    print("notes-probe 推导 300 条（走仓库的缓存，NoteStore.summary）：\(String(format: "%.2f", summaries)) ms")
    let model = NotesWindowModel(store: store)
    model.layout = .list
    let listing = Self.median(20) { _ = model.notes }
    print("notes-probe NotesWindowModel.notes 一次：\(String(format: "%.3f", listing)) ms")
    model.query = "任务 text"
    let searching = Self.median(5) { _ = model.notes }
    print(
      "notes-probe NotesWindowModel.notes 一次（在搜「任务 text」）：\(String(format: "%.2f", searching)) ms")
    model.query = ""
    let views = Self.median(20) { _ = (store.active, store.archived, store.trashed) }
    print("notes-probe 仓库三个视图各取一次：\(String(format: "%.3f", views)) ms")
    let fiveKB = try #require(notes.first { $0.body.utf8.count > 5000 })
    let editor = Self.median(10) {
      let view = NoteTextView.make()
      view.setPaper(NotePaper.of(fiveKB), fontSize: 15, markdown: true, spacing: .standard)
      view.setText(fiveKB.body)
      view.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
      view.layoutManager?.ensureLayout(for: view.textContainer!)
    }
    print("notes-probe 正文编辑器建一个（5 KB：TextKit 栈 + 整篇样式 + 排版）：\(String(format: "%.2f", editor)) ms")
    // 拆开：建栈、只放字（Markdown 开 / 关）、排版
    for markdown in [true, false] {
      var parts = [Double](repeating: 0, count: 4)
      let clock = ContinuousClock()
      for _ in 0..<5 {
        var view: NoteTextView!
        parts[0] += Self.ms(clock.measure { view = NoteTextView.make() }) / 5
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
        parts[1] +=
          Self.ms(
            clock.measure {
              view.setPaper(
                NotePaper.of(fiveKB), fontSize: 15, markdown: markdown, spacing: .standard)
            }) / 5
        parts[2] += Self.ms(clock.measure { view.setText(fiveKB.body) }) / 5
        parts[3] +=
          Self.ms(
            clock.measure {
              view.layoutManager?.ensureLayout(for: view.textContainer!)
            }) / 5
      }
      print(
        "notes-probe   拆开（Markdown \(markdown ? "开" : "关")）：建栈 \(String(format: "%.2f", parts[0]))、"
          + "纸色 \(String(format: "%.2f", parts[1]))、放字 \(String(format: "%.2f", parts[2]))、"
          + "排版 \(String(format: "%.2f", parts[3])) ms")
    }
    if ProcessInfo.processInfo.environment["KITTY_NOTES_PROBE_LOOP"] == "editor" {
      print("notes-probe loop pid \(ProcessInfo.processInfo.processIdentifier)")
      let end = Date.now.addingTimeInterval(10)
      while Date.now < end {
        let view = NoteTextView.make()
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
        view.setPaper(NotePaper.of(fiveKB), fontSize: 15, markdown: true, spacing: .standard)
        view.setText(fiveKB.body)
      }
      return
    }
    // 同一份带样式的字交给不挂代理的 TextKit 1 文本视图（对照：排版本身多贵），和挂了代理的（藏标记那一问）
    let source = NSTextStorage(string: fiveKB.body)
    NoteStyles.apply(
      to: source, lines: NSRange(location: 0, length: source.length),
      theme: NoteStyles.Theme(
        paper: NotePaper.of(fiveKB), fontSize: 15, markdown: true, spacing: .standard),
      shown: [], blocks: [])
    for delegated in [false, true] {
      let plain = Self.median(5) {
        let view = NoteTextView.make()
        if !delegated { view.layoutManager?.delegate = nil }
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
        view.textStorage?.setAttributedString(source)
        view.layoutManager?.ensureLayout(for: view.textContainer!)
      }
      print(
        "notes-probe   对照：排好样式的字直接放进去（\(delegated ? "挂着" : "不挂")布局代理）：\(String(format: "%.2f", plain)) ms"
      )
    }
    let styled = Self.median(5) {
      let storage = NSTextStorage(string: fiveKB.body)
      NoteStyles.apply(
        to: storage, lines: NSRange(location: 0, length: storage.length),
        theme: NoteStyles.Theme(
          paper: NotePaper.of(fiveKB), fontSize: 15, markdown: true, spacing: .standard),
        shown: [], blocks: [])
    }
    print("notes-probe   其中 NoteStyles.apply 整篇（不排版）：\(String(format: "%.2f", styled)) ms")

    // 全部便签窗口（同 NotesWindowTests 的屏外窗口：带标题栏、摆在屏外、不当 key）
    let suite = "kitty-notes-probe-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let hosting = NSHostingController(
      rootView: NotesWindowView(model: model).defaultAppStorage(defaults))
    hosting.sceneBridgingOptions = [.title, .toolbars]
    let window = ProbeWindow(contentViewController: hosting)
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    window.toolbarStyle = .unified
    window.setContentSize(NSSize(width: 940, height: 580))
    window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    try #require(window.screen == nil && !window.isKeyWindow)
    Self.spin(0.5)
    func select(_ id: String) -> (wall: Double, cpu: Double) {
      Self.timed(
        { model.selection = id },
        ready: {
          NotesWindow.editor(in: window.contentView).flatMap {
            $0.identifier?.rawValue == id ? $0 : nil
          }
        })
    }
    // 拿 sample 看主线程忙在哪：TEST_RUNNER_KITTY_NOTES_PROBE_LOOP=window 时只在这里来回切 10 秒
    if ProcessInfo.processInfo.environment["KITTY_NOTES_PROBE_LOOP"] == "window" {
      print("notes-probe loop pid \(ProcessInfo.processInfo.processIdentifier)")
      let end = Date.now.addingTimeInterval(10)
      var round = 0
      while Date.now < end {
        _ = select(ids[round % 2 == 0 ? 4 : 0])
        round += 1
      }
      return
    }
    // 先各点开一次（「看过的」），再来回切 12 次（用户说的「切回来」）；另点 12 条没看过的
    _ = select(ids[0])
    _ = select(ids[4])
    Self.report("全部便签窗口 来回切（看过的两条）", (0..<12).map { select(ids[$0 % 2 == 0 ? 4 : 0]) })
    Self.report("全部便签窗口 点没看过的", (0..<12).map { select(ids[10 + $0 * 7]) })
    // 列表跟着重画：别处改了一条（固定 / 取消固定），右边那条在打字（每个字仓库都变一次）
    let cpuOnly = { (change: () -> Void) -> (wall: Double, cpu: Double) in
      Self.timed(change) { nil }
    }
    Self.report(
      "全部便签窗口 固定 / 取消固定一条（列表重画）",
      (0..<8).map { round in cpuOnly { store.setPinned(round % 2 == 0, of: ids[2]) } })
    if ProcessInfo.processInfo.environment["KITTY_NOTES_PROBE_LOOP"] == "pin" {
      print("notes-probe loop pid \(ProcessInfo.processInfo.processIdentifier)")
      let end = Date.now.addingTimeInterval(10)
      var round = 0
      while Date.now < end {
        _ = cpuOnly { store.setPinned(round % 2 == 0, of: ids[2]) }
        round += 1
      }
      return
    }
    // 在右边的正文里打一个字（走文本视图自己的路：改字 → 交给仓库 → 列表里那一行跟着变）
    let typing = try #require(NotesWindow.editor(in: window.contentView))
    Self.report(
      "全部便签窗口 正文里打一个字",
      (0..<8).map { _ in
        cpuOnly {
          typing.insertText("字", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
      })
    // 别处改了另一条的正文（列表里那一行重画）
    Self.report(
      "全部便签窗口 别处改了另一条的正文",
      (0..<8).map { round in
        cpuOnly {
          store.setBody(Self.body(2) + String(repeating: "字", count: round + 1), of: ids[2])
        }
      })

    // 屏幕边缘那叠：摆在离所有屏幕很远的地方、不当 key；打开的便签先固定上（开着时装着全局的鼠标监听）
    let far = NoteDeckScreen(
      name: "测试", frame: CGRect(x: -40000, y: -40000, width: 1440, height: 900),
      visibleFrame: CGRect(x: -40000, y: -40000, width: 1440, height: 875))
    for frame in [NoteDeckLayout.panelFrame(on: far, edge: .right, options: NoteDeckOptions())] {
      try #require(
        !NSScreen.screens.contains { $0.frame.insetBy(dx: -2000, dy: -2000).intersects(frame) })
    }
    for id in ids { store.setPinned(true, of: id) }
    let deck = NoteDeck(store: store, island: nil, takesKeyboard: false)
    defer { deck.close() }
    deck.place(on: far, edge: .right, options: NoteDeckOptions())
    deck.model.send(.pillEntered(optionDown: false, allowed: true))
    Self.spin(0.5)
    func tap(_ id: String) -> (wall: Double, cpu: Double) {
      Self.timed(
        { deck.model.tapTab(id) }, ready: { NoteDeck.editor(for: id, in: deck.panel?.contentView) })
    }
    _ = tap(ids[0])
    _ = tap(ids[3])
    if let loop = ProcessInfo.processInfo.environment["KITTY_NOTES_PROBE_LOOP"],
      loop.hasPrefix("deck")
    {
      if loop == "deck-all" {
        deck.model.send(.showAll)
        Self.spin(0.3)
      }
      print("notes-probe loop pid \(ProcessInfo.processInfo.processIdentifier)")
      let end = Date.now.addingTimeInterval(10)
      var round = 0
      while Date.now < end {
        _ = tap(ids[round % 2 == 0 ? 0 : 3])
        round += 1
      }
      return
    }
    Self.report("那叠 来回切（5 张标签）", (0..<12).map { tap(ids[$0 % 2 == 0 ? 0 : 3]) })
    deck.model.send(.showAll)
    Self.spin(0.3)
    Self.report("那叠 来回切（「+N」展开成 300 张）", (0..<12).map { tap(ids[$0 % 2 == 0 ? 0 : 3]) })
    Self.report("那叠 点没看过的（300 张）", (0..<12).map { tap(ids[20 + $0 * 9]) })
  }
}

/// 带标题栏的窗口摆在屏外（系统默认会把它挪回屏幕里）
private final class ProbeWindow: NSWindow {
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }
}
