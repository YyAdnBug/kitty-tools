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
// 手测反馈第 6 批（2026-10-16）另加两个，开法一样（-only-testing 换成下面的函数名）：
//   - longNote()：长便签（20 / 50 KB，标题、折行的段落、列表、任务、代码块、引用）——正文编辑器拆开量（建栈、纸色、放字、
//     首屏排版、排完整篇，和挂 / 不挂布局代理排完整篇的对照），全部便签窗口的列表里在短的和长的之间点着切、便签墙上点开
//     长的：首屏多久、之后 1.5 秒里最长的一下（「卡一下」）、主线程 CPU、排版排完没有。加 TEST_RUNNER_KITTY_NOTES_PROBE_SLICES=1
//     把超过 16 ms 的每一下都打出来；LOOP=long（列表里来回切）/ wall-long（墙上开开关关）给 sample 用。
//   - wallEntry()：300 条的便签墙——第一次进墙、开关 Markdown、再建一个窗口（卡片缓存还在）各自多久、后面分批建卡片建到哪；
//     LOOP=markdown（隔两秒开关一次 Markdown）给 sample 用。
// 这两次改之前、改之后的数（-O）在 PLAN §10「便签」的「手测反馈第 6 批」。
//   - wallAnimation()：300 条的便签墙上点开 / 收回编辑卡（50 KB 的长便签、1 KB 的短便签对照）——动画期间每一帧主线程
//     多久、1 秒里一共多少；SLICES=1 打出每一轮，LOOP=wall-anim / wall-anim-short 给 sample 用。前后的数在同一节的
//     「便签墙编辑卡动画」那一条。

