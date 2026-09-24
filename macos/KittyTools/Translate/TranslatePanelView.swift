// 翻译浮窗根视图。M1 只是浮层外壳的验证版：原文输入框（测输入法、Enter 提交）和图钉（测固定）。
// M4 换成真实的多服务翻译界面。

import SwiftUI

struct TranslatePanelView: View {
  @AppStorage(Prefs.floatingPinned) private var pinned = false
  @State private var text = ""
  @State private var submitted = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("翻译").font(.headline)
        Spacer()
        Toggle(isOn: $pinned) { Image(systemName: pinned ? "pin.fill" : "pin") }
          .toggleStyle(.button)
          .buttonStyle(.borderless)
          .help("固定：失焦不隐藏，Esc 不关闭")
      }
      SourceTextView(text: $text) { submitted = text }
        .frame(minHeight: 90)
        .overlay(alignment: .topLeading) {
          if text.isEmpty {
            Text("输入要翻译的文字，Enter 提交，Shift+Enter 换行")
              .foregroundStyle(.tertiary)
              .padding(.leading, 7)
              .padding(.top, 6)
              .allowsHitTesting(false)
          }
        }
        .padding(6)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
      if !submitted.isEmpty {
        Text("已提交：\(submitted)").textSelection(.enabled)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 14)
    .padding(.top, 12)
    .padding(.bottom, 14)
  }
}
