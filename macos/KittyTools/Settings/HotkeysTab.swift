// 设置 › 快捷键（N13）：按 剪贴板与启动器 / 翻译 / 截图与录制 / 便签 / 提醒 / 状态屏 / 启动台 / 刘海岛 / 主界面 分组（HotKeyAction.sections，和菜单栏分节同名同序），每行 = 20 pt 家族色块 +
// 动作名（HotKeyAction.rowTitle：状态屏那一行照它的键实际做的事写，默认「选一个状态进入」）+ 输入框式录制器（HotKeyRecorder）；
// 注册失败（-9868 等）或录制时的提示用 systemOrange 小字写在那一行下面；连按两下缺辅助功能授权时再给一个「去授权」。
// 全局的下面是「截图时」两组（2026-11-06 拍板 A3，ShotKeys）：标注工具、出图和操作，只在截图框选和标注里有效；
// 截图功能关着时不列，录屏那一行跟着录制功能；第二组底下「全部恢复默认」。
// 剪贴板、启动器、翻译浮窗里的按键不写进页里，最后一句话 +「查看全部快捷键…」打开速查表（N11）。

import SwiftUI

struct HotkeysTab: View {
  let center: HotKeyCenter

  var body: some View {
    Form {
      ForEach(HotKeyAction.sections, id: \.title) { section in
        Section(section.title) {
          ForEach(section.actions, id: \.self) { HotKeyRow(target: .global($0), center: center) }
        }
      }
      if Feature.screenshot.isOn {
        Section {
          ForEach(ShotKey.tools, id: \.self) { HotKeyRow(target: .shot($0), center: center) }
        } header: {
          Text("截图时：标注工具")
          Text("只在截图框选和标注里有效，单个键也行")
        }
        Section {
          ForEach(ShotKey.others.filter(\.feature.isOn), id: \.self) {
            HotKeyRow(target: .shot($0), center: center)
          }
        } header: {
          Text("截图时：出图和操作")
        } footer: {
          HStack(alignment: .firstTextBaseline) {
            SectionFootnote("↩ 拷贝、Esc 退出、⌫ 删除标注、方向键微调、⌘D 复制标注固定不改。")
            Spacer(minLength: 8)
            Button("全部恢复默认") {
              for key in ShotKey.allCases { key.set(key.defaultKey) }
              // 各行的录制框跟着 generation 重读；正在录的那一行录完自己会重新注册
              if center.recording == nil { center.reload() }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Style.brandInk)
            .pointerStyle(.link)
            .font(.subheadline)
          }
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
        SectionFootnote(
          "点录制框后按下新组合，或者快速连按两下 ⌘ ⌥ ⌃ ⇧ 中的一个；Esc 取消，⌫ 清除，右键可恢复默认。连按两下要「辅助功能」授权。")
      }
    }
    .formStyle(.grouped)
  }
}

/// 一行快捷键：色块 + 名字（出问题时下面一行橙字）+ 录制器
private struct HotKeyRow: View {
  let target: KeyTarget
  let center: HotKeyCenter
  @State private var message: String?

  var body: some View {
    HStack(spacing: 10) {
      KindTile(symbol: symbol, color: color, size: 20)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
        // 录制时的提示和注册不上的原因都写（录上连按两下时两样可能同时有：提醒 + 缺授权）
        ForEach(problems, id: \.self) { problem in
          Text(problem)
            .font(.subheadline)
            .foregroundStyle(Color(nsColor: .systemOrange))
            .fixedSize(horizontal: false, vertical: true)
        }
        // 连按两下缺辅助功能授权（拍板 B1）：给了之后热键中心自己重新注册，这一行跟着变
        if case .global(let action) = target, center.needsAccessibility(action) {
          Button("去授权") { Permissions.grant(.accessibility) }
            .buttonStyle(.plain)
            .foregroundStyle(Style.brandInk)
            .pointerStyle(.link)
            .font(.subheadline)
        }
      }
      Spacer(minLength: 8)
      HotKeyRecorder(target: target, center: center, message: $message)
    }
  }

  private var title: String {
    switch target {
    case .global(let action): action.rowTitle
    case .shot(let key): key.title
    }
  }

  private var symbol: String {
    switch target {
    case .global(let action): action.symbol
    case .shot(let key): key.symbol
    }
  }

  private var color: Color {
    switch target {
    case .global(let action): action.color
    case .shot: Style.Family.screenshot
    }
  }

  /// 先录制时的提示、再注册不上的原因，一样的只写一次
  private var problems: [String] {
    var failure: String?
    if case .global(let action) = target { failure = center.failureMessage(for: action) }
    let list = [message, failure].compactMap(\.self)
    return list.count == 2 && list[0] == list[1] ? [list[0]] : list
  }
}
