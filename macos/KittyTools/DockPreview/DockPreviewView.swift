// 程序坞预览的面板内容（第九族第 2 批；拍板 C4 C5 C6）：顶上一行 App 图标 + 名字，下面一排（多了换行）窗口卡片——缩略图（还没
// 截到 / 截不到画 App 图标）+ 标题，最小化 / 隐藏 / 在别的桌面的在图的左下角一个角标；悬停的那张底色变浅灰、往外抬 2 点，图的
// 右上角出 ✕（拿得到关闭钮的才有）。点卡片切过去，点 ✕ 关掉那扇。卡片的尺寸按 DockPreviewLayout 排好的方案；整块铺满宿主、
// 顶上对齐，面板的大小只由窗口定（换图标时窗口在滑，内容不另走一条曲线）。换 App 时新旧两排叠在同一处交叉淡变。
// 角标和 ✕ 用卡片上小标记同一个底（hudMark：HUD 深底 + 内描边，永远深色）。没有屏幕录制授权时只有图标位和标题，
// 最底下多一行说明（拍板 A2）。本 App 不激活，悬停靠 HoverTracker（activeAlways 追踪区）。

import AppKit
import SwiftUI

/// 面板要画的东西（DockPreview 填，视图只读）
@Observable final class DockPreviewModel {
  var appName = ""
  var appIcon: NSImage?
  /// 列出来的窗口（和 plan.thumbs 一一对应：多到排不下的已经去掉了）
  var windows: [DockWindow] = []
  var images: [CGWindowID: CGImage] = [:]
  /// 拿得到关闭钮的（别的桌面上的、没有关闭钮的不出 ✕）
  var closable: Set<CGWindowID> = []
  var plan = DockPreviewLayout.Plan(thumbs: [], lines: [], content: .zero, panel: .zero)
  var edge = DockPreviewLayout.Edge.bottom
  /// 有屏幕录制授权：截缩略图
  var showsThumbnails = true
  /// 换了一个 App 加一：卡片那几排拿它当 id，换 App 时交叉淡变
  var generation = 0
  /// 截图自检摆悬停的样子（Whisker §9 的静态参数）：这一扇画成悬停着的。正常使用一直是 nil
  var hovered: CGWindowID?
  var onOpen: (DockWindow) -> Void = { _ in }
  var onClose: (DockWindow) -> Void = { _ in }
}

struct DockPreviewView: View {
  let model: DockPreviewModel

  var body: some View {
    VStack(spacing: 0) {
      header
      ZStack(alignment: .top) {
        cards
          .id(model.generation)
          .transition(.opacity)
      }
      if !model.showsThumbnails {
        Text("允许屏幕录制后显示缩略图")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .frame(height: DockPreviewLayout.noteHeight)
      }
    }
    .padding(DockPreviewLayout.padding)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .overlay(PanelRim())
  }

  private var header: some View {
    HStack(spacing: 6) {
      if let icon = model.appIcon {
        Image(nsImage: icon).resizable().frame(width: 16, height: 16).accessibilityHidden(true)
      }
      Text(model.appName)
        .font(.system(size: 13, weight: .semibold))
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .frame(maxWidth: .infinity)
    .frame(height: DockPreviewLayout.headerHeight, alignment: .top)
    .accessibilityElement(children: .combine)
  }

  /// 卡片：程序坞在下面时一排排往上叠（每排横着），在左右两边时一列列往屏幕里排（每列竖着）
  private var cards: some View {
    let spacing = DockPreviewLayout.spacing
    let outer =
      model.edge.isHorizontal
      ? AnyLayout(VStackLayout(spacing: spacing))
      : AnyLayout(HStackLayout(alignment: .top, spacing: spacing))
    let inner =
      model.edge.isHorizontal
      ? AnyLayout(HStackLayout(alignment: .top, spacing: spacing))
      : AnyLayout(VStackLayout(spacing: spacing))
    return outer {
      ForEach(model.plan.lines, id: \.lowerBound) { line in
        inner {
          ForEach(line, id: \.self) { index in
            if index < model.windows.count, index < model.plan.thumbs.count {
              card(model.windows[index], size: model.plan.thumbs[index])
            }
          }
        }
      }
    }
  }

  private func card(_ window: DockWindow, size: CGSize) -> some View {
    PreviewCard(
      window: window, appName: model.appName, image: model.images[window.id],
      icon: model.appIcon, size: size, compact: !model.showsThumbnails,
      closable: model.closable.contains(window.id), hovered: model.hovered == window.id,
      open: { model.onOpen(window) }, close: { model.onClose(window) })
  }
}

/// 一扇窗口：缩略图 + 标题
private struct PreviewCard: View {
  let window: DockWindow
  /// 窗口没标题时写它（没有屏幕录制授权时别的桌面上的窗口都没标题）
  let appName: String
  let image: CGImage?
  let icon: NSImage?
  let size: CGSize
  /// 没有屏幕录制授权：图标位，不截图
  let compact: Bool
  let closable: Bool
  let open: () -> Void
  let close: () -> Void
  @State private var hovered: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(
    window: DockWindow, appName: String, image: CGImage?, icon: NSImage?, size: CGSize,
    compact: Bool, closable: Bool, hovered: Bool, open: @escaping () -> Void,
    close: @escaping () -> Void
  ) {
    self.window = window
    self.appName = appName
    self.image = image
    self.icon = icon
    self.size = size
    self.compact = compact
    self.closable = closable
    self.open = open
    self.close = close
    _hovered = State(initialValue: hovered)
  }

