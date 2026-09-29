// 设置 › 启动器：呼出时切英文输入法、文件搜索的文件夹授权、浏览器书签与历史（每家写读到了几条 / 没找到书签文件 /
// 没有安装，体检 B39；Chrome 下「也搜浏览历史」，默认关，体检 D8）、网页搜索与快捷链接
// （N12：行 = 网站图标或种类色块 / 名称 / 状态 / 关键词键帽 / 兜底开关，拖动排序，「+ −」增删（自定义的先确认），
// 单击一行推进到 SearchEngineDetail 编辑）、兜底时机、清空使用记录。页头画在自己的 NavigationStack 里，推进时一起换掉。
// 按键说明不写在这里（N11，进快捷键速查表）；启动器没有固定，失焦就收起（N8）。

import SwiftUI

struct LauncherTab: View {
  /// 清空使用记录（LauncherUsage.clearAll）
  var clearUsage: () -> Void = {}
  @AppStorage(Prefs.launcherRomanInput) private var romanInput = false
  @AppStorage(Prefs.launcherFallbackAlways) private var fallbackAlways = false
  @AppStorage(Prefs.launcherBookmarksChrome) private var chrome = true
  @AppStorage(Prefs.launcherBookmarksEdge) private var edge = false
  @AppStorage(Prefs.launcherBookmarksBrave) private var brave = false
  @AppStorage(Prefs.launcherHistoryChrome) private var chromeHistory = false
  /// 直接读写偏好里的 JSON，不留一份拷贝（设置窗常驻：别处改了偏好，拷贝会过期，再改一下就把别处的改动覆盖掉）
  @AppStorage(Prefs.launcherWebSearchEngines) private var enginesData: Data?
  /// 推进的详情页在 navigation.path（主菜单「返回」也要读写它）
  @Environment(SettingsNavigation.self) private var navigation
  /// 列表里用键盘选中的一条（「−」和 ⌫ 删它；鼠标单击直接推进，不留选中）
  @State private var selection: String?
  /// 等确认删除的自定义搜索 / 快捷链接
  @State private var removing: String?
  @State private var confirmsClear = false
  /// 文件搜索的文件夹授权：nil = 还没问过，否则是被拒绝的文件夹（出现、设置窗成为 key 时刷新；
  /// 不写成初始值：初始值每次重建视图都会求值，要去读受保护目录）
  @State private var deniedFolders: [String]?

  var body: some View {
    NavigationStack(path: Bindable(navigation).path) {
      VStack(spacing: 0) {
        PageHeader(page: .launcher)
        form
      }
      .navigationTitle(SettingsPage.launcher.title)
      .navigationDestination(for: String.self) { id in SearchEngineDetail(id: id) }
    }
    .onAppear { deniedFolders = Permissions.deniedFolders() }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
      deniedFolders = Permissions.deniedFolders()
    }
    .confirmationDialog("清空启动器的使用记录？", isPresented: $confirmsClear) {
      Button("清空", role: .destructive, action: clearUsage)
    } message: {
      Text("「常用」和按使用习惯的排序会从头开始学，收藏不动。")
    }
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

