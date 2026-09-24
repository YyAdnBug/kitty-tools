// 设置 › 启动器：点外关闭、浏览器书签、网页搜索引擎（启用 / 关键词直达）。快捷键在「快捷键」页。

import SwiftUI

struct LauncherTab: View {
  @AppStorage(Prefs.launcherHideOnUnfocus) private var hideOnUnfocus = true
  @AppStorage(Prefs.launcherBookmarksChrome) private var chrome = true
  @AppStorage(Prefs.launcherBookmarksEdge) private var edge = false
  @AppStorage(Prefs.launcherBookmarksBrave) private var brave = false
  @State private var engines = WebSearch.engines

  var body: some View {
    Form {
      Section {
        Toggle("点面板外面时自动关闭", isOn: $hideOnUnfocus)
      } footer: {
        caption(
          "↩ 打开，⌘↩ 在访达中显示，⌘C 复制路径或网址，⌘1–9 打开第几项，Esc 先清空再关闭。"
            + "输入网址或 / ~ 开头的路径可直接打开；输入算式得到计算结果；「cb 关键词」搜剪贴板里的文本。")
      }
      Section("浏览器书签") {
        Toggle("Chrome", isOn: $chrome)
        Toggle("Edge", isOn: $edge)
        Toggle("Brave", isOn: $brave)
      }
      Section {
        ForEach($engines) { $engine in
          LabeledContent(engine.name) {
            HStack(spacing: 12) {
              TextField("关键词", text: $engine.keyword, prompt: Text("关键词"))
                .labelsHidden()
                .frame(width: 80)
              Toggle("启用", isOn: $engine.enabled).labelsHidden()
            }
          }
        }
      } header: {
        Text("网页搜索")
      } footer: {
        caption("没有匹配的本地结果时，用启用的引擎搜索。设了关键词后，输入「关键词 空格 内容」直接用这个引擎搜。")
      }
    }
    .formStyle(.grouped)
    .frame(width: 520)
    .fixedSize(horizontal: false, vertical: true)
    .onChange(of: engines) {
      // 关键词去掉空格；和别的引擎重复时清空，免得「g 内容」不知道走哪个
      var seen = Set<String>()
      for index in engines.indices {
        let keyword = engines[index].keyword.filter { !$0.isWhitespace }.lowercased()
        engines[index].keyword = keyword.isEmpty || seen.insert(keyword).inserted ? keyword : ""
      }
      WebSearch.engines = engines
    }
  }

  private func caption(_ text: String) -> some View {
    Text(text)
      .font(.caption)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.leading)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}
