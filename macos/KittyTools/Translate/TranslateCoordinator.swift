// 翻译会话：一段原文 → 预处理 → 检测语种、解析源 / 目标 → 所有启用的服务并行翻译（大模型逐字流式）。
// 新会话取消旧会话的全部请求；单张卡片可单独重试。列表第一个服务出结果后写历史、按设置自动复制
// （复制即译带来、还没改过的原文不自动复制，体检 A19）。截断的结果（B19）不算完成。
// 服务分发在 TranslateService.translate 的一个 switch 里。浮窗的收藏（⌘D，体检 A31）、复制第 N 张卡（⌘1–9）、
// 替换原文（划词来的会话）都以这里的状态为准；静默替换走 translateOnce（只用第一个服务、不开浮窗）。
// 原文改过还没重译（needsTranslate）时浮窗才出「翻译 ↩」胶囊（N5）；翻译历史的列表状态在 historyList，
// 它的搜索框命令和 ⌘ 键（N7）也从这里分发。

import AppKit
import Carbon.HIToolbox
import Observation

@Observable final class TranslateCoordinator {
  enum CardState: Equatable {
    case waiting
    /// 生成中：到目前为止的译文；空串 = 模型在思考、还没有正文（卡片显示「思考中」，mac-whisker S3）
    case running(String)
    case done(String)
    /// 输出到服务的单次上限被截断（体检 B19）：已出来的部分照常显示 + 一行说明；不算完成
    /// （不写历史、不自动复制、primaryResult 不认它，不给收藏和替换原文）
    case truncated(String)
    case failed(TranslateError)

    var text: String? {
      switch self {
      case .running(let text), .done(let text), .truncated(let text): text
      default: nil
      }
    }

    var isThinking: Bool { self == .running("") }
  }

  struct Card: Identifiable {
    let service: TranslateService
    var state: CardState
    var id: String { service.id }
  }

  var sourceText = "" {
    didSet { if !sourceText.isEmpty { missedSelection = false } }
  }
  /// 划词没取到文字、当输入翻译打开的（体检 A16）：原文框占位换成「没取到选中的文字…」，开始输入就恢复
  private(set) var missedSelection = false
  /// 历史的「清空历史…」确认框（「⋯」菜单和历史 ⌘K 都开它，确认框挂在浮窗根视图上）
  var confirmsClearHistory = false
  /// 翻译历史盖在结果区上（⌘Y、「⋯」菜单）；开 / 关都让列表复位（搜索词、范围、选中、撤销）。
  /// 关上时焦点立刻还给原文框：不等历史区淡出，不然淡出期间按的键落进看不见、已复位的搜索框
  var showsHistory = false {
    didSet {
      guard showsHistory != oldValue else { return }
      historyList.reset()
      if !showsHistory { focusSource() }
    }
  }
  /// 翻译历史的键盘列表（N7）
  let historyList: HistoryList
  /// 最近一次翻译的原文（去首尾空白）。setter 不设 private 只为截图自检
  var translatedSource: String?
  // 以下几项只由会话自己改；setter 不设 private 只为截图自检能直接摆出各种状态
  /// 本地检测出的原文语种（偏向第一 / 第二语言；纯数字等认不出时为 nil）
  var detected: Lang?
  /// 实际译成的语言
  var target: Lang?
  /// 这次用的固定源语言（nil = 自动检测）；方向标签按这次的值显示，不看浮窗上此刻的选择
  var fixedSource: Lang?
  /// 选的固定目标正好是原文语言、这次改按「自动」译了：记下原来选的目标，标签写「原文已是 X」
  var abandonedTarget: Lang?
  var cards: [Card] = []
  /// 这次原文来自划词：取词时的前台 App 和原选区。浮窗里显示「替换原文」（只粘回这个 App，
  /// 并照原选区补回首尾的空白和换行）
  var replaceSource: (pid: pid_t, text: String)?
  /// 刚被复制的卡片（⌘1–9 或卡片上的复制按钮），卡片上短暂显示对勾
  private(set) var copiedCard: String?
  /// 每复制一次加一：同一张卡对勾还在（Style.copiedHold）时再复制也要再闪一次，对勾计时也从头算
  private(set) var copyTick = 0
  /// 原文区的提示（划词缺「辅助功能」授权、原文过长等）；截图识字失败这类走刘海岛，不走这里
  private(set) var notice: String?
  /// 提示要引导去授权的那一项；nil 就不显示授权按钮
  private(set) var noticePermission: Permissions.Kind?

