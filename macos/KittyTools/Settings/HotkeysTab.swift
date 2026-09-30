// 设置 › 快捷键（N13）：按 剪贴板与启动器 / 翻译 / 截图与录制 分组（和菜单栏分节同名同序），每行 = 20 pt 家族色块 +
// 动作名 + 输入框式录制器（HotKeyRecorder）；注册失败（-9868 等）或录制时的提示用 systemOrange 小字写在那一行下面。
// 面板里的按键不写进页里，最后一句话 +「查看全部快捷键…」打开速查表（N11）。

import SwiftUI

struct HotkeysTab: View {
  let center: HotKeyCenter

  var body: some View {
    Form {
      ForEach(HotKeyAction.sections, id: \.title) { section in
        Section(section.title) {
          ForEach(section.actions, id: \.self) { HotKeyRow(action: $0, center: center) }
        }
      }
      Section {
        LabeledContent {
          ShortcutsButton()
        } label: {
          Text("面板里的按键")
          Text("剪贴板、启动器、翻译浮窗和截图里按什么键，都在速查表里。")
        }
      } footer: {
        Text("点录制框后按下新组合；Esc 取消，⌫ 清除，右键可恢复默认。")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }
}

/// 一行快捷键：色块 + 名字（出问题时下面一行橙字）+ 录制器
private struct HotKeyRow: View {
  let action: HotKeyAction
  let center: HotKeyCenter
  @State private var message: String?

  var body: some View {
    HStack(spacing: 10) {
      KindTile(symbol: action.symbol, color: action.color, size: 20)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(action.title)
        if let problem = message ?? center.failureMessage(for: action) {
          Text(problem)
            .font(.caption)
            .foregroundStyle(Color(nsColor: .systemOrange))
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 8)
      HotKeyRecorder(action: action, center: center, message: $message)
    }
  }
}
