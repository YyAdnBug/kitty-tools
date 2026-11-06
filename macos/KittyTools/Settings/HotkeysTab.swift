// 设置 › 快捷键（N13）：按 剪贴板与启动器 / 翻译 / 截图与录制 / 便签 / 提醒 / 状态屏 / 启动台 / 刘海岛 / 主界面 分组（HotKeyAction.sections，和菜单栏分节同名同序），每行 = 20 pt 家族色块 +
// 动作名（HotKeyAction.rowTitle：状态屏那一行照它的键实际做的事写，默认「选一个状态进入」）+ 输入框式录制器（HotKeyRecorder）；
// 注册失败（-9868 等）或录制时的提示用 systemOrange 小字写在那一行下面；连按两下缺辅助功能授权时再给一个「去授权」。
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
          Text("剪贴板、启动器、翻译浮窗和截图里按什么键，都在速查表里")
        }
      } footer: {
        SectionFootnote("点录制框后按下新组合，或者快速连按两下 ⌘ ⌥ ⌃ ⇧ 中的一个；Esc 取消，⌫ 清除，右键可恢复默认。连按两下要「辅助功能」授权。")
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
        Text(action.rowTitle)
        // 录制时的提示和注册不上的原因都写（录上连按两下时两样可能同时有：提醒 + 缺授权）
        ForEach(problems, id: \.self) { problem in
          Text(problem)
            .font(.subheadline)
            .foregroundStyle(Color(nsColor: .systemOrange))
            .fixedSize(horizontal: false, vertical: true)
        }
        // 连按两下缺辅助功能授权（拍板 B1）：给了之后热键中心自己重新注册，这一行跟着变
        if center.needsAccessibility(action) {
          Button("去授权") { Permissions.grant(.accessibility) }
            .buttonStyle(.link)
            .font(.subheadline)
        }
      }
      Spacer(minLength: 8)
      HotKeyRecorder(action: action, center: center, message: $message)
    }
  }

  /// 先录制时的提示、再注册不上的原因，一样的只写一次
  private var problems: [String] {
    let list = [message, center.failureMessage(for: action)].compactMap(\.self)
    return list.count == 2 && list[0] == list[1] ? [list[0]] : list
  }
}
