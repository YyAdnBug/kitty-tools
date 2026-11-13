// 首次安装的欢迎引导（N14，Whisker 品牌时刻，对标 Apple 自家 App 的首次启动页 / Raycast）：盖在设置窗上的 sheet，奶油底，三屏。
// 第一屏 = 品牌图标 + 大标题 + 全部功能两列（勾选框 + 家族色块 + 名字 + Feature.blurb，这台系统上有的都列，加了功能这里自己跟上；
// 2026-10-26 用户报引导还停在四件套）。勾选框就是功能开关（同 设置 › 通用 › 功能，立即生效）：新装时只勾着常用的四样
// （Feature.seedNewInstall），用得上的勾上（2026-11-04 功能管理拍板 M6，对标 PowerToys / Raycast 的首次引导）；
// 第二屏「授权」= 勾上的功能用得着的辅助功能、屏幕录制（OnboardingView.permissions；PermissionRow，同 设置 › 通用 › 权限，
// 每秒刷新），一项都用不着就跳过这一屏，别的授权用到时再问；
// 第三屏「按一下试试」= 主要全局快捷键一行一个（Whisker 键帽），用户真的按下、热键触发时（热键照常执行，面板照样弹出）
// 那一行弹出品牌粉 ✓（pop）：热键弹出的面板 / 截图遮罩正盖在引导上，所以 ✓ 等引导所在的 sheet 重新成为 key
// （用户关掉面板、截完图回来）再弹，播报是即时的。屏与屏之间 settle 滑过去，减弱动态效果时只淡入淡出；
// 没有跳过、页码点、上一步 / 下一步，只有一个品牌粉主按钮（Esc 照样关：藏着一个 cancelAction 按钮）。「关于」页可以重看。
// 第三屏底下一个勾选框「登录时自动打开」（体检 D20：不开机自启的话重启后快捷键全都没反应；勾不勾跟随当前状态——首次安装
// 一启动就按默认（开）注册好了，第四轮体检 E1），点「开始使用」时生效（勾掉就取消注册），失败走刘海岛；从磁盘映像等
// 临时位置运行时换成一行说明。关掉引导后照旧停在通用页（下面就是这个开关）。
// 首次安装时引导走完（「开始使用」、Esc、关掉设置窗）才记「看过这一版」：中途退出（授权屏幕录制后系统要求重开）下次启动
// 接着开，从做到的那一屏起（resume，E1；AppDelegate.showWelcomeIfNeeded）。

import ServiceManagement
import SwiftUI

struct OnboardingView: View {
  enum Screen: Int, Comparable {
    case welcome, permissions, tryIt

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
  }

  /// 第二屏要开的授权（纯函数，M6）：勾上的功能里有用得着的才列，顺序固定（辅助功能在前）。辅助功能管粘贴回原 App（剪贴板、
  /// 启动器）、划词、长截图自动滚动、录屏显示按键、状态屏拦键鼠、程序坞预览；屏幕录制管截图（截图翻译、识字也是）、录屏、
  /// 程序坞预览的缩略图。便签、提醒、启动台用不着（提醒的「进入状态屏」到时候再问）
  static func permissions(for features: Set<Feature>) -> [Permissions.Kind] {
    let accessibility: Set<Feature> = [
      .clipboard, .launcher, .translate, .screenshot, .record, .statusScreen, .dockPreview,
    ]
    let screenRecording: Set<Feature> = [.translate, .screenshot, .record, .dockPreview]
    return [
      features.isDisjoint(with: accessibility) ? nil : .accessibility,
      features.isDisjoint(with: screenRecording) ? nil : .screenRecording,
    ].compactMap { $0 }
  }

  /// 那几项授权都给了没有（没走完的引导接着开时用）
  static func granted(_ kinds: [Permissions.Kind]) -> Bool {
    kinds.allSatisfy {
      $0 == .accessibility
        ? Permissions.isAccessibilityTrusted : Permissions.isScreenRecordingAllowed
    }
  }

