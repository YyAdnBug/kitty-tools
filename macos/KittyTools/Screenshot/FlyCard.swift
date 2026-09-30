// 截图「咔嚓，飞入」（Whisker 招牌时刻 S1，mac-whisker §5）：复制 / 快速保存截图后，遮罩一收起选区就起飞（不闪白、不原地抬起：
// 用户 2026-09-27 觉得闪一下不对，⌘⇧4 / CleanShot 都只有快门声），圆角和阴影在飞的头 0.18 s 里长出来，沿弧线（x、y 两轴弹簧时长不同）飞到所在屏幕右下角缩成缩略图，落地在右上角弹出品牌粉 ✓（保存时是文件夹 + 目录名），
// 角标弹完后交给常驻缩略图（ShotShelf，CleanShot 式，同一个位置接着显示）；没有接手的（失败、没给 linger）停 0.9 s
// 后向右滑出屏幕。窗口只取起终点的并集、不接鼠标，飞完就关；飞行中显示选区原图（cropping，不复制），落地后换成缩小过的图（和常驻缩略图同一张）。
// 卡片先飞，角标等复制 / 保存真的成功了才由调用方 land（失败就没有角标）。快门声跟随系统「播放用户界面音效」和设置 › 截图的开关。
// 减弱动态效果时调用方不飞，直接让常驻缩略图在角落淡入。
// 录屏（第 3 批，拍板 R11-a）同一套：飞的是最后一帧（poster），没有快门声、文件已存好所以直接 land 文件夹角标；
// 落地时卡片上多出播放符号和左下角时长（VideoMarks，常驻缩略图的视频卡同一个）。
// 录音（第 5 批，拍板 A5-a）也是这一套：飞的是电平包络画的波形图，起点是录音 HUD（从小卡长到常驻缩略图那么大，落地尺寸另给），
// 落地时左上角出 waveform 标记（没有播放符号）+ 时长。

import AppKit
import SwiftUI

enum FlyCard {
  enum Badge {
    case copied
    /// 存到的文件
    case saved(URL)

    /// 结果的一句话（旁白；减弱动态效果时不飞，刘海岛说这句）
    var title: String {
      switch self {
      case .copied: "已复制截图"
      case .saved: "已保存到「\(folder ?? "")」"
      }
    }

    /// 存到的文件夹的显示名（访达里的名字：中文系统上 Desktop 是「桌面」，同保存 ▾ 菜单的「存储到「桌面」」）
    var folder: String? {
      if case .saved(let url) = self {
        FileManager.default.displayName(atPath: url.deletingLastPathComponent().path)
      } else {
        nil
      }
    }
  }

  /// 一张飞行卡片的结局：复制 / 保存成功后 land，落地（或已落地）时弹出角标
  @Observable final class Landing {
    fileprivate(set) var badge: Badge?
    /// 角标真的弹出来的那一刻（卡片落地且复制 / 保存成功；卡片已经滑走就不会调）：菜单栏图标跟着弹一下
    @ObservationIgnored var onShow: (() -> Void)?

    /// announces：卡片不接鼠标，主动给 VoiceOver 播报结果；录屏自己说（带时长）或由岛说时传 false
    func land(_ badge: Badge, announces: Bool = true) {
      self.badge = badge
      if announces { Island.announce(badge.title) }
    }
  }

  /// 飞行中的窗口（连截几张时各飞各的）
  private static var windows: Set<NSPanel> = []
  /// 飞完的窗口留着复用：挂过 NSHostingView 的窗口 close 后 AppKit 不释放窗口对象（实测，空 Text 也一样），
  /// 每次新建会越攒越多。close 会销毁窗口服务器那边的缓冲区，清掉 contentView 会放掉视图和截图
  private static var idle: [NSPanel] = []
  /// 正在放的快门声（NSSound 放完之前要有人持有）
  private static var shutter: NSSound?

  /// 落地时缩到这个框里（不放大）；离可见区域右下角的距离
  private static let maxSize = CGSize(width: 200, height: 140)
  private static let inset: CGFloat = 16

  /// 卡片上显示的图：选区比例的顶部，最大是卡片尺寸的 2 倍（按屏幕像素）。飞行卡片和常驻缩略图共用（交接时像素一样）；
  /// 整张原图（5K 选区几十 MB）不进卡片窗口的图层，原图只留给拷贝、拖出
  static func cardImage(of image: CGImage, frame: CGRect, size: CGSize, backingScale: CGFloat)
    -> CGImage
  {
    let pixels = 2 * backingScale
    return thumbnail(
      of: visiblePart(of: image, frame: frame),
      fitting: CGSize(width: size.width * pixels, height: size.height * pixels))
  }

