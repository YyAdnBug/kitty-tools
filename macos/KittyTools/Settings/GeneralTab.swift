// 设置 › 通用：外观（跟随系统 / 浅色 / 深色）与强调色（跟随系统 + 系统设置那一排 8 色，都是改了立刻生效）、开机自启、权限状态（辅助功能、屏幕录制、剪贴板访问；从未授权变已授权时符号替换 + 弹一下）。

import ServiceManagement
import SwiftUI

struct GeneralTab: View {
  @AppStorage(Prefs.appearance) private var appearance = AppAppearance.system
  @State private var trusted = Permissions.isAccessibilityTrusted
  @State private var screenRecording = Permissions.isScreenRecordingAllowed
  @State private var loginStatus = SMAppService.mainApp.status
  @State private var loginError: String?
  /// NSPasteboard.AccessBehavior 的 rawValue（这个类型 macOS 15.4 才有），窗口变成 key 时刷新
  @State private var pasteboardBehavior = Self.currentPasteboardBehavior

  var body: some View {
    Form {
      Section {
        Picker("外观", selection: $appearance) {
          ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .onChange(of: appearance) { AppAppearance.apply() }
        caption("截图工具栏和刘海岛提示始终是深色。")
        LabeledContent("强调色") { AccentPicker() }
        caption(
          Accent.shared.choice == .system
            ? "系统强调色选「多色」时使用品牌粉。"
            : "菜单高亮、焦点环和侧栏选中由系统绘制，仍使用系统强调色。")
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
        if #available(macOS 15.4, *) { pasteboardAccess }
      }
    }
    .formStyle(.grouped)
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
      trusted = Permissions.isAccessibilityTrusted
      screenRecording = Permissions.isScreenRecordingAllowed
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

  /// macOS 15.4 起的剪贴板隐私：「默认」时本 App 还不在系统设置的列表里，「始终允许」没问题，都不提示
  @available(macOS 15.4, *)
  @ViewBuilder private var pasteboardAccess: some View {
    switch pasteboardBehavior.flatMap(NSPasteboard.AccessBehavior.init(rawValue:)) {
    case .ask:
      LabeledContent("剪贴板访问") {
        Button("打开隐私设置") {
          NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
        }
      }
      caption("系统会在读取剪贴板时询问。请到「隐私与安全性 › 从其他 App 粘贴」里把本 App 改成「始终允许」。")
    case .alwaysDeny:
      LabeledContent("剪贴板访问") {
        Label("已被拒绝", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
      }
      caption("系统已拒绝本 App 读取剪贴板，剪贴板历史不会再记录新内容。到「隐私与安全性 › 从其他 App 粘贴」里改成「始终允许」。")
    default:
      EmptyView()
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
  let grant: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      KindTile(symbol: symbol, color: color, size: 24)
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      PermissionStatus(granted: granted, grant: grant)
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

/// 开机自启（登录项）：SMAppService.mainApp，系统设置里显示为本 App
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