  /// 查单个词时系统词典的释义（不是单个词、查不到、设置关掉时为 nil）；setter 不设 private 只为截图自检
  var dictionary: DictionaryEntry?
  /// 这次原文是单个词、大模型按词典格式回答（结果是释义不是译文：不自动复制、不给「替换原文」）
  private(set) var isWordLookup = false

  let services: TranslateServiceStore
  let history: HistoryStore
  @ObservationIgnored private var request: TranslateRequest?
  /// 复制即译带来的原文（去首尾空白）：没改过就不自动复制（免得盖掉刚复制的原文，体检 A19）；别的入口开会话时清掉
  @ObservationIgnored private var copiedSource: String?
  @ObservationIgnored private var dictionaryTask: Task<Void, Never>?
  @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

  /// 原文上限（字节）：再长的文本请求和渲染都不划算
  static let maxSourceBytes = 32 * 1024

  init(services: TranslateServiceStore, history: HistoryStore) {
    self.services = services
    self.history = history
    historyList = HistoryList(store: history)
    historyList.retranslate = { [unowned self] in translate($0.source) }
    historyList.confirmClear = { [unowned self] in confirmsClearHistory = true }
  }

  /// 原文改过、还没重新翻译：原文框右下角弹出「翻译 ↩」（N5），开始翻译就收回
  var needsTranslate: Bool { Self.isEdited(sourceText, since: translatedSource) }

  /// 原文非空、且和最近一次翻译的原文（去首尾空白后）不同。纯函数，配单测
  static func isEdited(_ source: String, since translated: String?) -> Bool {
    let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
    return !text.isEmpty && text != translated
  }

  var isRunning: Bool {
    cards.contains {
      switch $0.state {
      case .waiting, .running: true
      default: false
      }
    }
  }

  /// 第一个服务的完成结果（写历史、自动复制、收藏、替换原文都认它）
  var primaryResult: (service: TranslateService, text: String)? {
    guard let first = cards.first, case .done(let text) = first.state, !text.isEmpty else {
      return nil
    }
    return (first.service, text)
  }

  /// 这次翻译收藏了没有（星标）；读 history.revision 让收藏变化时刷新
  var isFavorite: Bool {
    _ = history.revision
    guard let request, let target else { return false }
    return history.isFavorite(source: request.text, target: target)
  }

  /// ⌘D / 星标：收藏或取消这次翻译（第一个服务出结果后才能收藏）；返回是否做了。
  /// 关着历史时取消收藏就把这条删掉（收藏时才记进去的，留着就成了「关了历史却有历史」）。
  /// 焦点一直在原文框，星标变了读屏看不到：播报（同历史 ⌘C、启动器 ⌘D）
  @discardableResult
  func toggleFavorite() -> Bool {
    guard let request, let primary = primaryResult else { return false }
    let favorite = !isFavorite
    if !favorite, !UserDefaults.standard.bool(forKey: Prefs.translateHistoryEnabled) {
      history.remove(source: request.text, target: request.to)
    } else {
      history.setFavorite(
        source: request.text, target: request.to, result: primary.text,
        service: primary.service.name, favorite)
    }
    Island.announce(favorite ? "已收藏" : "已取消收藏")
    return true
  }

  /// 替换原文用：译文去掉首尾空白后，套上原选区的首尾空白（三击选中的整行带着换行，替换后段落不能被接起来）。
  /// 纯函数，配单测
  static func rewrap(_ translation: String, like original: String) -> String {
    let leading = String(original.prefix { $0.isWhitespace || $0.isNewline })
    let trailing = String(original.reversed().prefix { $0.isWhitespace || $0.isNewline }.reversed())
    guard leading.count < original.count else { return translation }  // 原文全是空白
    return leading + translation.trimmingCharacters(in: .whitespacesAndNewlines) + trailing
  }

