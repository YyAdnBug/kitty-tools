// 设置 › 快捷键（N13）：按 剪贴板与启动器 / 翻译 / 截图与录制 / 便签 / 提醒 / 状态屏 / 启动台 / 刘海岛 / 主界面 分组（HotKeyAction.sections，和菜单栏分节同名同序），每行 = 20 pt 家族色块 +
// 动作名（HotKeyAction.rowTitle：状态屏那一行照它的键实际做的事写，默认「选一个状态进入」）+ 输入框式录制器（HotKeyRecorder）；
// 注册失败（-9868 等）或录制时的提示用 systemOrange 小字写在那一行下面；连按两下缺辅助功能授权时再给一个「去授权」；
// 默认键在这台的键盘布局下会吞字母、没设键的（第五轮体检 E9，HotKeyAction.withheldNote）也写一行。
// 全局的下面是「截图时」两组（2026-11-06 拍板 A3，ShotKeys）：标注工具、出图和操作，只在截图框选和标注里有效；
// 截图功能关着时不列，录屏那一行跟着录制功能；第二组底下「全部恢复默认」（第五轮体检 U5：先存一份旧的，岛上给「撤销」）。
// 剪贴板、启动器、翻译浮窗里的按键不写进页里，一句话 +「查看全部快捷键…」打开速查表（N11）。
// 最下面「在这些 App 里停用」（HotKeyBlockSection，2026-11-10）。

import SwiftUI

struct HotkeysTab: View {
  let center: HotKeyCenter
  /// 那一行为什么空着（E9；截图自检摆出橙字时换掉，不碰真的偏好和键盘布局）
  var withheld: (HotKeyAction) -> String? = { $0.withheldNote }
  @Environment(Island.self) private var island: Island?

  var body: some View {
    Form {
      ForEach(HotKeyAction.sections, id: \.title) { section in
        Section(section.title) {
          ForEach(section.actions, id: \.self) {
            HotKeyRow(target: .global($0), center: center, withheld: withheld)
          }
        }
      }
      if Feature.screenshot.isOn {
        Section {
          ForEach(ShotKey.tools, id: \.self) {
            HotKeyRow(target: .shot($0), center: center, withheld: withheld)
          }
        } header: {
          Text("截图时：标注工具")
            .settingsAnchor(.hotkeysShotTools)
          Text("只在截图框选和标注里有效，单个键也行")
        }
        Section {
          ForEach(ShotKey.others.filter(\.feature.isOn), id: \.self) {
            HotKeyRow(target: .shot($0), center: center, withheld: withheld)
          }
        } header: {
          Text("截图时：出图和操作")
            .settingsAnchor(.hotkeysShotOutput)
        } footer: {
          HStack(alignment: .firstTextBaseline) {
            SectionFootnote("↩ 拷贝、Esc 退出、⌫ 删除标注、方向键微调、⌘D 复制标注固定不改。")
            Spacer(minLength: 8)
            Button("全部恢复默认", action: resetShotKeys)
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
        .settingsAnchor(.hotkeysPanels)
      } footer: {
        SectionFootnote(
          "点录制框后按下新组合，或者快速连按两下 ⌘ ⌥ ⌃ ⇧ 中的一个；Esc 取消，⌫ 清除，右键可恢复默认。连按两下要「辅助功能」授权。")
      }
      HotKeyBlockSection(center: center)
    }
    .formStyle(.grouped)
    .settingsScrollTarget()
  }

  /// 截图时的键全部换回默认（U5）：先存一份旧的，岛上「已恢复默认」带「撤销」，撤销时整份放回。本来就都是默认的不弹岛
  private func resetShotKeys() {
    let before = ShotKey.snapshot()
    for key in ShotKey.allCases { key.set(key.defaultKey) }
    reloadKeys()
    guard !before.isEmpty else { return }
    island?.show(
      "已恢复默认", detail: "截图时的 \(before.count) 个快捷键", tone: .success,
      symbol: "arrow.counterclockwise.circle.fill",
      actions: [
        .init("撤销") {
          ShotKey.restore(before)
          reloadKeys()
        }
      ])
  }

  /// 各行的录制框跟着 generation 重读；正在录的那一行录完自己会重新注册
  private func reloadKeys() {
    if center.recording == nil { center.reload() }
  }
}

/// 一行快捷键：色块 + 名字（出问题时下面一行橙字）+ 录制器
private struct HotKeyRow: View {
  let target: KeyTarget
  let center: HotKeyCenter
  let withheld: (HotKeyAction) -> String?
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
    case .command(_, let title): title
    }
  }

  private var symbol: String {
    switch target {
    case .global(let action): action.symbol
    case .shot(let key): key.symbol
    case .command: "terminal.fill"
    }
  }

  private var color: Color {
    switch target {
    case .global(let action): action.color
    case .shot: Style.Family.screenshot
    case .command: Style.Family.command
    }
  }

  /// 先录制时的提示、再注册不上的原因、再为什么默认没占（E9），一样的只写一次
  private var problems: [String] {
    var failure: String?
    var withheld: String?
    if case .global(let action) = target {
      failure = center.failureMessage(for: action)
      // 键存在偏好里、不可观察：录上、清掉、导入后热键中心 reload 会把 generation 加一，跟着重算
      _ = center.generation
      withheld = self.withheld(action)
    }
    var seen = Set<String>()
    return [message, failure, withheld].compactMap(\.self).filter { seen.insert($0).inserted }
  }
}
