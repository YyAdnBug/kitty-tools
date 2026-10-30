// Style 的动态色要能在任意线程解析：SwiftUI 在显示链接线程异步渲染动画时会解析它们，
// 取色闭包绑定主线程的话会在后台触发执行器断言闪退（2026-09-27 真机崩溃）；发丝线宽跟着增强对比度走（Whisker §7）

import AppKit
import SwiftUI
import Testing

@testable import KittyTools

struct StyleTests {
  @Test func dynamicColorsResolveOffMainThread() async {
    let colors = [
      Style.brand, Style.brandInk, Style.onBrand, Style.selectedFill, Style.hairline,
      Style.inputFill,
    ]
    .map(NSColor.init)
    for color in colors {
      #expect(await Self.resolveOffMain(color) != nil)
    }
  }

  /// 发丝线：平时 0.5 pt，增强对比度 1 pt（Hairline、hairlineBorder、输入框、录制框共用这一个判断）
  @Test func hairlineWidthFollowsContrast() {
    #expect(Style.hairlineWidth(.standard) == 0.5)
    #expect(Style.hairlineWidth(.increased) == 1)
  }

  /// 主按钮（BrandButtonStyle）常规档和旁边的系统带边框按钮一样高（2026-10-12 视觉对齐：原来 22，
  /// 剪贴板对话框、导入导出表单里比旁边的「取消」高 2 pt）
  @MainActor @Test func brandButtonIsAsTallAsSystemButton() {
    let brand = NSHostingView(rootView: Button("保存") {}.buttonStyle(BrandButtonStyle()))
    let system = NSHostingView(rootView: Button("取消") {})
    #expect(brand.fittingSize.height == system.fittingSize.height)
    // 26 起系统控件加高：常规档 15 上 20、27 上实测 24
    if #available(macOS 26, *) {
      #expect(brand.fittingSize.height == 24)
      // 按基线并排还是一样高 = 两边的字在同一条基线上（字往上让 1 pt 这一排就高到 25，27 上实测）；15 上那 2 pt
      // 是按像素量的，这一条没在 15 上跑过，只锁 26 起
      let row = NSHostingView(
        rootView: HStack(alignment: .firstTextBaseline) {
          Button("保存") {}.buttonStyle(BrandButtonStyle())
          Button("取消") {}
        })
      #expect(row.fittingSize.height == system.fittingSize.height)
    } else {
      #expect(brand.fittingSize.height == 20)
    }
  }

  /// 降低透明度时的 0.9 不透明底只给 15 的毛玻璃；macOS 26 的玻璃自己变实，不再垫（Whisker §7）
  @Test func opaqueUnderlayOnlyBeforeGlass() {
    #expect(!Style.opaqueUnderlay(reduceTransparency: false))
    if #available(macOS 26, *) {
      #expect(!Style.opaqueUnderlay(reduceTransparency: true))
    } else {
      #expect(Style.opaqueUnderlay(reduceTransparency: true))
    }
  }

  /// Panel 皮肤（Whisker §2）：15 是 .popover 毛玻璃 + maskImage 圆角，macOS 26 是 16 pt 圆角的液态玻璃；
  /// 两种都是内容（SwiftUI）和拖边放在同一个父视图里（拖边把滚轮转给它旁边的内容）
  @MainActor @Test func panelMaterialPerSystem() throws {
    let panel = OverlayPanel(
      size: NSSize(width: 300, height: 200), minSize: NSSize(width: 200, height: 100),
      autoHide: .resignKey, isPinned: { false }, content: Color.clear)
    let root = try #require(panel.contentView)
    let background: NSView
    if #available(macOS 26, *) {
      let glass = try #require(root as? NSGlassEffectView)
      #expect(glass.cornerRadius == Style.Radius.panel)
      background = try #require(glass.contentView)
    } else {
      let effect = try #require(root as? NSVisualEffectView)
      #expect(effect.material == .popover && effect.state == .active && effect.maskImage != nil)
      background = effect
    }
    // SwiftUI 内容（铺满）+ 左右两条拖边（毛玻璃自己也有子视图，按类型数）
    let names = background.subviews.map { String(describing: type(of: $0)) }
    #expect(names.filter { $0.hasPrefix("NSHostingView") }.count == 1, "\(names)")
    #expect(names.filter { $0 == "ResizeEdge" }.count == 2, "\(names)")
  }

  /// 面板描边和卡片高光不能是整块位图（常驻内存，2026-10-07）：直接拿渐变描形状，SwiftUI 会把它栅格化成形状外接矩形
  /// 那么大的 PaintShapeLayer，P3 屏上每像素 8 字节——720 × 520 的面板一张 11.4 MB、收起后也不还，三块面板加翻译卡片
  /// 常驻约 55 MB。现在是纯色描边 + 渐变蒙版，两样都是不带位图的图层（mac-whisker §8）。
  /// 认的是 SwiftUI 现在怎么把这两个视图变成图层（macOS 15.7）：系统升级后这条挂了，先用内存探针的屏上模式
  /// （KITTY_MEMORY_PROBE_ONSCREEN）看面板显示后 CoreAnimation 涨了多少，再改这里
  @MainActor @Test func rimAndCardHighlightAreNotRasterized() throws {
    let panel = OverlayPanel(
      size: NSSize(width: 320, height: 240), autoHide: .resignKey, isPinned: { true },
      content: Color.clear.frame(width: 200, height: 120).cardSurface()
        .environment(\.colorScheme, .dark))
    panel.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    panel.orderFront(nil)
    defer { panel.orderOut(nil) }
    RunLoop.main.run(until: .now.addingTimeInterval(0.2))
    var names: [String] = []
    var gradients = 0
    func collect(_ layer: CALayer) {
      names.append(String(describing: type(of: layer)))
      if layer is CAGradientLayer { gradients += 1 }
      layer.sublayers?.forEach(collect)
      if let mask = layer.mask { collect(mask) }
    }
    collect(try #require(panel.contentView?.layer))
    #expect(!names.contains { $0.contains("PaintShape") }, "\(names)")
    // 高光还在：卡片一层渐变蒙版，面板描边一层（macOS 26 的玻璃不画面板描边）
    if #available(macOS 26, *) {
      #expect(gradients == 1, "\(names)")
    } else {
      #expect(gradients == 2, "\(names)")
    }
  }

  /// 在并发线程池里解析（会调到动态色的取色闭包）
  @concurrent nonisolated private static func resolveOffMain(_ color: NSColor) async -> NSColor? {
    #expect(pthread_main_np() == 0)  // 确实不在主线程
    return color.usingColorSpace(.sRGB)
  }
}

