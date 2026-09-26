// 设置 › 启动器：点外关闭、呼出时切英文输入法、浏览器书签、网页搜索与快捷链接（增删、排序、关键词、兜底）、
// 兜底时机、清空使用记录；说明里写键位和文件搜索（open / find，排除目录走系统 Spotlight 隐私）。快捷键在「快捷键」页。

import SwiftUI

struct LauncherTab: View {
  /// 清空使用记录（LauncherUsage.clearAll）
  var clearUsage: () -> Void = {}
  @AppStorage(Prefs.launcherHideOnUnfocus) private var hideOnUnfocus = true
  @AppStorage(Prefs.launcherRomanInput) private var romanInput = false
  @AppStorage(Prefs.launcherSqueezeEntrance) private var squeezeEntrance = false
  @AppStorage(Prefs.launcherFallbackAlways) private var fallbackAlways = false
  @AppStorage(Prefs.launcherBookmarksChrome) private var chrome = true
  @AppStorage(Prefs.launcherBookmarksEdge) private var edge = false
  @AppStorage(Prefs.launcherBookmarksBrave) private var brave = false
  /// 直接读写偏好里的 JSON，不留一份拷贝（设置窗常驻：导入旧版后拷贝会过期，再改一下就把导入的覆盖掉）
  @AppStorage(Prefs.launcherWebSearchEngines) private var enginesData: Data?
  @State private var editing: Draft?
  @State private var confirmsClear = false
  /// 文件搜索的文件夹授权：nil = 还没问过，否则是被拒绝的文件夹（出现、设置窗成为 key 时刷新；
  /// 不写成初始值：初始值每次重建视图都会求值，要去读受保护目录）
  @State private var deniedFolders: [String]?

  /// 编辑中的一条（新建或改已有的）
  private struct Draft: Identifiable {
    var engine: SearchEngine
    let isNew: Bool
    var id: String { engine.id }
  }

  var body: some View {
    Form {
      Section {
        Toggle("点面板外面时自动关闭", isOn: $hideOnUnfocus)
        Toggle("呼出时切到英文输入法", isOn: $romanInput)
        Toggle(isOn: $squeezeEntrance) {
          Text("呼出时挤压弹开（实验）")
          Text("像 macOS 26 的聚焦搜索：从窄一点、矮一点弹开到原尺寸；减弱动态效果时不弹")
        }
      } footer: {
        caption(
          "↩ 打开（计算结果、cb 是粘贴），⌘↩ 在访达中显示（计算结果、cb 只复制），⌥↩ 在访达里搜索，⌃↩ 网页搜索，"
            + "Tab 补全（计算结果接着算、目录接着往下找），⌘C 复制路径或网址，⌘1–9 打开第几项，Esc 先清空再关闭。"
            + "输入网址或 / ~ 开头的路径可直接打开；输入算式得到计算结果；「cb 关键词」搜剪贴板里的文本。"
            + "切英文输入法只在搜索框里生效，离开后恢复；要搜中文时先关掉。")
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
          "「open 文件名」或空格开头搜文件并打开，「find 文件名」搜文件并在访达中显示（⌘↩ 反过来），只输 open 列出最近打开和下载的文件。"
            + "Spotlight 只给本 App 能访问的文件夹里的结果，所以桌面、文稿、下载、iCloud 云盘要先允许访问（系统会逐个询问）；"
            + "不想被搜到的文件夹加到系统设置 › Spotlight › 搜索隐私。")
      }
      Section("浏览器书签") {
        Toggle("Chrome", isOn: $chrome)
        Toggle("Edge", isOn: $edge)
        Toggle("Brave", isOn: $brave)
      }
      Section {
        ForEach(engines) { $engine in
          EngineRow(
            engine: $engine, duplicate: duplicate(of: engine),
            canMoveUp: engine.id != engines.wrappedValue.first?.id,
            canMoveDown: engine.id != engines.wrappedValue.last?.id
          ) { offset in
            move(engine.id, by: offset)
          } onEdit: {
            editing = Draft(engine: engine, isNew: false)
          }
        }
        addMenu
        Toggle("有本地结果时也显示兜底搜索", isOn: $fallbackAlways)
      } header: {
        Text("网页搜索与快捷链接")
      } footer: {
        caption(
          "网址里写 {query} 的是搜索：输入「关键词 空格 内容」直接搜，勾了「兜底」的在没有本地结果时按列表顺序出现，⌃↩ 用第一个。"
            + "不写 {query} 的是快捷链接：搜名字或关键词打开固定网址（也可以填 / 或 ~ 开头的路径）。关键词重复时用靠前的那个。")
      }
      Section {
        Button("清空使用记录…", role: .destructive) { confirmsClear = true }
      } header: {
        Text("使用记录")
      } footer: {
        caption("启动器按用过的次数和时间排序、列出「最近使用」。在「最近使用」里选中一项按 ⌘⌫ 可以单独移除。")
      }
    }
    .formStyle(.grouped)
    .onAppear { deniedFolders = Permissions.deniedFolders() }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
      deniedFolders = Permissions.deniedFolders()
    }
    .sheet(item: $editing) { draft in
      EngineEditor(engine: draft.engine, isNew: draft.isNew) { saved in
        var list = engines.wrappedValue
        if let index = list.firstIndex(where: { $0.id == saved.id }) {
          list[index] = saved
        } else {
          list.append(saved)
        }
        engines.wrappedValue = list
      } onDelete: {
        engines.wrappedValue.removeAll { $0.id == draft.engine.id }
      }
    }
    .confirmationDialog("清空启动器的使用记录？", isPresented: $confirmsClear) {
      Button("清空", role: .destructive, action: clearUsage)
    } message: {
      Text("「最近使用」和按使用习惯的排序会从头开始学。")
    }
  }

  private var addMenu: some View {
    Menu {
      let added = Set(engines.wrappedValue.map(\.id))
      ForEach(WebSearch.presets.filter { !added.contains($0.id) }) { preset in
        Button("\(preset.name)（\(preset.keyword)）") { engines.wrappedValue.append(preset) }
      }
      Divider()
      Button("自定义搜索或快捷链接…") {
        editing = Draft(
          engine: SearchEngine(
            id: "custom-" + UUID().uuidString.prefix(8), name: "", keyword: "",
            urlTemplate: "https://", enabled: false), isNew: true)
      }
    } label: {
      Label("添加", systemImage: "plus")
    }
    .fixedSize()
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

  private func move(_ id: String, by offset: Int) {
    var list = engines.wrappedValue
    guard let index = list.firstIndex(where: { $0.id == id }), list.indices.contains(index + offset)
    else { return }
    list.swapAt(index, index + offset)
    engines.wrappedValue = list
  }

  private var folderDetail: String {
    switch deniedFolders {
    case nil: "还没允许：这些文件夹里的文件搜不到"
    case let denied? where denied.isEmpty: "都已允许"
    case let denied?: "没有权限：" + denied.joined(separator: "、") + "（去系统设置里打开）"
    }
  }

  /// 关键词和排在前面的一条重复（或是保留的 cb）时，返回提示里说的名字（只提示，不替用户改）
  private func duplicate(of engine: SearchEngine) -> String? {
    let keyword = engine.keyword.lowercased()
    guard !keyword.isEmpty else { return nil }
    if let owner = WebSearch.reservedKeywords[keyword] { return owner }
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

private struct EngineRow: View {
  @Binding var engine: SearchEngine
  let duplicate: String?
  let canMoveUp: Bool
  let canMoveDown: Bool
  let onMove: (Int) -> Void
  let onEdit: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: engine.isQuicklink ? "link" : "magnifyingglass")
        .foregroundStyle(.tint)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 1) {
        Text(engine.name).lineLimit(1)
        Text(engine.urlTemplate)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer(minLength: 6)
      if let duplicate {
        Text("与\(duplicate)重复").font(.caption).foregroundStyle(.red)
      }
      TextField("关键词", text: $engine.keyword, prompt: Text("关键词"))
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
        .frame(width: 64)
      Toggle("兜底", isOn: $engine.enabled)
        .toggleStyle(.checkbox)
        .disabled(engine.isQuicklink)
        .help(engine.isQuicklink ? "快捷链接不参与兜底" : "没有本地结果时用它搜索")
      Group {
        Button("上移", systemImage: "chevron.up") { onMove(-1) }.disabled(!canMoveUp)
        Button("下移", systemImage: "chevron.down") { onMove(1) }.disabled(!canMoveDown)
        Button("编辑", systemImage: "slider.horizontal.3", action: onEdit)
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
    }
  }
}