  /// ⌘1–9 / 卡片上的复制：复制这张卡当前的译文（流式中也可以复制已出来的部分）；返回是否复制了。
  /// announces：播报「已复制译文」（焦点在原文框，对勾读屏看不到）；自动复制不播，免得打断朗读译文
  @discardableResult
  func copyCard(_ id: String, announces: Bool = true) -> Bool {
    guard let text = cards.first(where: { $0.id == id })?.state.text, !text.isEmpty else {
      return false
    }
    // 译文 / 单词释义是本 App 给出的新文字：同时记进剪贴板历史（mac-native §5）
    Paster.write(string: text, record: true)
    copiedCard = id
    if announces { Island.announce("已复制译文") }
    copyTick += 1
    let tick = copyTick
    Task {
      try? await Task.sleep(for: Style.copiedHold)
      if copyTick == tick { copiedCard = nil }
    }
    return true
  }

  /// 清空上一次的内容，等用户输入（浮窗「清空」、划词没取到文字、提示）。missedSelection：划词没取到文字，
  /// 占位换成「没取到选中的文字，可以直接输入或粘贴」。输入翻译热键不走这里（保留上次的，见 resumeInput）
  func beginInput(missedSelection: Bool = false) {
    cancel()
    sourceText = ""
    self.missedSelection = missedSelection
    translatedSource = nil
    replaceSource = nil
    copiedSource = nil
    cards = []
    dictionary = nil
    isWordLookup = false
    detected = nil
    target = nil
    fixedSource = nil
    abandonedTarget = nil
    notice = nil
    noticePermission = nil
    showsHistory = false
  }

  func showNotice(_ text: String, permission: Permissions.Kind? = nil) {
    beginInput()
    notice = text
    noticePermission = permission
  }

  /// 输入翻译热键 / 菜单再打开浮窗（体检 A14）：保留上次的原文和结果（调用方把原文全选，打字即替换），
  /// 收起提示、关上历史；上次收起时被中断的卡片重新跑
  func resumeInput() {
    notice = nil
    noticePermission = nil
    missedSelection = false
    showsHistory = false
    for card in cards where card.state == .failed(.interrupted) { run(card.service) }
  }

  /// selectedIn：原文是从这个 App 划词取来的（浮窗里给「替换原文」）；fromCopy：复制即译带来的（不自动复制）
  func translate(_ text: String, selectedIn app: pid_t? = nil, fromCopy: Bool = false) {
    sourceText = text
    replaceSource = app.map { ($0, text) }
    copiedSource = fromCopy ? text.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    start()
  }

  /// 用当前原文开新会话（语言设置变了也调它重译）
  func start() {
    cancel()
    showsHistory = false
    notice = nil
    noticePermission = nil
    missedSelection = false
    translatedSource = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
    let text = Self.preprocess(sourceText)
    guard !text.isEmpty else { return }
    guard text.utf8.count <= Self.maxSourceBytes else {
      notice = "原文太长（上限 32 KB），请分段翻译"
      cards = []
      return
    }
    let plan = Self.plan(for: text)
    detected = plan.detected
    fixedSource = plan.fixedSource
    target = plan.request.to
    abandonedTarget = plan.abandonedTarget
    request = plan.request
    isWordLookup = plan.request.isWord
    cards = services.enabled.map { Card(service: $0, state: .waiting) }
    for card in cards { run(card.service) }
    lookUpDictionary(text)
  }

  /// 单个词：后台查系统词典（首查要加载词典），查到就在结果区最上面出词典卡片
  private func lookUpDictionary(_ text: String) {
    dictionaryTask?.cancel()
    dictionary = nil
    guard WordLookup.isWord(text),
      UserDefaults.standard.bool(forKey: Prefs.translateSystemDictionary)
    else { return }
    dictionaryTask = Task {
      let entry = await WordLookup.systemDictionary(text)
      guard !Task.isCancelled else { return }
      dictionary = entry
    }
  }

