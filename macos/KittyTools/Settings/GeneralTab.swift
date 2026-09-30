// 设置 › 通用：外观（跟随系统 / 浅色 / 深色三张缩略图）与强调色（跟随系统 + 系统设置那一排 8 色，都是改了立刻生效）、
// 呼出面板时挤压弹开（实验，剪贴板 / 启动器 / 翻译浮窗共用，2026-09-29 从启动器页挪来）、
// 菜单栏图标（显示 / 隐藏、单色 / 彩色，StatusItem 看着偏好立刻跟着变，第 9 批 M1 M2）、登录时打开、
// 权限状态（辅助功能、屏幕录制、麦克风（录屏第 4 批）、15.4 起的剪贴板访问，同一种 PermissionRow；从未授权变已授权时
// 符号替换 + 弹一下）。

import AVFoundation
import ServiceManagement
import SwiftUI

struct GeneralTab: View {
  @AppStorage(Prefs.appearance) private var appearance = AppAppearance.system
  @AppStorage(Prefs.statusItemVisible) private var statusItemVisible = true
  @AppStorage(Prefs.statusItemStyle) private var statusItemStyle = StatusItem.IconStyle.template
  @AppStorage(Prefs.panelSqueezeEntrance) private var squeezeEntrance = false
  @State private var trusted = Permissions.isAccessibilityTrusted
  @State private var screenRecording = Permissions.isScreenRecordingAllowed
  @State private var microphone = Permissions.microphoneStatus
  @State private var loginStatus = SMAppService.mainApp.status
  @State private var loginError: String?
  /// NSPasteboard.AccessBehavior 的 rawValue（这个类型 macOS 15.4 才有），窗口变成 key 时刷新
  @State private var pasteboardBehavior = Self.currentPasteboardBehavior

