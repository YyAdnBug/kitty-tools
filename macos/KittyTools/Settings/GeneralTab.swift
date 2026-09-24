// 设置 › 通用：开机自启、权限状态（辅助功能、屏幕录制、剪贴板访问）、从旧版导入（设置、密钥、剪贴板保留条目、翻译历史）。

import ServiceManagement
import SwiftUI

struct GeneralTab: View {
  /// 导入旧版的全部内容，返回逐行结果（LegacyImport.run）
  let importLegacy: () async -> String
  @State private var trusted = Permissions.isAccessibilityTrusted
  @State private var screenRecording = Permissions.isScreenRecordingAllowed
  @State private var loginStatus = SMAppService.mainApp.status
  @State private var loginError: String?
  /// NSPasteboard.AccessBehavior 的 rawValue（这个类型 macOS 15.4 才有），窗口变成 key 时刷新
  @State private var pasteboardBehavior = Self.currentPasteboardBehavior
  @State private var importResult: String?
  @State private var isImporting = false
  @State private var confirmImport = false

  var body: some View {
    Form {
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
        LabeledContent("辅助功能") {
          if trusted {
            Label("已授权", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
          } else {
            Button("去授权") {
              Permissions.requestAccessibility()
              Permissions.openAccessibilitySettings()
            }
          }
        }
        caption("粘贴回原 App、划词翻译都需要「辅助功能」授权。")
        LabeledContent("屏幕录制") {
          if screenRecording {
            Label("已授权", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
          } else {
            Button("去授权") {
              Permissions.requestScreenRecording()
              Permissions.Kind.screenRecording.openSettings()
            }
          }
        }
        caption("截图翻译需要「屏幕录制」授权；授权后可能要重新打开本 App 才生效。")
        if #available(macOS 15.4, *) { pasteboardAccess }
      }
      Section("从旧版导入") {
        LabeledContent {
          if isImporting { ProgressView().controlSize(.small) }
        } label: {
          Button("导入旧版 Kitty Tools 的数据…") { confirmImport = true }
            .disabled(isImporting)
        }
        if let importResult { Text(importResult).font(.callout).foregroundStyle(.secondary) }
        caption(
          "导入翻译服务与密钥、语言和剪贴板偏好，收藏、片段和分组里的剪贴板条目（含图片），以及全部翻译历史。"
            + "不导入快捷键（两个版本同时运行时会冲突）和普通剪贴板历史。可以重复导入，不会产生重复，旧版数据不会被改动。")
      }
    }
    .formStyle(.grouped)
    .frame(width: 520)
    .fixedSize(horizontal: false, vertical: true)
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
      trusted = Permissions.isAccessibilityTrusted
      screenRecording = Permissions.isScreenRecordingAllowed
      loginStatus = SMAppService.mainApp.status
      pasteboardBehavior = Self.currentPasteboardBehavior
    }
    .confirmationDialog("导入旧版数据？", isPresented: $confirmImport) {
      Button("导入") {
        isImporting = true
        Task {
          importResult = await importLegacy()
          loginStatus = SMAppService.mainApp.status  // 旧版开了开机自启的话，导入时已注册
          isImporting = false
        }
      }
    } message: {
      Text("会覆盖当前的翻译服务列表和相关偏好；剪贴板条目和翻译历史会合并进来。建议先退出旧版再导入。")
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
