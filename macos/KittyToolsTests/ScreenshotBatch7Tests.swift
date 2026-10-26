// 体检第 7 批（截图）单测：快速保存的目录（A28）、长截图时钉图让开（B40）、长截图状态行（B42：正常结束不变橙、只有对不上抖）、
// 选区太矮的长截图说原因（B43）、钉图的按键和右键菜单（C9 D17）、长截图时收走压在选区上的常驻缩略图（B40）、常驻缩略图开关默认开（D18）、截图家族叫法统一（B41）。
// 钉图、常驻缩略图摆在屏外 (-20000, -20000)、从不 makeKey；不读写用户偏好（样式在 Harness 的临时偏好域里），不弹面板、不抢键盘。

import AppKit
import Carbon.HIToolbox
import Testing

@testable import KittyTools

@MainActor @Suite(.serialized)
struct ScreenshotBatch7Tests {
  typealias Harness = SelectionInteractionTests.Harness

  private static let image: CGImage = {
    let context = CGContext(
      data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
    return context.makeImage()!
  }()

  /// 钉上后等淡入（0.12 s）和回弹（0.35 s）放完，透明度、大小才是终值
  private func settle() {
    RunLoop.main.run(until: Date.now.addingTimeInterval(0.5))
  }

  // MARK: A28 快速保存的目录

  // 设置里选的文件夹还在就用它；选过的文件夹没了（拔掉的移动硬盘）退回和没选过一样（系统截屏位置 → 桌面）
  @Test func quickSaveDirectoryFallsBack() throws {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "kitty-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(ScreenshotOutput.directory(saved: folder.path).path == folder.path)
    let fallback = ScreenshotOutput.directory(saved: nil)
    #expect(ScreenshotOutput.directory(saved: folder.path + "-gone") == fallback)
  }

  // MARK: B40 长截图时钉图让开

  // 和选区相交的钉图不接鼠标、淡到 0.3，不相交的不动；结束后回到用户选的透明度
  @Test func pinsStepAsideForScrollCapture() throws {
    let board = PinBoard()
    board.pin(Self.image, frame: CGRect(x: -20000, y: -20000, width: 200, height: 100))
    board.pin(Self.image, frame: CGRect(x: -19000, y: -20000, width: 200, height: 100))
    defer { board.closeAll() }
    settle()
    let (over, aside) = (board.panels[0], board.panels[1])
    over.opacity = 0.6
    board.suspend(covering: CGRect(x: -19950, y: -19950, width: 400, height: 300))
    #expect(over.ignoresMouseEvents)
    #expect(abs(over.alphaValue - 0.3) < 0.01)
    #expect(!aside.ignoresMouseEvents && !aside.isSuspended)
    #expect(abs(aside.alphaValue - 1) < 0.01)
    board.resume()
    #expect(!over.ignoresMouseEvents && !over.isSuspended)
    #expect(abs(over.alphaValue - 0.6) < 0.01)
  }

  // 叠着两张常驻缩略图、选区只盖到最底下那张：收走它后上面那张落进同一格，也要一起收走（不留在选区上挡滚轮）
  @Test func shelfCardsFallingIntoRegionAreDismissed() {
    let shelf = ShotShelf()
    let rect = CGRect(x: -20000, y: -20000, width: 200, height: 130)
    // 带着 .saved 角标：已有文件，不往临时目录写拖出用的 PNG
    let badge = FlyCard.Badge.saved(URL(filePath: "/nonexistent/a.png"))
    for _ in 0..<2 {
      shelf.add(Self.image, png: Data(), scale: 2, source: rect, at: rect, badge: badge)
    }
    let (upper, lower) = (shelf.cards[0], shelf.cards[1])
    #expect(upper.rect.minY > lower.rect.maxY)
    shelf.dismiss(covering: CGRect(x: -19950, y: -19990, width: 100, height: 40))
    #expect(lower.isLeaving && upper.isLeaving)
    settle()  // 滑出动画放完、窗口关掉
  }

  // MARK: B42 长截图状态行

  /// 预览上滚轮浏览长图：跟随态 nil、往回看给起始行、滚回最新那头回到跟随、整张放得下时滚不动
  @Test func scrollPreviewBrowse() throws {
    func browse(_ from: Int?, _ points: CGFloat, shown: Range<Int> = 300..<400) -> Int? {
      ScrollCaptureHUD.browse(
        from: from, by: points, shown: shown, total: 0..<400, rowsPerPoint: 4, growingUp: false)
    }
    // 往回滚 10 点 = 40 行（跟随态从现在看的那段算起）
    #expect(browse(nil, 10) == 260)
    #expect(browse(260, 10) == 220)
    // 往前滚回最新那头（含滚过头）：回到跟随
    #expect(browse(260, -10) == nil)
    #expect(browse(260, -1000) == nil)
    // 滚到最前面夹住；长图整张都在预览里时滚不动
    #expect(browse(20, 100) == 0)
    #expect(browse(nil, 10, shown: 0..<400) == nil)
    // 往上接（聊天记录往上翻）：最新的在顶上，贴着顶就是跟随
    #expect(
      ScrollCaptureHUD.browse(
        from: 40, by: 20, shown: 0..<100, total: 0..<400, rowsPerPoint: 4, growingUp: true) == nil)

    // 预览右边的位置指示条：宽 3、离右边 3、上下各留 2，看最前面时贴顶、最后面时贴底
    let box = CGRect(x: 10, y: 100, width: 196, height: 220)
    let top = try #require(ScrollCaptureHUD.scrubberFrame(in: box, shown: 0..<100, total: 0..<1000))
    let bottom = try #require(
      ScrollCaptureHUD.scrubberFrame(in: box, shown: 900..<1000, total: 0..<1000))
    #expect(top.width == 3 && box.maxX - top.maxX == 3)
    #expect(abs(box.maxY - 2 - top.maxY) < 0.01 && abs(bottom.minY - (box.minY + 2)) < 0.01)
    #expect(top.size == bottom.size && top.height >= 20)
    // 半截高的长图：条占一半、落在正中
    let half = try #require(
      ScrollCaptureHUD.scrubberFrame(in: box, shown: 50..<150, total: 0..<200))
    #expect(abs(half.height - (box.height - 4) / 2) < 0.01 && abs(half.midY - box.midY) < 0.01)
    // 长图整张都在预览里：不画
    #expect(ScrollCaptureHUD.scrubberFrame(in: box, shown: 0..<200, total: 0..<200) == nil)
  }

  @Test func scrollStatusTones() {
    func status(
      _ notice: ScrollCapture.Status?, _ isFull: Bool, _ isLost: Bool, _ isAutoScrolling: Bool
    ) -> ScrollCapture.Status {
      ScrollCapture.status(
        notice: notice, isFull: isFull, isLost: isLost, isAutoScrolling: isAutoScrolling)
    }
    // 平常的操作说明：不变色、不播报
    let idle = status(nil, false, false, false)
    #expect(idle.tone == .normal && !idle.announces)
    #expect(status(nil, false, false, true).text.hasPrefix("自动滚动中"))
    // 最长了是正常结束：不变橙、要播报，文案是「拷贝」
    let full = status(nil, true, true, false)
    #expect(full == ScrollCapture.Status(text: "已经最长了，按 ↩ 拷贝"))
    // 对不上：橙色、抖一下
    #expect(status(nil, false, true, false).tone == .lost)
    // 停留的提示优先：到底了是平常色，缺授权是橙色不抖
    let bottom = ScrollCapture.Status(text: "已经滚到底了")
    #expect(status(bottom, true, true, false) == bottom)
    #expect(bottom.tone == .normal && bottom.announces)
    // 停在「到底了」后又对不上：对不上盖过平常色的提示（橙、抖、播报）；橙色的提示照旧优先
    #expect(status(bottom, false, true, false).tone == .lost)
    let lostStop = ScrollCapture.Status(text: "对不上，已停止自动滚动", tone: .lost)
    #expect(status(lostStop, false, true, false) == lostStop)
    // 浏览提示只盖过平常的操作说明，不播报；对不上、最长了、停留的提示都优先
    let browsing = ScrollCapture.status(
      notice: nil, isFull: false, isLost: false, isAutoScrolling: false, isBrowsing: true)
    #expect(browsing == ScrollCapture.Status(text: "双击预览回到最新", announces: false))
    for (notice, isFull, isLost) in [
      (nil, true, false), (nil, false, true), (bottom, false, false),
    ] as [(ScrollCapture.Status?, Bool, Bool)] {
      #expect(
        ScrollCapture.status(
          notice: notice, isFull: isFull, isLost: isLost, isAutoScrolling: false, isBrowsing: true)
          != browsing)
    }
  }

  // 面板按钮叫法和截图工具栏一致：拷贝 / 存储到「访达里的名字」/ 另存为…（B41）
  @Test func scrollPanelUsesShotWording() throws {
    let folder = FileManager.default.displayName(atPath: ScreenshotOutput.saveDirectory.path)
    #expect(ScreenshotOutput.saveTitle == "存储到「\(folder)」")  // 四处共用的叫法
    func views(in view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + views(in: $0) } }
    let tips = Set(views(in: ScrollCaptureHUD()).compactMap { ($0 as? NSButton)?.toolTip })
    #expect(tips.isSuperset(of: ["拷贝（↩）", "存储到「\(folder)」（⌘S）", "另存为…（⇧⌘S）"]))
    let h = Harness()
    h.makeSelection()
    #expect(h.toolbar?.button(for: .output(.save))?.toolTip == "存储到「\(folder)」（⌘S）")
  }

  // MARK: B43 选区太矮

  // 不到 60 点高按 S：不进长截图，提示音 + 顶部提示 + 播报原因；拉高了再按就交出选区
  @Test func shortSelectionExplainsScroll() async {
    let h = Harness()
    h.drag(CGPoint(x: 300, y: 300), CGPoint(x: 700, y: 340))
    let refused = await h.outcome { h.key(kVK_ANSI_S, "s") }
    if case .color(let text)? = refused {
      #expect(text == "没交回结果")
    } else {
      Issue.record("太矮的选区也进了长截图：\(String(describing: refused))")
    }
    #expect(h.view.announcement == "选区太矮，拉高一点再长截图")
    h.key(kVK_Escape, "\u{1b}")
    h.drag(CGPoint(x: 300, y: 200), CGPoint(x: 700, y: 400))
    let accepted = await h.outcome { h.key(kVK_ANSI_S, "s") }
    guard case .scroll? = accepted else {
      Issue.record("够高的选区没进长截图：\(String(describing: accepted))")
      return
    }
  }

  // MARK: C9 D17 钉图的按键与右键菜单

  // 右键菜单：拷贝 / 识字并拷贝 O / 翻译 / 存储到「X」⌘S / 另存为… ⇧⌘S ｜ 透明度 / 原始大小 ⌘0 ｜ 关闭 ⌘W
  @Test func pinMenuMatchesShotOutputs() throws {
    let board = PinBoard()
    var outputs: [RegionSelector.Action] = []
    board.output = { action, _, _ in outputs.append(action) }
    board.pin(Self.image, frame: CGRect(x: -20000, y: -20000, width: 200, height: 100))
    defer { board.closeAll() }
    let view = try #require(board.panels.first?.contentView)
    let event = try #require(
      NSEvent.mouseEvent(
        with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    let menu = try #require(view.menu(for: event))
    let folder = FileManager.default.displayName(atPath: ScreenshotOutput.saveDirectory.path)
    #expect(
      menu.items.map(\.title) == [
        "拷贝", "识字并拷贝", "翻译", "存储到「\(folder)」", "另存为…", "", "透明度", "原始大小", "", "关闭",
      ])
    let keys = menu.items.map { "\($0.keyEquivalentModifierMask.rawValue):\($0.keyEquivalent)" }
    let command = NSEvent.ModifierFlags.command.rawValue
    let shiftCommand = NSEvent.ModifierFlags([.command, .shift]).rawValue
    #expect(keys[0] == "\(command):c" && keys[1] == "0:o" && keys[3] == "\(command):s")
    #expect(
      keys[4] == "\(shiftCommand):s" && keys[7] == "\(command):0" && keys[9] == "\(command):w")
    // 菜单项点下去走对应的输出
    for index in 0..<5 {
      let item = menu.items[index]
      NSApp.sendAction(try #require(item.action), to: item.target, from: item)
    }
    #expect(outputs == [.copy, .recognize, .translate, .save, .saveAs])
    // 按键和菜单查同一张表（performKeyEquivalent 要钉图真是 key，经 keyDown 走同一个查表）：
    // ⌘C 拷贝、⌘S 快速保存、⇧⌘S 另存为、单键 O 识字并拷贝；按住不放不反复执行
    outputs = []
    func press(
      _ keyCode: Int, _ key: String, _ flags: NSEvent.ModifierFlags = [], repeating: Bool = false
    ) throws {
      view.keyDown(
        with: try #require(
          NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
            context: nil, characters: key, charactersIgnoringModifiers: key,
            isARepeat: repeating, keyCode: UInt16(keyCode))))
    }
    try press(kVK_ANSI_C, "c", .command)
    try press(kVK_ANSI_S, "s", .command)
    try press(kVK_ANSI_S, "s", [.command, .shift])
    try press(kVK_ANSI_S, "s", [.command, .capsLock])  // 大写锁定不算修饰键
    try press(kVK_ANSI_O, "o")
    try press(kVK_ANSI_O, "o", repeating: true)
    #expect(outputs == [.copy, .save, .saveAs, .save, .recognize])
  }

  // 透明度（2026-10-03 用户要求，原来点一下换一档）：右键「透明度 ▸」里是一行 10–100% 的滑块，拖到哪钉图就是多少（按整数
  // 百分比），旁边的百分比、滑块和钉图的旁白值跟着变，再打开时停在当前值；悬停圆钮弹出的是同一行（popUp 会卡住测试，不点）
  @Test func pinOpacitySlider() throws {
    let board = PinBoard()
    board.pin(Self.image, frame: CGRect(x: -20000, y: -20000, width: 200, height: 100))
    defer { board.closeAll() }
    let panel = try #require(board.panels.first)
    panel.finishPopIn()  // 屏外的窗口 display link 不走，回弹停不下来
    settle()  // 淡入放完
    let view = try #require(panel.contentView)
    let event = try #require(
      NSEvent.mouseEvent(
        with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    func row() throws -> (NSSlider, NSTextField) {
      let menu = try #require(view.menu(for: event))
      let row = try #require(
        menu.items.first { $0.title == "透明度" }?.submenu?.items.first?.view)
      return (
        try #require(row.subviews.compactMap { $0 as? NSSlider }.first),
        try #require(row.subviews.compactMap { $0 as? NSTextField }.first)
      )
    }
    let (slider, label) = try row()
    #expect(slider.minValue == 10 && slider.maxValue == 100 && slider.doubleValue == 100)
    #expect(label.stringValue == "100%" && slider.accessibilityLabel() == "透明度")
    slider.doubleValue = 34.6
    NSApp.sendAction(try #require(slider.action), to: slider.target, from: slider)
    #expect(abs(panel.opacity - 0.35) < 0.001 && abs(panel.alphaValue - 0.35) < 0.01)
    #expect(label.stringValue == "35%" && slider.accessibilityValueDescription() == "35%")
    #expect(view.accessibilityValue() as? String == "200 × 100 点，透明度 35%")
    #expect(try row().0.doubleValue == 35)
  }

  // MARK: D18 常驻缩略图开关

  @Test func thumbnailShelfOnByDefault() {
    Prefs.registerDefaults()  // 只写注册域（不落盘）
    let registered = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)
    #expect(registered[Prefs.screenshotShelf] as? Bool == true)
  }
}