  var body: some View {
    Form {
      Section {
        LabeledContent("外观") { AppearancePicker(selection: $appearance) }
          .onChange(of: appearance) { AppAppearance.apply() }
        LabeledContent("强调色") { AccentPicker() }
        caption(
          Accent.shared.choice == .system
            ? "系统强调色选「多色」时使用品牌粉。"
            : "菜单高亮和焦点环由系统绘制，仍使用系统强调色。")
        Toggle(isOn: $squeezeEntrance) {
          Text("呼出面板时挤压弹开（实验）")
          Text("剪贴板、启动器和翻译浮窗从窄一点、矮一点弹开到原尺寸；减弱动态效果时不弹")
        }
      }
      Section("菜单栏") {
        Toggle("在菜单栏显示图标", isOn: $statusItemVisible)
        caption("隐藏后，再打开一次 Kitty Tools（在启动器或访达里）可以回到设置；快捷键照常能用。")
        // 分段左边是菜单栏上现在那张图（1:1 实时预览）：分段控件只显示文字，塞不进图。
        // LabeledContent 的标签不随 .disabled 变淡，图标隐藏时自己淡成 .tertiary（同系统禁用文字）
        LabeledContent {
          HStack(spacing: 10) {
            if let image = statusItemStyle.image {
              Image(nsImage: image)
                .opacity(statusItemVisible ? 1 : Style.disabledOpacity)
                .accessibilityHidden(true)
            }
            Picker("图标样式", selection: $statusItemStyle) {
              ForEach(StatusItem.IconStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
          }
        } label: {
          Text("图标样式").foregroundStyle(statusItemVisible ? .primary : .tertiary)
        }
        .disabled(!statusItemVisible)
      }
      Section("启动") {
        Toggle("登录时自动打开", isOn: launchAtLogin)
          .disabled(!LaunchAtLogin.isInstalled)
        if !LaunchAtLogin.isInstalled {
          caption("正在从磁盘映像或临时位置运行。请先把 App 拖进「应用程序」文件夹，再开启这一项。")
        } else if loginStatus == .requiresApproval {
          LabeledContent {
            Button("打开登录项设置") { SMAppService.openSystemSettingsLoginItems() }
          } label: {
            caption("需要在「系统设置 › 通用 › 登录项与扩展」里允许本 App 在后台运行。")
          }
        }
        if let loginError { caption(loginError).foregroundStyle(.red) }
      }
      Section("权限") {
        PermissionRow(
          title: "辅助功能", detail: "粘贴回原 App、划词翻译、长截图自动滚动", symbol: "hand.raised.fill",
          color: Style.Family.command, granted: trusted
        ) {
          Permissions.requestAccessibility()
          Permissions.openAccessibilitySettings()
        }
        PermissionRow(
          title: "屏幕录制", detail: "截图、截图翻译、识字；授权后可能要重新打开本 App 才生效",
          symbol: "record.circle", color: Style.Family.screenshot, granted: screenRecording
        ) {
          Permissions.requestScreenRecording()
          Permissions.Kind.screenRecording.openSettings()
        }
        // 没问过时请求（系统弹框，回来就刷新）；拒绝过 / 受限的系统不再弹框，打开系统设置的麦克风页
        PermissionRow(
          title: "麦克风", detail: "录屏时录下你的声音", symbol: "mic.fill",
          color: Style.Family.screenshot, granted: microphone == .authorized
        ) {
          guard microphone == .notDetermined else {
            return Permissions.Kind.microphone.openSettings()
          }
          Task {
            _ = await Permissions.requestMicrophone()
            microphone = Permissions.microphoneStatus
          }
        }
        if #available(macOS 15.4, *) { pasteboardAccess }
      }
    }
    .formStyle(.grouped)
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
      trusted = Permissions.isAccessibilityTrusted
      screenRecording = Permissions.isScreenRecordingAllowed
      microphone = Permissions.microphoneStatus
      loginStatus = SMAppService.mainApp.status
      pasteboardBehavior = Self.currentPasteboardBehavior
    }
  }

  private var launchAtLogin: Binding<Bool> {
    Binding {
      loginStatus == .enabled || loginStatus == .requiresApproval
    } set: { isOn in
      do {
        try LaunchAtLogin.set(isOn)
        loginError = nil
      } catch {
        loginError = "设置失败：\(error.localizedDescription)"
      }
      loginStatus = SMAppService.mainApp.status
    }
  }

  /// macOS 15.4 起的剪贴板隐私，和上面两行同一种权限行：「默认」（本 App 还不在系统设置的列表里）和「始终允许」
  /// 都算已授权；「询问」「拒绝」给「打开设置」。拒绝的后果写进说明，不另加红字
  @available(macOS 15.4, *)
  private var pasteboardAccess: some View {
    let behavior = pasteboardBehavior.flatMap(NSPasteboard.AccessBehavior.init(rawValue:))
    return PermissionRow(
      title: "剪贴板访问",
      detail: behavior == .alwaysDeny
        ? "已被拒绝，剪贴板历史不会再记录新内容；到「从其他 App 粘贴」里改成始终允许"
        : "后台记录剪贴板历史；系统询问时到「从其他 App 粘贴」里改成始终允许",
      symbol: "doc.on.clipboard.fill", color: Style.Family.clipboard,
      granted: behavior != .ask && behavior != .alwaysDeny, button: "打开设置"
    ) {
      // ponytail: 打开「隐私与安全性」总页；「从其他 App 粘贴」的专用锚点真机查到再换
      NSWorkspace.shared.open(
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
    }
  }

  private static var currentPasteboardBehavior: Int? {
    if #available(macOS 15.4, *) { NSPasteboard.general.accessBehavior.rawValue } else { nil }
  }

  private func caption(_ text: String) -> some View {
    Text(text).font(.caption).foregroundStyle(.secondary)
  }
}

/// 一行权限：家族色块 + 名字 + 用途，右边是状态（未授权时带「去授权」）。从未授权变已授权时符号替换 + 弹一下
/// （Whisker §6 设置）；通用页和欢迎引导共用
struct PermissionRow: View {
  let title: String
  let detail: String
  let symbol: String
  let color: Color
  let granted: Bool
  /// 未授权时的按钮文字
  var button = "去授权"
  let grant: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      KindTile(symbol: symbol, color: color, size: 24)
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      PermissionStatus(granted: granted, button: button, grant: grant)
    }
    .accessibilityElement(children: .combine)
  }
}