  /// 等比缩到 limit（像素）以内，本来就小的原样返回
  static func thumbnail(of image: CGImage, fitting limit: CGSize) -> CGImage {
    let fit = min(1, limit.width / CGFloat(image.width), limit.height / CGFloat(image.height))
    guard fit < 1 else { return image }
    // 保留原图的色彩空间（P3 屏）；位图上下文只收 RGB，别的换成 sRGB
    let rgb = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
    guard let space = rgb ?? CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil, width: max(Int((CGFloat(image.width) * fit).rounded()), 1),
        height: max(Int((CGFloat(image.height) * fit).rounded()), 1), bitsPerComponent: 8,
        bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return image }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
    return context.makeImage() ?? image
  }

  /// 和选区同比例的顶部（长截图很高，只露开头那一屏）；cropping 共享像素，不复制
  static func visiblePart(of image: CGImage, frame: CGRect) -> CGImage {
    guard frame.width >= 1 else { return image }
    let rows = min(image.height, Int((CGFloat(image.width) * frame.height / frame.width).rounded()))
    return image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: max(rows, 1))) ?? image
  }

  /// 落地的位置：frame 所在屏幕可见区右下角内缩 16，缩进 200×140（不放大）；常驻缩略图也按它摆。
  /// size：落地的卡片尺寸另给（录音从小小的 HUD 起飞、长到 poster 那么大；同样缩进 200×140），nil = 选区的尺寸
  static func landingRect(for frame: CGRect, size: CGSize? = nil) -> CGRect? {
    let size = size ?? frame.size
    guard size.width >= 1, size.height >= 1,
      let screen = NSScreen.screens.first(where: {
        $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY))
      }) ?? NSScreen.main
    else { return nil }
    let fit = min(1, maxSize.width / size.width, maxSize.height / size.height)
    let visible = screen.visibleFrame
    return CGRect(
      x: visible.maxX - inset - size.width * fit, y: visible.minY + inset,
      width: size.width * fit, height: size.height * fit)
  }

  /// image：选区的图；frame：选区（点，AppKit 全局坐标）。linger：角标弹完后交给常驻缩略图（落地位置、角标），
  /// 给了它卡片就不自己滑走。seconds：录屏的时长（录屏第 3 批）：落地时多出播放符号和时长。
  /// 录音（第 5 批）：frame 是 HUD 处和 image 同比例的小框，size 是落地尺寸（landingRect），audio 让落地的标记换成 waveform
  static func fly(
    _ image: CGImage, from frame: CGRect, size: CGSize? = nil,
    linger: ((CGRect, Badge) -> Void)? = nil, seconds: Int? = nil, audio: Bool = false
  ) -> Landing {
    let landing = Landing()
    guard let end = landingRect(for: frame, size: size),
      let screen = NSScreen.screens.first(where: { $0.frame.intersects(end) })
    else { return landing }
    // 起飞到落地显示选区原图（cropping 共享像素、不另编码；复制 / 保存编码期间本来就持有它）：第一帧和刚收起的
    // 遮罩一模一样，大选区也不会先糊一下（缩略图放大到选区那么大会糊，以前被闪白盖住了）。落地后换成按落地尺寸
    // 做的缩略图（和常驻缩略图同一张，交接时像素一样），大图跟着窗口一起放掉
    let full = visiblePart(of: image, frame: frame)
    let shown = cardImage(
      of: image, frame: frame, size: end.size, backingScale: screen.backingScaleFactor)
    // 滑出去要整张离开屏幕右边
    let exit = screen.frame.maxX - end.minX + 30
    let union = frame.union(end).union(end.offsetBy(dx: exit, dy: 0)).insetBy(dx: -40, dy: -40)
    let local = { (rect: CGRect) in
      CGRect(
        x: rect.minX - union.minX, y: union.maxY - rect.maxY, width: rect.width, height: rect.height
      )
    }

    let panel = idle.popLast() ?? makePanel()
    panel.setFrame(union, display: false)
    let host = NSHostingView(
      rootView: FlyCardView(
        full: full, image: shown, start: local(frame), end: local(end), exit: exit,
        seconds: seconds, audio: audio, landing: landing,
        linger: linger.map { linger in { linger(end, $0) } }
      ) { [weak panel] in
        // weak：窗口 → 视图 → 这个闭包，强引用会成环，每飞一次漏一个窗口和整张图
        guard let panel else { return }
        panel.close()
        // 下一轮再拆视图：别在它自己的 SwiftUI 任务里把它释放
        Task {
          panel.contentView = nil
          windows.remove(panel)
          idle.append(panel)
        }
      })
    host.sizingOptions = []
    panel.contentView = host
    windows.insert(panel)
    panel.orderFrontRegardless()
    return landing
  }

  private static func makePanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: true)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    panel.animationBehavior = .none
    panel.isReleasedWhenClosed = false
    return panel
  }

  /// 系统截屏的快门声。跟随系统「播放用户界面音效」（没设过 = 开）；声音文件在系统私有路径，找不到就不响
  static func playShutter() {
    guard UserDefaults.standard.bool(forKey: Prefs.screenshotShutterSound),
      UserDefaults(suiteName: "com.apple.systemsound")?
        .object(forKey: "com.apple.sound.uiaudio.enabled") as? Bool ?? true
    else { return }
    let url = URL(
      fileURLWithPath:
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
    )
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    shutter = NSSound(contentsOf: url, byReference: true)
    shutter?.play()
  }
}