  /// 没走完的引导下次接着开时从哪一屏起（纯函数，E1）：做到过第三屏的回第三屏；停在第二屏（授权）的，要的几项都已经授权了
  /// （多半是授权屏幕录制后系统让重开）就直接到第三屏，还缺的回第二屏接着授权；只看过第一屏、没记录的从头来
  static func resume(reached: Screen?, granted: Bool) -> Screen {
    switch reached {
    case .tryIt: .tryIt
    case .permissions: granted ? .tryIt : .permissions
    case .welcome, nil: .welcome
    }
  }

  let center: HotKeyCenter
  /// 换到了哪一屏（AppDelegate 记进偏好，下次没走完接着开时用；截图自检里不记）
  var onScreen: (Screen) -> Void = { _ in }
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(Island.self) private var island: Island?
  @State private var screen: Screen
  /// 第三屏的「登录时自动打开」，点「开始使用」时生效（用户动过它才算数）
  @State private var launchAtLogin: Bool
  /// 用户动过「登录时自动打开」没有：没动就不改登录项（重看时状态是「要批准」、勾选框显示没勾，别因此取消注册）
  @State private var loginTouched = false
  private let firstRun: Bool
  /// 引导开着时按过的全局快捷键
  @State private var tried: Set<HotKeyAction>
  /// 按过、✓ 还没弹的（等引导重新成为 key）
  @State private var pending: Set<HotKeyAction> = []
  /// 引导所在的窗口（sheet），只认它重新成为 key
  @State private var window: ObjectIdentifier?

  /// 挂在设置窗工具栏下沿：首次安装时设置窗是默认大小（内容 600，工具栏约 52），高 520 放得下
  static let size = CGSize(width: 580, height: 520)

  /// firstRun：首次安装，「登录时自动打开」默认勾（启动时已经注册过；没注册成的也勾着，点「开始使用」再试一次）；
  /// 关于页重看时跟随当前状态（不把用户在通用页关掉的又打开）。
  /// screen：从哪一屏开始（没走完接着开的、截图自检摆状态）；tried：哪些已经按过（截图自检）
  init(
    center: HotKeyCenter, firstRun: Bool = false, screen: Screen = .welcome,
    tried: Set<HotKeyAction> = [], onScreen: @escaping (Screen) -> Void = { _ in }
  ) {
    self.center = center
    self.onScreen = onScreen
    self.firstRun = firstRun
    _launchAtLogin = State(initialValue: firstRun || SMAppService.mainApp.status == .enabled)
    _screen = State(initialValue: screen)
    _tried = State(initialValue: tried)
  }

