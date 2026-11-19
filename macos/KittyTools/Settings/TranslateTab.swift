// 设置 › 翻译（2026-11-18 设置改版 S4）：外面是语言（第一 / 第二语言；源、目标只在浮窗顶部切换）、翻译服务列表（N12：
// 行 = 图标 / 名称 / 状态 / 开关，拖动排序；「+」菜单加回没加的内置服务或新建 AI 服务（厂商预设，D15），「−」/ ⌫ 删：
// 内置的直接删、密钥留着，AI 服务先确认、连密钥一起删（体检 B21）；单击一行推进到 TranslateServiceDetail）、
// 行为（复制即译、自动复制译文、浮窗位置），「查词与朗读 ›」「翻译历史 ›」两个子页，按键行。
// 「查词与朗读」：系统词典、大模型按词典回答、打开「词典」、英文单词发音（真人 / 系统声音 × 美音 / 英音合成一个选单，S6）、
// 朗读速度。「翻译历史」：记不记、保留条数、导出、清空（关着翻译也能导出、清空）。
// 「高级…」：译文字号（真卡片实时预览，和浮窗 ⌘± 是同一个值）、面板大小、段内换行、截图翻译盖回截图、截图翻译复制原文。
// 页头画在自己的 NavigationStack 里，推进时一起换掉。控件分工（Whisker §6）：2–3 项分段、3–5 项单选、> 5 项弹出菜单。

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TranslateTab: View {
  @Bindable var services: TranslateServiceStore
  let history: HistoryStore
  let speaker: Speaker
  /// 截图自检直接画「高级…」表单（sheet 画不进屏外截图）
  var drawsAdvanced = false
  @AppStorage(Prefs.translateFontScale) private var fontScale = 1.0
  @AppStorage(Prefs.translateSystemDictionary) private var systemDictionary = true
  @AppStorage(Prefs.translateWordMode) private var wordMode = true
  @AppStorage(Prefs.translateWordRecording) private var wordRecording = true
  @AppStorage(Prefs.translateWordAccent) private var wordAccent = "us"
  @AppStorage(Prefs.translateSpeechSpeed) private var speechSpeed = 1.0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(Island.self) private var island: Island?
  @AppStorage(Prefs.translateFirst) private var first = Lang.zhHans.rawValue
  @AppStorage(Prefs.translateSecond) private var second = Lang.en.rawValue
  @AppStorage(Prefs.translateRemoveNewlines) private var removeNewlines = false
  /// 和翻译浮窗「⋯」菜单、状态胶囊、菜单栏的勾是同一个偏好
  @AppStorage(Prefs.translateCopyToTranslate) private var copyToTranslate = false
  @AppStorage(Prefs.translateAutoCopy) private var autoCopy = false
  @AppStorage(Prefs.translateCopyRecognized) private var copyRecognized = false
  @AppStorage(Prefs.translateScreenshotOverlay) private var screenshotOverlay = false
  @AppStorage(Prefs.translateHistoryEnabled) private var historyEnabled = true
  @AppStorage(Prefs.translateHistoryLimit) private var historyLimit = 5000
  @AppStorage(Prefs.translatePanelPosition) private var panelPosition = "top"
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
        switch SettingsSubpage(route: id) {
        case .translateLookup?: lookupPage
        case .translateHistory?: historyPage
        default: TranslateServiceDetail(store: services, id: id, focusesKey: id == justAdded)
        }
      }
      .advancedSheet(.translate, summary: "字号、换行和截图翻译", inline: drawsAdvanced) { advanced }
    }
    .onChange(of: navigation.path) { keysRevision += 1 }
    .confirmationDialog(
      "删除「\(services.services.first { $0.id == removing }?.displayName ?? "")」？",
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

  /// 外面：语言、翻译服务、行为、两个子页、按键、高级…
  private var form: some View {
    Form {
      Section { FeatureToggle(feature: .translate, inPage: true) }
      Group {
        Section {
          Picker("第一语言", selection: $first) {
            ForEach(Lang.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
          }
          .settingsAnchor(.translateFirst)
          Picker("第二语言", selection: $second) {
            ForEach(Lang.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
          }
          .settingsAnchor(.translateSecond)
        } header: {
          InfoHeader(
            "语言",
            info:
              "目标语言选「自动」时：原文是第一语言就译成第二语言，否则译成第一语言（简繁中文算同一种）。源语言和目标语言在翻译浮窗顶部切换，会一直记住。"
          )
        }
        // 两个选成同一种语言（简繁也算）就互换，免得「自动」变成中译中
        .onChange(of: first) { old, new in if sameLanguage(new, second) { second = old } }
        .onChange(of: second) { old, new in if sameLanguage(new, first) { first = old } }
        Section {
          serviceList
          ListEditBar(
            removeTitle: "删除所选的服务", canRemove: selection != nil, remove: removeSelected
          ) {
            addMenu
          }
        } header: {
          InfoHeader(
            "翻译服务",
            info:
              "拖动调整顺序，结果按这个顺序显示；排在最前、翻译成功的那个服务的结果写入历史、用于自动复制和收藏。点一行进入设置。删掉的内置服务可以从「+」加回来，密钥还在。"
          )
          .settingsAnchor(.translateServices)
        }
        Section("行为") {
          SettingRow(title: "复制即译", subtitle: "复制文字就弹出翻译", info: "网址、路径和数字不翻。") {
            Toggle("复制即译", isOn: $copyToTranslate)
              .toggleStyle(.switch)
          }
          .settingsAnchor(.translateCopyToTranslate)
          SettingRow(title: "自动复制译文", info: "复制即译弹出的翻译不会自动复制，免得覆盖你刚复制的原文。") {
            Toggle("自动复制译文", isOn: $autoCopy)
              .toggleStyle(.switch)
          }
          .settingsAnchor(.translateAutoCopy)
          SettingRow(
            title: "浮窗位置",
            info: "划词、截图翻译、复制即译时出现的位置：屏幕上方是鼠标所在屏幕的上方正中，跟随鼠标是光标旁边；输入翻译总在上次拖到的位置。"
          ) {
            Picker("浮窗位置", selection: $panelPosition) {
              Text("屏幕上方").tag("top")
              Text("跟随鼠标").tag("mouse")
              Text("上次位置").tag("last")
            }
            .pickerStyle(.segmented)
          }
          .settingsAnchor(.translatePanelPosition)
        }
        Section {
          SettingsPushRow(
            title: SettingsSubpage.translateLookup.title,
            isNew: SettingsItem.subpageIsNew(.translateLookup, fresh: navigation.fresh),
            value: Self.lookupValue(dictionary: systemDictionary, voice: wordVoice.wrappedValue)
          ) {
            navigation.path = [SettingsSubpage.translateLookup.route]
          }
        }
      }
      .gated(by: .translate)
      // 翻译历史管的是已有的数据（保留条数、导出、清空）：功能关着也能进去
      Section {
        SettingsPushRow(
          title: SettingsSubpage.translateHistory.title,
          isNew: SettingsItem.subpageIsNew(.translateHistory, fresh: navigation.fresh),
          value: Self.historyValue(enabled: historyEnabled, limit: historyLimit)
        ) {
          navigation.path = [SettingsSubpage.translateHistory.route]
        }
      }
      Section {
        SettingRow(
          title: "翻译浮窗里的按键", subtitle: "↩ 翻译，⌘1–9 复制结果，⌘Y 看历史",
          info: "⌘R 重新翻译；划词来的翻译可以「替换原文」。"
        ) {
          ShortcutsButton()
        }
        .settingsAnchor(.translateKeys)
      }
      .gated(by: .translate)
      Section {
      } footer: {
        AdvancedButton(page: .translate)
      }
    }
    .formStyle(.grouped)
    .settingsScrollTarget()
  }

  /// 设置 › 翻译 › 查词与朗读
  private var lookupPage: some View {
    SubpageForm(
      subpage: .translateLookup,
      status: Self.lookupValue(dictionary: systemDictionary, voice: wordVoice.wrappedValue)
    ) {
      Section {
        SettingRow(title: "查单个词时显示系统词典的释义", info: "查单个词时不自动复制、不给「替换原文」。") {
          Toggle("查单个词时显示系统词典的释义", isOn: $systemDictionary)
            .toggleStyle(.switch)
        }
        .settingsAnchor(.translateSystemDictionary)
        Toggle("查单个词时大模型按词典回答（读音、词性、例句）", isOn: $wordMode)
          .settingsAnchor(.translateWordMode)
        SettingRow(
          title: "系统词典的中文释义", subtitle: "想看中文释义，在「词典」里换词典",
          info: "默认给英文词英英释义；在「词典」App 的设置里勾上「牛津英汉汉英词典」并拖到最前面，就会显示中文释义。"
        ) {
          Button("打开「词典」") { NSWorkspace.shared.open(URL(string: "dict://")!) }
        }
        .settingsAnchor(.translateDictionaryApp)
      } header: {
        Text("查词")
      }
      .gated(by: .translate)
      Section {
        SettingRow(
          title: "英文单词发音", subtitle: "真人发音会把单词发给有道",
          info: "取不到时用系统声音。句子用系统声音，可以在 系统设置 › 辅助功能 › 朗读内容 里下载音质更好的声音。"
        ) {
          Picker("英文单词发音", selection: wordVoice) {
            ForEach(WordVoice.allCases, id: \.self) { Text(plain: $0.title).tag($0) }
          }
        }
        .settingsAnchor(.translatePronunciation)
        // 四档横排单选（3–5 项，mac-whisker-settings）；导入、同步来的怪值显示成最近的一档（Speaker.speed）
        LabeledContent {
          Picker(
            selection: Binding {
              Speaker.speed(speechSpeed)
            } set: {
              speechSpeed = $0
            }
          ) {
            ForEach(Speaker.speeds, id: \.self) { speed in
              (speed == 1 ? Text("正常") : Text(verbatim: speed.formatted() + "×")).tag(speed)
            }
          } label: {
            Text("朗读速度")
          }
          .pickerStyle(.radioGroup)
          .horizontalRadioGroupLayout()
          .labelsHidden()
          .fixedSize()
        } label: {
          HStack(spacing: 6) {
            Text("朗读速度")
            if WhatsNew.marks(section: "朗读速度", of: .translate, in: navigation.fresh) { NewTag() }
          }
          Text("原文、译文和单词的小喇叭都按它读，练听力可以放慢")
        }
        .onChange(of: speechSpeed) { WhatsNew.touch(section: "朗读速度", of: .translate) }
        .settingsAnchor(.translateSpeechSpeed)
      } header: {
        Text("朗读")
      }
      .gated(by: .translate)
    }
  }

  /// 设置 › 翻译 › 翻译历史（关着翻译也能导出、清空，保留条数照常能改）
  private var historyPage: some View {
    SubpageForm(
      subpage: .translateHistory,
      status: Self.historyValue(enabled: historyEnabled, limit: historyLimit)
    ) {
      Section {
        Toggle("记录翻译历史", isOn: $historyEnabled)
          .gated(by: .translate)
          .settingsAnchor(.translateHistory)
        SettingRow(title: "历史最多保留", info: "收藏的记录不算在保留条数里、永不清理。") {
          Picker("历史最多保留", selection: $historyLimit) {
            // 档位和 Prefs.migrate 读同一张表：旧档位迁过来，不会显示成空白
            ForEach(Prefs.translateHistoryLimitChoices, id: \.self) {
              Text($0 == 0 ? "不限" : "\($0) 条").tag($0)
            }
          }
          .pickerStyle(.segmented)
        }
        .disabled(!historyEnabled)
        .settingsAnchor(.translateHistoryLimit)
        LabeledContent("导出和清空") {
          HStack(spacing: 8) {
            Menu("导出…") { HistoryExportItems(history: history, island: island) }
              .fixedSize()
            // 关着「记录翻译历史」也能清（旧记录还在），和浮窗「⋯」菜单同一个确认框、同一句结果
            DangerButton("清空翻译历史…") { confirmsClear = true }
          }
        }
        .settingsAnchor(.translateHistoryExport)
      }
    }
  }

  /// 「高级…」表单：译文字号（真卡片预览）、面板大小、段内换行、截图翻译的两项
  @ViewBuilder private var advanced: some View {
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
      .settingsAnchor(.translateFontScale)
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
    .gated(by: .translate)
    Section {
      PanelSizeRow(
        detail: "拖浮窗的边改大小", info: "拖左右两边改宽度，拖下边改最高多高（内容少时照样变矮）。",
        widthKey: Prefs.translatePanelWidth,
        heightKey: Prefs.translatePanelMaxHeight, defaultWidth: TranslatePanelView.defaultWidth
      )
      .settingsAnchor(.translatePanelSize)
      Toggle("翻译前把同一段里的换行接起来（适合 PDF 复制的文字）", isOn: $removeNewlines)
        .settingsAnchor(.translateRemoveNewlines)
    }
    .gated(by: .translate)
    Section("截图翻译") {
      SettingRow(
        title: "截图翻译时把译文直接盖回截图上", subtitle: "译文盖回原处，能接着标注",
        info: "截图翻译和截图工具栏里的「翻译」都留在截图页里，译文按原来的位置盖回图上，可以接着标注、复制、保存；关着时在翻译浮窗里看，能对比几个服务、复制译文。",
        isNew: WhatsNew.marks(section: "截图翻译时把译文直接盖回截图上", of: .translate, in: navigation.fresh)
      ) {
        Toggle("截图翻译时把译文直接盖回截图上", isOn: $screenshotOverlay)
          .toggleStyle(.switch)
      }
      // 拨过这一行，「新」就算看过了（光点进这一页不算；WhatsNew）
      .onChange(of: screenshotOverlay) {
        WhatsNew.touch(section: "截图翻译时把译文直接盖回截图上", of: .translate)
      }
      .settingsAnchor(.translateOverlay)
      SettingRow(
        title: "截图翻译时复制识别出的原文", subtitle: "识别出的原文放进剪贴板", info: copyRecognizedInfo
      ) {
        Toggle("截图翻译时复制识别出的原文", isOn: $copyRecognized)
          .toggleStyle(.switch)
      }
      .settingsAnchor(.translateCopyRecognized)
    }
    .gated(by: .translate)
  }

  /// 「截图翻译时复制识别出的原文」的 ⓘ：跟着「自动复制译文」（别写成三元式：抽字会漏）
  private var copyRecognizedInfo: LocalizedStringResource {
    if autoCopy { return "识别出来就放进剪贴板；译文出来后，剪贴板换成译文（外面开着自动复制译文）。" }
    return "识别出来就放进剪贴板，⌘V 能直接粘贴；关着时只记进剪贴板历史。"
  }

  /// 「查词与朗读 ›」行尾：系统词典开着「词典 · 真人美音」，关着只写发音
  static func lookupValue(dictionary: Bool, voice: WordVoice) -> LocalizedStringResource {
    let short = String(localized: voice.short)
    // 别写成三元式（抽字时第二个分支会漏掉）
    if dictionary { return "词典 · \(short)" }
    return "\(short)"
  }

  /// 「翻译历史 ›」行尾：开着「最多 5000 条」/「不限」，关着「关」
  static func historyValue(enabled: Bool, limit: Int) -> LocalizedStringResource {
    if !enabled { return "关" }
    if limit == 0 { return "不限" }
    return "最多 \(limit) 条"
  }

  /// 「英文单词发音」（设置改版 S6，用户 11-18 定四项）：真人发音开不开 × 美音 / 英音。原来的美音 / 英音也管取不到录音、
  /// 关了真人发音时用的系统声音（Speaker.voice(for:)），所以四种组合都是一项。读写的照旧是原来两个键，只写变了的那个
  enum WordVoice: CaseIterable {
    case humanUS, humanUK, systemUS, systemUK

    init(recording: Bool, accent: String) {
      let uk = accent == "uk"
      self = recording ? (uk ? .humanUK : .humanUS) : (uk ? .systemUK : .systemUS)
    }

    var recording: Bool { self == .humanUS || self == .humanUK }
    var accent: String { self == .humanUK || self == .systemUK ? "uk" : "us" }

    var title: LocalizedStringResource {
      switch self {
      case .humanUS: "真人 · 美音"
      case .humanUK: "真人 · 英音"
      case .systemUS: "系统声音 · 美音"
      case .systemUK: "系统声音 · 英音"
      }
    }

    /// 推进行行尾的短名
    var short: LocalizedStringResource {
      switch self {
      case .humanUS: "真人美音"
      case .humanUK: "真人英音"
      case .systemUS: "系统美音"
      case .systemUK: "系统英音"
      }
    }

    /// 从 old 换成这一项要写什么（没变的是 nil，不写进持久域）
    func writes(from old: WordVoice) -> (recording: Bool?, accent: String?) {
      (recording == old.recording ? nil : recording, accent == old.accent ? nil : accent)
    }
  }

  private var wordVoice: Binding<WordVoice> {
    Binding {
      WordVoice(recording: wordRecording, accent: wordAccent)
    } set: { choice in
      // 经 @AppStorage 写（截图自检给的临时偏好域也认）
      let writes = choice.writes(from: WordVoice(recording: wordRecording, accent: wordAccent))
      if let recording = writes.recording { wordRecording = recording }
      if let accent = writes.accent { wordAccent = accent }
    }
  }

  /// 预览卡里的译文（跟界面语言：只是摆给人看的样子）
  private static var sample: String { String(localized: "SwiftUI 提供了声明 App 界面所需的视图、控件和布局结构。") }

  private func sameLanguage(_ a: String, _ b: String) -> Bool {
    guard let a = Lang(rawValue: a), let b = Lang(rawValue: b) else { return false }
    return a.isSameLanguage(as: b)
  }

  /// 「+」（体检 B21 D15）：还没加的内置服务（18 pt 服务图标；不花钱的一节「免费」排最前，2026-11-15）｜
  /// 「AI 服务」子菜单（厂商预设：名称、协议、地址填好）+ 自定义 / Azure。选了就加到列表末尾、推进详情页
  /// （AI 服务光标落在 API Key）
  private var addMenu: some View {
    let missing = services.missingBuiltins
    let free = missing.filter(\.isFree)
    let paid = missing.filter { !$0.isFree }
    return Menu {
      if !free.isEmpty {
        Section("免费") { builtinItems(free) }
      }
      if !paid.isEmpty {
        Section("要填密钥") { builtinItems(paid) }
      }
      if !missing.isEmpty { Divider() }
      // 子菜单（复数的「AI 服务」）和新建服务的默认名（单数）英文不同：显式 key
      Menu(String(localized: "translate.add.aiServices", defaultValue: "AI 服务")) {
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

  private func builtinItems(_ kinds: [TranslateService.Kind]) -> some View {
    ForEach(kinds, id: \.self) { kind in
      let service = TranslateService.builtin(kind)
      Button {
        add(service)
      } label: {
        Label {
          // 智谱的默认名带着「（免费）」：已经在「免费」那一节里了
          Text(service.shortName)
        } icon: {
          ServiceTile.menuIcon(service)
        }
      }
    }
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
          service: $service, status: service.settingsStatus, isFree: service.settingsIsFree,
          open: { open(service.id) },
          move: { move(service.id, by: $0) }
        )
        .tag(service.id)
      }
      .onMove { services.services.move(fromOffsets: $0, toOffset: $1) }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .orderedListFrame(rows: services.services.count)
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
  /// 名字后面标「免费」（智谱默认名里的「（免费）」这时去掉，不说两遍：用短名字）
  var isFree = false
  let open: () -> Void
  /// 上移（-1）/ 下移（+1）
  let move: (Int) -> Void

  var body: some View {
    HStack(spacing: 10) {
      ServiceTile(service: service, size: 24)
      VStack(alignment: .leading, spacing: 1) {
        HStack(spacing: 6) {
          Text(isFree ? service.shortName : service.displayName)
            .font(.system(size: 13))
          if isFree { FreeTag() }
        }
        Text(status.text)
          .font(.system(size: 11))
          .foregroundStyle(OrderedList.statusStyle(isProblem: status.isProblem))
      }
      .lineLimit(1)
      .truncationMode(.tail)
      .accessibilityElement(children: .combine)
      Spacer(minLength: 8)
      Toggle("启用「\(service.displayName)」", isOn: $service.isEnabled)
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.mini)
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

/// 服务行名字后面的「免费」：和浮窗里「自动」标签同一个样子（品牌粉 0.16 底、brandInk 字），和描边的「新」分得开
private struct FreeTag: View {
  var body: some View {
    Text("免费")
      .font(.system(size: 10, weight: .semibold))
      .foregroundStyle(Style.brandInk)
      .padding(.horizontal, 4)
      .padding(.vertical, 1)
      .background(Style.brand.opacity(0.16), in: .capsule)
      .fixedSize()
  }
}