private struct FlyCardView: View {
  /// 选区原图（飞行中）和落地尺寸的缩略图（落地后）
  let full: CGImage
  let image: CGImage
  /// 起点（选区）、终点（右下角），窗口内坐标（原点左上）
  let start: CGRect
  let end: CGRect
  /// 滑出的距离
  let exit: CGFloat
  /// 录屏的时长（落地时出播放符号和时长）；截图 nil
  let seconds: Int?
  /// 录音：落地的标记是 waveform（没有播放符号）
  let audio: Bool
  let landing: FlyCard.Landing
  /// 角标弹完后交给常驻缩略图
  let linger: ((FlyCard.Badge) -> Void)?
  let onFinish: () -> Void

  @State private var flying = false
  @State private var landed = false
  @State private var leaving = false

  // 下面的弹簧、缓动是 S1 专用参数（mac-whisker §5 S1 写死的数，不是 §4 七条命名曲线之一）：
  // 圆角 / 描边 / 阴影 easeOut 0.18 s、x spring(0.42, 0.10) 与 y spring(0.50, 0.10)（时长不同走出弧线）、
  // 尺寸 spring(0.45, 0)、滑出 easeIn 0.28 s；角标出现是命名曲线 pop
  var body: some View {
    let rect = flying ? end : start
    let shape = RoundedRectangle(cornerRadius: flying ? Style.Radius.card : 0, style: .continuous)
    Image(decorative: landed ? image : full, scale: 1)
      .resizable()
      .aspectRatio(contentMode: .fill)
      .animation(.spring(duration: 0.45, bounce: 0)) {
        $0.frame(width: rect.width, height: rect.height)
      }
      .animation(.easeOut(duration: 0.18)) {
        $0
          .clipShape(shape)
          .overlay(shape.strokeBorder(.white.opacity(flying ? 0.25 : 0), lineWidth: 0.5))
          .shadow(color: .black.opacity(flying ? 0.28 : 0), radius: 16, y: 6)
      }
      // 第一帧要和选区一模一样：播放符号和时长落地才出来（和角标同时），常驻缩略图接手时原样接上
      .overlay {
        if landed, let seconds {
          VideoMarks(seconds: seconds, compact: VideoMarks.isCompact(end.size), audio: audio)
            .transition(.opacity)
        }
      }
      .animation(.easeOut(duration: Style.fadeIn), value: landed && seconds != nil)
      .overlay(alignment: .topTrailing) {
        if landed, let badge = landing.badge {
          FlyCardBadge(badge: badge, drawsOn: true)
            .offset(FlyCardBadge.offset)
            .transition(.scale(scale: 0.4).combined(with: .opacity))
        }
      }
      .animation(Style.Motion.pop.animation(reduced: false), value: landed && landing.badge != nil)
      .onChange(of: landed && landing.badge != nil) { _, shown in if shown { landing.onShow?() } }
      // 两轴弹簧时长不同，走出一道弧线
      .animation(.spring(duration: 0.50, bounce: 0.10)) { $0.offset(y: rect.midY) }
      .animation(.spring(duration: 0.42, bounce: 0.10)) { $0.offset(x: rect.midX) }
      .animation(.easeIn(duration: 0.28)) { $0.offset(x: leaving ? exit : 0) }
      .position(x: 0, y: 0)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .task {
        // 第一帧就是选区原样（原图，和刚收起的遮罩里一模一样），下一帧起飞
        flying = true
        try? await Task.sleep(for: .seconds(0.45))
        landed = true
        // 等复制 / 保存成功（最多 2 s）：成功就在角标弹完后交给常驻缩略图，自己直接关（同一个位置接着显示，看不出换了窗口）
        for _ in 0..<20 where landing.badge == nil {
          try? await Task.sleep(for: .milliseconds(100))
        }
        if let badge = landing.badge, let linger {
          try? await Task.sleep(for: .seconds(0.4))
          linger(badge)
          onFinish()
          return
        }
        try? await Task.sleep(for: .seconds(0.9))
        leaving = true
        try? await Task.sleep(for: .seconds(0.3))
        onFinish()
      }
  }
}

