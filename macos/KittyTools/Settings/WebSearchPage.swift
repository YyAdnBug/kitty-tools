// 设置 › 启动器 › 网页搜索与快捷链接（2026-11-07 用户「要不要也做成进入详情编辑，和命令和别名一样」，从启动器页挪进推进去的
// 这一页）：页头 40 pt 搜索家族色块 + 一句现状；N12 那张列表——行 = 网站图标或种类色块 / 名称 / 状态 / 关键词键帽 / 兜底开关，
// 拖动排序，「+ −」增删（预置的直接删、「+」能加回来，自定义的先确认），单击一行再推进一层到 SearchEngineDetail 编辑
// （‹ 返回一层一层退）；「有本地结果时也显示兜底搜索」。列表直接读写偏好里的 JSON，不留拷贝。启动器关着时整页变灰。

import SwiftUI

struct WebSearchPage: View {
  static let route = "page:web-search"
  @AppStorage(Prefs.launcherFallbackAlways) private var fallbackAlways = false
  /// 直接读写偏好里的 JSON，不留一份拷贝（设置窗常驻：别处改了偏好，拷贝会过期，再改一下就把别处的改动覆盖掉）
  @AppStorage(Prefs.launcherWebSearchEngines) private var enginesData: Data?
  /// 推进的编辑页在 navigation.path（主菜单「返回」也要读写它）
  @Environment(SettingsNavigation.self) private var navigation
  @Environment(\.dismiss) private var dismiss
  /// 列表里用键盘选中的一条（「−」和 ⌫ 删它；鼠标单击直接推进，不留选中）
  @State private var selection: String?
  /// 等确认删除的自定义搜索 / 快捷链接
  @State private var removing: String?

  var body: some View {
    VStack(spacing: 0) {
      DetailHeader(title: "网页搜索与快捷链接", status: Self.summary(engines)) {
        KindTile(symbol: "globe", color: Style.Family.search, size: 40)
      }
      Form {
        Section {
          engineList
          ListEditBar(
            removeTitle: "删除所选的一条", canRemove: selection != nil, remove: removeSelected
          ) {
            addMenu
          }
          Toggle("有本地结果时也显示兜底搜索", isOn: $fallbackAlways)
        } footer: {
          SectionFootnote(
            "网址里有 {query} 的是搜索（「关键词 空格 内容」直达，开关 = 没有本地结果时兜底），没有的是快捷链接。"
              + "拖动调整顺序，搜索的关键词重复时用靠前的；点一行编辑。")
        }
      }
      .formStyle(.grouped)
      .gated(by: .launcher)
    }
    .navigationTitle("网页搜索与快捷链接")
    .toolbar { SettingsBackButton { dismiss() } }
    .confirmationDialog(
      "删除「\(engines.first { $0.id == removing }.map(SearchEngineDetail.title) ?? "")」？",
      isPresented: Binding {
        removing != nil
      } set: {
        if !$0 { removing = nil }
      }
    ) {
      Button("删除", role: .destructive) {
        if let removing { delete(removing) }
      }
    } message: {
      Text(SearchEngineDetail.deleteMessage)
    }
  }

  /// 启动器页那一行和这一页页头的小字：几个搜索、几个快捷链接、谁兜底、有几条要改（纯函数，配单测）
  static func summary(_ engines: [SearchEngine]) -> String {
    guard !engines.isEmpty else { return "还没有，点进去添加" }
    let searches = engines.filter { !$0.isQuicklink }
    let links = engines.count - searches.count
    var text = "\(searches.count) 个搜索" + (links > 0 ? "、\(links) 个快捷链接" : "")
    let fallback = searches.filter(\.enabled).map(SearchEngineDetail.title)
    if fallback.isEmpty {
      text += "，不兜底"
    } else {
      text += "；兜底：" + fallback.prefix(3).joined(separator: "、")
      if fallback.count > 3 { text += " 等 \(fallback.count) 个" }
    }
    let problems = engines.filter { SearchEngineDetail.problem(of: $0, in: engines) != nil }.count
    if problems > 0 { text += "；\(problems) 条要改一下" }
    return text
  }

  // MARK: 网页搜索与快捷链接列表（N12）

