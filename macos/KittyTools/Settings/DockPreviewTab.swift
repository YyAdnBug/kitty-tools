// 设置 › 程序坞预览（第九族，2026-10-22；拍板 A2 A3 D1）。两组：
// 「程序坞预览」——启用开关（功能开关 Feature.dockPreview，默认关），页脚说怎么用；
// 「权限」——辅助功能（缺了不能用）、屏幕录制（缺了只列标题、没有缩略图），和通用页同一种 PermissionRow；
//   这台 Mac 上有私有接口取不到时，组下面橙字说少了什么（别的桌面上的窗口不列、切窗口可能不准）。
// 第一组里另有「停多久再弹出」（2026-11-06 用户要的，Prefs.dockPreviewDelay，默认 0.4 秒）和「按 ⌘Tab 时也显示」
// （2026-11-06 拍板 C2，Prefs.dockPreviewCmdTab，默认开）；功能关着时都变灰。
// 别的设置都没有：缩略图大小、列哪些窗口都是定死的（拍板 C1 C5），以后要再加。页头由 SettingsRoot 画（家族色青）。

import SwiftUI

struct DockPreviewTab: View {
  @State private var trusted = Permissions.isAccessibilityTrusted
  @State private var screenRecording = Permissions.isScreenRecordingAllowed
  @AppStorage(Prefs.dockPreviewDelay) private var delay = 400
  @AppStorage(Prefs.dockPreviewCmdTab) private var cmdTab = true
  /// 取不到的私有接口（截图自检传固定的；正常是 nil = 现问）
  var missing: [String]?

  var body: some View {
    // 从系统设置授权回来，设置窗重新当 key 时刷新两行的状态（同通用页；只认设置窗自己，F3）
    form.onSettingsBecameKey {
      trusted = Permissions.isAccessibilityTrusted
      screenRecording = Permissions.isScreenRecordingAllowed
    }
  }

  private var form: some View {
    Form {
      Section {
        FeatureToggle(feature: .dockPreview, inPage: true)
        Picker("停多久再弹出", selection: $delay) {
          ForEach(Prefs.dockPreviewDelayChoices, id: \.self) { milliseconds in
            Text(Self.title(milliseconds)).tag(milliseconds)
          }
        }
        .gated(by: .dockPreview)
        Toggle(isOn: $cmdTab) {
          Text("按 ⌘Tab 时也显示")
          Text("切换 App 时，在切换器上方显示选中那个 App 的窗口")
        }
        .gated(by: .dockPreview)
      } header: {
        Text("程序坞预览")
      } footer: {
        SectionFootnote(
          "鼠标在程序坞的图标上停这么久才弹出，弹出后移到别的图标上马上换。点一张切到那扇窗口，悬停时点左上角的 ✕ 关掉它。最小化的、隐藏的和别的桌面上的窗口也列出来。"
        )
      }
      Section {
        PermissionRow(
          title: "辅助功能", detail: "知道鼠标停在哪个图标上，列出、切换和关掉窗口；没有它用不了",
          symbol: "hand.raised.fill", color: Style.Family.command, granted: trusted
        ) { Permissions.grant(.accessibility) }
        PermissionRow(
          title: "屏幕录制", detail: "截窗口的缩略图；没有它只列窗口的名字", symbol: HotKeyAction.screenRecord.symbol,
          color: Style.Family.screenshot, granted: screenRecording
        ) { Permissions.grant(.screenRecording) }
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

  /// 「0.4 秒」「1 秒」
  static func title(_ milliseconds: Int) -> String {
    (Double(milliseconds) / 1000).formatted(.number.precision(.fractionLength(0...1))) + " 秒"
  }
}
