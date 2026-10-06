// 底栏左边的就地提示（mac-whisker §6 剪贴板 / 启动器）：剪贴板面板和启动器共用同一种提示和画法——
// 「✓ 已复制」（systemGreen 对勾）/「⚠ 只复制了第 1 条」（只染三角，字保持默认色）/「已删除 N 条 · 撤销 ⌘Z」
// （撤销是 brandInk 文字按钮）。带撤销的停 5 秒，其余 1.6 秒；计时和播报在各自的 model 里（焦点一直在搜索框，要主动播报）。
// 另有 UpdateBarHint：有新版本时两个面板底栏里常驻的「更新到 x」。

import SwiftUI

enum BarNotice: Hashable {
  case message(String)
  /// 没做全（如「只复制了第 1 条」）：不带成功的绿色对勾
  case warning(String)
  /// 后面跟「撤销 ⌘Z」
  case undo(String)

  var text: String {
    switch self {
    case .message(let text), .warning(let text), .undo(let text): text
    }
  }

  /// 停多久：带撤销的 5 秒，其余 1.6 秒
  var seconds: Double {
    if case .undo = self { 5 } else { 1.6 }
  }
}

/// 有新版本时底栏里常驻的「更新到 x」（剪贴板面板、启动器共用，2026-10-06；对标 Alfred 窗口底部的小提示）：跟在左边的
/// 条数 / 种类后面，就地提示出来时让开；点了先收起面板，再下载安装、装好自动重新打开（同菜单栏菜单顶上那一项，符号也是
/// 同一个；进度和失败原因在刘海岛上）。Updater 从环境里取：没给（单测、多数截图自检）或没有新版本时什么都不画
struct UpdateBarHint: View {
  /// 收起所在的面板
  let dismiss: () -> Void
  @Environment(Updater.self) private var updater: Updater?

  var body: some View {
    if let updater, let release = updater.available {
      Button {
        dismiss()
        Task { await updater.install() }
      } label: {
        Label("更新到 \(release.version)", systemImage: "arrow.down.circle.fill")
          .foregroundStyle(Style.brandInk)
          .contentShape(.rect)
      }
      .pointerStyle(.link)
      .help("有新版本：下载并安装 \(release.version)，装好自动重新打开")
      .accessibilityHint("有新版本，下载安装后自动重新打开")
    }
  }
}

struct BarNoticeView: View {
  let notice: BarNotice
  /// 点「撤销」
  let undo: () -> Void

  var body: some View {
    switch notice {
    case .message(let text):
      Label(text, systemImage: "checkmark.circle.fill")
        .symbolRenderingMode(.palette)
        .foregroundStyle(Color(nsColor: .systemGreen), Color(nsColor: .systemGreen))
        .symbolEffect(.bounce, value: text)
    case .warning(let text):
      // 只染三角：橙字在浅色底上对比度不够，字保持默认色
      Label {
        Text(text)
      } icon: {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(Color(nsColor: .systemOrange))
      }
    case .undo(let text):
      HStack(spacing: 8) {
        Text(text).foregroundStyle(.secondary)
        Text("·").foregroundStyle(.tertiary)
        Button(action: undo) {
          HStack(spacing: 6) {
            Text("撤销").foregroundStyle(Style.brandInk)
            KeyCap("⌘Z")
          }
        }
        .pointerStyle(.link)
        .accessibilityLabel("撤销")
        .accessibilityHint(text)
      }
    }
  }
}
