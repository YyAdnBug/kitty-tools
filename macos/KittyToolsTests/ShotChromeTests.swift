// 截图遮罩外观的纯几何：洞 / 高亮框的圆角路径元素数恒定（S5 变形要求）、工具栏放哪、HUD 小控件的外圈描边、
// 工具栏图标在 macOS 15 上都有

import AppKit
import Testing

@testable import KittyTools

@MainActor @Suite
struct ShotChromeTests {
  private func elements(_ path: CGPath) -> [CGPathElementType] {
    var types: [CGPathElementType] = []
    path.applyWithBlock { types.append($0.pointee.type) }
    return types
  }

  // 窗口（圆角 10）、光标处的零尺寸占位、选区（圆角 0）三种洞的路径结构一样，才能互相插值
  @Test func roundedPathKeepsElementsForMorphing() {
    let window = SelectionView.roundedPath(
      CGRect(x: 10, y: 20, width: 300, height: 200), radius: 10)
    let spot = SelectionView.roundedPath(CGRect(x: 50, y: 60, width: 0, height: 0), radius: 10)
    let selection = SelectionView.roundedPath(
      CGRect(x: 10, y: 20, width: 300, height: 200), radius: 0)
    #expect(elements(window).count == 10)
    #expect(elements(window) == elements(spot))
    #expect(elements(window) == elements(selection))
    #expect(spot.boundingBoxOfPath == CGRect(x: 50, y: 60, width: 0, height: 0))
    #expect(window.boundingBoxOfPath == CGRect(x: 10, y: 20, width: 300, height: 200))
  }

  // 选区下方放不下 → 上方；上下都放不下（整屏）→ 选区底部里面；横向夹在屏内 10 pt
  @Test func toolbarPlacement() {
    let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let size = CGSize(width: 700, height: 40)
    let below = SelectionView.toolbarPlacement(
      size: size, selection: CGRect(x: 300, y: 200, width: 400, height: 300), in: bounds)
    #expect(below.origin == CGPoint(x: 150, y: 150))
    #expect(below.edge == .top)
    let above = SelectionView.toolbarPlacement(
      size: size, selection: CGRect(x: 0, y: 20, width: 200, height: 300), in: bounds)
    #expect(above.origin == CGPoint(x: 10, y: 330))
    #expect(above.edge == .bottom)
    let inside = SelectionView.toolbarPlacement(size: size, selection: bounds, in: bounds)
    #expect(inside.origin == CGPoint(x: 250, y: 10))
    #expect(inside.edge == .bottom)
    // 鼠标给的小数点选区：栏落在整点上（图标、描边不发糊）
    let fractional = SelectionView.toolbarPlacement(
      size: size, selection: CGRect(x: 300.3, y: 200.6, width: 400.5, height: 300), in: bounds)
    #expect(fractional.origin == CGPoint(x: 151, y: 151))
    // 录屏的录制条没有样式托盘（tray 0）：选区下方只剩 20 pt 也放在下方，不白让 40 pt 挤进选区
    let tall = CGRect(x: 300, y: 70, width: 400, height: 710)
    let shot = SelectionView.toolbarPlacement(size: size, selection: tall, in: bounds)
    #expect(shot.origin.y == 80 && shot.edge == .bottom)
    let record = SelectionView.toolbarPlacement(size: size, selection: tall, in: bounds, tray: 0)
    #expect(record.origin == CGPoint(x: 150, y: 20))
    #expect(record.edge == .top)
  }