  private var form: some View {
    Form {
      Section {
        Toggle(isOn: $romanInput) {
          Text("呼出时切到英文输入法")
          Text("只在搜索框里生效，离开后恢复；要搜中文时先关掉")
        }
      } footer: {
        HStack(alignment: .firstTextBaseline) {
          caption(
            "搜 App、系统设置、文件、书签、网址、路径、算式（也能换算单位和进制）和系统命令（lock、quit、kill 这些），"
              + "↩ 打开，⌘K 看这一项的全部动作。")
          Spacer(minLength: 8)
          ShortcutsButton()
        }
      }
      Section {
        PermissionRow(
          title: "桌面、文稿、下载、iCloud 云盘", detail: folderDetail, symbol: "folder.fill",
          color: Style.Family.general, granted: deniedFolders == []
        ) {
          if deniedFolders == nil {
            deniedFolders = Permissions.requestFolderAccess()
          } else {
            Permissions.Kind.filesAndFolders.openSettings()
          }
        }
      } header: {
        Text("文件搜索")
      } footer: {
        caption(
          "「open 文件名」搜文件并打开，「find 文件名」在访达中显示；不想被搜到的文件夹加到系统设置 › Spotlight › 搜索隐私。")
      }
      Section("浏览器书签与历史") {
        bookmarkToggle(Bookmarks.browsers[0], isOn: $chrome)
        historyToggle
        bookmarkToggle(Bookmarks.browsers[1], isOn: $edge)
        bookmarkToggle(Bookmarks.browsers[2], isOn: $brave)
      }
      Section {
        engineList
        ListEditBar(
          removeTitle: "删除所选的一条", canRemove: selection != nil, remove: removeSelected
        ) {
          addMenu
        }
        Toggle("有本地结果时也显示兜底搜索", isOn: $fallbackAlways)
      } header: {
        Text("网页搜索与快捷链接")
      } footer: {
        caption(
          "网址里有 {query} 的是搜索（「关键词 空格 内容」直达，开关 = 没有本地结果时兜底），没有的是快捷链接。"
            + "拖动调整顺序，搜索的关键词重复时用靠前的；点一行编辑。")
      }
      Section {
        Button("清空使用记录…", role: .destructive) { confirmsClear = true }
      } header: {
        Text("使用记录")
      } footer: {
        caption(
          "启动器按用过的次数和时间排序，空搜索框里先列收藏（⌘D 加入），再列「常用」。在「常用」里选中一项按 ⌘⌫ 可以单独移除，⌘Z 撤销。")
      }
    }
    .formStyle(.grouped)
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
    .scrollDisabled(list.count <= OrderedList.visibleRows)
    .frame(height: OrderedList.height(rows: list.count))
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

  /// 推进详情页（直接换掉路径：双击时第一下已经推进了，第二下的 primaryAction 不再叠一层）
  /// 推进详情页并清掉选中（↩ 推进后回来，再单击同一行时选中会变、才推得进去）
  private func open(_ id: String) {
    selection = nil
    navigation.path = [id]
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

  /// 一家浏览器的书签开关：开着时下面一行写读到了几条，没读到（没有书签文件、文件里一条都没有）时橙字（配置问题的
  /// 语义色）；没装的置灰、显示关着（启动器也不搜它）。条数和启动器搜的是同一份缓存，文件没变不重读；关着的不读文件
  @ViewBuilder
  private func bookmarkToggle(_ browser: Bookmarks.Browser, isOn: Binding<Bool>) -> some View {
    let status = Bookmarks.status(of: browser, enabled: isOn.wrappedValue)
    Toggle(isOn: status == .notInstalled ? .constant(false) : isOn) {
      Text(browser.name)
      switch status {
      case .notInstalled: Text("没有安装")
      case .read(let count) where count > 0: Text("已读到 \(count) 条")
      case .noFile, .read:
        Text(status == .noFile ? "没找到书签文件" : "书签文件里一条书签都没有")
          .foregroundStyle(Color(nsColor: .systemOrange))
      case nil: EmptyView()
      }
    }
    .disabled(status == .notInstalled)
  }

  /// Chrome 下的「也搜浏览历史」（体检 D8，默认关）：Chrome 没装、书签开关关着时置灰、显示关着（书签关着时说明写原因）；
  /// 开着时下一行写读到了几条（同书签），打开时就去读（进程外，读完换上）
  @ViewBuilder private var historyToggle: some View {
    let installed = Bookmarks.isInstalled(Bookmarks.chrome)
    let available = chrome && installed
    let status = BrowserHistory.shared.status
    Toggle(isOn: available ? $chromeHistory : .constant(false)) {
      Text("也搜浏览历史")
      if available && chromeHistory {
        switch status {
        case .read(let count) where count > 0: Text("已读到 \(count) 条")
        case .noFile, .read:
          Text(status == .noFile ? "没找到浏览历史文件" : "浏览历史里还没有常去的网页")
            .foregroundStyle(Color(nsColor: .systemOrange))
        case .unknown: Text("正在读取…")
        }
      } else if installed && !chrome {
        Text("要先打开上面的 Chrome")
      } else {
        Text("去过两次以上或手输过的网页，排在书签后面")
      }
    }
    .disabled(!available)
    .task(id: available && chromeHistory) { await BrowserHistory.shared.refresh() }
  }

  private var folderDetail: String {
    switch deniedFolders {
    case nil: "还没允许：这些文件夹里的文件搜不到"
    case let denied? where denied.isEmpty: "都已允许"
    case let denied?: "没有权限：" + denied.joined(separator: "、") + "（去系统设置里打开）"
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
        .controlSize(.small)
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
