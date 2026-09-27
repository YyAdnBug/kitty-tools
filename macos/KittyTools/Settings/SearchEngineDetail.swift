// 设置 › 启动器 › 某条网页搜索或快捷链接（N12 详情页，从列表推进来）：页头 40 pt 种类色块 + 名称 + 状态，
// 下面分组表单：名称、关键词、网址、兜底开关（只有搜索有），删除（自定义的先确认）。改动即时写回偏好里的 JSON 列表
// （和 LauncherTab 读写同一个键，启动器下次搜索就用上）；有问题（没名称、网址不完整、关键词被占用或重复、
// 用不上）时页头和列表行的状态变成橙色说明，不拦着保存。工具栏「‹ 返回」/ ⌘[ 回列表（SettingsBackButton）。

import SwiftUI

struct SearchEngineDetail: View {
  let id: String
  @AppStorage(Prefs.launcherWebSearchEngines) private var enginesData: Data?
  @Environment(\.dismiss) private var dismiss
  @State private var confirmsDelete = false

  var body: some View {
    let list = Self.decode(enginesData)
    // 删掉之后、退回列表之前的这一帧没有这一条：什么都不画
    if let engine = list.first(where: { $0.id == id }) {
      form(engine, problem: Self.problem(of: engine, in: list))
        .navigationTitle(Self.title(engine))
        .toolbar { SettingsBackButton { dismiss() } }
    }
  }

  private func form(_ engine: SearchEngine, problem: String?) -> some View {
    let binding = Binding {
      engine
    } set: {
      save($0)
    }
    return Form {
      Section {
        TextField("名称", text: binding.name, prompt: Text("如 GitHub"))
        TextField("关键词", text: binding.keyword, prompt: Text("可不填"))
        TextField(
          "网址", text: binding.urlTemplate, prompt: Text("https://example.com/search?q={query}"))
        if !engine.isQuicklink {
          Toggle("没有本地结果时用它兜底", isOn: binding.enabled)
        }
      } header: {
        DetailHeader(
          title: Self.title(engine), status: problem ?? Self.kindTitle(engine),
          isProblem: problem != nil
        ) {
          Self.tile(engine, size: 40)
        }
      } footer: {
        OrderedList.footnote(
          engine.isQuicklink
            ? "网址里没有 {query}：快捷链接，搜名字或关键词直接打开这个网址（也可以填 / 或 ~ 开头的路径）。"
            : "网址里有 {query}：搜索，输入「关键词 空格 内容」时内容替换进 {query}。")
      }
      Section {
        Button(Self.isPreset(id) ? "删除" : "删除…", role: .destructive) {
          if Self.isPreset(id) { delete() } else { confirmsDelete = true }
        }
      }
    }
    .formStyle(.grouped)
    .confirmationDialog("删除「\(Self.title(engine))」？", isPresented: $confirmsDelete) {
      Button("删除", role: .destructive, action: delete)
    } message: {
      Text(Self.deleteMessage)
    }
    // 名称、网址的首尾空白在离开时去掉（边输边去会吃掉正在打的空格）
    .onDisappear {
      var trimmed = engine
      trimmed.name = trimmed.name.trimmingCharacters(in: .whitespaces)
      trimmed.urlTemplate = trimmed.urlTemplate.trimmingCharacters(in: .whitespaces)
      if trimmed != engine { save(trimmed) }
    }
  }

  private func delete() {
    dismiss()
    var list = Self.decode(enginesData)
    list.removeAll { $0.id == id }
    enginesData = Self.encode(list)
  }

  private func save(_ engine: SearchEngine) {
    var list = Self.decode(enginesData)
    guard let index = list.firstIndex(where: { $0.id == id }) else { return }
    list[index] = engine
    enginesData = Self.encode(list)
  }

  // MARK: 列表读写与展示（LauncherTab 共用）

  /// 偏好里的 JSON → 列表（没存过用默认的）
  static func decode(_ data: Data?) -> [SearchEngine] {
    data.flatMap { try? JSONDecoder().decode([SearchEngine].self, from: $0) } ?? WebSearch.defaults
  }

