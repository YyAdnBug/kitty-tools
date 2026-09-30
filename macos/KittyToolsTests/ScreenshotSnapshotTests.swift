import AppKit
import Carbon.HIToolbox
import SwiftUI
import Testing

@testable import KittyTools

// 截图重设计（Whisker §6 截图，2026-09-26）的屏外截图自检（按需启用，同 SnapshotProbeTests）：遮罩待选 / 框选 / 调整、
// 工具栏上下、按工具的样式托盘、10 种标注与选中手柄、弯箭头和弯直线（选中 / 拖弯曲手柄 / 各种颜色粗细 / 弯到头）、尺寸输入、文字输入（三种样式）、比例和保存菜单、右键提示、截图翻译框选、常驻缩略图
// （飞行卡片落地后交接的同一张卡）、长截图面板与边框，按 2x 写成 PNG（带 -crop 的是局部，看线和图标对不对齐）。
// 录屏框选（待选提示、调整阶段的录制条、截图里按 R 切过去的录制条）和录制 HUD（倒数、录制中、放弃上膛）也在这里；
// 第 3 批补了常驻缩略图的视频卡（落地、悬停、矮卡、没有最后一帧的占位）。
// 状态用 SelectionInteractionTests 的屏外窗口 + 合成事件摆（不弹遮罩、不抢键盘）；图层要在窗口里显示过才有内容，
// 所以把屏外 (-20000, -20000) 的无边框窗口（当不了 key）orderFront 一下再 layer.render(in:)。材质在屏外会发灰，只锁布局。
//   TEST_RUNNER_KITTY_SNAPSHOT_DIR=/tmp/shots xcodebuild -project macos/KittyTools.xcodeproj \
//     -scheme KittyTools test -only-testing:KittyToolsTests/ScreenshotSnapshotTests
@MainActor @Suite(.serialized)
struct ScreenshotSnapshotTests {
  typealias Harness = SelectionInteractionTests.Harness
  nonisolated private static let directory =
    ProcessInfo.processInfo.environment["KITTY_SNAPSHOT_DIR"]

  /// 假桌面上的两个窗口（视图坐标，从前到后）：前面是备忘录（文字），后面是表格（色块）
  static let windows = [
    CGRect(x: 140, y: 380, width: 460, height: 300),
    CGRect(x: 520, y: 120, width: 560, height: 420),
  ]