  /// 单击一行推进详情页，↑↓ 选中（给「−」和 ⌫ 用）、↩ 推进，拖动排序（和翻译服务列表同一套）
  private var engineList: some View {
    let list = engines
    return List(selection: OrderedList.selection($selection, open: open)) {
      ForEach(list) { engine in
        EngineListRow(
          engine: engine, problem: SearchEngineDetail.problem(of: engine, in: list),
          enabled: Binding {
            engine.enabled
          } set: {
            setFallback(engine.id, $0)
          },
          open: { open(engine.id) }, move: { move(engine.id, by: $0) }
        )
        .tag(engine.id)
      }
      .onMove { from, to in
        var list = engines
        list.move(fromOffsets: from, toOffset: to)
        engines = list
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .orderedListFrame(rows: list.count)
    .contextMenu(forSelectionType: String.self) { ids in
      if let id = ids.first {
        Button("编辑…") { open(id) }
        Divider()
        Button("上移") { move(id, by: -1) }.disabled(id == list.first?.id)
        Button("下移") { move(id, by: 1) }.disabled(id == list.last?.id)
        Divider()
        Button(SearchEngineDetail.isPreset(id) ? "删除" : "删除…", role: .destructive) {
          remove(id)
        }
      }
    } primaryAction: { ids in
      if let id = ids.first { open(id) }
    }
    .onDeleteCommand(perform: removeSelected)
  }

  /// 「+」：还没加的预置搜索，或新建一条自定义的（加进列表末尾、直接推进详情页填）
  private var addMenu: some View {
    Menu {
      let added = Set(engines.map(\.id))
      ForEach(WebSearch.presets.filter { !added.contains($0.id) }) { preset in
        Button("\(preset.name)（\(preset.keyword)）") { engines.append(preset) }
      }
      Divider()
      Button("自定义搜索或快捷链接…") {
        let engine = SearchEngine(
          id: "custom-" + UUID().uuidString.prefix(8), name: "", keyword: "",
          urlTemplate: "https://", enabled: false)
        engines.append(engine)
        open(engine.id)
      }
    } label: {
      Image(systemName: "plus")
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .accessibilityLabel("添加搜索或快捷链接")
    .help("添加搜索或快捷链接")
  }

  private var engines: [SearchEngine] {
    get { SearchEngineDetail.decode(enginesData) }
    nonmutating set { enginesData = SearchEngineDetail.encode(newValue) }
  }

  /// 行上的兜底开关（按 id 找，拖动排序后下标会变）
  private func setFallback(_ id: String, _ value: Bool) {
    var list = engines
    guard let index = list.firstIndex(where: { $0.id == id }) else { return }
    list[index].enabled = value
    engines = list
  }

  /// 推进编辑页（直接换掉路径：双击时第一下已经推进了，第二下的 primaryAction 不再叠一层）并清掉选中
  /// （↩ 推进后回来，再单击同一行时选中会变、才推得进去）
  private func open(_ id: String) {
    selection = nil
    navigation.path = [Self.route, id]
  }

  /// 右键菜单和无障碍动作里的上移 / 下移（键盘、读屏用户没法拖）；到头了什么都不做
  private func move(_ id: String, by offset: Int) {
    var list = engines
    guard let index = list.firstIndex(where: { $0.id == id }), list.indices.contains(index + offset)
    else { return }
    list.swapAt(index, index + offset)
    engines = list
  }

  /// 「−」、⌫、右键「删除」：预置的直接删（「+」里能加回来），自定义的先确认
  private func remove(_ id: String) {
    if SearchEngineDetail.isPreset(id) { delete(id) } else { removing = id }
  }

  private func delete(_ id: String) {
    engines.removeAll { $0.id == id }
    if selection == id { selection = nil }
  }

  private func removeSelected() {
    if let selection { remove(selection) }
  }
}

/// 一条搜索 / 快捷链接：种类色块、名称 + 状态（有问题时橙色说明）、关键词键帽、兜底开关（快捷链接没有，留位对齐）、
/// ›（只是提示能推进，点整行都推进）
private struct EngineListRow: View {
  let engine: SearchEngine
  let problem: String?
  let enabled: Binding<Bool>
  let open: () -> Void
  /// 上移（-1）/ 下移（+1）
  let move: (Int) -> Void

  var body: some View {
    let title = SearchEngineDetail.title(engine)
    HStack(spacing: 10) {
      SearchEngineDetail.tile(engine, size: 24)
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.system(size: 13))
          .foregroundStyle(
            engine.name.trimmingCharacters(in: .whitespaces).isEmpty ? .secondary : .primary)
        Text(problem ?? SearchEngineDetail.kindTitle(engine))
          .font(.system(size: 11))
          .foregroundStyle(OrderedList.statusStyle(isProblem: problem != nil))
      }
      .lineLimit(1)
      .truncationMode(.tail)
      .accessibilityElement(children: .combine)
      Spacer(minLength: 8)
      if !engine.keyword.isEmpty {
        KeyCap(engine.keyword)
          .accessibilityLabel("关键词 \(engine.keyword)")
      }
      Toggle("「\(title)」没有本地结果时兜底", isOn: enabled)
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.mini)
        .help("没有本地结果时用它搜索")
        // 快捷链接不参与兜底：藏起来但留位置，开关和键帽上下对齐
        .opacity(engine.isQuicklink ? 0 : 1)
        .disabled(engine.isQuicklink)
        .accessibilityHidden(engine.isQuicklink)
      Image(systemName: "chevron.forward")
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
    }
    .frame(height: OrderedList.rowHeight - 8)
    .accessibilityAction(named: "编辑", open)
    .accessibilityAction(named: "上移") { move(-1) }
    .accessibilityAction(named: "下移") { move(1) }
  }
}