  /// 列表 → JSON；关键词里不能有空格（「关键词 空格 内容」靠空格切分）
  static func encode(_ list: [SearchEngine]) -> Data? {
    try? JSONEncoder().encode(
      list.map { engine in
        var engine = engine
        engine.keyword = engine.keyword.filter { !$0.isWhitespace }
        return engine
      })
  }

  /// 预置的删了还能从「+」加回来，直接删；自定义的删掉就找不回来，要先确认（列表和详情页同一套）
  static func isPreset(_ id: String) -> Bool { WebSearch.presets.contains { $0.id == id } }

  static let deleteMessage = "自定义的名称、关键词和网址删掉就找不回来了。"

  static func title(_ engine: SearchEngine) -> String {
    let name = engine.name.trimmingCharacters(in: .whitespaces)
    return name.isEmpty ? "未命名" : name
  }

  /// 没问题时的状态副标题：说明它怎么用（列表行上开关的含义也靠它）
  static func kindTitle(_ engine: SearchEngine) -> String {
    if engine.isQuicklink { return "快捷链接" }
    return engine.enabled ? "搜索 · 没有本地结果时兜底" : "搜索 · 只用关键词"
  }

  /// 种类色块（和启动器里同一套家族色）：搜索 = 网页搜索靛蓝，网址快捷链接 = 网址青，路径 = 通用灰。
  /// ponytail: 不取网站图标（打开设置就去请求每个网站不合适）；以后启动器缓存了 favicon 再换成它
  static func tile(_ engine: SearchEngine, size: CGFloat) -> KindTile {
    let target = engine.urlTemplate.trimmingCharacters(in: .whitespaces)
    if !engine.isQuicklink {
      return KindTile(symbol: "magnifyingglass", color: Style.Family.search, size: size)
    }
    if target.hasPrefix("/") || target.hasPrefix("~") {
      return KindTile(symbol: "folder.fill", color: Style.Family.general, size: size)
    }
    return KindTile(symbol: "link", color: Style.Family.url, size: size)
  }

  /// 这一条的问题（橙色提示；nil = 能用）。list 用来查搜索的关键词和前面的搜索重复（「关键词 空格 内容」直达只看搜索，
  /// 重复时用靠前的；快捷链接的关键词只参与名称匹配，和谁同名都不算重复）：
  /// 名称不空；搜索的网址要有协议（https:、maps: 之类，http(s) 还得有主机名，默认的「https://」不算填好）；
  /// 快捷链接也可以是 / ~ 开头的路径；关键词不能是保留的 cb / open / find；搜索没关键词又不兜底就用不上
  static func problem(of engine: SearchEngine, in list: [SearchEngine]) -> String? {
    if engine.name.trimmingCharacters(in: .whitespaces).isEmpty { return "还没填名称" }
    let url = engine.urlTemplate.trimmingCharacters(in: .whitespaces)
    let parsed = URL(string: url.replacing("{query}", with: "q"))
    let hasScheme =
      parsed?.scheme.map {
        $0.count > 1 && (!["http", "https"].contains($0.lowercased()) || parsed?.host() != nil)
      } ?? false
    let isPath = engine.isQuicklink && (url.hasPrefix("/") || url.hasPrefix("~"))
    if !hasScheme && !isPath { return "网址不完整" }
    let keyword = engine.keyword.lowercased()
    if let owner = WebSearch.reservedKeywords[keyword] { return "关键词「\(keyword)」留给\(owner)" }
    if !engine.isQuicklink, !keyword.isEmpty,
      let index = list.firstIndex(where: { $0.id == engine.id }),
      let earlier = list[..<index].first(where: {
        !$0.isQuicklink && $0.keyword.lowercased() == keyword
      })
    {
      return "关键词和「\(title(earlier))」重复，用的是靠前的那个"
    }
    if !engine.isQuicklink && keyword.isEmpty && !engine.enabled { return "没有关键词也不兜底，用不上" }
    return nil
  }
}
