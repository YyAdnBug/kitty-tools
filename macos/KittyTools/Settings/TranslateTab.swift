// 设置 › 翻译：语言（第一 / 第二语言；源、目标只在浮窗顶部切换）、译文字号（真卡片实时预览，和浮窗 ⌘± 是同一个值）、
// 行为（浮窗位置、段内换行、复制即译、自动复制、历史保留条数、导出与清空），翻译服务列表（N12：行 = 图标 / 名称 /
// 状态 / 开关，拖动排序；「+」菜单加回没加的内置服务或新建 AI 服务（厂商预设，D15），「−」/ ⌫ 删：内置的直接删、
// 密钥留着，AI 服务先确认、连密钥一起删（体检 B21）；单击一行推进到 TranslateServiceDetail 改选项、密钥、测试连接）。
// 页头画在自己的 NavigationStack 里，推进时一起换掉。浮窗按键不写在这里（N11，进快捷键速查表）。
// 控件分工（Whisker §6）：2–3 项分段、3–5 项单选、> 5 项弹出菜单。

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TranslateTab: View {
  @Bindable var services: TranslateServiceStore
  let history: HistoryStore
  let speaker: Speaker
  @AppStorage(Prefs.translateFontScale) private var fontScale = 1.0
  @AppStorage(Prefs.translateSystemDictionary) private var systemDictionary = true
  @AppStorage(Prefs.translateWordMode) private var wordMode = true
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(Island.self) private var island: Island?
  @AppStorage(Prefs.translateFirst) private var first = Lang.zhHans.rawValue
  @AppStorage(Prefs.translateSecond) private var second = Lang.en.rawValue
  @AppStorage(Prefs.translateRemoveNewlines) private var removeNewlines = false
  /// 和翻译浮窗「⋯」菜单、状态胶囊、菜单栏的勾是同一个偏好
  @AppStorage(Prefs.translateCopyToTranslate) private var copyToTranslate = false
  @AppStorage(Prefs.translateAutoCopy) private var autoCopy = false
  @AppStorage(Prefs.translateHistoryEnabled) private var historyEnabled = true
  @AppStorage(Prefs.translateHistoryLimit) private var historyLimit = 5000
  @AppStorage(Prefs.translatePanelPosition) private var panelPosition = "mouse"
  /// 推进的详情页在 navigation.path（主菜单「返回」也要读写它）
  @Environment(SettingsNavigation.self) private var navigation
  /// 列表里用键盘选中的服务（「−」和 ⌫ 删它；鼠标单击直接推进，不留选中）
  @State private var selection: String?
  /// 等确认删除的自建 AI 服务
  @State private var removing: String?
  @State private var keysRevision = 0
  /// 刚从「+」新建的 AI 服务：推进的详情页把光标放进 API Key
  @State private var justAdded: String?
  @State private var confirmsClear = false

  var body: some View {
    NavigationStack(path: Bindable(navigation).path) {
      VStack(spacing: 0) {
        PageHeader(page: .translate)
        form
      }
      .navigationTitle(SettingsPage.translate.title)
      .navigationDestination(for: String.self) { id in
        TranslateServiceDetail(store: services, id: id, focusesKey: id == justAdded)
      }
    }
    .onChange(of: navigation.path) { keysRevision += 1 }
    .confirmationDialog(
      "删除「\(services.services.first { $0.id == removing }?.name ?? "")」？",
      isPresented: Binding {
        removing != nil
      } set: {
        if !$0 { removing = nil }
      }
    ) {
      Button("删除", role: .destructive) {
        if let removing { services.remove(removing) }
        selection = nil
      }
    } message: {
      Text("会同时删除它保存在钥匙串里的密钥")
    }
    .confirmationDialog("清空翻译历史？", isPresented: $confirmsClear) {
      Button("清空", role: .destructive) { HistoryMenu.clear(history, island: island) }
    } message: {
      Text("收藏的记录会保留")
    }
  }

  private var form: some View {
    Form {
      Section("语言") {
        Picker("第一语言", selection: $first) {
          ForEach(Lang.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
        }
        Picker("第二语言", selection: $second) {
          ForEach(Lang.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
        }
        Text(
          "目标语言选「自动」时：原文是第一语言就译成第二语言，否则译成第一语言（简繁中文算同一种）。"
            + "源语言和目标语言在翻译浮窗顶部切换，会一直记住。"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      // 两个选成同一种语言（简繁也算）就互换，免得「自动」变成中译中
      .onChange(of: first) { old, new in if sameLanguage(new, second) { second = old } }
      .onChange(of: second) { old, new in if sameLanguage(new, first) { first = old } }
      Section("译文字号") {
        LabeledContent {
          HStack(spacing: 10) {
            Slider(value: $fontScale, in: TranslateCoordinator.fontScales, step: 0.1)
              .tint(Style.brand)  // 根视图的 .accentColor 管不到滑块（实测），单独给
            Text(fontScale.formatted(.percent.precision(.fractionLength(0))))
              .font(.system(size: 12, weight: .medium)).monospacedDigit()
              .contentTransition(.numericText(value: fontScale))
              .frame(width: 40, alignment: .trailing)
          }
        } label: {
          Text("大小")
        }
        // 实时预览：浮窗里的同一张卡（第一个服务），字号跟着滑块变
        ProviderCardView(
          card: .init(service: services.services.first ?? .zhipu, state: .done(Self.sample)),
          index: 0, language: .zhHans, speaker: speaker, fontScale: fontScale, onRetry: {}
        )
        // 只是预览：上面的按钮（复制、重试、收起）不接点击
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: fontScale)
      }
      Section {
        Toggle("查单个词时显示系统词典的释义", isOn: $systemDictionary)
        Toggle("查单个词时大模型按词典回答（读音、词性、例句）", isOn: $wordMode)
      } header: {
        Text("查词")
      } footer: {
        HStack(alignment: .firstTextBaseline) {
          Text("系统词典默认给英文词英英释义：在「词典」App 的设置里勾上「牛津英汉汉英词典」并拖到最前面，就会显示中文释义。查单个词时不自动复制、不给「替换原文」。")
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer(minLength: 8)
          Button("打开「词典」") { NSWorkspace.shared.open(URL(string: "dict://")!) }
            .font(.caption)
        }
      }
      Section {
        Picker(selection: $panelPosition) {
          Text("跟随鼠标").tag("mouse")
          Text("上次位置").tag("last")
        } label: {
          Text("浮窗位置")
          Text("跟随鼠标：划词、截图翻译、复制即译时出现在光标旁边；输入翻译总在上次拖到的位置")
        }
        .pickerStyle(.segmented)
        Toggle("翻译前把同一段里的换行接起来（适合 PDF 复制的文字）", isOn: $removeNewlines)
        Toggle(isOn: $copyToTranslate) {
          Text("复制即译")
          Text("在别的 App 里复制外语文字，浮窗自动弹出翻译（网址、路径、数字和第一语言的文字不翻）")
        }
        Toggle("自动复制第一个服务的译文", isOn: $autoCopy)
          .help("复制即译弹出的翻译不会自动复制，免得覆盖你刚复制的原文")
        Toggle("记录翻译历史", isOn: $historyEnabled)
        Picker("历史最多保留", selection: $historyLimit) {
          Text("1000 条").tag(1000)
          Text("5000 条").tag(5000)
          Text("不限").tag(0)
        }
        .pickerStyle(.segmented)
        .disabled(!historyEnabled)
        LabeledContent("导出和清空") {
          HStack(spacing: 8) {
            Menu("导出…") {
              Section("全部历史") {
                Button("CSV（表格）…") { export(favoritesOnly: false, anki: false) }
                Button("TSV（Anki 卡片）…") { export(favoritesOnly: false, anki: true) }
              }
              Section("只导收藏（生词本）") {
                Button("CSV（表格）…") { export(favoritesOnly: true, anki: false) }
                Button("TSV（Anki 卡片）…") { export(favoritesOnly: true, anki: true) }
              }
            }
            .fixedSize()
            // 关着「记录翻译历史」也能清（旧记录还在），和浮窗「⋯」菜单同一个确认框、同一句结果
            Button("清空翻译历史…", role: .destructive) { confirmsClear = true }
          }
        }
      } header: {
        Text("行为")
      } footer: {
        HStack(alignment: .firstTextBaseline) {
          Text("收藏的记录不算在保留条数里、永不清理。划词来的翻译可以「替换原文」，浮窗里的按键见快捷键速查表。")
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer(minLength: 8)
          ShortcutsButton()
        }
      }
      Section {
        serviceList
        ListEditBar(
          removeTitle: "删除所选的服务", canRemove: selection != nil, remove: removeSelected
        ) {
          addMenu
        }
      } header: {
        Text("翻译服务")
      } footer: {
        OrderedList.footnote(
          "拖动调整顺序，结果按这个顺序显示，第一个服务的结果写入历史、用于自动复制；点一行进入设置。删掉的内置服务可以从「+」加回来，密钥还在。")
      }
    }
    .formStyle(.grouped)
  }

  private static let sample = "SwiftUI 提供了声明 App 界面所需的视图、控件和布局结构。"

  private func sameLanguage(_ a: String, _ b: String) -> Bool {
    guard let a = Lang(rawValue: a), let b = Lang(rawValue: b) else { return false }
    return a.isSameLanguage(as: b)
  }

  /// 导出翻译历史 / 收藏（和浮窗「⋯」菜单、历史 ⌘K 同一个 HistoryMenu.export）
  private func export(favoritesOnly: Bool, anki: Bool) {
    HistoryMenu.export(history, favoritesOnly: favoritesOnly, anki: anki, island: island)
  }

  /// 「+」（体检 B21 D15）：还没加的内置服务（18 pt 服务图标）｜「AI 服务」子菜单（厂商预设：名称、协议、地址填好）
  /// + 自定义 / Azure。选了就加到列表末尾、推进详情页（AI 服务光标落在 API Key）
  private var addMenu: some View {
    Menu {
      ForEach(services.missingBuiltins, id: \.self) { kind in
        let service = TranslateService.builtin(kind)
        Button {
          add(service)
        } label: {
          Label {
            Text(service.name)
          } icon: {
            ServiceTile.menuIcon(service)
          }
        }
      }
      if !services.missingBuiltins.isEmpty { Divider() }
      Menu("AI 服务") {
        ForEach(TranslateService.aiPresets) { preset in
          Button {
            add(preset.make(), focusesKey: true)
          } label: {
            Label {
              Text(preset.name)
            } icon: {
              ServiceTile.menuIcon(preset.make())
            }
          }
        }
        Divider()
        Button("自定义（OpenAI 兼容）…") { add(.newAI(), focusesKey: true) }
        Button("Azure OpenAI…") {
          var service = TranslateService.newAI()
          service.name = "Azure OpenAI"
          service.aiProtocol = .azure
          add(service, focusesKey: true)
        }
      }
    } label: {
      Image(systemName: "plus")
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .accessibilityLabel("添加翻译服务")
    .help("添加翻译服务")
  }

  /// 加一个服务：内置的直接启用（加回来就是要用；密钥是删之前留下的）、AI 服务等测试连接成功再自动启用；推进详情页
  private func add(_ service: TranslateService, focusesKey: Bool = false) {
    var service = service
    if service.kind != .ai { service.isEnabled = true }
    services.services.append(service)
    justAdded = focusesKey ? service.id : nil
    open(service.id)
  }

  /// 「−」、⌫、右键「删除」：内置的直接删（「+」里能加回来，密钥留着），AI 服务先确认（连密钥一起删）
  private func remove(_ id: String) {
    if isRemovable(id) {
      removing = id
    } else {
      services.remove(id)
      if selection == id { selection = nil }
    }
  }

  private func removeSelected() {
    if let selection { remove(selection) }
  }

  // MARK: 服务列表（N12）

  /// 单击一行推进详情页，↑↓ 选中（给「−」和 ⌫ 用）、↩ 推进，拖动排序（OrderedList.selection）
  private var serviceList: some View {
    List(selection: OrderedList.selection($selection, open: open)) {
      ForEach($services.services) { $service in
        ServiceListRow(
          service: $service, status: service.settingsStatus, open: { open(service.id) },
          move: { move(service.id, by: $0) }
        )
        .tag(service.id)
      }
      .onMove { services.services.move(fromOffsets: $0, toOffset: $1) }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .scrollDisabled(services.services.count <= OrderedList.visibleRows)
    .frame(height: OrderedList.height(rows: services.services.count))
    .contextMenu(forSelectionType: String.self) { ids in
      if let id = ids.first {
        Button("设置…") { open(id) }
        Divider()
        Button("上移") { move(id, by: -1) }.disabled(id == services.services.first?.id)
        Button("下移") { move(id, by: 1) }.disabled(id == services.services.last?.id)
        Divider()
        Button(isRemovable(id) ? "删除…" : "删除", role: .destructive) { remove(id) }
      }
    } primaryAction: { ids in
      if let id = ids.first { open(id) }
    }
    .onDeleteCommand(perform: removeSelected)
    // 从详情页回来时重建一次：行的状态读钥匙串，改了密钥不会让列表自己重画
    .id(keysRevision)
  }

  /// 推进详情页（直接换掉路径：双击时第一下已经推进了，第二下的 primaryAction 不再叠一层）
  /// 推进详情页并清掉选中（↩ 推进后回来，再单击同一行时选中会变、才推得进去）
  private func open(_ id: String) {
    selection = nil
    navigation.path = [id]
  }

  /// 右键菜单和无障碍动作里的上移 / 下移（键盘、读屏用户没法拖）；到头了什么都不做
  private func move(_ id: String, by offset: Int) {
    guard let index = services.services.firstIndex(where: { $0.id == id }),
      services.services.indices.contains(index + offset)
    else { return }
    services.services.swapAt(index, index + offset)
  }

  /// 删之前要确认的：自建的 AI 服务（连钥匙串里的密钥一起删）；内置服务直接删
  private func isRemovable(_ id: String) -> Bool {
    services.services.first { $0.id == id }?.kind == .ai
  }
}

/// 服务行：服务图标、名称 + 状态、启用开关、›（只是提示能推进，点整行都推进）
private struct ServiceListRow: View {
  @Binding var service: TranslateService
  let status: (text: String, isProblem: Bool)
  let open: () -> Void
  /// 上移（-1）/ 下移（+1）
  let move: (Int) -> Void

  var body: some View {
    HStack(spacing: 10) {
      ServiceTile(service: service, size: 24)
      VStack(alignment: .leading, spacing: 1) {
        Text(service.name).font(.system(size: 13))
        Text(status.text)
          .font(.system(size: 11))
          .foregroundStyle(OrderedList.statusStyle(isProblem: status.isProblem))
      }
      .lineLimit(1)
      .truncationMode(.tail)
      .accessibilityElement(children: .combine)
      Spacer(minLength: 8)
      Toggle("启用「\(service.name)」", isOn: $service.isEnabled)
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.small)
      Image(systemName: "chevron.forward")
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
    }
    .frame(height: OrderedList.rowHeight - 8)
    .accessibilityAction(named: "设置", open)
    .accessibilityAction(named: "上移") { move(-1) }
    .accessibilityAction(named: "下移") { move(1) }
  }
}
