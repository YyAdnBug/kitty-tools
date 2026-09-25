// 截图「咔嚓，飞入」（Whisker 招牌时刻 S1，mac-whisker §5）：复制 / 快速保存截图后，选区原地闪白、抬起，
// 沿弧线（x、y 两轴弹簧时长不同）飞到所在屏幕右下角缩成缩略图，落地弹出 ✓（保存时是文件夹 + 目录名），
// 停 0.9 s 后向右滑出屏幕。窗口只取起终点的并集、不接鼠标，飞完就关。快门声跟随系统「播放用户界面音效」
// 和设置 › 截图的开关。减弱动态效果时由调用方改成刘海岛轻提示。

import AppKit
import SwiftUI

enum FlyCard {
  enum Badge {
    case copied
    case saved(folder: String)
  }

  /// 飞行中的窗口（飞完移除；连截几张时各飞各的）
  private static var windows: Set<NSPanel> = []
  /// 正在放的快门声（NSSound 放完之前要有人持有）
  private static var shutter: NSSound?

  /// 落地时缩到这个框里（不放大）；离可见区域右下角的距离
  private static let maxSize = CGSize(width: 200, height: 140)
  private static let inset: CGFloat = 16

  /// image：选区的图（长截图取和选区同比例的顶部）；frame：选区（点，AppKit 全局坐标）
  static func fly(_ image: CGImage, from frame: CGRect, badge: Badge) {
    guard frame.width >= 1, frame.height >= 1,
      let screen = NSScreen.screens.first(where: {
        $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY))
      })
        ?? NSScreen.main
    else { return }
    let rows = min(image.height, Int((CGFloat(image.width) * frame.height / frame.width).rounded()))
    let shown =
      image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: max(rows, 1))) ?? image
    let fit = min(1, maxSize.width / frame.width, maxSize.height / frame.height)
    let visible = screen.visibleFrame
    let end = CGRect(
      x: visible.maxX - inset - frame.width * fit, y: visible.minY + inset,
      width: frame.width * fit, height: frame.height * fit)
    // 滑出去要整张离开屏幕右边
    let exit = screen.frame.maxX - end.minX + 30
    let union = frame.union(end).union(end.offsetBy(dx: exit, dy: 0)).insetBy(dx: -40, dy: -40)
    let local = { (rect: CGRect) in
      CGRect(
        x: rect.minX - union.minX, y: union.maxY - rect.maxY, width: rect.width, height: rect.height
      )
    }

    let panel = NSPanel(
      contentRect: union, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    panel.animationBehavior = .none
    panel.isReleasedWhenClosed = false
    let host = NSHostingView(
      rootView: FlyCardView(
        image: shown, start: local(frame), end: local(end), exit: exit, badge: badge
      ) {
        panel.orderOut(nil)
        windows.remove(panel)
      })
    host.sizingOptions = []
    panel.contentView = host
    windows.insert(panel)
    panel.orderFrontRegardless()
    let text =
      switch badge {
      case .copied: "已复制截图"
      case .saved(let folder): "截图已保存到\(folder)"
      }
    NSAccessibility.post(
      element: NSApp as Any, notification: .announcementRequested,
      userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
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
  let badge: FlyCard.Badge
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
        if landed {
          badgeView
            .offset(x: 6, y: 6)
            .transition(.scale(scale: 0.4).combined(with: .opacity))
        }
      }
      .animation(Style.Motion.pop.animation(reduced: false), value: landed)
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
        try? await Task.sleep(for: .seconds(0.9))
        leaving = true
        try? await Task.sleep(for: .seconds(0.3))
        onFinish()
      }
  }

  @ViewBuilder private var badgeView: some View {
    switch badge {
    case .copied:
      Image(systemName: "checkmark")
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(.white)
        .frame(width: 22, height: 22)
        .background(Circle().fill(Color.accentColor))
        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
    case .saved(let folder):
      Label(folder, systemImage: "folder.fill")
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
