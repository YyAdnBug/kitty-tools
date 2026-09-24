// 设置 › 通用：权限状态（辅助功能）、从旧版导入。开机自启、关于等在 M6 补。

import SwiftUI

struct GeneralTab: View {
  let services: TranslateServiceStore
  @State private var trusted = Permissions.isAccessibilityTrusted
  @State private var importResult: String?
  @State private var confirmImport = false

  var body: some View {
    Form {
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
        Text("粘贴回原 App、划词翻译都需要「辅助功能」授权。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Section("从旧版导入") {
        Button("导入旧版 Kitty Tools 的设置…") { confirmImport = true }
        if let importResult { Text(importResult).font(.callout).foregroundStyle(.secondary) }
        Text("导入翻译服务与密钥、语言和剪贴板偏好；不导入快捷键（两个版本同时运行时会冲突）。可以重复导入，旧版数据不会被改动。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .frame(width: 520, height: 320)
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
      trusted = Permissions.isAccessibilityTrusted
    }
    .confirmationDialog("导入旧版设置？", isPresented: $confirmImport) {
      Button("导入") {
        do {
          importResult = "✓ " + (try LegacyImport.importSettings(into: services))
        } catch {
          importResult = "✗ " + error.localizedDescription
        }
      }
    } message: {
      Text("会覆盖当前的翻译服务列表和相关偏好")
    }
  }
}