import AppKit
import SwiftUI
import Testing
import UniformTypeIdentifiers

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

  /// 第 7 批行内图片的量：1 MB / 200 张图的便签——载入（令牌 → 附件 + 上样式 + 排版）、打一个字（附件 → 令牌 + 重排）、
  /// 和同样大小、没有图的便签对照；画一遍之后缩略图缓存占多少像素。
  ///   TEST_RUNNER_KITTY_NOTES_PROBE=1 xcodebuild -project macos/KittyTools.xcodeproj -scheme KittyTools \
  ///     test -only-testing:'KittyToolsTests/NotesProbeTests/images()'
  @Test(.enabled(if: ProcessInfo.processInfo.environment["KITTY_NOTES_PROBE"] != nil))
  func images() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "kitty-notes-image-probe-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = NoteImageStore(directory: directory)
    var pictures: [NoteImages.Image] = []
    for index in 0..<40 {
      let id = UUID()
      let url = directory.appending(path: "\(id.uuidString).png")
      try NoteImageFixture.data(type: .png, width: 600 + index * 4, height: 400)
        .write(to: url)
      let image = NoteImages.Image(id: id, ext: "png", width: nil)
      store.remember(
        NoteImageStore.Stored(
          image: image, size: try #require(NoteImageStore.readSize(at: url))))
      pictures.append(image)
    }
    // 1 MB 的正文、约 200 张图：每段 5 KB 字 + 一行图
    let segment = (1...60).map { "第 \($0) 行：中英混排 mixed text with some words，慢慢来，比较快。\n" }
      .joined()
    var body = ""
    var counter = 0
    while body.utf8.count < 1 << 20 {
      body += segment + NoteImages.token(pictures[counter % pictures.count]) + "\n"
      counter += 1
    }
    let images = counter
    // 对照：把令牌换成「[图片]」（一样的文字、没有附件）
    let plain = body.replacingOccurrences(
      of: #"!\[image(\|[0-9]+)?\]\(kitty-note-image://[^)]*\)"#, with: "[图片]",
      options: .regularExpression)
    print("notes-probe 正文 \(body.utf8.count / 1024) KB、\(images) 张图（\(pictures.count) 个文件）")

    func load(_ text: String) -> NoteTextView {
      let view = NoteTextView.make()
      view.imageStore = store
      view.frame = NSRect(x: 0, y: 0, width: 600, height: 900)
      view.setPaper(
        NotePaper.all[0], fontSize: 15, markdown: true, spacing: .standard, paperIndex: 0)
      view.setText(text)
      if let layout = view.layoutManager, let container = view.textContainer {
        layout.ensureLayout(for: container)
      }
      return view
    }
    func firstScreen(_ view: NoteTextView) {
      if let layout = view.layoutManager, let container = view.textContainer {
        layout.ensureLayout(
          forCharacterRange: NSRange(location: 0, length: min(4000, view.textStorage?.length ?? 0)))
        _ = container
      }
    }
    let loadedImages = Self.median(3) { _ = load(body) }
    let loadedPlain = Self.median(3) { _ = load(plain) }
    print(
      "notes-probe 载入整篇（含排版到底）：有图 \(String(format: "%.1f", loadedImages)) ms，没图 \(String(format: "%.1f", loadedPlain)) ms"
    )
    let firstImages = Self.median(3) {
      let view = NoteTextView.make()
      view.imageStore = store
      view.frame = NSRect(x: 0, y: 0, width: 600, height: 900)
      view.setPaper(
        NotePaper.all[0], fontSize: 15, markdown: true, spacing: .standard, paperIndex: 0)
      view.setText(body)
      firstScreen(view)
    }
    print("notes-probe 载入 + 首屏排版：\(String(format: "%.1f", firstImages)) ms")

    // 打一个字：走完 shouldChangeText → 改字 → didChangeText（settle：附件 → 令牌 + 重排那几行）。
    // **两边同样的正文末尾**（2026-10-16 评审 F30）：都追加同一行普通文字，光标放在那一行里——原来一个有图、一个没图，
    // 末尾还不一样，比不了
    let tail = "\n末尾一行普通文字，中英混排 mixed text，用来把光标放在同一处。\n"
    for (name, text) in [("有图", body), ("没图", plain)] {
      let view = load(text + tail)
      view.setSelectedRange(NSRange(location: (view.textStorage?.length ?? 1) - 20, length: 0))
      var samples: [Double] = []
      for _ in 0..<10 {
        let start = Self.cpu()
        view.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
        samples.append(Self.cpu() - start)
      }
      samples.sort()
      print(
        "notes-probe 打一个字（主线程 CPU）：\(name) 中位 \(String(format: "%.1f", samples[samples.count / 2])) ms，最多 \(String(format: "%.1f", samples.last ?? 0)) ms"
      )
    }
    // 50 张大图便签「换到这一条」的首屏耗时（SPEC §9.6；2026-10-16 评审 F30 补量）：
    // 每条一张 900 × 600 的图、正文 4 KB，量「setText + 首屏排版」——换一条便签时主线程上最大的一块
    var manyBodies: [String] = []
    for index in 0..<50 {
      let image = pictures[index % pictures.count]
      var note = "第 \(index) 条带大图的便签\n"
      while note.utf8.count < 4 * 1024 { note += segment }
      note += NoteImages.token(image) + "\n末尾一行\n"
      manyBodies.append(note)
    }
    let switchToImage = Self.median(5) {
      let view = NoteTextView.make()
      view.imageStore = store
      view.frame = NSRect(x: 0, y: 0, width: 600, height: 900)
      view.setPaper(
        NotePaper.all[0], fontSize: 15, markdown: true, spacing: .standard, paperIndex: 0)
      view.setText(manyBodies[25])
      firstScreen(view)
    }
    let switchToPlain = Self.median(5) {
      let view = NoteTextView.make()
      view.imageStore = store
      view.frame = NSRect(x: 0, y: 0, width: 600, height: 900)
      view.setPaper(
        NotePaper.all[0], fontSize: 15, markdown: true, spacing: .standard, paperIndex: 0)
      view.setText(
        manyBodies[25].replacingOccurrences(
          of: #"!\[image(\|[0-9]+)?\]\(kitty-note-image://[^)]*\)"#, with: "[图片]",
          options: .regularExpression))
      firstScreen(view)
    }
    print(
      "notes-probe 50 张大图便签换过去的首屏（4 KB 正文 + 一张 900 × 600 的图）：有图 \(String(format: "%.1f", switchToImage)) ms，没图 \(String(format: "%.1f", switchToPlain)) ms"
    )

    // 互转本身：整篇附件 → 令牌
    let view = load(body)
    if let storage = view.textStorage {
      let convert = Self.median(5) { _ = NoteImageAttachment.stored(from: storage) }
      print("notes-probe 附件 → 令牌（整篇 \(storage.length) 个字）：\(String(format: "%.1f", convert)) ms")
    }
    // 缩略图缓存：画一遍看得见的那一屏（600 × 900），再看缓存占多少
    NoteImageThumbnails.discard()
    let draw = view
    // 画头三屏（600 × 2700；正文里每 ~2.7 KB 一张图，一屏 900 pt 里往往一张都没有）：缓存里进了几张、占多少像素。
    // 上限是 NoteImageThumbnails.maxCost（一两屏 Retina 满宽大图），写进 PLAN
    let area = NSRect(x: 0, y: 0, width: 600, height: 2700)
    let rep = try #require(draw.bitmapImageRepForCachingDisplay(in: area))
    draw.cacheDisplay(in: area, to: rep)
    for _ in 0..<200 where NoteImageThumbnails.cost == 0 {
      RunLoop.main.run(until: Date.now.addingTimeInterval(0.02))
    }
    draw.cacheDisplay(in: area, to: rep)
    print(
      "notes-probe 缩略图缓存：画头三屏之后 \(NoteImageThumbnails.cost) 像素 / \(NoteImageThumbnails.count) 张（约 \(NoteImageThumbnails.cost * 4 / 1024 / 1024) MB 位图；上限 \(NoteImageThumbnails.maxCost) 像素）"
    )
    NoteImageThumbnails.discard()
    print("notes-probe 放掉之后：\(NoteImageThumbnails.cost) 像素")
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
    let window = ProbeWindow(
      contentViewController: .windowContent(
        NotesWindowView(model: model).defaultAppStorage(defaults)))
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

  // MARK: 长便签（手测反馈第 6 批 A3：「切到文字多的便签时，过渡还是会卡一下」）

  /// 一条长便签的正文：约 kb KB，标题、折行的段落、列表、任务、代码块、引用轮着来
  private static func longBody(_ kb: Int, seed: Int) -> String {
    let blocks = [
      "## 第 \(seed) 节的小标题",
      "这是一段比较长的正文，中英混排 mixed with English words，**粗体** 和 *斜体*、`inline code`、"
        + "[链接](https://example.com/\(seed))，写长一点让它在正文框里折成两三行，看看排版要多久。",
      "- 列表里的一项，item \(seed)\n- 第二项 **粗**\n  - 缩进的一项",
      "☐ 没做完的任务 \(seed)\n☑ 做完的任务 ~~划掉~~",
      "```swift\nlet value = \(seed)\nfunc f(_ x: Int) -> Int { x * 2 }\n// 注释 **不粗**\n```",
      "> 引用的一行话，长一点让它折行：慢慢来，比较快，先把现有的行为钉住再挪。\n> 第二行引用",
      "普通的一行文字。",
    ]
    var body = "# 长便签 \(seed)\n"
    var index = 0
    while body.utf8.count < kb * 1024 {
      body += blocks[index % blocks.count] + "\n"
      index += 1
    }
    return body
  }

  /// 做一件事（change），之后 seconds 秒里每 1 ms 转一下跑环：ready() 第一次给出正文框、画完一遍的墙上时间（不强制
  /// 排完整篇：只排要画的那一屏）、这段时间里最长的一下（一次 change / 一轮跑环占了主线程多久——「卡一下」）、
  /// 主线程 CPU、到最后排版排到了哪（没排完的字数）
  private static func hitches(
    _ seconds: Double, _ change: () -> Void, ready: () -> NoteTextView?
  ) -> (first: Double, longest: Double, cpu: Double, unlaid: Int) {
    let clock = ContinuousClock()
    let start = clock.now
    let cpu0 = cpu()
    change()
    var longest = ms(clock.now - start)
    var first = Double.infinity
    var editor: NoteTextView?
    // 超过一帧（16 ms）的那几下：什么时候开始（离 change 多久）、多长
    var slow = longest > 16 ? [(0.0, longest)] : []
    while clock.now - start < .milliseconds(Int(seconds * 1000)) {
      let slice = clock.now
      RunLoop.main.run(mode: .default, before: .now.addingTimeInterval(0.001))
      if first == .infinity, let found = ready() {
        found.window?.displayIfNeeded()
        first = ms(clock.now - start)
        editor = found
      }
      let took = ms(clock.now - slice)
      if took > 16 { slow.append((ms(slice - start), took)) }
      longest = max(longest, took)
    }
    if ProcessInfo.processInfo.environment["KITTY_NOTES_PROBE_SLICES"] != nil {
      print(
        "notes-probe     超过 16 ms 的几下（开始于 / 多长）："
          + slow.map { String(format: "%.0f/%.0f", $0.0, $0.1) }.joined(separator: "  "))
    }
    let unlaid = editor.flatMap { view in
      view.layoutManager.map { (view.textStorage?.length ?? 0) - $0.firstUnlaidCharacterIndex() }
    }
    return (first, longest, cpu() - cpu0, unlaid ?? -1)
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["KITTY_NOTES_PROBE"] != nil))
  func longNote() throws {
    let store = try NoteStore(db: Database(path: ":memory:"))
    let t0 = Date(timeIntervalSince1970: 1_760_000_000)
    for index in (0..<30).reversed() {
      store.create(body: Self.body(index), now: t0.addingTimeInterval(Double(30 - index)))
    }
    store.create(body: Self.longBody(50, seed: 2), now: t0.addingTimeInterval(100))
    store.create(body: Self.longBody(20, seed: 1), now: t0.addingTimeInterval(101))
    let ids = store.active.map(\.id)
    let (twenty, fifty) = (try #require(store.note(ids[0])), try #require(store.note(ids[1])))
    print(
      "notes-probe 长便签 \(twenty.body.utf8.count / 1024) KB / \(fifty.body.utf8.count / 1024) KB，"
        + "\((fifty.body as NSString).length) 个字（UTF-16）")

    // 拆开（50 KB）：建栈、纸色、放字（认代码块 + 整篇样式 + 换进文本存储）、首屏排版、排完整篇
    for note in [twenty, fifty] {
      var parts = [Double](repeating: 0, count: 6)
      let clock = ContinuousClock()
      let rounds = 5
      for _ in 0..<rounds {
        var view: NoteTextView!
        parts[0] += Self.ms(clock.measure { view = NoteTextView.make() }) / Double(rounds)
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
        parts[1] +=
          Self.ms(
            clock.measure {
              view.setPaper(
                NotePaper.of(note), fontSize: 15, markdown: true, spacing: .standard)
            }) / Double(rounds)
        parts[2] += Self.ms(clock.measure { view.setText(note.body) }) / Double(rounds)
        parts[3] +=
          Self.ms(
            clock.measure {
              view.layoutManager?.ensureLayout(
                forBoundingRect: NSRect(x: 0, y: 0, width: 600, height: 500),
                in: view.textContainer!)
            }) / Double(rounds)
        parts[4] +=
          Self.ms(clock.measure { view.layoutManager?.ensureLayout(for: view.textContainer!) })
          / Double(rounds)
      }
      let blocks = Self.median(5) {
        _ = NoteMarkdown.codeBlocks(in: note.body as NSString)
      }
      let styled = Self.median(5) {
        let storage = NSTextStorage(string: note.body)
        NoteStyles.apply(
          to: storage, lines: NSRange(location: 0, length: storage.length),
          theme: NoteStyles.Theme(
            paper: NotePaper.of(note), fontSize: 15, markdown: true, spacing: .standard),
          shown: [], blocks: NoteMarkdown.codeBlocks(in: storage.mutableString))
      }
      print(
        "notes-probe   \(note.body.utf8.count / 1024) KB 拆开：建栈 \(String(format: "%.2f", parts[0]))、"
          + "纸色 \(String(format: "%.2f", parts[1]))、放字 \(String(format: "%.2f", parts[2]))"
          + "（其中认代码块 \(String(format: "%.2f", blocks))、整篇样式 \(String(format: "%.2f", styled))）、"
          + "首屏排版 \(String(format: "%.2f", parts[3]))、排完整篇 \(String(format: "%.2f", parts[4])) ms")
      // 排版本身：同一份排好样式的字，挂 / 不挂布局代理（行高居中、藏标记那几问）排完整篇
      let source = NSTextStorage(string: note.body)
      NoteStyles.apply(
        to: source, lines: NSRange(location: 0, length: source.length),
        theme: NoteStyles.Theme(
          paper: NotePaper.of(note), fontSize: 15, markdown: true, spacing: .standard),
        shown: [], blocks: NoteMarkdown.codeBlocks(in: source.mutableString))
      for delegated in [false, true] {
        let full = Self.median(3) {
          let view = NoteTextView.make()
          if !delegated { view.layoutManager?.delegate = nil }
          view.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
          view.textStorage?.setAttributedString(source)
          view.layoutManager?.ensureLayout(for: view.textContainer!)
        }
        print(
          "notes-probe     对照：排好样式的字放进去排完整篇（\(delegated ? "挂着" : "不挂")布局代理）："
            + "\(String(format: "%.2f", full)) ms")
      }
    }

    // 全部便签窗口：列表视图里点着切（短 ↔ 长），便签墙上点开长的那张
    let suite = "kitty-notes-probe-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = NotesWindowModel(store: store)
    model.layout = .list
    let window = ProbeWindow(
      contentViewController: .windowContent(
        NotesWindowView(model: model).defaultAppStorage(defaults)))
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    window.toolbarStyle = .unified
    window.setContentSize(NSSize(width: 940, height: 580))
    window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    try #require(window.screen == nil && !window.isKeyWindow)
    Self.spin(0.5)
    func editor(_ id: String) -> NoteTextView? {
      NotesWindow.editor(in: window.contentView, for: id).flatMap {
        $0.identifier?.rawValue == id ? $0 : nil
      }
    }
    func report(
      _ name: String, _ samples: [(first: Double, longest: Double, cpu: Double, unlaid: Int)]
    ) {
      func median(_ values: [Double]) -> String {
        String(format: "%.1f", values.sorted()[values.count / 2])
      }
      print(
        "notes-probe \(name)：首屏 中位 \(median(samples.map(\.first))) ms，"
          + "最长的一下 中位 \(median(samples.map(\.longest))) ms（最多 "
          + "\(String(format: "%.1f", samples.map(\.longest).max() ?? 0))），"
          + "1.5 秒里主线程 CPU 中位 \(median(samples.map(\.cpu))) ms，"
          + "没排完的字 \(samples.map(\.unlaid).max() ?? -1)")
    }
    func select(_ id: String) -> (first: Double, longest: Double, cpu: Double, unlaid: Int) {
      Self.hitches(1.5, { model.selection = id }, ready: { editor(id) })
    }
    if ProcessInfo.processInfo.environment["KITTY_NOTES_PROBE_LOOP"] == "long" {
      print("notes-probe loop pid \(ProcessInfo.processInfo.processIdentifier)")
      let end = Date.now.addingTimeInterval(10)
      var round = 0
      while Date.now < end {
        model.selection = ids[round % 2 == 0 ? 1 : 5]
        Self.spin(0.3)
        round += 1
      }
      return
    }
    _ = select(ids[5])
    var toLong: [(first: Double, longest: Double, cpu: Double, unlaid: Int)] = []
    var toTwenty: [(first: Double, longest: Double, cpu: Double, unlaid: Int)] = []
    for _ in 0..<5 {
      toLong.append(select(ids[1]))
      _ = select(ids[5])
      toTwenty.append(select(ids[0]))
      _ = select(ids[5])
    }
    report("列表 切到 50 KB 的", toLong)
    report("列表 切到 20 KB 的", toTwenty)
    model.layout = .wall
    Self.spin(0.5)
    if ProcessInfo.processInfo.environment["KITTY_NOTES_PROBE_LOOP"] == "wall-long" {
      print("notes-probe loop pid \(ProcessInfo.processInfo.processIdentifier)")
      let end = Date.now.addingTimeInterval(10)
      while Date.now < end {
        model.open(ids[1], focus: false)
        Self.spin(0.4)
        model.collapse()
        Self.spin(0.4)
      }
      return
    }
    var wall: [(first: Double, longest: Double, cpu: Double, unlaid: Int)] = []
    for _ in 0..<5 {
      wall.append(
        Self.hitches(1.5, { model.open(ids[1], focus: false) }, ready: { editor(ids[1]) }))
      model.collapse()
      Self.spin(0.6)
    }
    report("便签墙 点开 50 KB 的", wall)
  }

  // MARK: 第一次进便签墙（手测反馈第 6 批 B6：「第一次进墙卡在主线程」）

  /// 300 条便签的墙：建窗口到画出第一屏、之后 1.5 秒里最长的一下和主线程 CPU；开关 Markdown 一次；关掉再开（同一个
  /// 模型和仓库，缓存还在）
  @Test(.enabled(if: ProcessInfo.processInfo.environment["KITTY_NOTES_PROBE"] != nil))
  func wallEntry() throws {
    let store = try NoteStore(db: Database(path: ":memory:"))
    let t0 = Date(timeIntervalSince1970: 1_760_000_000)
    for index in (0..<300).reversed() {
      store.create(body: Self.body(index), now: t0.addingTimeInterval(Double(300 - index)))
    }
    let suite = "kitty-notes-probe-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = NotesWindowModel(store: store)
    func line(_ name: String, _ sample: (first: Double, longest: Double, cpu: Double, unlaid: Int))
    {
      print(
        "notes-probe \(name)："
          + (sample.first.isFinite ? "第一屏 \(String(format: "%.1f", sample.first)) ms，" : "")
          + "最长的一下 \(String(format: "%.1f", sample.longest)) ms（含建窗口那一下），"
          + "1.5 秒里主线程 CPU \(String(format: "%.1f", sample.cpu)) ms")
    }
    var window: ProbeWindow?
    func open() -> (first: Double, longest: Double, cpu: Double, unlaid: Int) {
      var built = 0.0
      let sample = Self.hitches(
        1.5,
        {
          let clock = ContinuousClock()
          let start = clock.now
          let made = ProbeWindow(
            contentViewController: .windowContent(
              NotesWindowView(model: model).defaultAppStorage(defaults)))
          made.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
          made.toolbarStyle = .unified
          made.setContentSize(NSSize(width: 940, height: 580))
          made.setFrameOrigin(NSPoint(x: -20000, y: -20000))
          made.isReleasedWhenClosed = false
          made.orderFront(nil)
          made.displayIfNeeded()
          window = made
          built = Self.ms(clock.now - start)
        },
        ready: { nil })
      return (built, sample.longest, sample.cpu, sample.unlaid)
    }
    /// 建好了几张卡片（Markdown 开着 / 关着的）
    func built(_ markdown: Bool) -> Int {
      store.active.filter { store.cachedWallCard(of: $0, markdown: markdown) != nil }.count
    }
    line("第一次进墙（300 条）", open())
    if ProcessInfo.processInfo.environment["KITTY_NOTES_PROBE_LOOP"] == "markdown" {
      print("notes-probe loop pid \(ProcessInfo.processInfo.processIdentifier)")
      for round in 0..<5 {
        defaults.set(round % 2 == 1, forKey: Prefs.notesMarkdown)
        Self.spin(2)
      }
      window?.close()
      return
    }
    print("notes-probe   1.5 秒后卡片建好了 \(built(true)) 张")
    line(
      "开关 Markdown",
      Self.hitches(1.5, { defaults.set(false, forKey: Prefs.notesMarkdown) }, ready: { nil }))
    print("notes-probe   1.5 秒后卡片建好了 \(built(false)) 张")
    let clock = ContinuousClock()
    let start = clock.now
    while built(false) < store.active.count, clock.now - start < .seconds(10) { Self.spin(0.05) }
    print(
      "notes-probe   全部建好用了 \(String(format: "%.1f", Self.ms(clock.now - start) + 1500)) ms（从开关算起）")
    window?.close()
    window = nil
    model.closed()
    Self.spin(0.3)
    line("再建一个窗口（同一个仓库，卡片缓存还在）", open())
    window?.close()
  }

  // MARK: 便签墙上编辑卡放大 / 收回的动画（手测反馈第 6 批之后：动画的每一帧整面墙都重排、重画）

  /// 做一件事（change），之后 seconds 秒里每 1 ms 转一下跑环：每一轮（第一轮连 change 本身）离开始多久、
  /// 主线程用了多少 CPU、墙上多久
  private static func slices(_ seconds: Double, _ change: () -> Void) -> [(
    at: Double, cpu: Double, wall: Double
  )] {
    let clock = ContinuousClock()
    let start = clock.now
    var cpu0 = cpu()
    change()
    var result: [(at: Double, cpu: Double, wall: Double)] = []
    var slice = start
    repeat {
      RunLoop.main.run(mode: .default, before: .now.addingTimeInterval(0.001))
      let (now, cpu1) = (clock.now, cpu())
      result.append((ms(slice - start), cpu1 - cpu0, ms(now - slice)))
      (slice, cpu0) = (now, cpu1)
    } while clock.now - start < .milliseconds(Int(seconds * 1000))
    return result
  }

  /// 300 条便签的墙（顶上一张 50 KB 的长便签、第二张 1 KB 的短便签对照），屏外窗口 940 × 580：点开、收回编辑卡，
  /// 各量之后 1 秒。「第一下」= 改 expanded 到第一轮有活的更新做完（点开时建编辑区在里面）；「之后每帧」= 之后每一轮跑环
  /// 主线程用了超过 1 ms CPU 的（动画的一帧、正文框补样式的一段）：几帧、最长、平均；「1 秒合计」= 这 1 秒里主线程的 CPU。
  /// 加 TEST_RUNNER_KITTY_NOTES_PROBE_SLICES=1 把每一轮超过 1 ms 的都打出来；LOOP=wall-anim（长的）/ wall-anim-short（短的）
  /// 隔 0.6 秒开关一次、开 10 秒，wall-anim-select 隔 0.3 秒换一次选中的（不打开），给 sample 用
  @Test(.enabled(if: ProcessInfo.processInfo.environment["KITTY_NOTES_PROBE"] != nil))
  func wallAnimation() throws {
    let store = try NoteStore(db: Database(path: ":memory:"))
    let t0 = Date(timeIntervalSince1970: 1_760_000_000)
    for index in (0..<300).reversed() {
      store.create(body: Self.body(index), now: t0.addingTimeInterval(Double(300 - index)))
    }
    store.create(body: Self.longBody(50, seed: 2), now: t0.addingTimeInterval(400))
    let ids = store.active.map(\.id)
    let (long, short) = (ids[0], ids[1])
    try #require((store.note(long)?.body.utf8.count ?? 0) > 50_000)
    try #require((store.note(short)?.body.utf8.count ?? 0) < 1100)
    let suite = "kitty-notes-probe-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = NotesWindowModel(store: store)
    #expect(model.layout == .wall)
    let window = ProbeWindow(
      contentViewController: .windowContent(
        NotesWindowView(model: model).defaultAppStorage(defaults)))
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    window.toolbarStyle = .unified
    window.setContentSize(NSSize(width: 940, height: 580))
    window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    try #require(window.screen == nil && !window.isKeyWindow)
    // 卡片都建好（分批的建完）再量
    let clock = ContinuousClock()
    let start = clock.now
    while store.active.contains(where: { store.cachedWallCard(of: $0, markdown: true) == nil }),
      clock.now - start < .seconds(10)
    {
      Self.spin(0.05)
    }
    Self.spin(0.5)
    if let loop = ProcessInfo.processInfo.environment["KITTY_NOTES_PROBE_LOOP"],
      loop.hasPrefix("wall-anim")
    {
      let id = loop == "wall-anim-short" ? short : long
      print("notes-probe loop pid \(ProcessInfo.processInfo.processIdentifier)")
      let end = Date.now.addingTimeInterval(10)
      var round = 0
      while loop == "wall-anim-select", Date.now < end {
        model.selection = ids[1 + round % 2]
        round += 1
        Self.spin(0.3)
      }
      while Date.now < end {
        model.open(id, focus: false)
        Self.spin(0.6)
        model.collapse()
        Self.spin(0.6)
      }
      return
    }
    typealias Sample = (first: Double, frames: [Double], walls: [Double], total: Double)
    func measure(_ change: () -> Void) -> Sample {
      let all = Self.slices(1, change)
      // 第一下：到第一轮超过 2 ms 的为止（连它）
      let cut = (all.firstIndex { $0.cpu > 2 } ?? 0) + 1
      let rest = all.dropFirst(cut).filter { $0.cpu > 1 }
      if ProcessInfo.processInfo.environment["KITTY_NOTES_PROBE_SLICES"] != nil {
        print(
          "notes-probe     每一轮超过 1 ms 的（开始于 / CPU / 墙上）："
            + all.filter { $0.cpu > 1 }.map {
              String(format: "%.0f/%.1f/%.1f", $0.at, $0.cpu, $0.wall)
            }.joined(separator: "  "))
      }
      return (
        all.prefix(cut).reduce(0) { $0 + $1.cpu }, rest.map(\.cpu), rest.map(\.wall),
        all.reduce(0) { $0 + $1.cpu }
      )
    }
    func report(_ name: String, _ samples: [Sample]) {
      func median(_ values: [Double]) -> String {
        values.isEmpty ? "-" : String(format: "%.1f", values.sorted()[values.count / 2])
      }
      let frames = samples.flatMap(\.frames)
      print(
        "notes-probe \(name)：第一下 中位 \(median(samples.map(\.first))) ms；之后每帧（CPU 超过 1 ms 的）"
          + "共 \(frames.count) 帧 / \(samples.count) 次，最长 \(String(format: "%.1f", frames.max() ?? 0)) ms"
          + "（墙上 \(String(format: "%.1f", samples.flatMap(\.walls).max() ?? 0))），"
          + "平均 \(String(format: "%.1f", frames.isEmpty ? 0 : frames.reduce(0, +) / Double(frames.count))) ms，"
          + "每次最长的一帧 中位 \(median(samples.map { $0.frames.max() ?? 0 })) ms；"
          + "1 秒合计 中位 \(median(samples.map(\.total))) ms")
    }
    // 对照：什么都不做的 1 秒；只换选中的（不打开：墙重新求值一遍，选中底挪过去）
    report("便签墙 什么都不做", (0..<3).map { _ in measure {} })
    report(
      "便签墙 只换选中的（不打开）", (0..<6).map { round in measure { model.selection = ids[1 + round % 2] } })
    // 点开的是选中的那张（↩、从那叠打开）；最后一组每次点的是另一张（点一张没选中的：选中跟着换）
    let cases = [
      ("50 KB 的长便签", [long]), ("1 KB 的短便签", [short]), ("短便签、选中跟着换", [short, ids[2]]),
    ]
    for (name, targets) in cases {
      // 先开关一次（第一次建编辑区的那些不算）
      for id in targets {
        model.open(id, focus: false)
        Self.spin(0.8)
        model.collapse()
        Self.spin(0.8)
      }
      var opening: [Sample] = []
      var closing: [Sample] = []
      for round in 0..<6 {
        opening.append(measure { model.open(targets[round % targets.count], focus: false) })
        closing.append(measure { model.collapse() })
      }
      report("便签墙 点开 \(name)", opening)
      report("便签墙 收回 \(name)", closing)
    }
  }
}

/// 带标题栏的窗口摆在屏外（系统默认会把它挪回屏幕里）
private final class ProbeWindow: NSWindow {
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }
}
