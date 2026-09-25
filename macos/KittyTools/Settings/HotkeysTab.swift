// 设置 › 快捷键：每个全局热键一行录制控件，注册失败就地显示原因。

import SwiftUI

struct HotkeysTab: View {
  let center: HotKeyCenter

  var body: some View {
    Form {
      Section {
        ForEach(HotKeyAction.allCases, id: \.self) { action in
          LabeledContent(action.title) { HotKeyRecorder(action: action, center: center) }
        }
      } footer: {
        Text("和旧版 Kitty Tools 同时运行时，请在旧版里清空相同的快捷键，否则按一次两边都会响应。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }
}
