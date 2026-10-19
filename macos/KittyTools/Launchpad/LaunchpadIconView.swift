// 启动台的图标视图（从 LaunchpadView 拆出来，2026-10-18）：主网格的 App 图标（图层抖动的 JigglingIcon）、文件夹面板里的
// App 图标（平时 SwiftUI Image、抖动时不带动画地换成 JigglingIcon）、主网格的文件夹方块（FolderGlyph，SwiftUI 的 Jiggle）。
// 为什么这么分、换视图为什么不能带动画：mac-whisker-launchpad §4、mac-launchpad。

import AppKit
import SwiftUI

/// App 图标：抖动时用图层转 ±1.5°（每个图标相位不同）。不走 SwiftUI 的 rotationEffect + repeatForever，
/// 那会让上百个视图每帧重排（F35 / R11）。
/// 抖动的那一下转动（纯函数，单测直接喂）：绕图标的中心转。layer-backed 视图的 anchorPoint 不一定是中心
/// （AppKit 默认左下角），把转轴从 anchor 挪到中心：先平移 −p、转、再平移 +p，p = 中心相对 anchor 的偏移（G15）
nonisolated enum LaunchpadJiggle {
  static func transform(degrees: Double, size: CGSize, anchor: CGPoint) -> CGAffineTransform {
    let pivot = CGPoint(x: (0.5 - anchor.x) * size.width, y: (0.5 - anchor.y) * size.height)
    return CGAffineTransform(translationX: pivot.x, y: pivot.y)
      .rotated(by: degrees * .pi / 180)
      .translatedBy(x: -pivot.x, y: -pivot.y)
  }
}

/// 没有固有尺寸的 NSImageView：大小只听 SwiftUI 给的 frame。普通的 NSImageView 拿图的尺寸当固有尺寸，抗压缩优先级又高，
/// SwiftUI 缩不到比图小——位图按最大那块屏画，换到图标小一些的屏上图标（和点得到的范围）就比格子要的大（2026-10-18 单测量出来的）
final class IconImageView: NSImageView {
  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
  }
}

struct JigglingIcon: NSViewRepresentable {
  let image: NSImage
  let size: CGFloat
  let active: Bool
  let phase: Double
  let reduceMotion: Bool

  func makeNSView(context: Context) -> IconImageView {
    let view = IconImageView()
    view.imageScaling = .scaleProportionallyUpOrDown
    view.wantsLayer = true
    return view
  }

  func updateNSView(_ view: IconImageView, context: Context) {
    view.image = image
    // 不碰 frame / anchorPoint / bounds：layer-backed 视图的几何归 AppKit / SwiftUI 管，改了会被布局复位、
    // 图标偏半个边长或绕着角转（G15）。转轴按图层**现在的** anchorPoint 算到图标中心上
    guard let layer = view.layer else { return }
    if active, !reduceMotion {
      if layer.animation(forKey: "launchpad-jiggle") == nil {
        let side = CGSize(width: size, height: size)
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(
          caTransform3D: CATransform3DMakeAffineTransform(
            LaunchpadJiggle.transform(degrees: -1.5, size: side, anchor: layer.anchorPoint)))
        animation.toValue = NSValue(
          caTransform3D: CATransform3DMakeAffineTransform(
            LaunchpadJiggle.transform(degrees: 1.5, size: side, anchor: layer.anchorPoint)))
        animation.duration = 0.13
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timeOffset = phase * 0.26
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: "launchpad-jiggle")
      }
    } else {
      layer.removeAnimation(forKey: "launchpad-jiggle")
    }
  }
}

/// 文件夹面板里的 App 图标：平时是 SwiftUI 的 Image（建得快：35 个的文件夹展开第一帧约 30 ms，全用 NSImageView 约 50 ms），
/// 抖动时换成图层抖动的 `JigglingIcon`（35 个主线程约 7%；SwiftUI 自己的 repeatForever 要 18–24%）。**换的时候不带动画**
/// （`.transition(.identity)` + 事务里去掉动画）：原来这一换跟着进抖动的动画淡出淡入，每个图标发白一下，看着闪（2026-10-18 真机反馈）；
/// 不带动画就不闪，屏上实录自检量过（LaunchpadAnimationLiveTests：和静止时最多差约 0.02，带动画的那版约 0.07）。主网格一直是 `JigglingIcon`
struct AppIconView: View {
  let image: NSImage
  let size: CGFloat
  let jiggling: Bool
  let phase: Double
  let reduceMotion: Bool

  var body: some View {
    Group {
      if jiggling, !reduceMotion {
        JigglingIcon(image: image, size: size, active: true, phase: phase, reduceMotion: false)
      } else {
        Image(nsImage: image)
          .resizable()
          .interpolation(.high)
      }
    }
    .transition(.identity)
    .transaction { $0.animation = nil }
  }
}

/// SwiftUI 的抖动（主网格的文件夹方块）：绕中心 ±1.5° 来回（0.13 s 一程），按格序晚一点开始、彼此错开。
/// 只转、不改布局；只有看得见的那一页在抖（R11）
struct Jiggle: ViewModifier {
  let active: Bool
  let phase: Double
  @State private var tilted = false

  func body(content: Content) -> some View {
    content
      .rotationEffect(.degrees(active ? (tilted ? 1.5 : -1.5) : 0))
      .onChange(of: active, initial: true) { _, on in
        if on {
          // 下一轮再开始：和进抖动同一轮的布局变化别被这条一直重复的动画带上
          DispatchQueue.main.async {
            withAnimation(
              .easeInOut(duration: 0.13).repeatForever(autoreverses: true).delay(phase * 0.13)
            ) { tilted = true }
          }
        } else {
          withAnimation(.easeOut(duration: 0.1)) { tilted = false }
        }
      }
  }
}

/// 文件夹图标：一块浅色半透明圆角底（照 macOS 15），里面按 3 × 3 画前 9 个 App 的小图标。文件夹里一个都没有时画系统的文件夹符号。
/// 抖动用 SwiftUI 的 `Jiggle`（一页里文件夹不多；App 图标用图层抖）。
struct FolderGlyph: View {
  let folder: LaunchpadFolder
  let model: LaunchpadModel
  let size: CGFloat
  let phase: Double
  /// 这一页正看着（只有它抖）
  var jiggles = true
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    glyph
      .modifier(Jiggle(active: model.jiggling && jiggles && !reduceMotion, phase: phase))
      .accessibilityHidden(true)
  }

  private var glyph: some View {
    let mini = size * 0.255
    let apps = folder.apps.prefix(9).compactMap { model.app($0) }
    let shape = RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
    return
      shape
      .fill(.white.opacity(0.32))
      .overlay { shape.stroke(.white.opacity(0.22), lineWidth: 0.5) }
      .overlay {
        if apps.isEmpty {
          Image(systemName: "folder.fill")
            .font(.system(size: size * 0.44))
            .foregroundStyle(.white.opacity(0.55))
        } else {
          VStack(spacing: size * 0.055) {
            ForEach(0..<3, id: \.self) { row in
              HStack(spacing: size * 0.055) {
                ForEach(0..<3, id: \.self) { column in
                  let index = row * 3 + column
                  if index < apps.count {
                    Image(nsImage: model.icons.icon(for: apps[index], size: mini))
                      .resizable()
                      .interpolation(.high)
                      .frame(width: mini, height: mini)
                  } else {
                    Color.clear.frame(width: mini, height: mini)
                  }
                }
              }
            }
          }
        }
      }
      .frame(width: size, height: size)
  }
}
