// 翻译会话：一段原文 → 预处理 → 检测语种、解析源 / 目标 → 所有启用的服务并行翻译（大模型逐字流式）。
// 新会话取消旧会话的全部请求；单张卡片可单独重试。列表第一个服务出结果后写历史、按设置自动复制。
// 服务分发在 TranslateService.translate 的一个 switch 里。

import Foundation
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
  // 以下三项只由会话自己改；setter 不设 private 只为截图自检能直接摆出各种状态
  var detected: Lang?
  var target: Lang?
  var cards: [Card] = []
  /// 原文区的提示（取词失败、原文过长等）
  private(set) var notice: String?

  let services: TranslateServiceStore
  let history: HistoryStore
  @ObservationIgnored private var request: TranslateRequest?
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

  /// 输入翻译：清空上一次的内容，等用户输入
  func beginInput() {
    cancel()
    sourceText = ""
    cards = []
    detected = nil
    target = nil
    notice = nil
    showsHistory = false
  }

  func showNotice(_ text: String) {
    beginInput()
    notice = text
  }

  func translate(_ text: String) {
    sourceText = text
    start()
  }

  /// 用当前原文开新会话（语言设置变了也调它重译）
  func start() {
    cancel()
    showsHistory = false
    notice = nil
    let defaults = UserDefaults.standard
    var text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
    if defaults.bool(forKey: Prefs.translateRemoveNewlines) {
      // 行尾连字符断开的单词接回去，其余换行变空格（PDF 复制出来的段落）
      text = text.replacing(/-\n\s*/, with: "").replacing(/\s*\n\s*/, with: " ")
    }
    guard !text.isEmpty else { return }
    guard text.utf8.count <= Self.maxSourceBytes else {
      notice = "原文太长（上限 32 KB），请分段翻译"
      cards = []
      return
    }
    detected = Lang.detect(text)
    let plan = Lang.resolve(
      source: defaults.string(forKey: Prefs.translateSource).flatMap(Lang.init(rawValue:)),
      target: defaults.string(forKey: Prefs.translateTarget).flatMap(Lang.init(rawValue:)),
      detected: detected,
      native: defaults.string(forKey: Prefs.translateNative).flatMap(Lang.init(rawValue:))
        ?? .zhHans,
      foreign: defaults.string(forKey: Prefs.translateForeign).flatMap(Lang.init(rawValue:)) ?? .en)
    target = plan.to
    request = TranslateRequest(text: text, from: plan.from, to: plan.to)
    cards = services.enabled.map { Card(service: $0, state: .waiting) }
    for card in cards { run(card.service) }
  }

  func retry(_ id: String) {
    guard let service = cards.first(where: { $0.id == id })?.service else { return }
    run(service)
  }

  func cancel() {
    for task in tasks.values { task.cancel() }
    tasks = [:]
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
    if defaults.bool(forKey: Prefs.translateAutoCopy),
      !defaults.bool(forKey: Prefs.translateCopyToTranslate)
    {
      Paster.write(string: text)
    }
  }
}