/// 刘海岛详情里的摘录：第一行前 24 个字，后面还有就补「…」
struct IslandExcerptTests {
  @Test func excerpt() {
    #expect(Island.excerpt("  发布吧  ") == "发布吧")
    #expect(Island.excerpt("第一行\n第二行") == "第一行…")
    #expect(Island.excerpt("第一行\r\n第二行") == "第一行…")
    let long = String(repeating: "字", count: 30)
    #expect(Island.excerpt(long) == String(repeating: "字", count: 24) + "…")
    #expect(Island.excerpt(String(repeating: "字", count: 24)) == String(repeating: "字", count: 24))
  }

  /// 岛的前导符号（视觉对齐第 3 批）：自带实心底的才按两色画，别的由岛垫语气色圆——空心圆、裸符号不能算进前一种
  @MainActor @Test func plateSymbols() {
    for symbol in [
      "checkmark.circle.fill", "trash.circle.fill", "exclamationmark.triangle.fill",
      "xmark.octagon.fill",
    ] {
      #expect(Island.hasPlate(symbol), "\(symbol)")
    }
    for symbol in ["trash", "xmark.circle", "eject.fill", "keyboard", "clock.fill", "circle"] {
      #expect(!Island.hasPlate(symbol), "\(symbol)")
    }
  }

  /// 传给岛的符号在这台机器的系统上都有（最低支持 macOS 15；名字写错的话岛上那一格是空的，编译查不出来）：
  /// 各语气的默认符号、调用处换上的圆底变体、没有圆底变体照传的裸符号。新加 island.show(… symbol:) 时把名字补进来
  @MainActor @Test func symbolsExist() {
    let plated = [
      "checkmark.circle.fill", "info.circle.fill", "exclamationmark.triangle.fill",
      "exclamationmark.circle.fill", "ellipsis.circle.fill", "trash.circle.fill",
      "square.and.arrow.up.circle.fill", "xmark.octagon.fill", "stop.circle.fill",
      "eject.circle.fill", "xmark.circle.fill", "speaker.slash.circle.fill", "speaker.circle.fill",
      "speaker.wave.2.circle.fill", "minus.circle.fill", "play.circle.fill", "pause.circle.fill",
      "clock.circle.fill", "waveform.circle.fill", "video.circle.fill", "arrow.down.circle.fill",
      "arrow.triangle.2.circlepath.circle.fill", "arrow.uturn.backward.circle.fill",
      ShelfCard.gifIslandSymbol, ShelfCard.compressIslandSymbol,
    ]
    let bare = [
      HotKeyAction.statusScreen.symbol, "square.and.arrow.down", "questionmark.folder",
      "clock.arrow.circlepath", "keyboard", "character.bubble", "character.bubble.fill",
      "pin.slash",
      "doc.on.doc", "qrcode", "sparkles", "text.badge.star", "pin.fill", "pin",
      "folder.badge.minus",
    ]
    for symbol in plated + bare {
      #expect(NSImage.symbol(symbol) != nil, "\(symbol)")
    }
    #expect(plated.allSatisfy(Island.hasPlate) && !bare.contains(where: Island.hasPlate))
  }

