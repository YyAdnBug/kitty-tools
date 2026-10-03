// 录屏的点按圈（手测反馈第 1 批，InputOverlay）：全局坐标 → 窗口内坐标、左 / 右键的圈形状不同、点在本 App 哪些窗口上不画、
// 窗口不进截图冻结帧也不在录屏白名单里（层级高过菜单和截图遮罩，窗口号由 ScreenRecorder 自己并进例外）、按下 / 拖动 /
// 松开各自留下几个图层（用完移除、连点互不吞、选区外按下再拖进来圈跟着）、收起后窗口放掉。除了最后一条，窗口只建不显示
// （不装鼠标监听）；动画的快慢（最短显示 0.2 s、涟漪到点才出现）屏外测不到，真机看（PLAN §12 第 53 条）；
// 真录进画面在按需实录自检 RecordingProbeTests.inputOverlayTake，样子在 ScreenshotSnapshotTests.renderInputOverlay。
// 按键提示（手测反馈第 2 批）：键名和修饰键的写法（和快捷键页同一套 HotKey.display）、内容的纯状态（追加、按住不放的 ×n、
// 停手 1.6 s 清空、放不下从左边丢）、胶囊放哪（区域录制离底 32、整屏让开录制 HUD 和程序坞、小区域夹进去、宽度上限）、
// 胶囊图层的增减（不算进圈的个数、没开显示按键时不做事、收起时清掉）、很窄的选区里字缩到胶囊里、本 App 的密码框
// 拿着键盘时不显示、本进程自己发的合成按键（粘贴的 ⌘V 这类）不显示。
// 淡入淡出的快慢真机看（PLAN §12 第 58–62 条）；真录进画面在 RecordingProbeTests.keysOverlayTake。

import AppKit
import Carbon.HIToolbox
import Testing

@testable import KittyTools

@MainActor
struct InputOverlayTests {
  static let frame = CGRect(x: 100, y: 200, width: 640, height: 360)

  /// 全局坐标 → 窗口内坐标（原点左下）；选区外面的照算（圈被窗口裁掉）；副屏的负坐标也对
  @Test func localPointInsideAndOutsideTheRecordedRegion() {
    let local = { InputOverlay.local($0, in: Self.frame) }
    #expect(local(CGPoint(x: 100, y: 200)) == .zero)
    #expect(local(CGPoint(x: 420, y: 380)) == CGPoint(x: 320, y: 180))
    #expect(local(CGPoint(x: 740, y: 560)) == CGPoint(x: 640, y: 360))
    // 选区外 10 pt：圆盘还露一半
    #expect(local(CGPoint(x: 90, y: 300)) == CGPoint(x: -10, y: 100))
    // 选区外 100 pt：整个圈都在窗口外面
    #expect(local(CGPoint(x: 0, y: 300)) == CGPoint(x: -100, y: 100))
    let side = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
    #expect(InputOverlay.local(CGPoint(x: -1000, y: 100), in: side) == CGPoint(x: 920, y: 300))
  }

  /// 左键实心圆盘、右键和其它键空心环：形状分开（强调色选石墨时颜色帮不上忙），空心环的线更粗
  @Test func leftIsDiscOthersAreRings() throws {
    #expect(InputOverlay.look(button: 0) == .disc)
    #expect([1, 2, 3, 4].map(InputOverlay.look) == [.ring, .ring, .ring, .ring])
    /// 圈里画强调色的那一层（最上面）
    func ring(_ look: InputOverlay.Look) throws -> CAShapeLayer {
      try #require(InputOverlay.mark(look, scale: 2).sublayers?.last as? CAShapeLayer)
    }
    let disc = try ring(.disc)
    let hollow = try ring(.ring)
    #expect(disc.fillColor != nil && hollow.fillColor == nil)
    #expect(disc.lineWidth == 2 && hollow.lineWidth == 3)
    #expect(disc.strokeColor == Style.Shot.accent.cgColor)
    // 圈比光标大得多（系统的点按圈约 20 pt）
    #expect(InputOverlay.mark(.disc, scale: 2).bounds.size == CGSize(width: 44, height: 44))
  }

