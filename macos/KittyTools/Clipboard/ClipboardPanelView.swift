// 剪贴板面板根视图。M1 只是浮层外壳的验证版：搜索框（测输入法）、固定样例列表（测粘贴回原 App）、
// 打开翻译浮窗（测兄弟窗口豁免）、图钉（测固定）。M2 / M3 换成真实历史。

import SwiftUI

struct ClipboardPanelView: View {
  var onPaste: (String) -> Void
  var onOpenTranslate: () -> Void

  @AppStorage(Prefs.clipboardHideOnUnfocus) private var hideOnUnfocus = true
  @State private var query = ""
  @State private var selection = 0
  @State private var trusted = Permissions.isAccessibilityTrusted

  private let samples = [
    "M1 粘贴测试：Hello, Kitty!",
    "多行文本\n第二行\n第三行",
    "中文 English 混排 😺 ⌘⇧V",
  ]

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        CommandTextField(text: $query, placeholder: "搜索（M1：测试输入法）", onCommand: handleCommand)
        Button("翻译浮窗", systemImage: "character.bubble", action: onOpenTranslate)
          .labelStyle(.iconOnly)
          .help("打开翻译浮窗（测试兄弟窗口豁免）")
        Toggle(isOn: pinned) { Image(systemName: hideOnUnfocus ? "pin" : "pin.fill") }
          .toggleStyle(.button)
          .help("固定：点外面不关闭")
      }
      .buttonStyle(.borderless)
      .padding(.horizontal, 14)
      .padding(.top, 12)
      .padding(.bottom, 10)
      Divider()
      if !trusted {
        HStack {
          Text("粘贴需要辅助功能授权，未授权时内容只写进剪贴板").font(.callout)
          Spacer()
          Button("去授权") {
            Permissions.requestAccessibility()
            Permissions.openAccessibilitySettings()
          }
        }
        .padding(10)
        .background(.yellow.opacity(0.15))
      }
      ScrollView {
        VStack(spacing: 2) {
          ForEach(samples.indices, id: \.self) { index in
            Text(samples[index])
              .lineLimit(1)
              .truncationMode(.tail)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 10)
              .padding(.vertical, 8)
              .background(
                index == selection ? Color.accentColor.opacity(0.2) : .clear,
                in: .rect(cornerRadius: 6)
              )
              .contentShape(.rect)
              .onTapGesture { onPaste(samples[index]) }
          }
        }
        .padding(8)
      }
      Text("↑↓ 选择 · Enter 粘贴 · Esc 关闭")
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(8)
    }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
      trusted = Permissions.isAccessibilityTrusted
    }
  }

  private var pinned: Binding<Bool> {
    Binding(get: { !hideOnUnfocus }, set: { hideOnUnfocus = !$0 })
  }

  private func handleCommand(_ selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.moveUp(_:)):
      selection = (selection + samples.count - 1) % samples.count
    case #selector(NSResponder.moveDown(_:)):
      selection = (selection + 1) % samples.count
    case #selector(NSResponder.insertNewline(_:)):
      onPaste(samples[selection])
    default:
      return false
    }
    return true
  }
}
