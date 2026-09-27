// 设置 › 翻译：语言（第一 / 第二语言；源、目标只在浮窗顶部切换）、译文字号（真卡片实时预览，和浮窗 ⌘± 是同一个值）、
// 行为（去换行、复制即译、自动复制、历史与导出），翻译服务列表（N12：行 = 图标 / 名称 / 状态 / 开关，拖动排序，
// 「+ −」增删自建 AI 实例，单击一行推进到 TranslateServiceDetail 改选项、密钥、测试连接）。
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
  @AppStorage(Prefs.translateHistoryLimit) private var historyLimit = 500
  /// 推进的详情页在 navigation.path（主菜单「返回」也要读写它）
  @Environment(SettingsNavigation.self) private var navigation
  /// 列表里用键盘选中的服务（「−」和 ⌫ 删它；鼠标单击直接推进，不留选中）
  @State private var selection: String?
  /// 等确认删除的自建 AI 服务
  @State private var removing: String?
  @State private var keysRevision = 0

  var body: some View {
    NavigationStack(path: Bindable(navigation).path) {
      VStack(spacing: 0) {
        PageHeader(page: .translate)
        form
      }
      .navigationTitle(SettingsPage.translate.title)
      .navigationDestination(for: String.self) { id in
        TranslateServiceDetail(store: services, id: id)
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
        Toggle("翻译前把换行合成一段（适合 PDF 复制的文字）", isOn: $removeNewlines)
        Toggle(isOn: $copyToTranslate) {
          Text("复制即译")
          Text("在别的 App 里复制文字，翻译浮窗自动弹出来翻译（不抢键盘）")
        }
        Toggle("自动复制第一个服务的译文", isOn: $autoCopy)
          .help("「复制即译」开着时不会自动复制，免得自己触发自己")
        Toggle("记录翻译历史", isOn: $historyEnabled)
        Picker("历史最多保留（条）", selection: $historyLimit) {
          ForEach([100, 200, 500, 1000, 2000], id: \.self) { Text(verbatim: "\($0)").tag($0) }
        }
        .pickerStyle(.radioGroup)
        .horizontalRadioGroupLayout()
        .disabled(!historyEnabled)
        LabeledContent("导出") {
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
        }
      } header: {
        Text("行为")
      } footer: {
        HStack(alignment: .firstTextBaseline) {
          Text("划词来的翻译可以「替换原文」，浮窗里的按键见快捷键速查表。")
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer(minLength: 8)
          ShortcutsButton()
        }
      }
      Section {
        serviceList
        ListEditBar(
          removeTitle: "删除所选的 AI 服务", canRemove: selection.map(isRemovable) ?? false,
          remove: { removing = selection }
        ) {
          Button("添加 AI 服务", systemImage: "plus") {
            let service = TranslateService.newAI()
            services.services.append(service)
            open(service.id)
          }
          .labelStyle(.iconOnly)
          .help("添加 AI 服务（OpenAI 兼容 / Azure / Anthropic）")
        }
      } header: {
        Text("翻译服务")
      } footer: {
        OrderedList.footnote(
          "拖动调整顺序，结果按这个顺序显示，第一个服务的结果写入历史、用于自动复制；点一行进入设置。")
      }
    }
    .formStyle(.grouped)
  }

  private static let sample = "SwiftUI 提供了声明 App 界面所需的视图、控件和布局结构。"

  private func sameLanguage(_ a: String, _ b: String) -> Bool {
    guard let a = Lang(rawValue: a), let b = Lang(rawValue: b) else { return false }
    return a.isSameLanguage(as: b)
  }

  /// 导出翻译历史 / 收藏：CSV 给表格（带 BOM，Excel 才认 UTF-8），TSV 给 Anki（正面原文、背面译文）。
  /// 结果（含没东西可导、写失败）用刘海说
  private func export(favoritesOnly: Bool, anki: Bool) {
    let entries = history.search("", favoritesOnly: favoritesOnly, limit: 0)
    guard !entries.isEmpty else {
      island?.show(favoritesOnly ? "还没有收藏" : "还没有翻译历史", detail: "没有可导出的记录", tone: .warning)
      return
    }
    let island = island
    let panel = NSSavePanel()
    panel.allowedContentTypes = [anki ? .tabSeparatedText : .commaSeparatedText]
    panel.nameFieldStringValue = (favoritesOnly ? "翻译收藏" : "翻译历史") + (anki ? ".tsv" : ".csv")
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      let text = anki ? HistoryStore.tsv(entries) : "\u{FEFF}" + HistoryStore.csv(entries)
      do {
        try text.write(to: url, atomically: true, encoding: .utf8)
        island?.show(
          "已导出 \(entries.count) 条", detail: url.lastPathComponent, symbol: "square.and.arrow.up")
      } catch {
        island?.show("导出失败", detail: error.localizedDescription, tone: .error)
      }
    }
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
        if isRemovable(id) {
          Divider()
          Button("删除…", role: .destructive) { removing = id }
        }
      }
    } primaryAction: { ids in
      if let id = ids.first { open(id) }
    }
    .onDeleteCommand { if let selection, isRemovable(selection) { removing = selection } }
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

  /// 只有自建的 AI 服务能删；内置服务只能关掉
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