  // 纯图层画的 HUD 小控件（尺寸胶囊、提示、信息卡）也有外圈 0.5 pt black 0.5：边外 0.5、圆角大 0.5，跟着尺寸走，不重复加
  @Test func hudSkinHasOuterStroke() throws {
    let layer = CALayer()
    Style.HUD.applySkin(to: layer, radius: 6)
    layer.bounds = CGRect(x: 0, y: 0, width: 120, height: 26)
    Style.HUD.applySkin(to: layer, radius: 13, curve: .circular)
    #expect(layer.sublayers?.count == 1)
    let ring = try #require(layer.sublayers?.first)
    #expect(ring.frame == CGRect(x: -0.5, y: -0.5, width: 121, height: 27))
    #expect(ring.borderWidth == 0.5 && ring.cornerRadius == 13.5 && ring.cornerCurve == .circular)
    #expect(ring.borderColor == Style.HUD.outerStroke.cgColor)
    // 尺寸胶囊：15 是这套皮肤；macOS 26 是深色液态玻璃（零件在玻璃里，不画皮肤和阴影）
    let field = SizeField()
    field.show(width: 640, height: 480, interactive: true, ratio: "自由", locked: false)
    if #available(macOS 26, *) {
      let glass = try #require(field.subviews.first as? NSGlassEffectView)
      #expect(field.subviews.count == 1 && glass.cornerRadius == Style.Radius.control)
      #expect(field.layer?.borderWidth == 0 && field.layer?.shadowPath == nil)
    } else {
      let outer = try #require(field.layer?.sublayers?.first { $0.name == ring.name })
      #expect(outer.frame == field.bounds.insetBy(dx: -0.5, dy: -0.5))
    }
  }

  // HUD 材质（Whisker §2）：15 是内缩 0.5 的 .hudWindow 毛玻璃 + 外圈描边 + 阴影；macOS 26 是铺满的深色液态玻璃，
  // 不画描边和自绘阴影；内容（按钮栈）都在 effect 里
  @Test func hudBarMaterialPerSystem() throws {
    let bar = HUDBar(radius: Style.Radius.panel, height: 40)
    bar.install([NSView(frame: CGRect(x: 0, y: 0, width: 60, height: 20))])
    let material = try #require(bar.subviews.first)
    #expect(bar.stack.superview === bar.effect)
    if #available(macOS 26, *) {
      let glass = try #require(material as? NSGlassEffectView)
      #expect(glass.cornerRadius == Style.Radius.panel && glass.contentView === bar.effect)
      #expect(glass.appearance?.name == .darkAqua)
      #expect(material.frame == bar.bounds)
      #expect(bar.layer?.borderWidth == 0 && bar.layer?.shadowPath == nil)
    } else {
      let effect = try #require(material as? NSVisualEffectView)
      #expect(effect === bar.effect && effect.material == .hudWindow)
      #expect(material.frame == bar.bounds.insetBy(dx: 0.5, dy: 0.5))
      #expect(bar.layer?.borderWidth == 0.5 && bar.layer?.shadowPath != nil)
    }
  }

  // 长截图面板：普通 NSView 包材质（15 毛玻璃，圆角裁切和描边在毛玻璃自己的图层上、外壳透明；26 液态玻璃），
  // 内容都在材质（26 是玻璃的 contentView）里
  @Test func scrollHUDMaterialPerSystem() throws {
    let hud = ScrollCaptureHUD()
    let material = try #require(hud.subviews.first)
    #expect(hud.subviews.count == 1)
    #expect(hud.layer?.borderWidth == 0 && hud.layer?.masksToBounds == false)
    if #available(macOS 26, *) {
      let glass = try #require(material as? NSGlassEffectView)
      #expect(glass.cornerRadius == Style.Radius.panel && glass.contentView?.subviews.count == 1)
    } else {
      #expect((material as? NSVisualEffectView)?.material == .hudWindow)
      #expect(material.subviews.filter { $0 is NSStackView }.count == 1)  // 预览、状态、按钮那一列
      let layer = try #require(material.layer)
      #expect(
        layer.borderWidth == 0.5 && layer.masksToBounds && layer.cornerRadius == Style.Radius.panel)
    }
  }

  // 长截图面板的按钮行和状态区（2026-10-12 视觉对齐）：▶ ｜ 另存为 存储 ｜ ✕ ✓（同截图工具栏、录制条：取消紧挨主圆钮、
  // 隔 4），钮 32 × 32、主圆钮 28；行在面板里水平居中、宽度是定死的（原来宽度不定——内容宽到面板内宽之间都满足约束，
  // 有时被拉满、整行偏左 14.5 pt）；四周内缩 10；状态区固定两行高：换成两行的提示时上面的高度读数不跳
  @Test func scrollHUDButtonRowAndStatus() throws {
    let hud = ScrollCaptureHUD()
    let window = NSWindow(
      contentRect: CGRect(x: -20000, y: -20000, width: ScrollCaptureHUD.width, height: 360),
      styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView = hud
    func all(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + all($0) } }
    func frame(_ view: NSView) -> CGRect { view.convert(view.bounds, to: hud) }
    let short = ScrollCapture.status(
      notice: nil, isFull: false, isLost: false, isAutoScrolling: false
    ).text
    hud.show(short, width: 1200, height: 480)
    window.layoutIfNeeded()
    let buttons = all(hud).compactMap { $0 as? BarButton }.sorted {
      frame($0).minX < frame($1).minX
    }
    #expect(
      buttons.map(\.toolTip) == [
        "自动滚动（空格）", "另存为…（⇧⌘S）", ScreenshotOutput.saveTitle + "（⌘S）", "取消（Esc）", "拷贝（↩）",
      ])
    let rects = buttons.map(frame)
    #expect(rects.dropLast().allSatisfy { $0.size == CGSize(width: 32, height: 32) })
    #expect(rects[4].size == CGSize(width: 28, height: 28))
    #expect(rects[4].minX - rects[3].maxX == 4 && rects[3].minX - rects[2].maxX > 4)
    // 行居中、不歧义；上下左右内缩 10（按钮行离底 10，预览离顶 10）
    let row = try #require(buttons[0].superview as? NSStackView)
    #expect(!row.hasAmbiguousLayout)
    #expect(abs(rects[0].minX - (hud.bounds.maxX - rects[4].maxX)) < 0.01)
    #expect(rects[0].minY == 10 && frame(row).height == 32)
    let preview = try #require(all(hud).first { $0 is NSImageView && !($0.superview is NSButton) })
    #expect(frame(preview).maxY == hud.bounds.maxY - 10 && frame(preview).minX == 10)
    // 状态一行 → 两行 → 一行：读数、预览、按钮都不挪；状态文字自己在两行高的区域里竖直居中
    let status = try #require(
      all(hud).compactMap { $0 as? NSTextField }.first { $0.maximumNumberOfLines == 2 })
    let reading = try #require(
      all(hud).first { String(describing: type(of: $0)).contains("NSHostingView") })
    let (readingFrame, previewFrame, oneLine) = (frame(reading), frame(preview), frame(status))
    hud.show("自动滚动需要「辅助功能」授权，授权后点 ▶ 开始", tone: .warning, width: 1200, height: 480)
    window.layoutIfNeeded()
    #expect(frame(status).height > oneLine.height * 1.5)
    #expect(frame(reading) == readingFrame && frame(preview) == previewFrame)
    #expect(buttons.map(frame) == rects)
    #expect(abs(frame(status).midY - oneLine.midY) < 0.6)
    // 平常的几句都是一行（面板内宽 196）：操作说明、自动滚动中、对不上、最长了
    for (isFull, isLost, auto, browsing) in [
      (false, false, true, false), (false, true, false, false), (true, false, false, false),
      (false, false, false, true),
    ] {
      let text = ScrollCapture.status(
        notice: nil, isFull: isFull, isLost: isLost, isAutoScrolling: auto, isBrowsing: browsing
      ).text
      hud.show(text, width: 1200, height: 480)
      window.layoutIfNeeded()
      #expect(frame(status).height == oneLine.height, "\(text)")
    }
  }

  // 样式托盘的选项分段（2026-10-12 视觉对齐，落到刻度上）：选项高 22、圆角 mini 4、12 pt medium；轨道高 26（上下各 2）、
  // 圆角 control 6（和里面的选项同心）
  @Test func styleBarSegmentsSitOnTheScale() throws {
    let tray = StyleBar()
    tray.update(tool: .rectangle, style: .init(color: .pink, weight: .medium, option: 1))
    tray.frame.size = tray.preferredSize
    tray.layoutSubtreeIfNeeded()
    let segment = try #require(tray.stack.arrangedSubviews.last as? NSStackView)
    #expect(segment.frame.height == 26 && segment.layer?.cornerRadius == Style.Radius.control)
    let options = segment.arrangedSubviews.compactMap { $0 as? NSButton }
    #expect(options.count == 2)
    for option in options {
      #expect(option.frame.height == 22 && option.layer?.cornerRadius == Style.Radius.mini)
      let font = option.attributedTitle.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
      #expect(font == NSFont.systemFont(ofSize: 12, weight: .medium))
    }
  }

  // 栏里用到的 SF Symbols（连同菜单栏 / 快捷键页的热键动作图标）在最低系统上都存在（force unwrap 不会崩）
  @Test func toolbarSymbolsExist() {
    let symbols =
      Annotation.Tool.allCases.map(\.symbol) + HotKeyAction.allCases.map(\.symbol) + [
        "arrow.uturn.backward", "arrow.uturn.forward", "text.viewfinder", "translate",
        "rectangle.expand.vertical", "pin", "square.and.arrow.down", "chevron.down", "xmark",
        "checkmark",
      ]
    for symbol in symbols {
      #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol)")
    }
  }

  // 两段胶囊并排、间距 6；每个工具按钮都在左段里
  @Test func toolbarLayout() throws {
    let toolbar = EditorToolbar()
    #expect(toolbar.frame.height == 40)
    let frames = Annotation.Tool.allCases.map(toolbar.toolButtonFrame)
    #expect(frames.allSatisfy { $0.width == 32 && $0.height == 32 }, "\(frames)")
    #expect(zip(frames, frames.dropFirst()).allSatisfy { $0.maxX < $1.minX })
    let save = try #require(toolbar.button(for: .output(.save)))
    #expect(save.convert(save.bounds, to: toolbar).minX > frames.last!.maxX + 6)
  }
}
