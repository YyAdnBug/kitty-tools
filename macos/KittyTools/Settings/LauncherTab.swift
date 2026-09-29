// 设置 › 启动器：呼出时切英文输入法、文件搜索的文件夹授权、浏览器书签与历史（第 12 批：只列本机装了的，每家一行
// 16 pt App 图标 + 名字 + 书签开关，写读到了几条 / 没找到书签文件 / 需要完全磁盘访问权限（体检 B39）；开着时下面缩进
// 一行「也搜浏览历史」，默认关，体检 D8）、网页搜索与快捷链接
// （N12：行 = 网站图标或种类色块 / 名称 / 状态 / 关键词键帽 / 兜底开关，拖动排序，「+ −」增删（自定义的先确认），
// 单击一行推进到 SearchEngineDetail 编辑）、兜底时机、清空使用记录。页头画在自己的 NavigationStack 里，推进时一起换掉。
// 按键说明不写在这里（N11，进快捷键速查表）；启动器没有固定，失焦就收起（N8）。

import SwiftUI

struct LauncherTab: View {
  /// 清空使用记录（LauncherUsage.clearAll）
  var clearUsage: () -> Void = {}
  @AppStorage(Prefs.launcherRomanInput) private var romanInput = false
  @AppStorage(Prefs.launcherFallbackAlways) private var fallbackAlways = false
  /// 书签 / 浏览历史开着的浏览器 id（换行分隔，Browsers.ids 拆）
  @AppStorage(Prefs.launcherBrowserBookmarks) private var bookmarkIDs = Prefs.defaultBookmarkIDs
  @AppStorage(Prefs.launcherBrowserHistory) private var historyIDs = ""
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
  /// 本机装了的浏览器和它的 App 位置（出现、设置窗变成 key 时重查；不写成初始值，同上）
  @State private var browsers: [(browser: Browsers.Browser, app: URL)] = []
  /// 设置窗变成 key 时加一：页面重画（书签条数重读）、浏览历史重读一次（去系统设置给了完全磁盘访问权限回来就能看到）
  @State private var checks = 0

  var body: some View {
    NavigationStack(path: Bindable(navigation).path) {
      VStack(spacing: 0) {
        PageHeader(page: .launcher)
        form
      }
      .navigationTitle(SettingsPage.launcher.title)
      .navigationDestination(for: String.self) { id in SearchEngineDetail(id: id) }
    }
    .onAppear(perform: recheck)
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
      recheck()
    }
    // 开关变了、设置窗重新变 key：该读的浏览历史 / Firefox 书签在进程外读，关掉的扔掉
    .task(id: "\(bookmarkIDs)|\(historyIDs)|\(checks)") { await BrowserHistory.shared.refresh() }
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
      Section {
        ForEach(browsers, id: \.browser.id) { browserRows($0.browser, app: $0.app) }
      } header: {
        Text("浏览器书签与历史")
      } footer: {
        caption("只列本机装了的浏览器。")
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

  private func recheck() {
    deniedFolders = Permissions.deniedFolders()
    browsers = Browsers.installed()
    checks += 1
  }

  /// 一家浏览器：图标 + 名字 + 书签开关，开着时下面写读到了几条，没读到（没有书签文件、文件里一条都没有、没授权）
  /// 橙字（配置问题的语义色）；Safari 没授权时右边「去授权…」，下面一行说明怎么加。条数和启动器搜的是同一份缓存，
  /// 文件没变不重读；关着的不读文件。书签开着时下面缩进一行「也搜浏览历史」（体检 D8，默认关）
  @ViewBuilder
  private func browserRows(_ browser: Browsers.Browser, app: URL) -> some View {
    let bookmarks = binding(for: browser, in: $bookmarkIDs)
    let status = bookmarks.wrappedValue ? Bookmarks.status(of: browser) : nil
    Toggle(isOn: bookmarks) {
      // 图标、「去授权…」都对着名字那一行（开关也是）；图标 16 + 间距 8 = 下面「也搜浏览历史」缩进的 24
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
          .resizable()
          .frame(width: 16, height: 16)
          .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }  // 图标中线落在字的中线上
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(browser.name)
          Group {
            if let status {
              statusText(
                status, noun: "书签", empty: "书签文件里一条书签都没有", missing: "没找到书签文件")
            }
            if status == .needsAccess { Text("在列表里点 +，选中 Kitty Tools") }
          }
          .font(.subheadline)
          .foregroundStyle(.secondary)
        }
        if status == .needsAccess {
          Spacer(minLength: 8)
          Button("去授权…", action: Permissions.Kind.fullDiskAccess.openSettings)
        }
      }
    }
    // 读屏在开关上也能直接去授权（按钮在开关的标签里）
    .accessibilityActions {
      if status == .needsAccess {
        Button("去授权…", action: Permissions.Kind.fullDiskAccess.openSettings)
      }
    }
    if bookmarks.wrappedValue {
      let history = binding(for: browser, in: $historyIDs)
      Toggle(isOn: history) {
        // 每家下面都有这一行：读屏跳着找开关时要听得出是哪家的
        Text("也搜浏览历史").accessibilityLabel("也搜 \(browser.name) 的浏览历史")
        if history.wrappedValue {
          statusText(
            BrowserHistory.shared.status(.init(browser: browser, kind: .history)), noun: "历史",
            empty: "浏览历史里还没有常去的网页", missing: "没找到浏览历史文件")
        } else {
          // Safari 的库没有「手输过」这一项，只按访问次数
          Text(
            browser.format == .safari
              ? "去过两次以上的网页，排在书签后面" : "去过两次以上或手输过的网页，排在书签后面")
        }
      }
      .padding(.leading, 24)
    }
  }

  /// 开关 ↔ 偏好里的 id 列表
  private func binding(for browser: Browsers.Browser, in ids: Binding<String>) -> Binding<Bool> {
    Binding {
      Browsers.ids(ids.wrappedValue).contains(browser.id)
    } set: {
      ids.wrappedValue = Browsers.setting(browser.id, on: $0, in: ids.wrappedValue)
    }
  }

  /// 开关下的一行：「已读到 N 条书签」；没读到、没授权是橙字
  @ViewBuilder
  private func statusText(_ status: Browsers.Status, noun: String, empty: String, missing: String)
    -> some View
  {
    switch status {
    case .reading: Text("正在读取…")
    case .read(let count) where count > 0: Text("已读到 \(count) 条\(noun)")
    case .read: problem(empty)
    case .noFile: problem(missing)
    case .needsAccess: problem("需要完全磁盘访问权限")
    }
  }

  private func problem(_ text: String) -> some View {
    Text(text).foregroundStyle(Color(nsColor: .systemOrange))
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