  /// 去首尾空白；设置里开了就把同一段里的换行接起来（PDF 复制出来的段落）：OCR.joiningLines，段内接行规则和识字同一个 OCR.joinLine
  /// （中日文直接连、其它加空格、行尾连字符接回；空行是段落分隔，保留成一个空行，体检 A32）
  private static func preprocess(_ source: String) -> String {
    let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
    guard UserDefaults.standard.bool(forKey: Prefs.translateRemoveNewlines) else { return text }
    return OCR.joiningLines(text, paragraphSeparator: "\n\n")
  }

  /// 复制即译要不要翻这段（体检 A12，纯函数配单测）：网址、路径、纯数字 / 符号、超长的、目标是「自动」时本来就是
  /// 第一语言的文字都静默跳过（不弹浮窗）。translated：最近一次翻译的原文，同一段再复制一次不重翻（B20）
  static func worthTranslating(
    copied text: String, translated: String?, first: Lang, second: Lang, autoTarget: Bool
  ) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != translated, trimmed.utf8.count <= maxSourceBytes else {
      return false
    }
    let oneLine = !trimmed.contains(where: \.isNewline)
    if !trimmed.contains(where: \.isWhitespace),
      ["http://", "https://", "file://"].contains(where: { trimmed.lowercased().hasPrefix($0) })
    {
      return false
    }
    if oneLine, trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") { return false }
    guard let detected = Lang.detect(trimmed, preferring: [first, second]) else { return false }
    return !(autoTarget && detected.isSameLanguage(as: first))
  }

  /// 按浮窗上选的源 / 目标（全局记住的）和检测结果定这次的请求；wordMode：单个词时让大模型按词典格式回答
  private static func plan(for text: String, wordMode: Bool = true) -> (
    request: TranslateRequest, detected: Lang?, fixedSource: Lang?, abandonedTarget: Lang?
  ) {
    let defaults = UserDefaults.standard
    let (first, second) = Lang.preferredPair
    let detected = Lang.detect(text, preferring: [first, second])
    let chosenTarget = defaults.string(forKey: Prefs.translateTarget).flatMap(Lang.init(rawValue:))
    let fixedSource = defaults.string(forKey: Prefs.translateSource).flatMap(Lang.init(rawValue:))
    let plan = Lang.resolve(
      source: fixedSource, target: chosenTarget, detected: detected, first: first, second: second)
    let isWord =
      wordMode && defaults.bool(forKey: Prefs.translateWordMode) && WordLookup.isWord(text)
    return (
      TranslateRequest(text: text, from: plan.from, to: plan.to, isWord: isWord), detected,
      fixedSource, plan.fellBack ? chosenTarget : nil
    )
  }

  /// 静默替换：不开浮窗、不动当前会话，只用第一个启用的服务、等完整结果；记历史（开着的话）。
  /// 不套「把换行合成一段」：要替换回去的文字，段落得保住；也不用单词模式（替换回去的要是译文，不是释义）
  func translateOnce(_ source: String) async throws -> String {
    let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, text.utf8.count <= Self.maxSourceBytes else {
      throw TranslateError(message: "原文为空或太长")
    }
    guard let service = services.enabled.first else {
      throw TranslateError.config("没有启用的翻译服务")
    }
    let request = Self.plan(for: text, wordMode: false).request
    var latest = ""
    for try await partial in service.translate(request) { latest = partial }
    try Task.checkCancellation()
    guard !latest.isEmpty else { throw TranslateError.emptyResult }
    let defaults = UserDefaults.standard
    if defaults.bool(forKey: Prefs.translateHistoryEnabled) {
      history.add(
        source: text, target: request.to, result: latest, service: service.name,
        limit: defaults.integer(forKey: Prefs.translateHistoryLimit))
    }
    return latest
  }

  func retry(_ id: String) {
    guard let service = cards.first(where: { $0.id == id })?.service else { return }
    run(service)
  }

  /// 停掉还在跑的服务，没出完的卡片标成中断（不然卡片一直是「生成中」，隐藏的浮窗里骨架、彗星、光标动画停不下来）
  func cancel() {
    dictionaryTask?.cancel()
    for task in tasks.values { task.cancel() }
    tasks = [:]
    for index in cards.indices {
      switch cards[index].state {
      case .waiting, .running: cards[index].state = .failed(.interrupted)
      default: break
      }
    }
  }

  private func run(_ service: TranslateService) {
    tasks[service.id]?.cancel()
    guard let request else { return }
    update(service.id, .waiting)
    tasks[service.id] = Task {
      var latest = ""
      do {
        for try await text in service.translate(request) {
          latest = text
          update(service.id, .running(text))
        }
        // 取消时流会正常结束而不是抛错：这里不能把半截结果当成完成
        guard !Task.isCancelled else { return }
        update(service.id, .done(latest))
        finished(service, request: request, text: latest)
      } catch {
        guard !Task.isCancelled, !(error is CancellationError) else { return }
        // 截断：半截照常显示、另写一行说明；不写历史、不自动复制（不调 finished）
        update(service.id, Self.state(after: error, latest: latest))
      }
    }
  }

  /// 流抛错后卡片的状态（纯函数，配单测）：输出到上限被截断、且已经出来了字的是 .truncated（半截照常显示），
  /// 其余是 .failed（不是 TranslateError 的包成服务类错误）
  static func state(after error: Error, latest: String) -> CardState {
    let error = error as? TranslateError ?? TranslateError(message: error.localizedDescription)
    return error == .truncated && !latest.isEmpty ? .truncated(latest) : .failed(error)
  }

  private func update(_ id: String, _ state: CardState) {
    guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
    cards[index].state = state
  }

  /// 只认列表第一个服务：写历史、自动复制（复制即译带来、还没改过的原文不复制：免得盖掉用户刚复制的原文，体检 A19；
  /// 本 App 写剪贴板都经 Paster.write，watcher 按 ownChangeCount 跳过，不会自己触发自己）
  private func finished(_ service: TranslateService, request: TranslateRequest, text: String) {
    guard service.id == cards.first?.id else { return }
    let defaults = UserDefaults.standard
    if defaults.bool(forKey: Prefs.translateHistoryEnabled) {
      history.add(
        source: request.text, target: request.to, result: text, service: service.name,
        limit: defaults.integer(forKey: Prefs.translateHistoryLimit))
    }
    // 单词模式的结果是一段释义，不自动复制（划个词查一下，剪贴板不该被换掉）
    // 和 ⌘1–9 一样对勾 + 整卡闪一下：剪贴板被换掉了要看得出来
    if Self.autoCopies(
      enabled: defaults.bool(forKey: Prefs.translateAutoCopy), isWord: request.isWord,
      copied: copiedSource, translated: translatedSource)
    {
      copyCard(service.id, announces: false)
    }
  }

  /// 这次的结果自动复制吗（纯函数，配单测）：设置开着、不是查词（释义不该换掉剪贴板）、原文不是复制即译带来又没改过的
  static func autoCopies(enabled: Bool, isWord: Bool, copied: String?, translated: String?) -> Bool
  {
    enabled && !isWord && (copied == nil || copied != translated)
  }

  // MARK: 浮窗快捷键（对标 Bob）

  /// 打开设置 › 翻译（⌘,、「⋯」菜单、空状态的按钮传 nil）；错误卡传服务 id，直达那个服务的详情页（体检 C5）。
  /// 由 AppDelegate 接上
  @ObservationIgnored var openSettings: (_ service: String?) -> Void = { _ in }
  /// 把焦点还给原文框（关历史时），由 AppDelegate 接上
  @ObservationIgnored var focusSource: () -> Void = {}

  static let fontScales = 0.8...1.6

  /// ⌘R 重新翻译、⌘D 收藏（全 App 收藏都是 ⌘D，⌘S 只表示存储，体检 A31）、⌘P 固定、⌘Y 历史、⌘, 设置（和「⋯」菜单的键位一致）、
  /// ⌘+ / ⌘- / ⌘0 字号、⌘1–9 复制第 N 张卡；历史开着时先给列表（⌘K ⌘⌫ ⌘Z ⌘C ⇧⌘C ⌘D，见 HistoryList）。
  /// ⌘C / ⌘V / ⌘A 等编辑键不在这里（交给输入框），⌘W 在 OverlayPanel。返回 true 表示处理了
  func handleKeyEquivalent(_ event: NSEvent) -> Bool {
    if showsHistory, historyList.handleKeyEquivalent(event) { return true }
    let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
    let code = Int(event.keyCode)
    // ⌘+ 在多数键盘上要按 ⇧（⌘⇧=），两种都认
    guard flags == .command || (flags == [.command, .shift] && code == kVK_ANSI_Equal) else {
      return false
    }
    let defaults = UserDefaults.standard
    let scale = defaults.double(forKey: Prefs.translateFontScale)
    switch code {
    case kVK_ANSI_Y:
      showsHistory.toggle()
    case kVK_ANSI_Comma:
      openSettings(nil)
    case kVK_ANSI_R:
      if sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        NSSound.beep()
      } else {
        start()
      }
    case kVK_ANSI_D:
      if !toggleFavorite() { NSSound.beep() }
    // ⌘W 在 OverlayPanel 里统一处理（各浮层都认，固定着也关）
    case kVK_ANSI_P:
      defaults.set(!defaults.bool(forKey: Prefs.floatingPinned), forKey: Prefs.floatingPinned)
    case kVK_ANSI_Equal, kVK_ANSI_KeypadPlus:
      defaults.set(min(scale + 0.1, Self.fontScales.upperBound), forKey: Prefs.translateFontScale)
    case kVK_ANSI_Minus, kVK_ANSI_KeypadMinus:
      defaults.set(max(scale - 0.1, Self.fontScales.lowerBound), forKey: Prefs.translateFontScale)
    case kVK_ANSI_0:
      defaults.set(1.0, forKey: Prefs.translateFontScale)
    default:
      guard let digit = Self.digitKeys.firstIndex(of: code) else { return false }
      if !(cards.indices.contains(digit) && copyCard(cards[digit].id)) { NSSound.beep() }
    }
    return true
  }

  private static let digitKeys = [
    kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8,
    kVK_ANSI_9,
  ]

  /// 历史搜索框的编辑命令（doCommandBy，输入法组字时不会来）：↑↓ 选、↩ 重新翻译这条、⇧Tab 换范围、
  /// → 在搜索词末尾时打开动作菜单（同剪贴板 / 启动器）、Esc 先清搜索词再关历史（回到浮窗）；
  /// ⌘K 菜单开着时先给它（HistoryList.handleMenuCommand）。
  /// 返回 false 交还字段编辑器；历史已关（搜索框还在淡出）时一律交还
  func handleHistoryCommand(_ selector: Selector) -> Bool {
    guard showsHistory else { return false }
    if historyList.showsActions { return historyList.handleMenuCommand(selector) }
    switch selector {
    case #selector(NSResponder.moveUp(_:)): historyList.move(by: -1)
    case #selector(NSResponder.moveDown(_:)): historyList.move(by: 1)
    case #selector(NSResponder.insertNewline(_:)):
      guard let entry = historyList.selected else {
        NSSound.beep()
        return true
      }
      translate(entry.source)
    case #selector(NSResponder.insertBacktab(_:)): historyList.favoritesOnly.toggle()
    case #selector(NSResponder.moveRight(_:))
    where historyList.selected != nil && HistoryList.caretAtEnd(of: historyList.query):
      historyList.showsActions = true
    case #selector(NSResponder.cancelOperation(_:)):
      if historyList.query.isEmpty { showsHistory = false } else { historyList.query = "" }
    default: return false
    }
    return true
  }
}