  /// 进行中的岛改详情（转 GIF、压缩的百分比，第二轮体检 R3）：只改详情；岛上不是这一条（标题不同、不是进行中）就不动
  @MainActor @Test func progressUpdatesDetailInPlace() {
    let content = { (title: String, tone: Island.Tone) in
      Island.Content(title: title, detail: nil, tone: tone, symbol: "circle", leading: .tone)
    }
    let island = Island(showing: content("正在压缩…", .progress))
    island.progress("正在压缩…", detail: "37%")
    #expect(island.content?.detail == "37%" && island.content?.title == "正在压缩…")
    island.progress("正在转成 GIF…", detail: "50%")
    #expect(island.content?.detail == "37%")
    let done = Island(showing: content("已压缩", .success))
    done.progress("已压缩", detail: "99%")
    #expect(done.content?.detail == nil)
    #expect(ShelfCard.progressDetail(37) == "37%")
    #expect(ShelfCard.progressDetail(37, note: "只转前 60 秒") == "只转前 60 秒 · 37%")
    #expect(ShelfCard.progressDetail(140) == "100%" && ShelfCard.progressDetail(-3) == "0%")
  }

  /// 能交互的岛（2026-10-26 拍板）：鼠标在岛上时来的新提示先排着、移开再换上（B5）；进行中的那条例外，结果原地换；
  /// 点了 × / 按钮（dismiss）时排着的直接换上
  @MainActor @Test func hoverQueuesNewNotices() {
    let content = { (title: String, tone: Island.Tone) in
      Island.Content(title: title, detail: nil, tone: tone, symbol: "circle", leading: .tone)
    }
    let island = Island(showing: content("已删除 3 条", .info), actions: [.init("撤销") {}])
    island.hover(true)
    #expect(island.isHovered && island.isExpanded)
    island.show("已复制")
    #expect(island.content?.title == "已删除 3 条" && island.actions.map(\.title) == ["撤销"])
    island.hover(false)
    #expect(island.content?.title == "已复制" && island.actions.isEmpty && !island.isExpanded)

    let closed = Island(showing: content("已删除 3 条", .info))
    closed.hover(true)
    closed.show("翻译失败", tone: .error)
    closed.dismiss()
    #expect(closed.content?.title == "翻译失败" && closed.isOpen)

    let working = Island(showing: content("翻译中…", .progress), actions: [.init("取消") {}])
    working.hover(true)
    working.show("已替换为译文")
    #expect(working.content?.title == "已替换为译文" && working.actions.isEmpty)
    // 进行中的离开就合上（它还要挂着）；别的离开后照旧展开着，到点再收
    let progress = Island(showing: content("正在压缩…", .progress))
    progress.hover(true)
    progress.hover(false)
    #expect(!progress.isExpanded && progress.content?.title == "正在压缩…")
  }

  /// 排着的进行中提示（评审 2）：调用方做完了按标题收时连排着的一起丢掉；排着时的百分比更新改的是排着的那条。
  /// 离开后照旧展开的卡片换成新的一条就合上（评审 3）
  @MainActor @Test func queuedProgressAndExpandedReset() {
    let content = { (title: String, tone: Island.Tone) in
      Island.Content(title: title, detail: nil, tone: tone, symbol: "circle", leading: .tone)
    }
    let island = Island(showing: content("已复制", .success))
    island.hover(true)
    island.show("识别中…", tone: .progress)
    island.progress("识别中…", detail: "42%")
    island.dismiss(ifShowing: "识别中…")
    island.hover(false)
    #expect(island.content?.title == "已复制")

    let saving = Island(showing: content("已复制", .success))
    saving.hover(true)
    saving.show("正在压缩…", tone: .progress)
    saving.progress("正在压缩…", detail: "37%", fraction: 0.37)
    saving.hover(false)
    #expect(saving.content?.title == "正在压缩…" && saving.content?.detail == "37%")
    #expect(saving.content?.fraction == 0.37)

    let left = Island(showing: content("翻译失败", .error), expanded: true)
    #expect(left.isExpanded)
    left.show("翻译中…", tone: .progress)
    #expect(!left.isExpanded && left.content?.title == "翻译中…")
  }