  var body: some View {
    VStack(spacing: DockPreviewLayout.titleGap) {
      thumbnail.frame(width: size.width, height: size.height)
      Text(title)
        .font(.system(size: 12))
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(width: size.width, height: DockPreviewLayout.titleHeight)
    }
    .padding(DockPreviewLayout.cardPadding)
    // 同心圆角：卡片离面板边 10 点 → 16 − 10 = 6。底色 0.10 s 淡入（Whisker §3 悬停）
    .background(
      RoundedRectangle(cornerRadius: Style.Radius.control, style: .continuous)
        .fill(hovered ? Style.hoverFill : .clear)
        .animation(.easeOut(duration: 0.10), value: hovered)
    )
    // 抬起是指针驱动的位移（glide；减弱动态效果时不抬）
    .offset(y: hovered && !reduceMotion ? -2 : 0)
    .animation(Style.Motion.glide.animation(reduced: reduceMotion), value: hovered)
    .contentShape(Rectangle())
    .onTapGesture(perform: open)
    .background { HoverTracker { hovered = $0 } }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityValue(stateName ?? "")
    .accessibilityAddTraits(.isButton)
    .accessibilityAction(.default, open)
    .accessibilityActions {
      if closable { Button("关闭窗口", action: close) }
    }
  }

  private var title: String { window.title.isEmpty ? appName : window.title }

  /// 图（或图标位）：角标、✕ 挂在图本身上（按比例缩进框里之后的那块），不挂在框上
  @ViewBuilder private var thumbnail: some View {
    // 同心圆角：图离卡片边 6 点 → 6 − 6 不到 4，用 mini
    let shape = RoundedRectangle(cornerRadius: Style.Radius.mini, style: .continuous)
    if let image, !compact {
      Image(decorative: image, scale: 2)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .clipShape(shape)
        .overlay(shape.hairlineBorder())
        .overlay(alignment: .bottomLeading) { badge }
        .overlay(alignment: .topTrailing) { closeButton }
    } else {
      shape.fill(Style.controlFill)
        .overlay {
          if let icon {
            Image(nsImage: icon).resizable().frame(width: 32, height: 32).accessibilityHidden(true)
          }
        }
        .overlay(alignment: .bottomLeading) { badge }
        .overlay(alignment: .topTrailing) { closeButton }
    }
  }

  /// 最小化 / 隐藏 / 在别的桌面的说明
  private var stateName: String? {
    switch window.state {
    case .shown: nil
    case .minimized: "已最小化"
    case .hidden: "已隐藏"
    case .elsewhere: "在别的桌面"
    }
  }

  @ViewBuilder private var badge: some View {
    if let stateName {
      Text(stateName)
        .font(.system(size: 10, weight: .medium))
        .padding(.horizontal, 6)
        .frame(height: 16)
        .hudMark(Capsule())
        .padding(4)
    }
  }

  /// 悬停时才有：22 pt 圆、10 pt 粗体 ✕（同常驻缩略图角上的圆钮），按下缩一点
  @ViewBuilder private var closeButton: some View {
    if hovered, closable {
      Button(action: close) {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .bold))
          .frame(width: 22, height: 22)
          .hudMark(Circle())
      }
      .buttonStyle(PressScale())
      .padding(4)
      .help("关闭窗口")
      .transition(.opacity)
    }
  }
}
