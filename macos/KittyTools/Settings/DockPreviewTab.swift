// 设置 › 程序坞预览（第九族，2026-10-22；拍板 A2 A3 D1）。两组：
// 「程序坞预览」——启用开关（功能开关 Feature.dockPreview，默认关），页脚说怎么用；
// 「权限」——辅助功能（缺了不能用）、屏幕录制（缺了只列标题、没有缩略图），和通用页同一种 PermissionRow；
//   这台 Mac 上有私有接口取不到时，组下面橙字说少了什么（别的桌面上的窗口不列、切窗口可能不准）。
// 别的设置都没有：出现快慢、缩略图大小、列哪些窗口都是定死的（拍板 B1 C1 C5），以后要再加。页头由 SettingsRoot 画（家族色青）。

import SwiftUI

struct DockPreviewTab: View {
  @State private var trusted = Permissions.isAccessibilityTrusted
  @State private var screenRecording = Permissions.isScreenRecordingAllowed
  /// 取不到的私有接口（截图自检传固定的；正常是 nil = 现问）
  var missing: [String]?

  var body: some View {
    // 从系统设置授权回来，设置窗重新当 key 时刷新两行的状态（同通用页）
    let becameKey = NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
    return form.onReceive(becameKey) { _ in
      trusted = Permissions.isAccessibilityTrusted
      screenRecording = Permissions.isScreenRecordingAllowed
    }
  }

  private var form: some View {
    Form {
      Section {
        FeatureToggle(feature: .dockPreview, inPage: true)
      } header: {
        Text("程序坞预览")
      } footer: {
        SectionFootnote(
          "点一张切到那扇窗口，悬停时点右上角的 ✕ 关掉它。最小化的、隐藏的和别的桌面上的窗口也列出来。")
      }
      Section {
        PermissionRow(
          title: "辅助功能", detail: "知道鼠标停在哪个图标上，列出、切换和关掉窗口；没有它用不了",
          symbol: "hand.raised.fill", color: Style.Family.command, granted: trusted
        ) {
          Permissions.requestAccessibility()
          Permissions.openAccessibilitySettings()
        }
        PermissionRow(
          title: "屏幕录制", detail: "截窗口的缩略图；没有它只列窗口的名字", symbol: HotKeyAction.screenRecord.symbol,
          color: Style.Family.screenshot, granted: screenRecording
        ) {
          Permissions.requestScreenRecording()
          Permissions.Kind.screenRecording.openSettings()
        }
      } header: {
        Text("权限")
      } footer: {
        let missing = missing ?? WindowServer.missing
        if !missing.isEmpty {
          // 接口名普通人看不懂：说后果，名字放在悬停提示里
          Text(
            "这台 Mac 上有的系统接口用不了："
              + WindowServer.consequences(of: missing).joined(separator: "；") + "。"
          )
          .font(.caption)
          .foregroundStyle(Color(nsColor: .systemOrange))
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 10)
          .help(missing.joined(separator: "、"))
        }
      }
    }
    .formStyle(.grouped)
  }
}
