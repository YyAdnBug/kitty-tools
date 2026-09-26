// 翻译会话：一段原文 → 预处理 → 检测语种、解析源 / 目标 → 所有启用的服务并行翻译（大模型逐字流式）。
// 新会话取消旧会话的全部请求；单张卡片可单独重试。列表第一个服务出结果后写历史、按设置自动复制。
// 服务分发在 TranslateService.translate 的一个 switch 里。浮窗的收藏（⌘S）、复制第 N 张卡（⌘1–9）、
// 替换原文（划词来的会话）都以这里的状态为准；静默替换走 translateOnce（只用第一个服务、不开浮窗）。

import AppKit
import Carbon.HIToolbox
import Observation

@Observable final class TranslateCoordinator {
  enum CardState: Equatable {
    case waiting
    case running(String)
    case done(String)
    case failed(String)

    var text: String? {
      switch self {
      case .running(let text), .done(let text): text
      default: nil
      }
    }
  }

  struct Card: Identifiable {
    let service: TranslateService
    var state: CardState
    var id: String { service.id }
  }

  var sourceText = ""
  var showsHistory = false
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
  /// 每复制一次加一：同一张卡 1.5 s 内再复制也要再闪一次，对勾计时也从头算
  private(set) var copyTick = 0
  /// 原文区的提示（取词失败、识别不到文字、原文过长等）
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
  @ObservationIgnored private var dictionaryTask: Task<Void, Never>?
  @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

  /// 原文上限（字节）：再长的文本请求和渲染都不划算
  static let maxSourceBytes = 32 * 1024

  init(services: TranslateServiceStore, history: HistoryStore) {
    self.services = services
    self.history = history
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

  /// ⌘S / 星标：收藏或取消这次翻译（第一个服务出结果后才能收藏）；返回是否做了。
  /// 关着历史时取消收藏就把这条删掉（收藏时才记进去的，留着就成了「关了历史却有历史」）
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

  /// ⌘1–9 / 卡片上的复制：复制这张卡当前的译文（流式中也可以复制已出来的部分）；返回是否复制了
  @discardableResult
  func copyCard(_ id: String) -> Bool {
    guard let text = cards.first(where: { $0.id == id })?.state.text, !text.isEmpty else {
      return false
    }
    Paster.write(string: text)
    copiedCard = id
    copyTick += 1
    let tick = copyTick
    Task {
      try? await Task.sleep(for: .seconds(1.5))
      if copyTick == tick { copiedCard = nil }
    }
    return true
  }

  /// 输入翻译：清空上一次的内容，等用户输入
  func beginInput() {
    cancel()
    sourceText = ""
    replaceSource = nil
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

  /// selectedIn：原文是从这个 App 划词取来的（浮窗里给「替换原文」）
  func translate(_ text: String, selectedIn app: pid_t? = nil) {
    sourceText = text
    replaceSource = app.map { ($0, text) }
    start()
  }

  /// 用当前原文开新会话（语言设置变了也调它重译）
  func start() {
    cancel()
    showsHistory = false
    notice = nil
    noticePermission = nil
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

  /// 去首尾空白；设置里开了就把换行合成一段（行尾连字符断开的单词接回去，其余换行变空格，PDF 复制出来的段落）
  private static func preprocess(_ source: String) -> String {
    let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
    guard UserDefaults.standard.bool(forKey: Prefs.translateRemoveNewlines) else { return text }
    return text.replacing(/-\n\s*/, with: "").replacing(/\s*\n\s*/, with: " ")
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
      throw TranslateError(message: "没有启用的翻译服务")
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
      case .waiting, .running: cards[index].state = .failed("已中断，点重试重新翻译")
      default: break
      }
    }
  }

  private func run(_ service: TranslateService) {
    tasks[service.id]?.cancel()
    guard let request else { return }
    update(service.id, .waiting)
    tasks[service.id] = Task {
      do {
        var latest = ""
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
        update(service.id, .failed(error.localizedDescription))
      }
    }
  }

  private func update(_ id: String, _ state: CardState) {
    guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
    cards[index].state = state
  }

  /// 只认列表第一个服务：写历史、自动复制（复制即译开着时不复制，否则会自己触发自己）
  private func finished(_ service: TranslateService, request: TranslateRequest, text: String) {
    guard service.id == cards.first?.id else { return }
    let defaults = UserDefaults.standard
    if defaults.bool(forKey: Prefs.translateHistoryEnabled) {
      history.add(
        source: request.text, target: request.to, result: text, service: service.name,
        limit: defaults.integer(forKey: Prefs.translateHistoryLimit))
    }
    // 单词模式的结果是一段释义，不自动复制（划个词查一下，剪贴板不该被换掉）
    if defaults.bool(forKey: Prefs.translateAutoCopy),
      !defaults.bool(forKey: Prefs.translateCopyToTranslate), !request.isWord
    {
      Paster.write(string: text)
    }
  }

  // MARK: 浮窗快捷键（对标 Bob）

  /// 收起浮窗（⌘W，固定着也收），由 AppDelegate 接上
  @ObservationIgnored var hidePanel: () -> Void = {}

  static let fontScales = 0.8...1.6

  /// ⌘R 重新翻译、⌘S 收藏、⌘W 关闭、⌘P 固定、⌘+ / ⌘- / ⌘0 字号、⌘1–9 复制第 N 张卡。
  /// ⌘C / ⌘V / ⌘A 等编辑键不在这里（交给输入框）。返回 true 表示处理了
  func handleKeyEquivalent(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
    let code = Int(event.keyCode)
    // ⌘+ 在多数键盘上要按 ⇧（⌘⇧=），两种都认
    guard flags == .command || (flags == [.command, .shift] && code == kVK_ANSI_Equal) else {
      return false
    }
    let defaults = UserDefaults.standard
    let scale = defaults.double(forKey: Prefs.translateFontScale)
    switch code {
    case kVK_ANSI_R:
      if sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        NSSound.beep()
      } else {
        start()
      }
    case kVK_ANSI_S:
      if !toggleFavorite() { NSSound.beep() }
    case kVK_ANSI_W:
      hidePanel()
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
}