  /// 点在本 App 自己的窗口上：只在录屏白名单里的（会录进画面：设置窗这类普通 NSWindow、面板、钉图）画；录不进去的不画，
  /// 不按层级猜——浮动层级的普通面板（长截图面板这类不在白名单里的）、状态栏层级的（录制 HUD、常驻缩略图）、
  /// 没有窗口号的都不画，不然点它们会在画面里凭空留个圈。窗口只建不显示
  @Test func clicksOnOwnWindowsShowOnlyOnRecordedOnes() {
    func window(_ type: NSWindow.Type, level: NSWindow.Level) -> NSWindow {
      let made = type.init(
        contentRect: CGRect(x: -20000, y: -20000, width: 80, height: 60), styleMask: [.borderless],
        backing: .buffered, defer: false)
      made.isReleasedWhenClosed = false
      made.level = level
      return made
    }
    let recorded = window(NSWindow.self, level: .normal)
    let floating = window(NSPanel.self, level: .floating)
    let status = window(NSWindow.self, level: .statusBar)
    #expect(InputOverlay.showsClick(onOwnWindow: recorded.windowNumber))
    #expect(!InputOverlay.showsClick(onOwnWindow: floating.windowNumber))
    #expect(!InputOverlay.showsClick(onOwnWindow: status.windowNumber))
    #expect(!InputOverlay.showsClick(onOwnWindow: 0))
    #expect(!InputOverlay.showsClick(onOwnWindow: -1))
  }