/// 授权状态：未授权时一个授权按钮 + 橙色 !，已授权是绿色 ✓（从未授权变已授权时符号替换 + 弹一下）。
/// PermissionRow 和欢迎引导的功能行共用；button 是按钮文字（引导里写明授权哪一项）
struct PermissionStatus: View {
  let granted: Bool
  var button = "去授权"
  let grant: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      if !granted { Button(button, action: grant) }
      Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(Color(nsColor: granted ? .systemGreen : .systemOrange))
        .contentTransition(.symbolEffect(.replace))
        .symbolEffect(.bounce, value: granted)
        .accessibilityLabel(granted ? "已授权" : "未授权")
    }
  }
}

/// 外观：和系统设置 › 外观一样的三张小缩略图，名字写在下面；选中的名字加粗，外面一圈强调色描边（隔 1.5 pt 缝，快速淡入）
private struct AppearancePicker: View {
  @Binding var selection: AppAppearance

  var body: some View {
    HStack(spacing: 6) {
      ForEach(AppAppearance.allCases) { option($0) }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("外观")
  }

  private func option(_ appearance: AppAppearance) -> some View {
    let selected = selection == appearance
    return Button {
      selection = appearance
    } label: {
      VStack(spacing: 3) {
        AppearanceThumbnail(appearance: appearance)
          .padding(4)
          .overlay {
            if selected {
              RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
                .strokeBorder(Style.brand, lineWidth: 2.5)
                .transition(.opacity)
            }
          }
        Text(appearance.title)
          .font(.system(size: 12, weight: selected ? .semibold : .regular))
          .foregroundStyle(selected ? .primary : .secondary)
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .animation(.easeOut(duration: Style.fadeIn), value: selected)
    .accessibilityLabel(appearance.title)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

/// 一张外观缩略图：桌面渐变 + 一扇从左上角露出来的小窗口（标题栏、两条内容、一个强调色小点）；
/// 跟随系统 = 浅色、深色沿斜线各取一半。颜色是示意用的定值，不跟当前外观走（强调色点按缩略图自己的深浅取）
private struct AppearanceThumbnail: View {
  let appearance: AppAppearance
  static let size = CGSize(width: 58, height: 38)

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Style.Radius.control, style: .continuous)
    let (w, h) = (Self.size.width, Self.size.height)
    ZStack {
      switch appearance {
      case .light: Self.desktop(dark: false)
      case .dark: Self.desktop(dark: true)
      case .system:
        Self.desktop(dark: false)
        Self.desktop(dark: true).mask(
          Path {
            $0.addLines([
              CGPoint(x: w * 0.62, y: 0), CGPoint(x: w, y: 0), CGPoint(x: w, y: h),
              CGPoint(x: w * 0.38, y: h),
            ])
          })
      }
    }
    .frame(width: w, height: h)
    .clipShape(shape)
    .overlay(shape.hairlineBorder())
  }

  private static func desktop(dark: Bool) -> some View {
    let window = RoundedRectangle(cornerRadius: Style.Radius.mini, style: .continuous)
    let bar = Color(white: dark ? 1 : 0, opacity: dark ? 0.22 : 0.13)
    let wallpaper: [Color] =
      dark
      ? [Color(red: 0.11, green: 0.16, blue: 0.29), Color(red: 0.20, green: 0.15, blue: 0.31)]
      : [Color(red: 0.62, green: 0.74, blue: 0.92), Color(red: 0.84, green: 0.80, blue: 0.94)]
    return LinearGradient(colors: wallpaper, startPoint: .top, endPoint: .bottom)
      .overlay(alignment: .topLeading) {
        VStack(alignment: .leading, spacing: 4) {
          Color(white: dark ? 0.24 : 0.91).frame(height: 7)  // 标题栏
          HStack(spacing: 3) {
            Circle().fill(Style.brand).frame(width: 5, height: 5)
            Capsule().fill(bar).frame(width: 20, height: 3)
          }
          .padding(.leading, 5)
          Capsule().fill(bar).frame(width: 28, height: 3).padding(.leading, 5)
        }
        .frame(width: 50, height: 32, alignment: .topLeading)
        .background(Color(white: dark ? 0.16 : 1))
        .clipShape(window)
        .overlay(window.strokeBorder(Color(white: dark ? 1 : 0, opacity: 0.12), lineWidth: 0.5))
        .offset(x: 10, y: 8)
      }
      .environment(\.colorScheme, dark ? .dark : .light)
  }
}

/// 强调色：和系统设置同样的一排色块（第一个多色 = 跟随系统），选中的那个中间一个白点、名字写在它下面
private struct AccentPicker: View {
  private let accent = Accent.shared
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: 10) {
      ForEach(AccentChoice.allCases) { swatch($0) }
    }
    // 选中项的名字挂在色块下面
    .padding(.bottom, 16)
    .animation(Style.Motion.pop.animation(reduced: reduceMotion), value: accent.choice)
  }

  private func swatch(_ choice: AccentChoice) -> some View {
    let selected = accent.choice == choice
    return Button {
      accent.select(choice)
    } label: {
      Circle()
        .fill(fill(of: choice))
        .overlay(Circle().strokeBorder(.black.opacity(0.14), lineWidth: 0.5))
        .overlay {
          if selected {
            Circle().fill(.white).frame(width: 6, height: 6)
              .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
          }
        }
        .frame(width: 20, height: 20)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .overlay(alignment: .bottom) {
      if selected {
        Text(choice.title).font(.caption).foregroundStyle(.secondary).fixedSize().offset(y: 17)
      }
    }
    .help(choice.title)
    .accessibilityLabel(choice.title)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  /// 跟随系统 = 系统设置「多色」那样的一圈彩虹
  private func fill(of choice: AccentChoice) -> AnyShapeStyle {
    guard let fixed = choice.fixed else {
      let ring: [AccentChoice] = [.red, .orange, .yellow, .green, .blue, .purple, .pink, .red]
      return AnyShapeStyle(
        AngularGradient(
          colors: ring.compactMap { $0.fixed.map { Color(nsColor: $0.light) } }, center: .center))
    }
    return AnyShapeStyle(Style.dynamic(light: fixed.light, dark: fixed.dark))
  }
}

/// 外观：改 NSApp.appearance，没自己定外观的窗口（浮层毛玻璃、设置窗、菜单栏菜单、欢迎引导）立刻跟着变；
/// 截图 HUD（vibrantDark）、刘海岛（纯黑）、飞行卡片本来就固定深色，不受影响（mac-whisker §2）
enum AppAppearance: String, CaseIterable, Identifiable {
  case system, light, dark

  var id: String { rawValue }

  var title: String {
    switch self {
    case .system: "跟随系统"
    case .light: "浅色"
    case .dark: "深色"
    }
  }

  /// 偏好值 → NSApp.appearance 的名字；nil = 跟随系统（没存过、存了认不得的值都算跟随系统）
  static func name(for pref: String?) -> NSAppearance.Name? {
    switch pref.flatMap(Self.init) {
    case .light: .aqua
    case .dark: .darkAqua
    case .system, nil: nil
    }
  }

  /// 按偏好设 NSApp.appearance：启动时（任何窗口出现前）和设置改了时各调一次
  static func apply() {
    NSApp.appearance = name(for: UserDefaults.standard.string(forKey: Prefs.appearance))
      .flatMap(NSAppearance.init(named:))
  }
}

/// 登录时打开（登录项）：SMAppService.mainApp，系统设置里显示为本 App；通用页开关和欢迎引导第二屏的勾选框共用
enum LaunchAtLogin {
  /// 从 DMG（/Volumes/…）或 App Translocation 的随机只读路径运行时不注册：登录项会指向一个很快就失效的位置
  static var isInstalled: Bool {
    let path = Bundle.main.bundlePath
    return !path.hasPrefix("/Volumes/") && !path.contains("/AppTranslocation/")
  }

  static func set(_ enabled: Bool) throws {
    if enabled {
      try SMAppService.mainApp.register()
    } else {
      try SMAppService.mainApp.unregister()
    }
  }
}
