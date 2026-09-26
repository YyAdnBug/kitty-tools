// 首次安装的欢迎引导（N14，Whisker 品牌时刻，对标 Apple 自家 App 的首次启动页 / Raycast）：盖在设置窗上的 sheet，奶油底，两屏。
// 第一屏 = 品牌图标 + 大标题 + 四行功能（家族色块 + 一句话），要授权的那两行右边直接是授权状态（PermissionStatus，每秒刷新）；
// 第二屏「按一下试试」= 主要全局快捷键一行一个（Whisker 键帽），用户真的按下、热键触发时（热键照常执行，面板照样弹出）
// 那一行弹出品牌粉 ✓（pop）：热键弹出的面板 / 截图遮罩正盖在引导上，所以 ✓ 等引导所在的 sheet 重新成为 key
// （用户关掉面板、截完图回来）再弹，播报是即时的。两屏之间 settle 滑过去，减弱动态效果时只淡入淡出；
// 没有跳过、页码点、上一步 / 下一步，只有一个品牌粉主按钮（Esc 照样关：藏着一个 cancelAction 按钮）。「关于」页可以重看。

import SwiftUI

struct OnboardingView: View {
  enum Screen { case welcome, tryIt }

  let center: HotKeyCenter
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var screen: Screen
  /// 引导开着时按过的全局快捷键
  @State private var tried: Set<HotKeyAction>
  /// 按过、✓ 还没弹的（等引导重新成为 key）
  @State private var pending: Set<HotKeyAction> = []
  /// 引导所在的窗口（sheet），只认它重新成为 key
  @State private var window: ObjectIdentifier?

  /// screen / tried：从哪一屏开始、哪些已经按过（截图自检摆状态用）
  init(center: HotKeyCenter, screen: Screen = .welcome, tried: Set<HotKeyAction> = []) {
    self.center = center
    _screen = State(initialValue: screen)
    _tried = State(initialValue: tried)
  }

  var body: some View {
    VStack(spacing: 0) {
      ZStack {
        switch screen {
        case .welcome: WelcomeScreen().transition(slide)
        case .tryIt: TryScreen(center: center, tried: tried).transition(slide)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .clipped()
      Button {
        if screen == .welcome {
          withAnimation(Style.Motion.settle.animation(reduced: reduceMotion)) { screen = .tryIt }
        } else {
          dismiss()
        }
      } label: {
        Text(screen == .welcome ? "继续" : "开始使用").frame(minWidth: 160)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .tint(Style.brand)
      .keyboardShortcut(.defaultAction)
      .padding(.top, 12)
      .padding(.bottom, 24)
    }
    .frame(width: 580, height: 480)
    .background(Style.brandCream)
    .background {
      // 没有可见的「跳过」（N14），Esc 靠这个看不见的按钮：macOS 上 sheet 没有 cancelAction 就不认 Esc
      Button("关闭引导") { dismiss() }
        .keyboardShortcut(.cancelAction)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
      WindowProbe { window = ObjectIdentifier($0) }
    }
    .onChange(of: center.fireCount) {
      guard let action = center.lastFired, !tried.contains(action) else { return }
      pending.insert(action)
      AccessibilityNotification.Announcement("按过了「\(action.title)」").post()
    }
    // ponytail: 热键什么也没弹出（截图 / 取词进行中又按）时 ✓ 等下次引导重新成为 key 才弹；真遇到再加兜底计时
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) {
      note in
      // 键盘回到引导：sheet 自己，或 AppKit 先交给了挂着它的设置窗
      guard let key = note.object as? NSWindow, let window, !pending.isEmpty,
        [key, key.attachedSheet].contains(where: { $0.map(ObjectIdentifier.init) == window })
      else { return }
      withAnimation(Style.Motion.pop.animation(reduced: reduceMotion)) { tried.formUnion(pending) }
      pending = []
    }
  }

  /// 只往前翻：第二屏从右边滑进来，第一屏往左滑出去
  private var slide: AnyTransition {
    guard !reduceMotion else { return .opacity }
    return .asymmetric(
      insertion: .move(edge: .trailing).combined(with: .opacity),
      removal: .move(edge: .leading).combined(with: .opacity))
  }
}

/// 大标题（品牌圆体 26）+ 一句说明
private struct Heading: View {
  let title: String
  let subtitle: String

  var body: some View {
    VStack(spacing: 4) {
      Text(title).font(.system(size: 26, weight: .bold, design: .rounded))
      Text(subtitle)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }
}

/// 白底卡片里的一列行，行间发丝线（从文字列开始）
private struct RowCard<Item: Hashable, Row: View>: View {
  let items: [Item]
  @ViewBuilder let row: (Item) -> Row

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
    VStack(spacing: 0) {
      ForEach(items, id: \.self) { item in
        VStack(spacing: 0) {
          if item != items.first { Style.hairline.frame(height: 0.5).padding(.leading, 46) }
          row(item).padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 40)
        }
      }
    }
    .background(.background, in: shape)
    .overlay(shape.strokeBorder(Style.hairline, lineWidth: 0.5))
    .padding(.horizontal, 36)
  }
}

/// 第一屏：品牌图标 + 大标题 + 四行功能；辅助功能、屏幕录制的状态每秒刷新（在系统设置里打开开关后，回到这里马上变）
private struct WelcomeScreen: View {
  @State private var trusted = Permissions.isAccessibilityTrusted
  @State private var screenRecording = Permissions.isScreenRecordingAllowed

