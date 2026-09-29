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

  @Test func scrollStatusTones() {
    let status = ScrollCapture.status
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
  }

  // 面板按钮叫法和截图工具栏一致：拷贝 / 存储到「访达里的名字」/ 另存为…（B41）
  @Test func scrollPanelUsesShotWording() throws {
    let folder = FileManager.default.displayName(atPath: ScreenshotOutput.saveDirectory.path)
    #expect(ScreenshotOutput.saveTitle == "存储到「\(folder)」")  // 四处共用的叫法
    let tips = Set(
      ScrollCaptureHUD().subviews.flatMap(\.subviews).flatMap { [$0] + $0.subviews }
        .compactMap { ($0 as? NSButton)?.toolTip })
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

  // MARK: D18 常驻缩略图开关

  @Test func thumbnailShelfOnByDefault() {
    Prefs.registerDefaults()  // 只写注册域（不落盘）
    let registered = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)
    #expect(registered[Prefs.screenshotShelf] as? Bool == true)
  }
}