  /// 窗口：普通 NSPanel（不子类化）、不接鼠标、永不当 key、不进旁白、没有阴影；层级高过菜单和截图遮罩（popUpMenu + 1）；
  /// 截图冻结帧按层级不收它，录屏白名单也不列它（窗口号由 ScreenRecorder 并进例外）
  @Test func panelStaysOutOfTheWayAndOutOfFreezeFrames() {
    let overlay = InputOverlay(frame: Self.frame)
    defer { overlay.close() }
    let panel = overlay.panel
    #expect(type(of: panel) == NSPanel.self)
    #expect(panel.frame == Self.frame && !panel.isVisible)
    #expect(panel.ignoresMouseEvents && !panel.canBecomeKey && !panel.canBecomeMain)
    #expect(!panel.hasShadow && !panel.isOpaque && !panel.isAccessibilityElement())
    #expect(panel.level.rawValue > NSWindow.Level.popUpMenu.rawValue + 1)
    #expect(
      panel.collectionBehavior.isSuperset(of: [
        .canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary,
      ]))
    #expect(overlay.windowID != nil)
    let own = [
      ScreenCapture.OwnWindow(
        id: 7, className: String(describing: type(of: panel)), level: panel.level.rawValue,
        isVisible: true, alpha: 1)
    ]
    #expect(ScreenCapture.keptOwnWindows(own).isEmpty)
    #expect(ScreenCapture.recordedOwnWindows(own).isEmpty)
  }

  /// 按下一个圈、拖动跟着走（直接设位置）、松开移除；同一个键没等到松开又按下（松开被别的 App 吞了）旧的先收掉；
  /// 左右键各管各的；选区外很远的按下也建（看不见），按住拖进选区时圈跟着进来。都走不带动画的入口（终态）
  @Test func pressMoveReleaseKeepNoStaleLayers() throws {
    let overlay = InputOverlay(frame: Self.frame)
    defer { overlay.close() }
    let canvas = try #require(overlay.panel.contentView?.layer)
    #expect(overlay.markCount == 0 && canvas.contents == nil)
    overlay.press(0, at: CGPoint(x: 420, y: 380), animated: false)
    #expect(overlay.markCount == 1)
    #expect(canvas.sublayers?.first?.position == CGPoint(x: 320, y: 180))
    overlay.move(0, to: CGPoint(x: 500, y: 300))
    #expect(canvas.sublayers?.first?.position == CGPoint(x: 400, y: 100))
    // 别的键的拖动不带着它走
    overlay.move(1, to: CGPoint(x: 120, y: 220))
    #expect(canvas.sublayers?.first?.position == CGPoint(x: 400, y: 100))
    overlay.press(1, at: CGPoint(x: 200, y: 260), animated: false)
    #expect(overlay.markCount == 2)
    overlay.press(0, at: CGPoint(x: 300, y: 300), animated: false)
    #expect(overlay.markCount == 2)
    overlay.release(0, animated: false)
    overlay.release(0, animated: false)  // 多来一次松开：没有可收的
    #expect(overlay.markCount == 1)
    overlay.release(1, animated: false)
    #expect(overlay.markCount == 0)
    // 选区外 200 pt 按下（比如按住别的窗口里的一个文件）再拖进选区、松开
    overlay.press(0, at: CGPoint(x: 100, y: 0), animated: false)
    #expect(overlay.markCount == 1)
    overlay.move(0, to: CGPoint(x: 420, y: 380))
    #expect(canvas.sublayers?.first?.position == CGPoint(x: 320, y: 180))
    overlay.release(0, animated: false)
    #expect(overlay.markCount == 0)
  }

  /// 带动画的松开：不当场移除（圆盘留着淡出，另加一圈涟漪；减弱动态效果没有涟漪），连点三下互不吞、各放各的，
  /// 放完都移除（不累积）
  @Test func animatedReleaseRemovesLayersWhenDone() async throws {
    let overlay = InputOverlay(frame: Self.frame)
    defer { overlay.close() }
    for index in 0..<3 {
      overlay.press(0, at: CGPoint(x: 300 + CGFloat(index) * 10, y: 300))
      overlay.release(0)
    }
    #expect(overlay.markCount == (Style.reduceMotion ? 3 : 6))
    for _ in 0..<60 where overlay.markCount > 0 { try await Task.sleep(for: .milliseconds(50)) }
    #expect(overlay.markCount == 0)
  }

  /// 收起：监听卸掉、图层清掉、窗口收起；会话放手后覆盖层和它的窗口都放掉（不然每录一次漏一个整屏窗口）。
  /// 这一条真的露出来再收（监听和窗口列表才是会留住它的地方）：窗口全透明、不接鼠标、当不了 key，露出来的这一瞬看不见
  @Test func closeReleasesOverlayAndWindow() {
    weak var overlay: InputOverlay?
    weak var panel: NSPanel?
    autoreleasepool {
      let made = InputOverlay(frame: Self.frame)
      made.present()
      #expect(made.panel.isVisible)
      made.press(0, at: CGPoint(x: 420, y: 380), animated: false)
      overlay = made
      panel = made.panel
      made.close()
      #expect(made.markCount == 0 && !made.panel.isVisible)
    }
    #expect(overlay == nil && panel == nil)
  }

  // MARK: 按键提示（手测反馈第 2 批）

  private func name(_ keyCode: Int, _ flags: NSEvent.ModifierFlags = []) -> String {
    HotKey(keyCode: UInt16(keyCode), flags: flags).display
  }

  /// 键名和快捷键页同一套（HotKey.display）：修饰键按 ⌃⌥⇧⌘ 在前；特殊键是符号、空格写「空格」、F 键写名字；字母按当前
  /// ASCII 布局取、大写（不写死是哪个字母：换了键盘布局也成立）；只按 ⇧ 加字母是 ⇧A；大写锁定、fn、小键盘这些标志不算修饰键
  @Test func keyNamesFollowTheShortcutNotation() {
    #expect(name(kVK_Return) == "↩" && name(kVK_Tab) == "⇥" && name(kVK_Delete) == "⌫")
    #expect(name(kVK_Escape) == "⎋" && name(kVK_Space) == "空格" && name(kVK_F5) == "F5")
    #expect(
      [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow].map { name($0) }
        == ["←", "→", "↑", "↓"])
    // 小键盘的 Enter 按布局取出来是控制字符，要有个画得出来的名字
    #expect(name(kVK_ANSI_KeypadEnter) == "⌤")
    let letter = name(kVK_ANSI_A)
    #expect(letter.count == 1 && letter == letter.uppercased())
    #expect(name(kVK_ANSI_A, .shift) == "⇧" + letter)
    #expect(name(kVK_ANSI_A, .command) == "⌘" + letter)
    #expect(name(kVK_ANSI_A, [.command, .shift, .option, .control]) == "⌃⌥⇧⌘" + letter)
    #expect(name(kVK_Return, [.command, .shift]) == "⇧⌘↩")
    #expect(name(kVK_LeftArrow, [.function, .numericPad, .capsLock]) == "←")
  }

  /// 只显示快捷键（第二轮体检 R2）：带 ⌘ / ⌃ / ⌥ 的组合显示（有没有 ⇧ 都算）；不带它们的只有 Esc 和 F 键显示——
  /// 这两样不出字、是一步操作。字母数字、空格、⇧ 加字母是打字，↩ ⇥ ⌫ 方向键是打字时的编辑和移动，不显示
  @Test func shortcutsOnlySkipsTyping() {
    func shows(_ keyCode: Int, _ flags: NSEvent.ModifierFlags = []) -> Bool {
      HotKey(keyCode: UInt16(keyCode), flags: flags).isShortcut
    }
    #expect(shows(kVK_ANSI_C, .command) && shows(kVK_ANSI_A, .control))
    #expect(shows(kVK_Space, .option) && shows(kVK_ANSI_Z, [.command, .shift]))
    #expect(shows(kVK_LeftArrow, .option) && shows(kVK_Return, .command))
    #expect(shows(kVK_Escape) && shows(kVK_F5) && shows(kVK_F5, .shift))
    for typing in [kVK_ANSI_A, kVK_ANSI_1, kVK_ANSI_Period, kVK_Space] {
      #expect(!shows(typing) && !shows(typing, .shift) && !shows(typing, .capsLock))
    }
    for editing in [
      kVK_Return, kVK_Tab, kVK_Delete, kVK_ForwardDelete, kVK_LeftArrow, kVK_UpArrow, kVK_Home,
    ] {
      #expect(!shows(editing) && !shows(editing, .shift) && !shows(editing, [.function]))
    }
  }

  /// 抽出共用的构造后，录制快捷键的规则不变：没有 ⌘ / ⌃ / ⌥ 的组合（F 键除外）不能当全局热键
  @Test func hotKeyRecordingRulesUnchanged() throws {
    func event(_ keyCode: Int, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
      try #require(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
          context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
          keyCode: UInt16(keyCode)))
    }
    #expect(try HotKey(event: event(kVK_ANSI_A, [])) == nil)
    #expect(try HotKey(event: event(kVK_ANSI_A, .shift)) == nil)
    #expect(
      try HotKey(event: event(kVK_ANSI_V, [.command, .shift]))
        == HotKey(keyCode: kVK_ANSI_V, modifiers: cmdKey | shiftKey))
    #expect(try HotKey(event: event(kVK_F5, [])) == HotKey(keyCode: kVK_F5, modifiers: 0))
    #expect(
      try HotKey(event: event(kVK_F5, .shift)) == HotKey(keyCode: kVK_F5, modifiers: shiftKey))
  }

  /// 一次按键一个记号、往右追加；按住不放的重复不追加、记在最后一个记号的次数上（另一个键的重复照常追加）；
  /// 停手满 1.6 s 清空（时刻是注入的），之后的第一下从头开始
  @Test func keysAppendCountRepeatsAndExpire() {
    typealias Token = InputOverlay.Keys.Token
    let start = ContinuousClock.now
    var keys = InputOverlay.Keys()
    let nothing = keys.expire(at: start)
    #expect(keys.tokens.isEmpty && keys.isIdle(at: start) && !nothing)
    keys.press("⌘C", at: start)
    keys.press("⌘V", at: start + .milliseconds(300))
    #expect(keys.tokens == [Token(name: "⌘C"), Token(name: "⌘V")])
    // 按住 ⌫ 不放：第一下追加，之后的重复只加次数
    keys.press("⌫", at: start + .milliseconds(600))
    for index in 1...4 {
      keys.press("⌫", isRepeat: true, at: start + .milliseconds(600 + index * 40))
    }
    #expect(keys.tokens.last == Token(name: "⌫", count: 5) && keys.tokens.count == 3)
    // 松开再按一次同一个键：新的记号
    keys.press("⌫", at: start + .milliseconds(1000))
    #expect(keys.tokens.count == 4 && keys.tokens.last == Token(name: "⌫"))
    // 最后一个记号不是它的重复（按着 A 又按了 B，系统改成重复 B 之前的那一下）：照常追加
    keys.press("A", isRepeat: true, at: start + .milliseconds(1100))
    #expect(keys.tokens.count == 5)
    // 最后一下之后不到 1.6 s：不清；满了：清空，只报一次
    let last = start + .milliseconds(1100)
    let early = keys.expire(at: last + .milliseconds(1599))
    #expect(!early && keys.tokens.count == 5)
    let expired = keys.expire(at: last + InputOverlay.Keys.idle)
    #expect(expired && keys.tokens.isEmpty)
    let again = keys.expire(at: last + .seconds(5))
    #expect(!again)
    // 停手很久、清空的那一下还没来得及跑：下一次按键自己从头开始
    keys.press("A", at: last + .seconds(6))
    keys.press("B", at: last + .seconds(9))
    #expect(keys.tokens == [Token(name: "B")])
  }

  /// 放不下时从左边丢，至少留最后一个（它一个就超宽也留着）
  @Test func keysTrimDropsFromTheLeft() {
    var keys = InputOverlay.Keys()
    let start = ContinuousClock.now
    for (index, name) in ["A", "B", "C", "D", "E"].enumerated() {
      keys.press(name, at: start + .milliseconds(index * 100))
    }
    /// 每个记号 10 宽
    let width = { (tokens: [InputOverlay.Keys.Token]) in CGFloat(tokens.count) * 10 }
    keys.trim(to: 50, width: width)
    #expect(keys.tokens.count == 5)
    keys.trim(to: 35, width: width)
    #expect(keys.tokens.map(\.name) == ["C", "D", "E"])
    keys.trim(to: 5, width: width)
    #expect(keys.tokens.map(\.name) == ["E"])
  }

  /// 胶囊放哪：区域录制（录制 HUD 在选区外面）离区域底边 32 pt、水平居中；整屏录制放在可见区底边上方 88 pt——让开底部
  /// 居中的录制 HUD（离底 24、高 40）和程序坞；选区上下都放不下 HUD（HUD 进了选区底部）时同样放到它上方 24 pt；
  /// 区域太矮时夹进区域里，再矮就竖直居中；宽度不超过区域宽减两边各 16，也不超过 640
  @Test func keysBarPlacement() {
    let screen = RecordingHUDTests.screen
    let visible = RecordingHUDTests.visible
    func bottom(_ region: CGRect, full: Bool = false) -> CGFloat {
      InputOverlay.keysBottom(region: region, screen: screen, visible: visible, isFullScreen: full)
    }
    let region = CGRect(x: 300, y: 300, width: 600, height: 400)
    #expect(bottom(region) == 332)
    #expect(
      InputOverlay.keysFrame(width: 120, bottom: bottom(region), in: region)
        == CGRect(x: 540, y: 332, width: 120, height: 46))
    // HUD 放在选区上方（下面放不下）：还是离区域底边 32
    #expect(bottom(CGRect(x: 300, y: 44, width: 600, height: 400)) == 76)
    // 整屏：可见区底边（程序坞上沿 70）+ 88，在录制 HUD（94…134）上方 24
    #expect(bottom(screen, full: true) == 158)
    #expect(
      InputOverlay.keysFrame(width: 200, bottom: 158, in: screen)
        == CGRect(x: 620, y: 158, width: 200, height: 46))
    // 选区几乎占满屏高：HUD 进了选区底部（y 30…70），胶囊在它上方 24
    #expect(bottom(CGRect(x: 0, y: 20, width: 1440, height: 860)) == 94)
    // 小区域（64 高是录屏的下限）：底边 + 32 放不下，夹到离顶 8；宽度夹到区域宽 − 32
    let small = CGRect(x: 100, y: 100, width: 200, height: 64)
    #expect(
      InputOverlay.keysFrame(width: 400, bottom: bottom(small), in: small)
        == CGRect(x: 116, y: 110, width: 168, height: 46))
    // 比胶囊加上下各 8 还矮：竖直居中
    let flat = CGRect(x: 100, y: 100, width: 300, height: 50)
    #expect(InputOverlay.keysFrame(width: 80, bottom: 132, in: flat).minY == 102)
    // 宽度上限
    #expect(InputOverlay.keysWidthLimit(region) == 568)
    #expect(InputOverlay.keysWidthLimit(screen) == 640)
    #expect(InputOverlay.keysWidthLimit(CGRect(x: 0, y: 0, width: 64, height: 64)) == 46)
    #expect(InputOverlay.keysFrame(width: 2000, bottom: 158, in: screen).width == 640)
    // 字比胶囊还宽：缩到两边各留 8 刚好放下；放得下不缩
    #expect(InputOverlay.keysTextScale(textWidth: 40, barWidth: 120) == 1)
    #expect(InputOverlay.keysTextScale(textWidth: 84, barWidth: 120) == 1)
    #expect(InputOverlay.keysTextScale(textWidth: 40, barWidth: 46) == 0.75)
    #expect(InputOverlay.keysTextScale(textWidth: 120, barWidth: 46) == 0.25)
  }

  /// 很窄的选区（64 pt 是录屏的下限）：一个记号就比胶囊放得下的宽，字等比缩小、留在胶囊里（两边各留 8），不画到胶囊和
  /// 选区外面；宽的选区里字不缩（和胶囊同宽减两边内边距）
  @Test func narrowRegionShrinksTheText() throws {
    func label(width: CGFloat, _ name: String) throws -> (text: CGRect, bar: CGRect) {
      let frame = CGRect(x: 100, y: 100, width: width, height: 200)
      let overlay = InputOverlay(frame: frame, clicks: false, keysBottom: frame.minY + 32)
      defer { overlay.close() }
      overlay.showKey(name, animated: false)
      let bar = try #require(overlay.panel.contentView?.layer?.sublayers?.first)
      let text = try #require(bar.sublayers?.first { $0 is CATextLayer })
      return (text.frame, bar.bounds)
    }
    let narrow = try label(width: 64, "⌃⌥⇧⌘F12")
    #expect(narrow.bar.width == 46)
    #expect(narrow.text.minX >= 8 - 0.5 && narrow.text.maxX <= 46 - 8 + 0.5)
    #expect(narrow.text.minY >= 0 && narrow.text.maxY <= 46)
    let wide = try label(width: 640, "⌃⌥⇧⌘F12")
    #expect(wide.text.width == wide.bar.width - 36 && wide.text.minX == 18)
  }

  /// 本进程自己发的按键（粘贴回原 App 的 ⌘V、片段 {cursor} 的 ←、划词兜底的 ⌘C）不显示：经 CGEvent 造的事件带着本进程
  /// 的进程号；真键盘的事件进程号是 0（这里改成 0 来模拟——真发出去的合成事件系统会盖回发送方的进程号，global 监听收到
  /// 的样子在按需实测 HotKeyMenuTests/keyMonitorsMissHotKeysAndSkipOwnKeys）。只造事件、不发
  @Test func ownSynthesizedKeysAreNotShown() throws {
    let paste = try #require(
      CGEvent(
        keyboardEventSource: CGEventSource(stateID: .combinedSessionState),
        virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true))
    paste.flags = .maskCommand
    #expect(try InputOverlay.isSynthesized(#require(NSEvent(cgEvent: paste))))
    paste.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
    #expect(try !InputOverlay.isSynthesized(#require(NSEvent(cgEvent: paste))))
  }

  /// 胶囊图层：没开显示按键时 showKey 不做事；开着时第一下建胶囊（在算好的位置，不算进圈的个数），再按变宽、还是同一颗；
  /// 按住不放只改次数；窄区域里一长串从左边丢、胶囊不超过区域宽减边距；收起时清掉。窗口只建不显示、走不带动画的入口
  @Test func showKeyBuildsOneCapsule() throws {
    let plain = InputOverlay(frame: Self.frame)
    plain.showKey("⌘C", animated: false)
    #expect(plain.keysBarFrame == nil && plain.keys.tokens.isEmpty)
    let plainLayers = plain.panel.contentView?.layer?.sublayers ?? []
    #expect(plainLayers.isEmpty)
    plain.close()

    let overlay = InputOverlay(frame: Self.frame, clicks: false, keysBottom: Self.frame.minY + 32)
    defer { overlay.close() }
    let canvas = try #require(overlay.panel.contentView?.layer)
    overlay.showKey("⌘C", animated: false)
    let first = try #require(overlay.keysBarFrame)
    #expect(first.minY == 32 && first.height == 46 && abs(first.midX - 320) <= 0.5)
    #expect(canvas.sublayers?.count == 1 && overlay.markCount == 0)
    overlay.showKey("⌘V", animated: false)
    let second = try #require(overlay.keysBarFrame)
    #expect(second.width > first.width && abs(second.midX - 320) <= 0.5)
    #expect(canvas.sublayers?.count == 1)
    overlay.showKey("⌫", animated: false)
    overlay.showKey("⌫", isRepeat: true, animated: false)
    overlay.showKey("⌫", isRepeat: true, animated: false)
    #expect(overlay.keys.tokens.map(\.name) == ["⌘C", "⌘V", "⌫"])
    #expect(overlay.keys.tokens.last?.count == 3)
    #expect(InputOverlay.keysText(overlay.keys.tokens).string == "⌘C ⌘V ⌫×3")
    // 圈和胶囊各数各的
    overlay.press(0, at: CGPoint(x: 420, y: 380), animated: false)
    #expect(overlay.markCount == 1 && canvas.sublayers?.count == 2)
    overlay.release(0, animated: false)
    // 一长串：放不下的从左边丢，胶囊不超过区域宽 − 32
    for index in 0..<60 { overlay.showKey("⌘\(index % 10)", animated: false) }
    let long = try #require(overlay.keysBarFrame)
    #expect(long.width <= Self.frame.width - 32 && long.width > Self.frame.width - 120)
    #expect(overlay.keys.tokens.count < 60 && overlay.keys.tokens.last?.name == "⌘9")
    overlay.close()
    #expect(overlay.keysBarFrame == nil && overlay.keys.tokens.isEmpty)
    #expect((canvas.sublayers ?? []).isEmpty)
  }

  /// 开着显示按键的覆盖层露出来（装键盘监听）、显示过按键（挂着等停手的任务）再收起：覆盖层和窗口都放掉
  @Test func closeReleasesOverlayShowingKeys() {
    weak var overlay: InputOverlay?
    weak var panel: NSPanel?
    autoreleasepool {
      let made = InputOverlay(frame: Self.frame, clicks: false, keysBottom: Self.frame.minY + 32)
      made.present()
      made.showKey("⌘C", animated: false)
      #expect(made.panel.isVisible && made.keysBarFrame != nil)
      overlay = made
      panel = made.panel
      made.close()
    }
    #expect(overlay == nil && panel == nil)
  }

  /// 本 App 自己的密码框（设置里填密钥的）拿着键盘时不显示按键：第一响应者是密码框的字段编辑器；普通输入框照常显示。
  /// 窗口在屏外、只建不显示
  @Test func ownSecureFieldsAreNotShown() throws {
    let window = NSWindow(
      contentRect: CGRect(x: -20000, y: -20000, width: 300, height: 120), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let secret = NSSecureTextField(frame: CGRect(x: 10, y: 60, width: 200, height: 24))
    let plain = NSTextField(frame: CGRect(x: 10, y: 20, width: 200, height: 24))
    window.contentView?.addSubview(secret)
    window.contentView?.addSubview(plain)
    #expect(!InputOverlay.isSecureInput(nil) && !InputOverlay.isSecureInput(window))
    #expect(window.makeFirstResponder(secret))
    #expect(window.firstResponder !== secret, "密码框拿到键盘时第一响应者该是字段编辑器")
    #expect(InputOverlay.isSecureInput(window.firstResponder))
    #expect(InputOverlay.isSecureInput(secret))
    #expect(window.makeFirstResponder(plain))
    #expect(!InputOverlay.isSecureInput(window.firstResponder))
  }
}