  /// 点了按钮时排着的那条让给按钮自己的结果（评审 6）：按钮出了新提示，排着的等它收起再出；没出就直接换上
  @MainActor @Test func performYieldsToActionResult() {
    let content = Island.Content(
      title: "已还原排列", detail: nil, tone: .success, symbol: "circle", leading: .tone)
    var island: Island?
    let undo = Island.Action("撤销") { island?.show("已撤销") }
    island = Island(showing: content, actions: [undo], expanded: true)
    island?.hover(true)
    island?.show("翻译失败", tone: .error)
    island?.perform(undo)
    #expect(island?.content?.title == "已撤销")
    island?.dismiss()
    #expect(island?.content?.title == "翻译失败")

    let quiet = Island(showing: content, actions: [.init("撤销") {}], expanded: true)
    quiet.hover(true)
    quiet.show("翻译失败", tone: .error)
    quiet.perform(quiet.actions[0])
    #expect(quiet.content?.title == "翻译失败")
  }

  /// 点岛本身只执行打开类的按钮（B3）：撤销这类只能点按钮；内容刚换过的那一下不算点击（B6）
  @MainActor @Test func tapRunsOnlyOpeningAction() {
    let content = Island.Content(
      title: "已保存", detail: "a.png", tone: .success, symbol: "circle", leading: .tone)
    var ran: [String] = []
    let undo = Island.Action("撤销") { ran.append("撤销") }
    let reveal = Island.Action("在访达中显示", opens: true) { ran.append("显示") }
    Island(showing: content, actions: [undo], expanded: true).tapped()
    #expect(ran.isEmpty)
    let island = Island(showing: content, actions: [undo, reveal], expanded: true)
    island.tapped()
    #expect(ran == ["显示"] && island.content == nil)

    let fresh = Island(showing: content)
    fresh.show("已保存", detail: "b.png", actions: [reveal])
    fresh.tapped()
    fresh.perform(reveal)
    #expect(ran == ["显示"] && fresh.content?.detail == "b.png")
  }

  /// 常用的几种按钮（C1）：打开系统设置、在访达中显示、存成的文件（在访达中显示 + 打开）都是打开类，点岛本身也执行
  @MainActor @Test func commonActions() {
    let url = URL(filePath: "/tmp/截屏.png")
    #expect(Island.Action.settings(for: .screenRecording).title == "打开系统设置")
    #expect(Island.Action.reveal(url).title == "在访达中显示")
    let file = [Island.Action].file(url)
    #expect(file.map(\.title) == ["在访达中显示", "打开"] && file.allSatisfy(\.opens))
    #expect(Island.Action.settings(for: .accessibility).opens)
  }

  /// 最近的提示（那一张里的列表）：最多 10 条、新的在前；进行中的不记；按钮只留打开类的（撤销过后再点会出事）
  @MainActor @Test func historyKeepsRecentNotices() {
    let island = Island(showing: nil)
    let url = URL(filePath: "/tmp/a.png")
    for index in 1...12 {
      island.show("第 \(index) 条", actions: [.init("撤销") {}, .reveal(url)])
    }
    island.show("翻译中…", tone: .progress)
    #expect(island.history.count == Island.historyLimit)
    #expect(island.history.first?.content.title == "第 12 条")
    #expect(island.history.last?.content.title == "第 3 条")
    #expect(island.history.allSatisfy { $0.actions.map(\.title) == ["在访达中显示"] })
  }

  /// 那一张（点刘海 / 快捷键叫出来）：开着时来的提示先排着、列表里当场就有；收起那一张时换上排着的那条
  @MainActor @Test func boardQueuesNotices() {
    let island = Island(showing: nil)
    island.boardActions = { [.init("截图", symbol: "camera.viewfinder") {}] }
    island.toggleBoard()
    #expect(island.isBoardOpen && island.isOpen && island.content == nil)
    #expect(island.quickActions.map(\.title) == ["截图"])
    island.show("已复制")
    #expect(island.isBoardOpen && island.content == nil)
    #expect(island.history.first?.content.title == "已复制")
    island.toggleBoard()
    #expect(!island.isBoardOpen && island.content?.title == "已复制")
    // 岛上正有提示时叫出那一张：换成那一张（那条已经在列表里）
    island.toggleBoard()
    #expect(island.isBoardOpen && island.content == nil && island.actions.isEmpty)
  }