  var body: some View {
    VStack(spacing: 0) {
      ZStack {
        switch screen {
        case .welcome: WelcomeScreen().transition(slide)
        case .permissions:
          PermissionScreen(kinds: Self.permissions(for: Feature.enabled)).transition(slide)
        case .tryIt:
          TryScreen(center: center, tried: tried, launchAtLogin: $launchAtLogin).transition(slide)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .clipped()
      Button {
        let next: Screen? =
          switch screen {
          // 勾上的功能一项授权都用不着：跳过授权那一屏
          case .welcome: Self.permissions(for: Feature.enabled).isEmpty ? .tryIt : .permissions
          case .permissions: .tryIt
          case .tryIt: nil
          }
        if let next {
          withAnimation(Style.Motion.settle.animation(reduced: reduceMotion)) { screen = next }
        } else {
          finish()
        }
      } label: {
        Text(screen == .tryIt ? "开始使用" : "继续").frame(minWidth: 160)
      }
      .buttonStyle(BrandButtonStyle())
      .controlSize(.large)
      .keyboardShortcut(.defaultAction)
      .padding(.top, 12)
      .padding(.bottom, 24)
    }
    .frame(width: Self.size.width, height: Self.size.height)
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
    .onChange(of: screen) { onScreen(screen) }
    .onChange(of: launchAtLogin) { loginTouched = true }
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

  /// 「开始使用」：用户动过勾选框才照它改登录项（首次安装一启动就按默认注册过了，勾掉就是用户不要）；没动过的不改，
  /// 只有首次安装、勾着、却还没注册上（启动时没注册成）的再试一次
  private func finish() {
    if LaunchAtLogin.isInstalled,
      let wants = Self.loginChange(
        touched: loginTouched, checked: launchAtLogin, firstRun: firstRun,
        status: SMAppService.mainApp.status)
    {
      do {
        try LaunchAtLogin.set(wants)
      } catch {
        island?.show(
          wants ? "没能加入登录项" : "没能取消登录项", detail: error.localizedDescription,
          tone: .warning)
      }
    }
    dismiss()
  }

  /// 点「开始使用」时登录项要改成什么（纯函数，E1）：true = 注册、false = 取消注册、nil = 不动。
  /// 动过勾选框：照它来，已经是那样的不重复做；没动过：只有首次安装勾着、还没注册的注册（要批准的、已开着的都不动）
  static func loginChange(
    touched: Bool, checked: Bool, firstRun: Bool, status: SMAppService.Status
  ) -> Bool? {
    let registered = status == .enabled || status == .requiresApproval
    if touched {
      if checked { return status == .enabled ? nil : true }
      return registered ? false : nil
    }
    return firstRun && checked && status == .notRegistered ? true : nil
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

/// 白底卡片里的一列行，行间发丝线（从文字列开始，右端和行内容一样缩 12，同速查表的卡片）
private struct RowCard<Item: Hashable, Row: View>: View {
  let items: [Item]
  @ViewBuilder let row: (Item) -> Row

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
    VStack(spacing: 0) {
      ForEach(items, id: \.self) { item in
        VStack(spacing: 0) {
          if item != items.first { Hairline().padding(.leading, 46).padding(.trailing, 12) }
          row(item).padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 40)
        }
      }
    }
    .background(.background, in: shape)
    .overlay(shape.hairlineBorder())
    .padding(.horizontal, 36)
  }
}

/// 第一屏：品牌图标 + 大标题 + 这台系统上有的全部功能，两列，每格一个勾选框（名字、色块取设置页的，一句话是 Feature.blurb）
private struct WelcomeScreen: View {
  var body: some View {
    // 插件不在这里列（拍板 A1：默认不添加，到 设置 › 通用 › 功能 里加）
    let features = Feature.listed
    let shape = RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
    VStack(spacing: 0) {
      BrandIcon(size: 64)
      Heading(
        title: "欢迎使用 Kitty Tools",
        subtitle: "这些小工具都住在菜单栏里，用快捷键随叫随到。\n勾上要用的，以后在 设置 › 通用 › 功能 里随时改。"
      )
      .padding(.top, 8)
      Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 10) {
        ForEach(Array(stride(from: 0, to: features.count, by: 2)), id: \.self) { start in
          GridRow {
            ForEach(features[start..<min(start + 2, features.count)], id: \.self) {
              FeatureChoice(feature: $0)
            }
          }
        }
      }
      .padding(14)
      .background(.background, in: shape)
      .overlay(shape.hairlineBorder())
      .padding(.horizontal, 36)
      .padding(.top, 14)
    }
  }
}

/// 第一屏的一格：系统勾选框，标签是色块 + 名字 + 一句话（点哪里都勾）。绑功能开关的偏好，勾了立即生效（同 FeatureToggle）；
/// 没勾的色块变淡（同设置侧栏「已关闭」那一行）
private struct FeatureChoice: View {
  let feature: Feature
  @AppStorage private var isOn: Bool

  init(feature: Feature) {
    self.feature = feature
    _isOn = AppStorage(wrappedValue: feature.defaultOn, feature.prefsKey)
  }

  var body: some View {
    Toggle(isOn: $isOn) {
      HStack(alignment: .top, spacing: 10) {
        KindTile(symbol: feature.page.symbol, color: feature.page.color, size: 24)
          .opacity(isOn ? 1 : Style.disabledOpacity)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 1) {
          Text(feature.title).fontWeight(.medium)
          Text(feature.blurb)
            .font(.subheadline).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())  // 色块、空白处也算点在勾选框上
    }
    .toggleStyle(.checkbox)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// 第二屏：勾上的功能用得着的辅助功能、屏幕录制（同 设置 › 通用 › 权限），每秒刷新（在系统设置里打开开关后，回到这里马上变）
private struct PermissionScreen: View {
  let kinds: [Permissions.Kind]
  @State private var trusted = Permissions.isAccessibilityTrusted
  @State private var screenRecording = Permissions.isScreenRecordingAllowed

  var body: some View {
    VStack(spacing: 0) {
      Heading(
        title: kinds.count > 1 ? "先开两项授权" : "先开一项授权",
        subtitle: (kinds.count > 1 ? "勾上的功能要用到它们，各管什么写在下面。" : "勾上的功能要用到它，管什么写在下面。")
          + "\n点「去授权」后在系统设置里打开开关，回到这里状态会自己变。")
      RowCard(items: kinds) { kind in
        if kind == .accessibility {
          PermissionRow.accessibility(granted: trusted)
        } else {
          PermissionRow.screenRecording(granted: screenRecording)
        }
      }
      .padding(.top, 18)
      Text("麦克风、文件夹这类授权等用到时再问；以后都在 设置 › 通用 › 权限 里")
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 12)
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

/// 第三屏「按一下试试」：列的是设好的组合；注册失败的那一行下面橙字写原因（按了也不会响）
private struct TryScreen: View {
  let center: HotKeyCenter
  let tried: Set<HotKeyAction>
  @Binding var launchAtLogin: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// 有默认键的几个功能各挑最常用的一个（七行正好放得下）
  private static let shown: [HotKeyAction] = [
    .clipboard, .launcher, .selectionTranslate, .screenshot, .screenshotTranslate, .screenRecord,
    .noteCapture,
  ]

  var body: some View {
    // 关着的功能（第一屏没勾的）的键不注册，按了也不会打勾：不列
    let actions = Self.shown.filter { $0.isActive && $0.hotKey != nil }
    VStack(spacing: 0) {
      if actions.isEmpty {
        // 第一屏勾的功能都没有默认键（便签以外的提醒、状态屏、启动台……），或一个都没勾
        Heading(
          title: "都准备好了",
          subtitle: Feature.enabled.isEmpty
            ? "一个功能都没勾。以后用得上，到 设置 › 通用 › 功能 里打开。"
            : "勾上的功能没有默认快捷键：点菜单栏图标就能用，\n想用键叫出来到 设置 › 快捷键 里设一个。")
      } else {
        Heading(title: "按一下试试", subtitle: "在任何 App 里按下这些键，对应的功能就会出来。\n现在按一下，按过的会打勾。")
        RowCard(items: actions) { row($0) }
          .padding(.top, 18)
      }
      Group {
        if LaunchAtLogin.isInstalled {
          Toggle("登录时自动打开，开机后快捷键就能用", isOn: $launchAtLogin)
            .toggleStyle(.checkbox)
            .font(.callout)
        } else {
          Text("拖进「应用程序」后可在 设置 › 通用 里开启登录时打开")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .padding(.top, 12)
      Text("提示从屏幕顶部正中冒出来，有刘海时点一下刘海能看最近几条\n点菜单栏图标看全部功能；换键、看面板里的按键：设置 › 快捷键")
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.top, 10)
    }
  }

  private func row(_ action: HotKeyAction) -> some View {
    let done = tried.contains(action)
    return HStack(spacing: 10) {
      KindTile(symbol: action.symbol, color: action.color, size: 24)
      VStack(alignment: .leading, spacing: 1) {
        // 两屏的行标题同一个字重（第一屏的功能名也是 medium）
        Text(action.title).fontWeight(.medium)
        if let problem = center.failureMessage(for: action) {
          Text(problem).font(.subheadline).foregroundStyle(Color(nsColor: .systemOrange))
        }
      }
      Spacer(minLength: 8)
      KeyCombo(action.hotKey?.display ?? "")
      ZStack {
        if done {
          // 16：和第一屏授权状态的 ✓ 一样大（PermissionStatus）
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 16, weight: .medium))
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