/// 视频卡（录屏）比截图卡多的两样：中央 28 pt 的 black 0.35 圆 + play.fill，左下角时长胶囊（11 pt semibold 等宽数字、
/// HUD 底色、高 18、离角 6）。飞行卡片落地时出现，常驻缩略图的视频卡同一个位置（交接时对得上）；矮卡（同常驻缩略图
/// 胶囊只留图标的尺寸）播放符号缩到 22 pt，不和时长叠在一起。不进旁白：卡片的名字里已经有时长。
/// 录音卡（第 5 批）：图本身就是波形，不放播放符号（点它不会播），换成左上角一个 18 pt 的 waveform 小标记（同时长胶囊的底色、
/// 离角 6，悬停时让给关闭钮）；时长胶囊同视频卡
struct VideoMarks: View {
  let seconds: Int
  var compact = false
  var audio = false

  /// 矮卡：高不到 90 或宽不到 150（和常驻缩略图的胶囊只留图标同一个门槛）
  static func isCompact(_ size: CGSize) -> Bool { size.height < 90 || size.width < 150 }

  var body: some View {
    if audio {
      Image(systemName: "waveform")
        .font(.system(size: 9, weight: .bold))
        .frame(width: 18, height: 18)
        .background(Circle().fill(Color(nsColor: Style.HUD.fill)))
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .bottomLeading) { duration }
        .foregroundStyle(Color(nsColor: Style.HUD.text))
        .accessibilityHidden(true)
    } else {
      let side: CGFloat = compact ? 22 : 28
      Image(systemName: "play.fill")
        .font(.system(size: compact ? 9 : 12, weight: .bold))
        .frame(width: side, height: side)
        .background(Circle().fill(.black.opacity(0.35)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomLeading) { duration }
        .foregroundStyle(Color(nsColor: Style.HUD.text))
        .accessibilityHidden(true)
    }
  }

  private var duration: some View {
    Text(ScreenRecorder.clock(seconds))
      .font(.system(size: 11, weight: .semibold).monospacedDigit())
      .lineLimit(1)
      .padding(.horizontal, 6)
      .frame(height: 18)
      .background(Capsule().fill(Color(nsColor: Style.HUD.fill)))
      .padding(6)
  }
}

/// 落地角标：复制 = 22 pt 品牌粉圆 + 对勾；保存 = 品牌粉胶囊 + 文件夹 + 目录名。贴在卡片右上角，
/// 常驻缩略图也用它、同样的位置（交接时对得上，看起来是同一张卡）
struct FlyCardBadge: View {
  let badge: FlyCard.Badge
  /// 刚落地：对勾描出来（26 上 drawOn，15 上弹一下）；常驻缩略图接手时已经画好了，不再播
  var drawsOn = false
  @State private var drawn = false

  /// 放在卡片右上角（overlay 的 topTrailing）再挪这么多：右边、上边各伸出 10，
  /// 圆形角标左上角 = (x + w − 12, y − 10)（方案页）；胶囊右边和圆对齐，往左长
  static let offset = CGSize(width: 10, height: -10)
  private static var pink: Color { Color(nsColor: Style.Shot.accent) }

  var body: some View {
    Group {
      switch badge {
      case .copied:
        check
          .font(.system(size: 11, weight: .bold))
          .frame(width: 22, height: 22)
          .background(Circle().fill(Self.pink))
      case .saved:
        Label {
          Text(badge.folder ?? "")
        } icon: {
          Image(systemName: "folder.fill").symbolEffect(.bounce, value: drawn)
        }
        .font(.system(size: 11, weight: .semibold))
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(Self.pink))
      }
    }
    .foregroundStyle(Color(nsColor: Style.Shot.onAccent))
    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
    .onAppear { if drawsOn { drawn = true } }
  }

  @ViewBuilder private var check: some View {
    if #available(macOS 26, *) {
      // drawOn 生效期间对勾藏着，一关掉就描出来
      Image(systemName: "checkmark").symbolEffect(.drawOn, isActive: drawsOn && !drawn)
    } else {
      Image(systemName: "checkmark").symbolEffect(.bounce, value: drawn)
    }
  }
}
