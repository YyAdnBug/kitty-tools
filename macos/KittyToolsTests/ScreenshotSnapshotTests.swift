import AppKit
import Carbon.HIToolbox
import SwiftUI
import Testing

@testable import KittyTools

// 截图重设计（Whisker §6 截图，2026-09-26）的屏外截图自检（按需启用，同 SnapshotProbeTests）：遮罩待选 / 框选 / 调整、
// 工具栏上下、按工具的样式托盘、10 种标注与选中手柄、弯箭头和弯直线（选中 / 拖弯曲手柄 / 各种颜色粗细 / 弯到头）、尺寸输入、文字输入（三种样式）、比例和保存菜单、右键提示、截图翻译框选、常驻缩略图
// （飞行卡片落地后交接的同一张卡）、长截图面板与边框，按 2x 写成 PNG（带 -crop 的是局部，看线和图标对不对齐）。
// 录屏框选（待选提示、调整阶段的录制条、截图里按 R 切过去的录制条）和录制 HUD（倒数、录制中、放弃上膛）也在这里；
// 第 3 批补了常驻缩略图的视频卡（落地、悬停、矮卡、没有最后一帧的占位）；第 4 批补了录制条的三个开关（默认 = 混合、全开、
// 全关，全开 / 全关再按石墨、黄色强调色各一遍）和录制 HUD 的声音状态（两个都开、只开系统声音、麦克风断开变橙）；录音第 5 批补了
// 录音 HUD（录制中带电平、暂停、没听到声音、响到橙色的一根）和录音卡（波形 + 左上 waveform 标记 + 时长：落地、悬停、矮卡）；
// 录音第 6 批补了录系统声音的录音 HUD（⏸ 原位置灰、「两者」麦克风断开的橙字）。第 7 批：视频卡悬停多一枚「转成 GIF」胶囊，
// 补了 GIF 卡（落地、悬停）。手测反馈第 1 批：录屏的点按圈（InputOverlay：左键圆盘 / 右键空心环，各放在浅色、深色、
// 和强调色一样的底上，再按石墨、黄色强调色各一遍；另一张压在假桌面上）。手测反馈第 2 批：录制条第四个开关「显示按键」
// （原来带录制条的图都宽了一格）和按键胶囊（整屏：短的 ⌘C、带 ×n 的，下面是录制 HUD；选区：一长串溢出从左边丢、小选区、字缩小的窄选区）。手测反馈第 3 批：录音控制条的
// 待录态（[系统声音][麦克风] ｜ [✕][●]：只开麦克风、两者、只开系统声音、按了开始还没录起来的置灰）。
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
    // 录制条的四个开关（录屏第 4 批；第四个显示按键是手测反馈第 2 批）：上面那张是默认（系统声音开，麦克风、显示点按、
    // 显示按键关）；全开、全关（偏好在 Harness 的临时域）。
    // 再换石墨（强调色比主文字色还暗）、黄色（最亮）各拍一遍：开和关要靠形状分得清。只换内存里的强调色，拍完换回
    let savedAccent = Accent.shared.choice
    defer { Accent.shared.select(savedAccent, persists: false) }
    for (accent, suffix) in [
      (AccentChoice?.none, ""), (.graphite, "-graphite"), (.yellow, "-yellow"),
    ] {
      if let accent { Accent.shared.select(accent, persists: false) }
      for (name, on) in [("record-bar-on", true), ("record-bar-off", false)] {
        h = record()
        let prefs = h.view.styleDefaults
        for key in [
          Prefs.screenRecordSystemAudio, Prefs.screenRecordMicrophone,
          Prefs.screenRecordShowsClicks, Prefs.screenRecordShowsKeys,
        ] {
          prefs.set(on, forKey: key)
        }
        h.drag(CGPoint(x: 300.3, y: 260.7), CGPoint(x: 800.4, y: 560.2))
        let toggled = try #require(h.recordBar)
        try shoot(h.window, name + suffix, crop: toggled.frame.insetBy(dx: -24, dy: -24))
      }
    }
    Accent.shared.select(savedAccent, persists: false)
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

    // 录屏的视频卡（第 3 批）：飞行卡片落地后交接的同一张卡（最后一帧 + 播放符号 + 左下角时长 + 文件夹角标）、悬停（「拷贝」
    // 「转成 GIF」+ 关闭 / 在访达中显示，第二轮体检 R1 起右下角多一个「压缩」圆钮）、矮卡（播放符号缩小；悬停胶囊只剩图标、
    // 没有四角圆钮）、没取到最后一帧的占位；压缩出来的那张悬停时右下角没有「压缩」
    for (name, size, poster, hovered, compressed) in [
      ("shot-video-landed", card, true, false, false),
      ("shot-video-hover", card, true, true, false),
      ("shot-video-compact", compact, true, false, false),
      ("shot-video-compact-hover", compact, true, true, false),
      ("shot-video-placeholder", card, false, false, false),
      ("shot-video-compressed-hover", card, true, true, true),
    ] {
      let video = ShelfCard(
        file: .video(desktopFolder.appending(path: "录屏 2026-09-30 10.00.00.mp4"), seconds: 83),
        poster: poster ? shot : nil, source: CGRect(origin: .zero, size: size),
        rect: CGRect(origin: .zero, size: size), screen: nil, panel: NSPanel(), shelf: ShotShelf(),
        isCompressed: compressed)
      video.isHovered = hovered
      for dark in [false, true] {
        try snapshot(
          ShelfCardView(card: video), over: desktop,
          size: NSSize(
            width: size.width + ShotShelf.margin * 2, height: size.height + ShotShelf.margin * 2),
          dark: dark, to: "\(out)/\(name)\(dark ? "-dark" : "").png")
      }
    }

    // 录屏转成的 GIF 卡（第 7 批）：第一帧 + 左下「GIF」胶囊（没有播放符号）+ 文件夹角标；悬停只有「拷贝」+ 关闭 / 在访达中显示
    // （视频卡悬停的「拷贝」「转成 GIF」两枚胶囊在上面的 shot-video-hover / -compact-hover）
    for (name, hovered) in [("shot-gif-landed", false), ("shot-gif-hover", true)] {
      let gif = ShelfCard(
        file: .gif(desktopFolder.appending(path: "录屏 2026-09-30 10.00.00.gif")), poster: shot,
        source: CGRect(origin: .zero, size: card), rect: CGRect(origin: .zero, size: card),
        screen: nil, panel: NSPanel(), shelf: ShotShelf())
      gif.isHovered = hovered
      for dark in [false, true] {
        try snapshot(
          ShelfCardView(card: gif), over: desktop,
          size: NSSize(
            width: card.width + ShotShelf.margin * 2, height: card.height + ShotShelf.margin * 2),
          dark: dark, to: "\(out)/\(name)\(dark ? "-dark" : "").png")
      }
    }

    // 录音卡（录音第 5 批）：波形 poster（HUD 底色 + 竖条）+ 左上角 waveform 标记 + 左下时长；落地、悬停（只有「拷贝」+ 关闭 /
    // 在访达中显示）、矮卡（实际落地总是 poster 的 200 × 125，矮卡只为看标记在小卡上挤不挤）
    let envelope = (0..<160).map { index -> Float in
      let x = Float(index)
      return index % 37 < 5 ? -58 : -30 + 16 * sin(x * 0.45) * sin(x * 0.07)
    }
    let wave = try #require(AudioRecorder.waveform(envelope))
    for (name, size, hovered) in [
      ("shot-audio-landed", AudioRecorder.posterSize, false),
      ("shot-audio-hover", AudioRecorder.posterSize, true),
      ("shot-audio-compact", CGSize(width: 112, height: 70), false),
    ] {
      let audio = ShelfCard(
        recording: desktopFolder.appending(path: "录音 2026-09-30 10.00.00.m4a"), seconds: 65,
        audio: true, poster: wave, source: CGRect(origin: .zero, size: size),
        rect: CGRect(origin: .zero, size: size), screen: nil, panel: NSPanel(), shelf: ShotShelf())
      audio.isHovered = hovered
      for dark in [false, true] {
        try snapshot(
          ShelfCardView(card: audio), over: desktop,
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
    // 第 4 批：声音状态（-sound 两个都开、-system 只开系统声音、-mic-lost 麦克风断开变橙）；原来那四张不录声音，和以前一样
    for (name, state, counting, armed) in [
      ("record-hud-countdown", RecordingHUD.State.countdown(3), true, false),
      ("record-hud", .recording(12), false, false),
      ("record-hud-armed", .recording(12), false, true),
      ("record-hud-full", .recording(12), false, false),
      ("record-hud-sound", .recording(12), false, false),
      ("record-hud-system", .recording(12), false, false),
      ("record-hud-mic-lost", .recording(12), false, false),
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
      let sound = ["record-hud-sound", "record-hud-system", "record-hud-mic-lost"].contains(name)
      let hud = RecordingHUD(
        state: state, stopKey: "⌥R", systemAudio: sound,
        microphone: sound && name != "record-hud-system")
      if armed { try #require(hud.button(for: .discard)).performClick(nil) }
      if name == "record-hud-mic-lost" { hud.microphoneLost(animated: false) }
      hud.removeFromSuperview()  // 从它自己的窗口里拿出来，摆到假桌面上
      hud.frame.origin = RecordingHUD.origin(
        size: hud.frame.size, region: full ? bounds : region, screen: bounds,
        visible: bounds.insetBy(dx: 0, dy: 24).offsetBy(dx: 0, dy: -12), isFullScreen: full,
        dragged: nil)
      root.addSubview(hud)
      try shoot(offscreen(root), name, crop: hud.frame.insetBy(dx: -24, dy: -24))
    }

    // 录音 HUD（录音第 5 批）：整屏的摆法（可见区底部居中、离底 24），[● 0:42][电平] ｜ [⏸] ｜ [✕][■]；
    // 录制中（说话的电平）、暂停（暂停符号、计时和电平变灰）、没听到声音（橙字）、最新一根超过 −1 dB（橙）；
    // 录音第 6 批：录系统声音（⏸ 原位置灰）、「两者」录着时麦克风断开（橙字「麦克风断开了」）
    let speech = (0..<24).map { index -> Float in -38 + 16 * sin(Float(index) * 0.9) }
    for (name, levels, paused, silent, pausable) in [
      ("audio-hud", speech, false, false, true), ("audio-hud-paused", speech, true, false, true),
      ("audio-hud-silent", [Float](repeating: -120, count: 24), false, true, true),
      ("audio-hud-loud", speech.dropLast() + [-0.4], false, false, true),
      ("audio-hud-system", speech, false, false, false),
      ("audio-hud-mic-lost", speech, false, false, false),
    ] {
      let root = NSView(frame: bounds)
      root.wantsLayer = true
      root.layer?.contents = desktop
      let hud = RecordingHUD(
        state: .recording(42), stopKey: nil, medium: .audio, pausable: pausable)
      hud.updateMeter(levels)
      if paused { hud.setPaused(true) }
      if silent { hud.setSilent(true) }
      if name == "audio-hud-mic-lost" { hud.microphoneLost(animated: false) }
      hud.removeFromSuperview()
      hud.frame.origin = RecordingHUD.origin(
        size: hud.frame.size, region: bounds, screen: bounds,
        visible: bounds.insetBy(dx: 0, dy: 24).offsetBy(dx: 0, dy: -12), isFullScreen: true,
        dragged: nil)
      root.addSubview(hud)
      try shoot(offscreen(root), name, crop: hud.frame.insetBy(dx: -24, dy: -24))
    }

    // 录音控制条的待录态（手测反馈第 3 批）：[系统声音][麦克风] ｜ [✕][●]，同一个位置；来源读临时偏好域——只开麦克风
    // （默认）、两者、只开系统声音；-starting 是按了开始、还没录起来（开关和 ● 置灰，✕ 不灰）
    let suite = "kitty-snapshot-\(UUID().uuidString)"
    let prefs = try #require(UserDefaults(suiteName: suite))
    defer { prefs.removePersistentDomain(forName: suite) }
    for (name, source, starting) in [
      ("audio-hud-ready", AudioRecorder.Source.microphone, false),
      ("audio-hud-ready-both", .both, false), ("audio-hud-ready-system", .system, false),
      ("audio-hud-ready-starting", .both, true),
    ] {
      prefs.set(source.rawValue, forKey: Prefs.audioRecordSource)
      let root = NSView(frame: bounds)
      root.wantsLayer = true
      root.layer?.contents = desktop
      let hud = RecordingHUD(state: .ready, stopKey: nil, medium: .audio, defaults: prefs)
      if starting { hud.setStarting() }
      hud.removeFromSuperview()
      hud.frame.origin = RecordingHUD.origin(
        size: hud.frame.size, region: bounds, screen: bounds,
        visible: bounds.insetBy(dx: 0, dy: 24).offsetBy(dx: 0, dy: -12), isFullScreen: true,
        dragged: nil)
      root.addSubview(hud)
      try shoot(offscreen(root), name, crop: hud.frame.insetBy(dx: -24, dy: -24))
      hud.close()
    }
  }

  /// 录屏的点按圈（手测反馈第 1 批，InputOverlay）：上排左键按下（实心圆盘）、下排右键按下（空心环），三栏底色是白、
  /// 近黑、强调色本身（最不利：圈的强调色融进底里，只剩白描边和阴影）；默认强调色、石墨（最暗）、黄色（最亮）各一张。
  /// -desktop 是压在假桌面上的样子：左键点在备忘录的字上、右键点在壁纸上、再一个左键点在表格的粉色柱子上。
  /// 都用不带动画的入口摆到按住的终态（render(in:) 画的也是模型值，拍不到过渡的半截）
  @Test(.enabled(if: directory != nil)) func renderInputOverlay() throws {
    /// 覆盖层的内容视图从它自己的窗口里拿出来（窗口不显示），摆到 frame 上；frame 也是它的窗口位置，全局坐标就是 root 的坐标
    func overlay(on root: NSView, frame: CGRect) throws -> InputOverlay {
      let overlay = InputOverlay(frame: frame)
      let view = try #require(overlay.panel.contentView)
      overlay.panel.contentView = nil
      view.frame = frame
      root.addSubview(view)
      return overlay
    }
    let savedAccent = Accent.shared.choice
    defer { Accent.shared.select(savedAccent, persists: false) }
    for (accent, suffix) in [
      (AccentChoice?.none, ""), (.graphite, "-graphite"), (.yellow, "-yellow"),
    ] {
      if let accent { Accent.shared.select(accent, persists: false) }
      let root = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 240))
      root.wantsLayer = true
      let grounds = [NSColor.white, NSColor(white: 0.11, alpha: 1), Style.Shot.accent]
      var overlays: [InputOverlay] = []
      for (index, color) in grounds.enumerated() {
        let column = CGRect(x: CGFloat(index) * 200, y: 0, width: 200, height: 240)
        let ground = NSView(frame: column)
        ground.wantsLayer = true
        ground.layer?.backgroundColor = color.cgColor
        root.addSubview(ground)
        let made = try overlay(on: root, frame: column)
        made.press(0, at: CGPoint(x: column.midX, y: 180), animated: false)
        made.press(1, at: CGPoint(x: column.midX, y: 60), animated: false)
        overlays.append(made)
      }
      try shoot(offscreen(root), "record-clicks" + suffix)
      overlays.forEach { $0.close() }
    }
    Accent.shared.select(savedAccent, persists: false)

    let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let root = NSView(frame: bounds)
    root.wantsLayer = true
    root.layer?.contents = try Self.desktop()
    let made = try overlay(on: root, frame: bounds)
    made.press(0, at: CGPoint(x: 300, y: 620), animated: false)
    made.press(1, at: CGPoint(x: 700, y: 640), animated: false)
    // 同一个键同时只有一个圈：第二个左键用另一块覆盖层摆
    let second = try overlay(on: root, frame: bounds)
    second.press(0, at: CGPoint(x: 905, y: 225), animated: false)
    try shoot(
      offscreen(root), "record-clicks-desktop",
      crop: CGRect(x: 140, y: 120, width: 960, height: 580)
    )
    made.close()
    second.close()
  }

  /// 录屏的按键胶囊（手测反馈第 2 批，InputOverlay）：
  /// - keys-full：整屏录制，胶囊在可见区底边上方 88 pt，下面是录制 HUD（HUD 不进画面，在屏幕上不能和胶囊叠着）；短的 ⌘C；
  /// - keys-repeat：录备忘录那个窗口，几个记号 + 按住不放的 ×n（次要文字色、小一号）；压在字上（底不透明，不透字）；
  /// - keys-overflow：选区录制，敲了一长串：放不下的从左边丢，胶囊不超过选区宽减两边各 16，离选区底边 32；
  /// - keys-small：小选区（200 × 64，录屏的下限）：胶囊夹进选区里；
  /// - keys-narrow：很窄的选区（64 宽）：一个记号就比胶囊放得下的宽，字等比缩小、留在胶囊里。
  /// 都走不带动画的入口（终态）；-crop 是胶囊附近的局部
  @Test(.enabled(if: directory != nil)) func renderKeys() throws {
    let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let visible = bounds.insetBy(dx: 0, dy: 24).offsetBy(dx: 0, dy: -12)
    let desktop = try Self.desktop()
    /// 假桌面 + 被录区域的边框（整屏没有）+ 录制 HUD + 开着显示按键的覆盖层（内容视图拿出来摆到 region 上）
    func stage(_ region: CGRect, full: Bool) throws -> (NSView, InputOverlay, RecordingHUD) {
      let root = NSView(frame: bounds)
      root.wantsLayer = true
      root.layer?.contents = desktop
      if !full {
        let border = ScrollBorderView(animates: false)
        border.frame = region.insetBy(dx: -ScrollBorderView.margin, dy: -ScrollBorderView.margin)
        root.addSubview(border)
      }
      let hud = RecordingHUD(state: .recording(12), stopKey: "⌥R", systemAudio: true)
      hud.removeFromSuperview()
      hud.frame.origin = RecordingHUD.origin(
        size: hud.frame.size, region: region, screen: bounds, visible: visible, isFullScreen: full,
        dragged: nil)
      root.addSubview(hud)
      let overlay = InputOverlay(
        frame: region,
        keysBottom: InputOverlay.keysBottom(
          region: region, screen: bounds, visible: visible, isFullScreen: full))
      let view = try #require(overlay.panel.contentView)
      overlay.panel.contentView = nil
      view.frame = region
      root.addSubview(view)
      return (root, overlay, hud)
    }
    /// 胶囊（视图坐标）连同 HUD 的外框，外扩一圈
    func around(_ overlay: InputOverlay, _ region: CGRect, _ hud: RecordingHUD) throws -> CGRect {
      try #require(overlay.keysBarFrame).offsetBy(dx: region.minX, dy: region.minY)
        .union(hud.frame).insetBy(dx: -60, dy: -30)
    }

    var (root, overlay, hud) = try stage(bounds, full: true)
    overlay.showKey("⌘C", animated: false)
    try shoot(offscreen(root), "record-keys-full", crop: try around(overlay, bounds, hud))
    overlay.close()

    // 录备忘录那个窗口：胶囊压在最下面两行字上
    (root, overlay, hud) = try stage(Self.windows[0], full: false)
    for name in ["⌘A", "⌘C", "⇧A", "空格", "↩"] { overlay.showKey(name, animated: false) }
    overlay.showKey("⌫", animated: false)
    for _ in 0..<11 { overlay.showKey("⌫", isRepeat: true, animated: false) }
    try shoot(
      offscreen(root), "record-keys-repeat", crop: try around(overlay, Self.windows[0], hud))
    overlay.close()

    let region = CGRect(x: 160, y: 260, width: 480, height: 400)
    (root, overlay, hud) = try stage(region, full: false)
    for letter in "THE QUICK BROWN FOX JUMPS OVER" {
      overlay.showKey(letter == " " ? "空格" : String(letter), animated: false)
    }
    overlay.showKey("⌘S", animated: false)
    try shoot(
      offscreen(root), "record-keys-overflow",
      crop: region.union(hud.frame).insetBy(dx: -30, dy: -30))
    overlay.close()

    let small = CGRect(x: 700, y: 560, width: 200, height: 64)
    (root, overlay, hud) = try stage(small, full: false)
    for name in ["⌃⌥⇧⌘K", "⌘V", "⌘V"] { overlay.showKey(name, animated: false) }
    try shoot(
      offscreen(root), "record-keys-small", crop: small.union(hud.frame).insetBy(dx: -40, dy: -30))
    overlay.close()

    let narrow = CGRect(x: 760, y: 500, width: 64, height: 160)
    (root, overlay, hud) = try stage(narrow, full: false)
    overlay.showKey("⇧A", animated: false)
    try shoot(
      offscreen(root), "record-keys-narrow",
      crop: narrow.union(hud.frame).insetBy(dx: -40, dy: -30))
    overlay.close()
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

  // 钉图的透明度滑块（2026-10-03）：右键「透明度 ▸」、悬停圆钮弹出的那一行（60%、最低 10%，浅 / 深色），垫在菜单材质上看对齐
  @Test(.enabled(if: directory != nil)) func renderPinOpacity() throws {
    let out = try #require(Self.directory)
    let board = PinBoard()
    let image = try #require(
      try Self.desktop().cropping(to: CGRect(x: 0, y: 0, width: 400, height: 200)))
    board.pin(image, frame: CGRect(x: -20000, y: -20000, width: 200, height: 100))
    defer { board.closeAll() }
    let panel = try #require(board.panels.first)
    let pin = try #require(panel.contentView)
    let event = try #require(
      NSEvent.mouseEvent(
        with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    for (percent, dark) in [(60, false), (60, true), (10, false)] {
      panel.opacity = CGFloat(percent) / 100
      let row = try #require(
        pin.menu(for: event)?.items.first { $0.title == "透明度" }?.submenu?.items.first?.view)
      // 菜单上下各有约 5 pt 的内边距
      let size = NSSize(width: row.frame.width, height: row.frame.height + 10)
      let window = NSWindow(
        contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
      let material = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
      material.material = .menu
      material.state = .active
      row.frame.origin = CGPoint(x: 0, y: 5)
      material.addSubview(row)
      window.contentView = material
      window.orderFront(nil)
      for _ in 0..<3 { RunLoop.main.run(until: Date.now.addingTimeInterval(0.1)) }
      let bitmap = try #require(material.bitmapImageRepForCachingDisplay(in: material.bounds))
      material.cacheDisplay(in: material.bounds, to: bitmap)
      try #require(bitmap.representation(using: .png, properties: [:]))
        .write(to: URL(filePath: "\(out)/shot-pin-opacity-\(percent)\(dark ? "-dark" : "").png"))
      window.orderOut(nil)
    }
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