  @Test(.enabled(if: directory != nil)) func renderOverlay() throws {
    let desktop = try Self.desktop()
    let capture = { Harness(windows: Self.windows, image: desktop) }
    let top = CGRect(x: 0, y: 560, width: 1200, height: 240)

    // 待选：悬停窗口（洞 + 粉框 + 窗口像素尺寸）+ 放大镜 + 顶部提示；桌面上（整屏轻暗）；按住 ⌘ 的十字准线
    var h = capture()
    h.move(CGPoint(x: 330, y: 520))
    try shoot(h.window, "idle-window", crop: CGRect(x: 100, y: 340, width: 620, height: 460))
    h = capture()
    h.move(CGPoint(x: 1000, y: 700))
    try shoot(h.window, "idle-desktop", crop: top)
    h = capture()
    h.move(CGPoint(x: 300.4, y: 300.6))
    h.modifiers(.command)
    try shoot(h.window, "idle-crosshair", crop: CGRect(x: 200, y: 100, width: 300, height: 300))

    // 框选中：⇧ 正方形，右边吸到后面窗口的左边（整屏粉色虚线参考线），放大镜、尺寸胶囊
    h = capture()
    h.begin(CGPoint(x: 200, y: 150), to: CGPoint(x: 517, y: 260), flags: .shift)
    try shoot(h.window, "draw-shift-snap", crop: CGRect(x: 150, y: 80, width: 600, height: 480))

    // 调整：手柄、悬停右边（加粗 + 手柄放大）、下方工具栏、左上尺寸胶囊（可点、比例按钮），深浅色
    let adjust = {
      let h = capture()
      // 鼠标给的是小数点（触控板）：边框、手柄要落在整像素上
      h.drag(CGPoint(x: 300.3, y: 260.7), CGPoint(x: 800.4, y: 560.2))
      h.move(CGPoint(x: 801, y: 420))
      return h
    }
    for dark in [false, true] {
      try shoot(
        adjust().window, "adjust", dark: dark, crop: CGRect(x: 150, y: 190, width: 900, height: 420)
      )
    }
    // 工具栏放不下选区下方 → 上方（托盘在栏上方）；整屏选区 → 栏放进选区底部、尺寸胶囊放进左上角
    h = capture()
    h.drag(CGPoint(x: 250, y: 30), CGPoint(x: 850, y: 330))
    h.view.tool = .arrow
    try shoot(h.window, "toolbar-above", crop: CGRect(x: 150, y: 0, width: 900, height: 460))
    h = capture()
    h.view.select(CGRect(x: 0, y: 0, width: 1200, height: 800))
    try shoot(h.window, "toolbar-inside")

    // 样式托盘：矩形（色点 + 三档 + 空心 / 实心）、文字（三个选项）、马赛克（没有色点）、聚光灯（浅 / 中 / 深）
    let trays: [(String, Annotation.Tool, Annotation.Style)] = [
      ("tray-rectangle", .rectangle, .init(color: .pink, weight: .medium, option: 1)),
      ("tray-text", .text, .init(color: .red, weight: .large, option: 2)),
      ("tray-mosaic", .mosaic, .init(weight: .small, option: 0)),
      ("tray-spotlight", .spotlight, .init(weight: .large)),
    ]
    for (name, tool, style) in trays {
      let h = adjust()
      h.move(CGPoint(x: 550, y: 400))
      h.view.style = style
      h.view.tool = tool
      try shoot(h.window, name, crop: barsFrame(h))
    }

    // 10 种标注（有 / 没有聚光灯各一张）
    let selection = CGRect(x: 120, y: 150, width: 960, height: 580)
    for (name, spotlight) in [("annotations", true), ("annotations-nospot", false)] {
      let h = capture()
      h.view.select(selection)
      h.view.annotations = Self.allAnnotations(spotlight: spotlight)
      h.move(CGPoint(x: 1150, y: 760))
      try shoot(h.window, name)
    }
    // 选中的矩形（虚线框 + 四角手柄）、选中的箭头（两端手柄，托盘显示它的颜色）
    for (name, shape, style) in [
      (
        "selected-rectangle",
        Annotation.Shape.rectangle(CGRect(x: 360, y: 330, width: 220, height: 120)),
        Annotation.Style(color: .pink)
      ),
      (
        "selected-arrow", .arrow(from: CGPoint(x: 700, y: 330), to: CGPoint(x: 480, y: 470)),
        .init(color: .blue, weight: .large)
      ),
    ] {
      let h = adjust()
      let annotation = Annotation(shape: shape, style: style)
      h.view.annotations = [annotation]
      h.view.tool = annotation.tool
      h.view.selectedAnnotation = annotation.id
      h.move(CGPoint(x: 1150, y: 760))
      try shoot(h.window, name, crop: CGRect(x: 150, y: 150, width: 900, height: 460))
    }
    // 弯箭头、弯直线各一套（同样的摆法）
    for (tool, noun) in [(Annotation.Tool.arrow, "arrow"), (.line, "line")] {
      // 选中的：两端手柄 + 弧线中点小一号的弯曲手柄；拖着弯曲手柄（跟手、放大镜不出）
      let curved = Annotation(
        shape: .bendable(
          tool, from: CGPoint(x: 400, y: 330), to: CGPoint(x: 720, y: 380),
          bend: CGVector(dx: 0, dy: 0.3)), style: .init(color: .pink))
      for (name, dragging) in [("selected-curved-\(noun)", false), ("bending-\(noun)", true)] {
        let h = adjust()
        h.view.annotations = [curved]
        h.view.tool = tool
        h.view.selectedAnnotation = curved.id
        if dragging {
          let handle = try #require(curved.handles.first { $0.0 == .bend }?.1)
          h.begin(handle, to: CGPoint(x: 600, y: 280))
        } else {
          h.move(CGPoint(x: 1150, y: 760))
        }
        try shoot(h.window, name, crop: CGRect(x: 360, y: 250, width: 400, height: 220))
      }
      // 各种颜色、粗细：往两边弯、偏向一端、弯成 U 形，各配一条同样式的直的对照
      h = capture()
      h.view.select(selection)
      h.view.annotations = Self.curved(tool)
      h.move(CGPoint(x: 1150, y: 760))
      try shoot(h.window, "curved-\(noun)s", crop: CGRect(x: 120, y: 150, width: 480, height: 300))
      // 弯到头的：手柄拖过尖端 / 尾端（沿弦停在 ¾ / ¼ 处）、贴着尖端的钩（箭头颈部不折）、弦很短的深 U、弯过后被拖短的
      h = capture()
      h.view.select(selection)
      h.view.annotations = Self.extreme(tool)
      h.move(CGPoint(x: 1150, y: 760))
      try shoot(h.window, "curved-\(noun)s-extreme", crop: selection)
    }

    // 尺寸胶囊：输入中（宽拿到键盘，粉色焦点环）；比例菜单开着；保存 ▾ 菜单开着
    h = adjust()
    h.clickSize(.width)
    let field = try #require(h.sizeField)
    try shoot(h.window, "size-editing", crop: field.frame.insetBy(dx: -40, dy: -30))
    // 文字输入中：焦点环（1 pt 粉 0.55 + 粉色外发光，底色时圆角同色块）、粉色光标；无底 / 描边 / 底色
    for (name, style) in [
      ("text-editing", Annotation.Style(color: .red, weight: .medium, option: 0)),
      ("text-editing-outline", .init(color: .white, weight: .medium, option: 1)),
      ("text-editing-plate", .init(color: .yellow, weight: .medium, option: 2)),
    ] {
      h = adjust()
      h.view.style = style
      h.view.tool = .text
      h.view.beginEditing(at: CGPoint(x: 420, y: 470))
      h.fieldEditor?.insertText(
        "输入中 Typing", replacementRange: NSRange(location: NSNotFound, length: 0))
      try shoot(h.window, name, crop: CGRect(x: 380, y: 400, width: 320, height: 110))
    }

    h = adjust()
    h.clickSize(nil)
    let menu = try #require(h.menu)
    try shoot(
      h.window, "ratio-menu",
      crop: menu.frame.union(try #require(h.sizeField).frame).insetBy(dx: -40, dy: -30))
    h = adjust()
    let caret = try #require(h.toolbar?.button(for: .saveMenu))
    caret.sendAction(caret.action, to: caret.target)
    try shoot(
      h.window, "save-menu",
      crop: try #require(h.menu).frame.union(try #require(h.toolbar).frame).insetBy(
        dx: -30, dy: -30))

    // 有标注时右键：不清空，顶部提示怎么退出
    h = adjust()
    h.view.annotations = [
      Annotation(shape: .rectangle(CGRect(x: 360, y: 330, width: 200, height: 100)))
    ]
    h.rightClick(CGPoint(x: 1000, y: 700))
    try shoot(h.window, "right-click-hint", crop: top)

    // 截图翻译 / 识字（quick）：待选（提示 + 放大镜）、框选中（粉线、只读尺寸、放大镜、吸附参考线）
    let quick = {
      Harness(
        mode: .quick, windows: Self.windows, image: desktop, hint: "拖动框选要翻译的文字 · Esc 取消")
    }
    h = quick()
    h.move(CGPoint(x: 330, y: 520))
    try shoot(h.window, "quick-idle", crop: CGRect(x: 100, y: 340, width: 700, height: 460))
    h = quick()
    h.begin(CGPoint(x: 150, y: 560), to: CGPoint(x: 460, y: 638))
    try shoot(h.window, "quick-draw", crop: CGRect(x: 100, y: 340, width: 700, height: 460))

    // 录屏（录屏第 1 批）：待选的顶部提示；调整阶段同截图（手柄、尺寸胶囊），选区下方是录制条 [取消][● 开始录制]
    // （HUD 永远深色，不出深色版）；-bar 是录制条的局部
    let record = { Harness(mode: .record, windows: Self.windows, image: desktop) }
    h = record()
    h.move(CGPoint(x: 1000, y: 700))
    try shoot(h.window, "record-idle", crop: top)
    h = record()
    h.drag(CGPoint(x: 300.3, y: 260.7), CGPoint(x: 800.4, y: 560.2))
    h.move(CGPoint(x: 801, y: 420))
    try shoot(h.window, "record-adjust", crop: CGRect(x: 150, y: 190, width: 900, height: 420))
    let bar = try #require(h.recordBar)
    try shoot(h.window, "record-adjust-bar", crop: bar.frame.insetBy(dx: -24, dy: -24))
    // 截图调整时按 R（录屏第 2 批）：工具栏原地换成录制条，选区、尺寸胶囊不变
    h = adjust()
    h.key(kVK_ANSI_R, "r")
    let switched = try #require(h.recordBar)
    let chosen = try #require(h.view.selection)
    try shoot(
      h.window, "record-switched", crop: switched.frame.union(chosen).insetBy(dx: -24, dy: -24))
  }

  @Test(.enabled(if: directory != nil)) func renderPeripherals() throws {
    let out = try #require(Self.directory)
    let desktop = try Self.desktop()
    // 常驻缩略图：飞行卡片落地后原地交接的同一张卡（同样的圆角、阴影、描边、右上角粉色角标），悬停时的 HUD 操作
    let shot = try #require(desktop.cropping(to: CGRect(x: 280, y: 240, width: 920, height: 600)))
    let card = CGSize(width: 200, height: 130)
    // 真的桌面目录：角标写访达里的名字（中文系统是「桌面」）
    let desktopFolder = try #require(
      FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first)
    let saved = FlyCard.Badge.saved(desktopFolder.appending(path: "a.png"))
    for (name, badge, hovered) in [
      ("shot-flycard-landed", FlyCard.Badge.copied, false), ("shot-flycard-saved", saved, false),
      ("shot-shelf-hover", saved, true),
    ] {
      let shelf = ShelfCard(
        image: shot, scale: 2, source: CGRect(origin: .zero, size: card),
        rect: CGRect(origin: .zero, size: card), badge: badge, screen: nil, panel: NSPanel(),
        shelf: ShotShelf())
      shelf.isHovered = hovered
      for dark in [false, true] {
        try snapshot(
          ShelfCardView(card: shelf), over: desktop,
          size: NSSize(
            width: card.width + ShotShelf.margin * 2, height: card.height + ShotShelf.margin * 2),
          dark: dark, to: "\(out)/\(name)\(dark ? "-dark" : "").png")
      }
    }

    // 矮卡（体检 B46）：悬停的「拷贝」「存储」胶囊只剩图标（名字靠 accessibilityLabel），四角圆钮不画
    let compact = CGSize(width: 110, height: 70)
    let small = ShelfCard(
      image: shot, scale: 2, source: CGRect(origin: .zero, size: compact),
      rect: CGRect(origin: .zero, size: compact), badge: .copied, screen: nil, panel: NSPanel(),
      shelf: ShotShelf())
    small.isHovered = true
    for dark in [false, true] {
      try snapshot(
        ShelfCardView(card: small), over: desktop,
        size: NSSize(
          width: compact.width + ShotShelf.margin * 2, height: compact.height + ShotShelf.margin * 2
        ),
        dark: dark, to: "\(out)/shot-shelf-compact-hover\(dark ? "-dark" : "").png")
    }

    // 录屏的视频卡（第 3 批）：飞行卡片落地后交接的同一张卡（最后一帧 + 播放符号 + 左下角时长 + 文件夹角标）、悬停（只有
    // 「拷贝」+ 关闭 / 在访达中显示）、矮卡（播放符号缩小；悬停胶囊只剩图标、没有四角圆钮）、没取到最后一帧的占位
    for (name, size, poster, hovered) in [
      ("shot-video-landed", card, true, false), ("shot-video-hover", card, true, true),
      ("shot-video-compact", compact, true, false),
      ("shot-video-compact-hover", compact, true, true),
      ("shot-video-placeholder", card, false, false),
    ] {
      let video = ShelfCard(
        video: desktopFolder.appending(path: "录屏 2026-09-30 10.00.00.mp4"), seconds: 83,
        poster: poster ? shot : nil, source: CGRect(origin: .zero, size: size),
        rect: CGRect(origin: .zero, size: size), screen: nil, panel: NSPanel(), shelf: ShotShelf())
      video.isHovered = hovered
      for dark in [false, true] {
        try snapshot(
          ShelfCardView(card: video), over: desktop,
          size: NSSize(
            width: size.width + ShotShelf.margin * 2, height: size.height + ShotShelf.margin * 2),
          dark: dark, to: "\(out)/\(name)\(dark ? "-dark" : "").png")
      }
    }

    // 长截图：选区外的粉色边框（呼吸 / 自动滚动时的蚂蚁线）+ 贴在右边的 HUD 面板（预览、高度读数、粉色自动滚动钮和拷贝钮）
    let page = try ScreenshotTests.render([
      "The quick brown fox jumps over the lazy dog", "敏捷的棕色狐狸跳过了懒狗", "日本語のテキスト",
      "한국어 텍스트", "Привет мир", "Hello World", "第七行", "第八行",
    ])
    let first = try #require(page.cropping(to: CGRect(x: 0, y: 0, width: 1200, height: 480)))
    let second = try #require(page.cropping(to: CGRect(x: 0, y: 360, width: 1200, height: 480)))
    var stitcher = try #require(
      ScrollStitcher(first: first, scrollbarWidth: 32, maxHeight: 30_000))
    _ = stitcher.add(second)
    let region = CGRect(x: 160, y: 200, width: 600, height: 420)
    for (name, auto) in [("scroll", false), ("scroll-auto", true)] {
      let root = NSView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
      root.wantsLayer = true
      root.layer?.contents = desktop
      let border = ScrollBorderView()
      border.frame = region.insetBy(dx: -ScrollBorderView.margin, dy: -ScrollBorderView.margin)
      border.update(lost: false, marching: auto)
      root.addSubview(border)
      let hud = ScrollCaptureHUD()
      hud.frame = CGRect(
        x: region.maxX + 10, y: region.minY, width: ScrollCaptureHUD.width,
        height: region.height)
      hud.isAutoScrolling = auto
      root.addSubview(hud)
      let window = offscreen(root)
      try shoot(window, name, crop: region.insetBy(dx: -30, dy: -30).union(hud.frame)) {
        hud.show(
          auto ? "自动滚动中：按空格或把鼠标移出选区停止" : "在选区里滚动，或按空格自动滚动",
          width: stitcher.width, height: stitcher.outputHeight)
        hud.updatePreview(stitcher: stitcher, scale: 2)
      }
    }
  }

  /// 录制 HUD（录屏第 2 批）：倒数（边框走蚂蚁线、HUD「3 秒后开始」）、录制中 0:12（边框静止、红点、计时、✕、■）、
  /// 放弃上膛（✕ 变红）、整屏（没有边框，可见区底部居中）。HUD 永远深色，不出深色版；-crop 是 HUD 的局部
  @Test(.enabled(if: directory != nil)) func renderRecordingHUD() throws {
    let desktop = try Self.desktop()
    let region = CGRect(x: 160, y: 260, width: 640, height: 400)
    let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
    for (name, state, counting, armed) in [
      ("record-hud-countdown", RecordingHUD.State.countdown(3), true, false),
      ("record-hud", .recording(12), false, false),
      ("record-hud-armed", .recording(12), false, true),
      ("record-hud-full", .recording(12), false, false),
    ] {
      let full = name.hasSuffix("full")
      let root = NSView(frame: bounds)
      root.wantsLayer = true
      root.layer?.contents = desktop
      if !full {
        let border = ScrollBorderView(animates: counting)
        border.frame = region.insetBy(dx: -ScrollBorderView.margin, dy: -ScrollBorderView.margin)
        if counting { border.update(lost: false, marching: true) }
        root.addSubview(border)
      }
      let hud = RecordingHUD(state: state, stopKey: "⌥R")
      if armed { try #require(hud.button(for: .discard)).performClick(nil) }
      hud.panel.contentView = NSView()  // 从它自己的窗口里拿出来，摆到假桌面上
      hud.frame.origin = RecordingHUD.origin(
        size: hud.frame.size, region: full ? bounds : region, screen: bounds,
        visible: bounds.insetBy(dx: 0, dy: 24).offsetBy(dx: 0, dy: -12), isFullScreen: full,
        dragged: nil)
      root.addSubview(hud)
      try shoot(offscreen(root), name, crop: hud.frame.insetBy(dx: -24, dy: -24))
    }
  }

  // MARK: 摆状态

  /// 10 种标注摆在假桌面上：荧光笔压在第一行字上、马赛克像素 / 模糊各压一段表格、文字三种样式、三个序号、聚光灯照着色块
  private static func allAnnotations(spotlight: Bool) -> [Annotation] {
    var list = [
      Annotation(
        shape: .highlighter(from: CGPoint(x: 160, y: 621), to: CGPoint(x: 430, y: 621)),
        style: .init(color: .yellow)),
      Annotation(shape: .rectangle(CGRect(x: 152, y: 530, width: 262, height: 34))),
      Annotation(
        shape: .rectangle(CGRect(x: 160, y: 400, width: 150, height: 50)),
        style: .init(color: .pink, option: 1)),
      Annotation(
        shape: .ellipse(CGRect(x: 610, y: 400, width: 170, height: 70)),
        style: .init(color: .green, weight: .small)),
      Annotation(
        shape: .arrow(from: CGPoint(x: 470, y: 250), to: CGPoint(x: 600, y: 360)),
        style: .init(color: .blue, weight: .large)),
      Annotation(
        shape: .line(from: CGPoint(x: 160, y: 300), to: CGPoint(x: 420, y: 300)),
        style: .init(color: .orange)),
      Annotation(
        shape: .pen(
          stride(from: 0.0, through: 1, by: 0.05).map {
            CGPoint(x: 170 + 240 * $0, y: 230 + 26 * sin($0 * .pi * 4))
          }), style: .init(color: .black, weight: .small)),
      Annotation(shape: .mosaic(CGRect(x: 540, y: 300, width: 250, height: 56))),
      Annotation(
        shape: .mosaic(CGRect(x: 540, y: 200, width: 250, height: 56)), style: .init(option: 1)),
      Annotation(shape: .text("看这里", origin: CGPoint(x: 640, y: 716))),
      Annotation(
        shape: .text("描边文字", origin: CGPoint(x: 820, y: 716)),
        style: .init(color: .white, weight: .medium, option: 1)),
      Annotation(
        shape: .text("底色 Plate", origin: CGPoint(x: 150, y: 716)),
        style: .init(color: .yellow, weight: .medium, option: 2)),
    ]
    for (index, weight) in Annotation.Weight.allCases.enumerated() {
      let center = CGPoint(x: 460 + CGFloat(index) * 50, y: 650)
      list.append(
        Annotation(
          shape: .counter(index + 1, center: center), style: .init(color: .pink, weight: weight)))
    }
    if spotlight {
      list.append(Annotation(shape: .spotlight(CGRect(x: 850, y: 190, width: 200, height: 170))))
    }
    return list
  }

  /// 弯箭头 / 弯直线一组（选区 (120, 150, 960 × 580) 里）：左列细 / 中 / 粗各一条弯的 + 一条同样式直的，右边偏向一端、
  /// U 形、压在表格上的白色和黄色
  private static func curved(_ tool: Annotation.Tool) -> [Annotation] {
    func item(_ from: CGPoint, _ to: CGPoint, _ bend: CGVector, _ style: Annotation.Style)
      -> Annotation
    {
      Annotation(shape: .bendable(tool, from: from, to: to, bend: bend), style: style)
    }
    return [
      item(
        CGPoint(x: 160, y: 180), CGPoint(x: 380, y: 190), CGVector(dx: 0, dy: 0.15),
        .init(color: .pink, weight: .small)),
      item(
        CGPoint(x: 160, y: 300), CGPoint(x: 380, y: 300), CGVector(dx: 0, dy: -0.2),
        .init(color: .red, weight: .medium)),
      item(CGPoint(x: 160, y: 350), CGPoint(x: 380, y: 350), .zero, .init(color: .red)),
      item(
        CGPoint(x: 420, y: 170), CGPoint(x: 470, y: 420), CGVector(dx: 0, dy: 0.25),
        .init(color: .blue, weight: .large)),
      item(
        CGPoint(x: 520, y: 170), CGPoint(x: 570, y: 420), .zero,
        .init(color: .blue, weight: .large)),
      item(
        CGPoint(x: 160, y: 560), CGPoint(x: 420, y: 700), CGVector(dx: 0.25, dy: -0.25),
        .init(color: .green, weight: .medium)),
      item(
        CGPoint(x: 640, y: 660), CGPoint(x: 540, y: 660), CGVector(dx: 0, dy: 1.1),
        .init(color: .orange, weight: .large)),
      item(
        CGPoint(x: 760, y: 300), CGPoint(x: 1040, y: 480), CGVector(dx: -0.15, dy: -0.3),
        .init(color: .white, weight: .large)),
      item(
        CGPoint(x: 1050, y: 680), CGPoint(x: 780, y: 600), CGVector(dx: 0, dy: 0.45),
        .init(color: .yellow, weight: .medium)),
      item(
        CGPoint(x: 660, y: 720), CGPoint(x: 900, y: 725), CGVector(dx: 0, dy: -0.2),
        .init(color: .black, weight: .small)),
    ]
  }

  /// 弯到头的箭头 / 直线（选区 (120, 150, 960 × 580) 里）：左列三档粗细的手柄拖过尖端、离弦不远（尖端带钩）+ 拖过尾端；
  /// 右边拖过尖端很远（J 形，一白一橙）、斜弦上的钩、弦 30 的深 U、弯过后被拖到弦 10 的粗 / 细（箭头头缩短）；
  /// 横贯选区的一条弦 900、手柄拖过尖端 20 点、离弦 4.5 点（长弦上很短的钩）
  private static func extreme(_ tool: Annotation.Tool) -> [Annotation] {
    func stored(_ from: CGPoint, _ to: CGPoint, _ bend: CGVector, _ style: Annotation.Style)
      -> Annotation
    {
      Annotation(shape: .bendable(tool, from: from, to: to, bend: bend), style: style)
    }
    func dragged(_ from: CGPoint, _ to: CGPoint, _ handle: CGPoint, _ style: Annotation.Style)
      -> Annotation
    {
      stored(
        from, to, Annotation.curveBend(from: from, to: to, through: handle, constrained: false),
        style)
    }
    return [
      dragged(
        CGPoint(x: 160, y: 700), CGPoint(x: 400, y: 700), CGPoint(x: 420, y: 712),
        .init(color: .pink, weight: .small)),
      dragged(
        CGPoint(x: 160, y: 620), CGPoint(x: 400, y: 620), CGPoint(x: 420, y: 638),
        .init(color: .red, weight: .medium)),
      dragged(
        CGPoint(x: 160, y: 530), CGPoint(x: 400, y: 530), CGPoint(x: 420, y: 555),
        .init(color: .blue, weight: .large)),
      dragged(
        CGPoint(x: 160, y: 420), CGPoint(x: 400, y: 420), CGPoint(x: 60, y: 410),
        .init(color: .green, weight: .medium)),
      dragged(
        CGPoint(x: 480, y: 520), CGPoint(x: 720, y: 520), CGPoint(x: 820, y: 660),
        .init(color: .orange, weight: .large)),
      dragged(
        CGPoint(x: 720, y: 330), CGPoint(x: 480, y: 330), CGPoint(x: 400, y: 250),
        .init(color: .white, weight: .large)),
      dragged(
        CGPoint(x: 800, y: 700), CGPoint(x: 1040, y: 600), CGPoint(x: 1080, y: 600),
        .init(color: .green, weight: .large)),
      stored(
        CGPoint(x: 820, y: 250), CGPoint(x: 850, y: 250), CGVector(dx: 0, dy: 5),
        .init(color: .yellow, weight: .medium)),
      stored(
        CGPoint(x: 950, y: 300), CGPoint(x: 960, y: 300), CGVector(dx: 0, dy: 1.8),
        .init(color: .red, weight: .large)),
      stored(
        CGPoint(x: 1010, y: 300), CGPoint(x: 1020, y: 300), CGVector(dx: 0, dy: 2),
        .init(color: .black, weight: .small)),
      dragged(
        CGPoint(x: 140, y: 175), CGPoint(x: 1040, y: 175), CGPoint(x: 1060, y: 179.5),
        .init(color: .red, weight: .large)),
    ]
  }

  /// 工具栏 + 样式托盘（+ 开着的菜单）外扩 24
  private func barsFrame(_ h: Harness) -> CGRect {
    let bars = h.view.subviews.filter {
      ($0 is EditorToolbar || $0 is StyleBar || $0 is HUDMenu) && !$0.isHidden
    }
    return bars.map(\.frame).reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -24, dy: -24)
  }

  /// 假桌面（1200 × 800 点 @2x）：渐变壁纸、菜单栏，后面一个表格窗口（行、色块），前面一个备忘录窗口（多语种文字）
  static func desktop() throws -> CGImage {
    let bitmap = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 2400, pixelsHigh: 1600, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0))
    bitmap.size = NSSize(width: 1200, height: 800)  // 按点画，像素是 2 倍
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    func text(_ string: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat, color: NSColor = .black)
    {
      NSAttributedString(
        string: string,
        attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color]
      ).draw(at: NSPoint(x: x, y: y))
    }
    NSGradient(
      starting: NSColor(srgbRed: 0.24, green: 0.19, blue: 0.50, alpha: 1),
      ending: NSColor(srgbRed: 0.10, green: 0.56, blue: 0.58, alpha: 1))?
      .draw(in: NSRect(x: 0, y: 0, width: 1200, height: 800), angle: -30)
    NSColor.white.withAlphaComponent(0.8).setFill()
    NSRect(x: 0, y: 776, width: 1200, height: 24).fill()
    text("Finder    文件    编辑    显示    前往    窗口", 16, 780, size: 13)
    for (index, frame) in windows.enumerated().reversed() {
      let shadow = NSShadow()
      shadow.shadowColor = .black.withAlphaComponent(0.35)
      shadow.shadowBlurRadius = 20
      shadow.shadowOffset = NSSize(width: 0, height: -8)
      NSGraphicsContext.saveGraphicsState()
      shadow.set()
      NSColor(white: index == 0 ? 1 : 0.97, alpha: 1).setFill()
      NSBezierPath(roundedRect: frame, xRadius: 10, yRadius: 10).fill()
      NSGraphicsContext.restoreGraphicsState()
      NSColor(white: 0.93, alpha: 1).setFill()
      NSRect(x: frame.minX, y: frame.maxY - 28, width: frame.width, height: 18).fill()
      NSBezierPath(
        roundedRect: NSRect(x: frame.minX, y: frame.maxY - 28, width: frame.width, height: 28),
        xRadius: 10, yRadius: 10
      ).fill()
      for (dot, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
        color.setFill()
        NSBezierPath(
          ovalIn: NSRect(
            x: frame.minX + 12 + CGFloat(dot) * 20, y: frame.maxY - 20, width: 12, height: 12)
        ).fill()
      }
      text(index == 0 ? "备忘录" : "季度数据.numbers", frame.midX - 30, frame.maxY - 22, size: 13)
    }
    // 前面的备忘录：一行一种文字
    let notes = [
      "The quick brown fox jumps over", "敏捷的棕色狐狸跳过了懒狗", "Hello World  #FF4D7E", "日本語のテキスト",
      "Привет мир", "한국어 텍스트", "第七行：截图自检",
    ]
    for (index, line) in notes.enumerated() {
      text(line, 160, 610 - CGFloat(index) * 34, size: 18)
    }
    // 后面的表格：斑马纹行（前面的窗口盖住左上角）+ 一组色块
    let table = windows[1]
    for row in 0..<9 {
      let y = table.maxY - 60 - CGFloat(row) * 38
      if row % 2 == 0 {
        NSColor(white: 0.92, alpha: 1).setFill()
        NSRect(x: table.minX + 90, y: y - 8, width: 280, height: 34).fill()
      }
      text("Q\(row % 4 + 1)   ¥\(1200 + row * 317)   +\(row * 3)%", table.minX + 100, y, size: 16)
    }
    for (index, color) in [NSColor.systemPink, .systemOrange, .systemTeal, .systemIndigo]
      .enumerated()
    {
      color.setFill()
      let height = CGFloat([150, 90, 200, 120][index])
      NSBezierPath(
        roundedRect: NSRect(
          x: table.maxX - 190 + CGFloat(index) * 42, y: table.minY + 30, width: 30, height: height),
        xRadius: 4, yRadius: 4
      ).fill()
    }
    return try #require(bitmap.cgImage)
  }

  // MARK: 渲染

  private func offscreen(_ view: NSView) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: view.frame.size),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    view.wantsLayer = true
    window.contentView = view
    return window
  }

  /// 同 SnapshotProbeTests.renderLayers：屏外窗口显示一下、跑几轮 RunLoop，再按 2x 渲染内容视图的图层
  /// （cacheDisplay 画不出直接加的子图层）。prepare 在布局之后跑；crop（点，视图坐标）另存一张局部
  private func shoot(
    _ window: NSWindow, _ name: String, dark: Bool = false, crop: CGRect? = nil,
    prepare: () -> Void = {}
  ) throws {
    let out = try #require(Self.directory)
    let view = try #require(window.contentView)
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.orderFront(nil)
    window.layoutIfNeeded()
    prepare()
    for _ in 0..<5 { RunLoop.main.run(until: Date.now.addingTimeInterval(0.1)) }
    let scale: CGFloat = 2
    let size = view.bounds.size
    let bitmap = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
        pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap)).cgContext
    context.scaleBy(x: scale, y: scale)
    try #require(view.layer).render(in: context)
    window.orderOut(nil)
    let image = try #require(bitmap.cgImage)
    let stem = "\(out)/shot-\(name)\(dark ? "-dark" : "")"
    try write(image, to: "\(stem).png")
    guard let crop = crop?.intersection(view.bounds), !crop.isEmpty else { return }
    // 图像行从上往下：y 翻过来
    let pixels = CGRect(
      x: crop.minX * scale, y: (size.height - crop.maxY) * scale, width: crop.width * scale,
      height: crop.height * scale
    ).integral
    try write(try #require(image.cropping(to: pixels)), to: "\(stem)-crop.png")
  }

  private func write(_ image: CGImage, to path: String) throws {
    let data = try #require(
      NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    try data.write(to: URL(filePath: path))
  }

  /// SwiftUI 视图放在假桌面的一角上渲染（常驻缩略图是透明窗口，看它压在画面上的样子）
  private func snapshot(
    _ view: some View, over desktop: CGImage, size: NSSize, dark: Bool, to path: String
  ) throws {
    let window = NSWindow(
      contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let background = NSImageView(frame: NSRect(origin: .zero, size: size))
    background.imageScaling = .scaleAxesIndependently
    background.image = NSImage(
      cgImage: try #require(
        desktop.cropping(
          to: CGRect(x: 1400, y: 900, width: size.width * 2, height: size.height * 2))),
      size: size)
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
