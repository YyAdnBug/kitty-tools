// 设置 › 启动器：点外关闭、浏览器书签、网页搜索引擎（关键词直达 / 无结果时兜底）。快捷键在「快捷键」页。

import SwiftUI

struct LauncherTab: View {
  @AppStorage(Prefs.launcherHideOnUnfocus) private var hideOnUnfocus = true
  @AppStorage(Prefs.launcherBookmarksChrome) private var chrome = true
  @AppStorage(Prefs.launcherBookmarksEdge) private var edge = false
  @AppStorage(Prefs.launcherBookmarksBrave) private var brave = false
  /// 直接读写偏好里的 JSON，不留一份拷贝（设置窗常驻：导入旧版后拷贝会过期，再改一下就把导入的覆盖掉）
  @AppStorage(Prefs.launcherWebSearchEngines) private var enginesData: Data?

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
        ForEach(engines) { $engine in
          LabeledContent {
            HStack(spacing: 12) {
              if let other = duplicate(of: engine) {
                Text("与\(other)重复").font(.caption).foregroundStyle(.red)
              }
              TextField("关键词", text: $engine.keyword, prompt: Text("关键词"))
                .labelsHidden()
                .frame(width: 80)
              Toggle("兜底", isOn: $engine.enabled)
                .help("没有本地结果时用它搜索")
            }
          } label: {
            Text(engine.name)
          }
        }
      } header: {
        Text("网页搜索")
      } footer: {
        caption("输入「关键词 空格 内容」直接用那个引擎搜；勾了「兜底」的引擎在没有本地结果时出现在列表里。关键词重复时用靠前的那个。")
      }
    }
    .formStyle(.grouped)
    .frame(width: 520)
    .fixedSize(horizontal: false, vertical: true)
  }

  private var engines: Binding<[SearchEngine]> {
    Binding {
      enginesData.flatMap { try? JSONDecoder().decode([SearchEngine].self, from: $0) }
        ?? WebSearch.defaults
    } set: {
      // 关键词里不能有空格
      let cleaned = $0.map { engine in
        var engine = engine
        engine.keyword = engine.keyword.filter { !$0.isWhitespace }
        return engine
      }
      enginesData = try? JSONEncoder().encode(cleaned)
    }
  }

  /// 关键词和排在前面的引擎重复时，返回那个引擎的名字（只提示，不替用户改）
  private func duplicate(of engine: SearchEngine) -> String? {
    let keyword = engine.keyword.lowercased()
    guard !keyword.isEmpty else { return nil }
    let list = engines.wrappedValue
    guard let index = list.firstIndex(of: engine) else { return nil }
    return list[..<index].first { $0.keyword.lowercased() == keyword }?.name
  }

  private func caption(_ text: String) -> some View {
    Text(text)
      .font(.caption)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.leading)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}
