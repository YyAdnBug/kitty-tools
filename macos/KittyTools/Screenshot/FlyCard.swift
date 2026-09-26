// 截图「咔嚓，飞入」（Whisker 招牌时刻 S1，mac-whisker §5）：复制 / 快速保存截图后，选区原地闪白、抬起，
// 沿弧线（x、y 两轴弹簧时长不同）飞到所在屏幕右下角缩成缩略图，落地弹出 ✓（保存时是文件夹 + 目录名），
// 角标弹完后交给常驻缩略图（ShotShelf，CleanShot 式，同一个位置接着显示）；没有接手的（失败、没给 linger）停 0.9 s
// 后向右滑出屏幕。窗口只取起终点的并集、不接鼠标，飞完就关。卡片先飞，角标等复制 / 保存真的成功了
// 才由调用方 land（失败就没有角标）。快门声跟随系统「播放用户界面音效」和设置 › 截图的开关。
// 减弱动态效果时调用方不飞，直接让常驻缩略图在角落淡入。

import AppKit
import SwiftUI

enum FlyCard {
  enum Badge {
    case copied
    /// 存到的文件
    case saved(URL)

    var folder: String? {
      if case .saved(let url) = self {
        url.deletingLastPathComponent().lastPathComponent
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

    func land(_ badge: Badge) {
      self.badge = badge
      FlyCard.announce(badge)
    }
  }

  /// 卡片不接鼠标：主动给 VoiceOver 播报结果
  static func announce(_ badge: Badge) {
    let text =
      switch badge {
      case .copied: "已复制截图"
      case .saved(let url): "截图已保存到\(url.deletingLastPathComponent().lastPathComponent)"
      }
    NSAccessibility.post(
      element: NSApp as Any, notification: .announcementRequested,
      userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
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

  /// 和选区同比例的顶部（长截图很高，只露开头那一屏）；cropping 共享像素，不复制
  static func visiblePart(of image: CGImage, frame: CGRect) -> CGImage {
    guard frame.width >= 1 else { return image }
    let rows = min(image.height, Int((CGFloat(image.width) * frame.height / frame.width).rounded()))
    return image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: max(rows, 1))) ?? image
  }

  /// 落地的位置：frame 所在屏幕可见区右下角内缩 16，缩进 200×140（不放大）；常驻缩略图也按它摆
  static func landingRect(for frame: CGRect) -> CGRect? {
    guard frame.width >= 1, frame.height >= 1,
      let screen = NSScreen.screens.first(where: {
        $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY))
      }) ?? NSScreen.main
    else { return nil }
    let fit = min(1, maxSize.width / frame.width, maxSize.height / frame.height)
    let visible = screen.visibleFrame
    return CGRect(
      x: visible.maxX - inset - frame.width * fit, y: visible.minY + inset,
      width: frame.width * fit, height: frame.height * fit)
  }

  /// image：选区的图；frame：选区（点，AppKit 全局坐标）。linger：角标弹完后交给常驻缩略图（落地位置、角标），
  /// 给了它卡片就不自己滑走
  static func fly(
    _ image: CGImage, from frame: CGRect, linger: ((CGRect, Badge) -> Void)? = nil
  ) -> Landing {
    let landing = Landing()
    guard let end = landingRect(for: frame),
      let screen = NSScreen.screens.first(where: { $0.frame.intersects(end) })
    else { return landing }
    let shown = visiblePart(of: image, frame: frame)
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
        image: shown, start: local(frame), end: local(end), exit: exit, landing: landing,
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
  let image: CGImage
  /// 起点（选区）、终点（右下角），窗口内坐标（原点左上）
  let start: CGRect
  let end: CGRect
  /// 滑出的距离
  let exit: CGFloat
  let landing: FlyCard.Landing
  /// 角标弹完后交给常驻缩略图
  let linger: ((FlyCard.Badge) -> Void)?
  let onFinish: () -> Void

  @State private var lifted = false
  @State private var flying = false
  @State private var landed = false
  @State private var leaving = false

  var body: some View {
    let rect = flying ? end : start
    let shape = RoundedRectangle(cornerRadius: lifted ? Style.Radius.card : 0, style: .continuous)
    Image(decorative: image, scale: 1)
      .resizable()
      .aspectRatio(contentMode: .fill)
      // 闪白 [0, 0.55, 0] 0.2 s
      .keyframeAnimator(initialValue: 0.0, trigger: lifted) { content, flash in
        content.overlay(Color.white.opacity(flash))
      } keyframes: { _ in
        LinearKeyframe(0.55, duration: 0.06)
        LinearKeyframe(0, duration: 0.14)
      }
      .animation(.spring(duration: 0.45, bounce: 0)) {
        $0.frame(width: rect.width, height: rect.height)
      }
      .animation(.easeOut(duration: 0.18)) {
        $0
          .clipShape(shape)
          .overlay(shape.strokeBorder(.white.opacity(lifted ? 0.25 : 0), lineWidth: 0.5))
          .shadow(color: .black.opacity(lifted ? 0.28 : 0), radius: 16, y: 6)
          .scaleEffect(lifted && !flying ? 1.03 : 1)
      }
      .overlay(alignment: .bottomTrailing) {
        if landed, let badge = landing.badge {
          FlyCardBadge(badge: badge)
            .offset(x: 6, y: 6)
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
        lifted = true
        try? await Task.sleep(for: .seconds(0.10))
        flying = true
        try? await Task.sleep(for: .seconds(0.40))
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

/// 落地角标：复制 = 22 pt accent 圆 + 对勾；保存 = accent 胶囊 + 文件夹 + 目录名（常驻缩略图也用它，看起来是同一张卡）
struct FlyCardBadge: View {
  let badge: FlyCard.Badge

  var body: some View {
    switch badge {
    case .copied:
      Image(systemName: "checkmark")
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(.white)
        .frame(width: 22, height: 22)
        .background(Circle().fill(Color.accentColor))
        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
    case .saved:
      Label(badge.folder ?? "", systemImage: "folder.fill")
        .font(.system(size: 11, weight: .semibold))
        .lineLimit(1)
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(Color.accentColor))
        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
    }
  }
}