  /// 指针停在刘海上才算：只认刘海本身（鼓起那一圈不算），含屏幕最顶那一行、不往上越过顶边；没有刘海的屏都不算
  @Test func notchHitIsTheNotchOnly() {
    let notch = CGRect(x: 650, y: 1074, width: 200, height: 38)  // 屏幕坐标，屏顶 y = 1112
    #expect(Island.onNotch(CGPoint(x: 750, y: 1100), notches: [notch]))
    #expect(Island.onNotch(CGPoint(x: 750, y: 1112), notches: [notch]))  // 最顶那一行
    #expect(!Island.onNotch(CGPoint(x: 750, y: 1114), notches: [notch]))  // 上面那块屏的底边
    #expect(!Island.onNotch(CGPoint(x: 645, y: 1100), notches: [notch]))  // 鼓起那一圈
    #expect(!Island.onNotch(CGPoint(x: 750, y: 1071), notches: [notch]))
    #expect(!Island.onNotch(CGPoint(x: 750, y: 1100), notches: []))
  }

  /// 那一张开着时排着的提示（评审 1、6）：指针离开那一张不当场换；在进行中的提示上叫出那一张，进行中的留着、收起后回来
  @MainActor @Test func boardKeepsProgressAndWaitsOnLeave() {
    let island = Island(showing: nil)
    island.show("正在压缩…", tone: .progress)
    island.toggleBoard()
    island.progress("正在压缩…", detail: "40%", fraction: 0.4)
    island.hover(true)
    island.show("已复制")
    island.hover(false)
    #expect(island.isBoardOpen && island.content == nil)
    island.toggleBoard()
    #expect(!island.isBoardOpen && island.content?.title == "已复制")
  }

  /// 刘海屏收起的终点整个藏在真刘海里面（2026-10-26 用户录屏：收起最后一瞬间跳一下）：比刘海窄、比刘海矮、没有耳朵。
  /// Island.geometry 给的宽是真刘海 + 4
  @Test func tuckedShapeHidesBehindTheNotch() {
    let notch = CGSize(width: 200, height: 38)
    let tucked = IslandGeometry.tucked(notchWidth: notch.width + 4, notchHeight: notch.height)
    #expect(tucked.width < notch.width - 8 && tucked.height < notch.height - 4)
    #expect(tucked.width > 0 && tucked.height > 0)
  }

  /// 双指往上滑收起：按手指方向算，「自然滚动」开着时 scrollingDeltaY 和手指同向（往下为正）
  @Test func swipeUpFollowsFingers() {
    #expect(Island.fingersUp(deltaY: -10, inverted: true) == 10)
    #expect(Island.fingersUp(deltaY: 10, inverted: false) == 10)
    #expect(Island.fingersUp(deltaY: 10, inverted: true) == -10)
  }

  /// 慢活才出「进行中」（识字的「识别中」）：很快做完的不出这一下；过了时限还没做完才出，而且只出一次。
  /// 慢活不靠墙上时钟模拟：全量并行跑时主线程被别的测试占着，「睡 300 ms」和「30 ms 后提示」谁先恢复说不准
  /// （活先恢复就把提示取消了，这在产品里是对的，测试却会判错）。所以慢活 = 等提示出过才做完
  @MainActor @Test(.timeLimit(.minutes(3))) func slowNoticeOnlyWhenWorkIsSlow() async {
    var notices = 0
    let quick = await Island.whenSlow(
      after: .milliseconds(80), notice: { notices += 1 }, work: { 7 })
    try? await Task.sleep(for: .milliseconds(200))
    #expect(quick == 7 && notices == 0)
    let (shown, signal) = AsyncStream<Void>.makeStream()
    let slow = await Island.whenSlow(
      after: .milliseconds(30),
      notice: {
        notices += 1
        signal.yield()
      },
      work: {
        for await _ in shown { break }
        return 9
      })
    #expect(slow == 9 && notices == 1)
  }

  /// 岛的前导缩略图只留 26×18 两倍像素的小图，长截图取顶部一段（不把整张原图放进岛）
  @Test func thumbnailIsSmallTopCrop() throws {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(
      CGContext(
        data: nil, width: 100, height: 3000, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = try #require(context.makeImage())
    guard case .thumbnail(let thumb) = Island.thumbnail(of: image) else {
      Issue.record("不是缩略图")
      return
    }
    let pixels = try #require(thumb.cgImage(forProposedRect: nil, context: nil, hints: nil))
    #expect(pixels.width == 52)
    #expect(pixels.height == 36)
  }
}