  private struct Feature: Hashable {
    let title: String
    let detail: String
    let symbol: String
    let color: Color
    /// 这一行要的授权（粘贴回原 App、划词翻译靠辅助功能；截图、识字靠屏幕录制）
    var permission: Permissions.Kind?
  }

  private static let features = [
    Feature(
      title: "剪贴板历史", detail: "复制过的文字、图片、文件都记下来，选一条直接粘贴回原 App",
      symbol: "doc.on.clipboard.fill", color: Style.Family.clipboard, permission: .accessibility),
    Feature(
      title: "启动器", detail: "搜 App、文件、书签和网页，顺手算个算式",
      symbol: "command", color: Style.Family.command),
    Feature(
      title: "翻译", detail: "划词、输入、截图都能翻，内置服务不用配密钥",
      symbol: "character.bubble.fill", color: Style.Family.translate),
    Feature(
      title: "截图", detail: "框选、标注、钉图、长截图，还能识别图里的文字",
      symbol: "camera.viewfinder", color: Style.Family.screenshot, permission: .screenRecording),
  ]

  var body: some View {
    VStack(spacing: 0) {
      BrandIcon(size: 84)
      Heading(title: "欢迎使用 Kitty Tools", subtitle: "剪贴板、启动器、翻译和截图，都住在菜单栏里。")
        .padding(.top, 10)
      RowCard(items: Self.features) { feature in
        HStack(spacing: 10) {
          KindTile(symbol: feature.symbol, color: feature.color, size: 24)
          VStack(alignment: .leading, spacing: 1) {
            Text(feature.title).fontWeight(.medium)
            Text(feature.detail).font(.caption).foregroundStyle(.secondary)
          }
          Spacer(minLength: 8)
          switch feature.permission {
          case .accessibility:
            PermissionStatus(granted: trusted, button: "授权辅助功能") {
              Permissions.requestAccessibility()
              Permissions.openAccessibilitySettings()
            }
          case .screenRecording:
            PermissionStatus(granted: screenRecording, button: "授权屏幕录制") {
              Permissions.requestScreenRecording()
              Permissions.Kind.screenRecording.openSettings()
            }
          default: EmptyView()
          }
        }
        .accessibilityElement(children: .combine)
      }
      .padding(.top, 20)
    }
    .task {
      while !Task.isCancelled {
        trusted = Permissions.isAccessibilityTrusted
        screenRecording = Permissions.isScreenRecordingAllowed
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }
}

/// 第二屏「按一下试试」：列的是设好的组合；注册失败的那一行下面橙字写原因（按了也不会响）
private struct TryScreen: View {
  let center: HotKeyCenter
  let tried: Set<HotKeyAction>
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private static let shown: [HotKeyAction] = [
    .clipboard, .launcher, .selectionTranslate, .inputTranslate, .screenshot, .screenshotTranslate,
  ]

  var body: some View {
    let actions = Self.shown.filter { $0.hotKey != nil }
    VStack(spacing: 0) {
      Heading(title: "按一下试试", subtitle: "在任何 App 里按下这些键，对应的功能就会出来。\n现在按一下，按过的会打勾。")
      RowCard(items: actions) { row($0) }
        .padding(.top, 18)
      Text("想换键或看面板里的按键：设置 › 快捷键")
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 10)
    }
  }

  private func row(_ action: HotKeyAction) -> some View {
    let done = tried.contains(action)
    return HStack(spacing: 10) {
      KindTile(symbol: action.symbol, color: action.color, size: 24)
      VStack(alignment: .leading, spacing: 1) {
        Text(action.title)
        if let problem = center.failureMessage(for: action) {
          Text(problem).font(.caption).foregroundStyle(Color(nsColor: .systemOrange))
        }
      }
      Spacer(minLength: 8)
      KeyCombo(action.hotKey?.display ?? "")
      ZStack {
        if done {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(Style.brand)
            .transition(reduceMotion ? .opacity : .scale(scale: 0.3).combined(with: .opacity))
        }
      }
      .frame(width: 20, height: 20)
    }
    .accessibilityElement(children: .combine)
    .accessibilityValue(done ? "已试过" : "还没按过")
  }
}

/// 报告自己所在的窗口（引导靠它认出自己的 sheet 重新成为 key）
private struct WindowProbe: NSViewRepresentable {
  let found: (NSWindow) -> Void

  func makeNSView(context: Context) -> ProbeView { ProbeView(found: found) }
  func updateNSView(_ view: ProbeView, context: Context) {}

  final class ProbeView: NSView {
    let found: (NSWindow) -> Void

    init(found: @escaping (NSWindow) -> Void) {
      self.found = found
      super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      // 挂进窗口可能发生在 SwiftUI 更新视图的中途：下一轮再改状态
      guard let window else { return }
      Task { found(window) }
    }
  }
}