/// 新建 / 编辑一条搜索或快捷链接（sheet）
private struct EngineEditor: View {
  @State var engine: SearchEngine
  let isNew: Bool
  let onSave: (SearchEngine) -> Void
  let onDelete: () -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(isNew ? "添加搜索或快捷链接" : "编辑「\(engine.name)」").font(.headline)
      Form {
        TextField("名称", text: $engine.name)
        TextField("关键词", text: $engine.keyword, prompt: Text("可不填"))
        TextField(
          "网址", text: $engine.urlTemplate, prompt: Text("https://example.com/search?q={query}"))
        if !engine.isQuicklink {
          Toggle("没有本地结果时用它兜底", isOn: $engine.enabled)
        }
      }
      Text(
        engine.isQuicklink
          ? "没有 {query}：快捷链接，搜名字或关键词直接打开这个网址（或 / ~ 开头的路径）。"
          : "有 {query}：搜索，输入「关键词 空格 内容」时内容替换进 {query}。不填关键词就要勾兜底，不然用不上。"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      HStack {
        if !isNew {
          Button("删除", role: .destructive) {
            onDelete()
            dismiss()
          }
        }
        Spacer()
        Button("取消", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("保存") {
          var saved = engine
          saved.name = saved.name.trimmingCharacters(in: .whitespaces)
          saved.urlTemplate = saved.urlTemplate.trimmingCharacters(in: .whitespaces)
          onSave(saved)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!isValid)
      }
    }
    .padding(20)
    .frame(width: 440)
  }

  /// 名称不空；搜索的网址要有协议（https:、maps: 之类）、还得有关键词或勾兜底（不然哪儿都用不上）；
  /// 快捷链接可以是网址，也可以是 / ~ 开头的路径（路径里替换搜索词打不开，所以搜索不收路径）；关键词不能是 cb
  private var isValid: Bool {
    let url = engine.urlTemplate.trimmingCharacters(in: .whitespaces)
    // 有协议；http(s) 还得有主机名（默认的「https://」不算填好）
    let parsed = URL(string: url.replacing("{query}", with: "q"))
    let hasScheme =
      parsed?.scheme.map {
        $0.count > 1 && (!["http", "https"].contains($0.lowercased()) || parsed?.host() != nil)
      } ?? false
    let keyword = engine.keyword.trimmingCharacters(in: .whitespaces).lowercased()
    guard !engine.name.trimmingCharacters(in: .whitespaces).isEmpty,
      WebSearch.reservedKeywords[keyword] == nil
    else { return false }
    if engine.isQuicklink { return hasScheme || url.hasPrefix("/") || url.hasPrefix("~") }
    return hasScheme && (!keyword.isEmpty || engine.enabled)
  }
}
