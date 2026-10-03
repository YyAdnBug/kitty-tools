// 大模型翻译（用户自建 AI 实例：OpenAI 兼容 / Azure OpenAI / Anthropic），SSE 流式输出。
// 也提供智谱内置复用的流式请求：按服务地址分档关闭「思考」，只有 400 / 422 才降一档重试，
// 成功的档位按「地址 + 模型」记在内存里，下次直接从它开始。按地址认厂商的表（AIVendor）也在这里，服务 logo 共用。
// 流里的约定：每次给出到目前为止的整段译文；空串 = 模型在思考、还没有正文（reasoning 字段或开头的 <think> 段，
// 卡片显示「思考中」）；输出到上限（finish_reason = length / stop_reason = max_tokens）时先给出半截、再抛 TranslateError.truncated。

import Foundation
import Synchronization

nonisolated enum AIService {
  static func stream(_ request: TranslateRequest, service: TranslateService)
    -> AsyncThrowingStream<String, Error>
  {
    let aiProtocol = service.aiProtocol ?? .openai
    let model = service.model?.trimmingCharacters(in: .whitespaces) ?? ""
    let key = service.secret()?.trimmingCharacters(in: .whitespaces) ?? ""
    guard let url = endpoint(service.baseURL ?? "", aiProtocol), !model.isEmpty else {
      return AsyncThrowingStream { $0.finish(throwing: TranslateError.config("请先在设置里填写服务地址和模型")) }
    }
    let target = request.to.englishName
    let from = request.from.map { " from \($0.englishName)" } ?? ""
    let system =
      request.isWord
      ? wordPrompt(to: request.to)
      : "You are a translation engine. Translate the user's text\(from) into \(target). "
        + "Output only the translation: no explanations, no quotes. Keep line breaks and Markdown structure."
    switch aiProtocol {
    case .openai, .azure:
      var body: [String: Any] = [
        "model": model, "stream": true,
        "messages": [
          ["role": "system", "content": system], ["role": "user", "content": request.text],
        ],
      ]
      if let maxTokens = maxTokens(url, aiProtocol) { body["max_tokens"] = maxTokens }
      let headers =
        aiProtocol == .azure
        ? ["api-key": key] : key.isEmpty ? [:] : ["Authorization": "Bearer \(key)"]
      return chatStream(
        url: url, headers: headers, body: body, tiers: tiers(url, aiProtocol, model), model: model,
        delta: openAIDelta)
    case .anthropic:
      let body: [String: Any] = [
        "model": model, "system": system, "max_tokens": 4096, "stream": true,
        "messages": [["role": "user", "content": request.text]],
      ]
      return chatStream(
        url: url, headers: ["x-api-key": key, "anthropic-version": "2023-06-01"], body: body,
        tiers: tiers(url, aiProtocol, model), model: model, delta: anthropicDelta)
    }
  }

  /// 单词模式（查词，D4）：照示例写一条简明双语词典词条（示例和智谱的一样，见 WordLookup.example）
  static func wordPrompt(to target: Lang) -> String {
    let example = WordLookup.example(to: target)
    return """
      You are a concise bilingual dictionary. Write the user's word as one dictionary entry with meanings in \
      \(target.englishName), in exactly the same format as the example: pronunciation on the first line, one line \
      per part of speech, then one or two example sentences with translations. Output only the entry.

      Example input: \(example.word)
      Example output:
      \(example.entry)
      """
  }

  /// 获取服务端可用模型（设置页「获取模型」）
  static func fetchModels(baseURL: String, aiProtocol: AIProtocolAlias, key: String) async throws
    -> [String]
  {
    guard let chat = endpoint(baseURL, aiProtocol) else { throw TranslateError(message: "服务地址不正确") }
    let listURL =
      aiProtocol == .anthropic
      ? chat.deletingLastPathComponent().appending(path: "models").appending(queryItems: [
        URLQueryItem(name: "limit", value: "1000")
      ])
      : chat.deletingLastPathComponent().deletingLastPathComponent().appending(path: "models")
    var request = URLRequest(url: listURL)
    request.timeoutInterval = 15
    switch aiProtocol {
    case .openai where !key.isEmpty:
      request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    case .azure: request.setValue(key, forHTTPHeaderField: "api-key")
    case .anthropic:
      request.setValue(key, forHTTPHeaderField: "x-api-key")
      request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    default: break
    }
    let (data, response) = try await HTTP.session(for: listURL).data(for: request)
    let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    try HTTP.check(response, object)
    let entries = (object["data"] ?? object["models"]) as? [[String: Any]] ?? []
    return Array(Set(entries.compactMap { ($0["id"] ?? $0["name"]) as? String })).sorted()
  }

  typealias AIProtocolAlias = TranslateService.AIProtocol

  // MARK: 共用的流式请求

  private static let workingTier = Mutex<[String: Int]>([:])

  static func chatStream(
    url: URL, headers: [String: String], body: [String: Any], tiers: [[String: Any]], model: String,
    delta: @escaping @Sendable ([String: Any]) -> StreamDelta
  ) -> AsyncThrowingStream<String, Error> {
    let cacheKey = "\(url.absoluteString)\n\(model)"
    let headers = headers.merging(openCodeHeaders(url)) { $1 }
    let requests = tiers.map { tier in
      HTTP.request(url, headers: headers, json: body.merging(tier) { $1 })
    }
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          var tier = workingTier.withLock { $0[cacheKey] } ?? 0
          while true {
            do {
              let events = try await HTTP.events(requests[tier])
              workingTier.withLock { $0[cacheKey] = tier }
              var text = StreamingText()
              var truncated = false
              var shown: String?
              for try await payload in events {
                guard
                  let object = (try? JSONSerialization.jsonObject(with: Data(payload.utf8)))
                    as? [String: Any]
                else { continue }
                if let message = HTTP.message(in: object) { throw TranslateError(message: message) }
                let piece = delta(object)
                if let content = piece.text { text.append(content) }
                truncated = truncated || piece.isTruncated
                // 空串只在思考时发（开头 role 那一段的空 content 不算）；内容没变不重复发
                let visible = text.visible
                if !visible.isEmpty || piece.isThinking || text.isThinking, visible != shown {
                  shown = visible
                  continuation.yield(visible)
                }
              }
              guard !text.final.isEmpty else { throw TranslateError.emptyResult }
              continuation.yield(text.final)
              continuation.finish(throwing: truncated ? TranslateError.truncated : nil)
              return
            } catch let error as TranslateError
              where [400, 422].contains(error.status) && tier < requests.count - 1
            {
              tier += 1
            }
          }
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  // MARK: 地址、参数、增量解析

  /// OpenAI 兼容 / Azure：已含 /chat/completions 原样用；末段是 v<数字> 或 openai 补 /chat/completions；
  /// 否则补 /v1/chat/completions。Anthropic：同理对应 /messages，默认 api.anthropic.com。没写协议补 https://
  static func endpoint(_ raw: String, _ aiProtocol: TranslateService.AIProtocol) -> URL? {
    var base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if base.isEmpty, aiProtocol == .anthropic { base = "https://api.anthropic.com" }
    guard !base.isEmpty else { return nil }
    if !base.contains("://") { base = "https://" + base }
    while base.hasSuffix("/") { base.removeLast() }
    let suffix = aiProtocol == .anthropic ? "/messages" : "/chat/completions"
    if base.lowercased().contains(suffix) { return URL(string: base) }
    let last = base.split(separator: "/").last.map { $0.lowercased() } ?? ""
    let versioned = last.wholeMatch(of: /v\d+(beta\d*)?/) != nil || last == "openai"
    return URL(string: base + (versioned ? suffix : "/v1" + suffix))
  }

  /// 智谱域名上限 1024（超了直接报错）；OpenAI 官方与 Azure 不传；其余 4096
  static func maxTokens(_ url: URL, _ aiProtocol: TranslateService.AIProtocol) -> Int? {
    if aiProtocol == .azure { return nil }
    switch AIVendor(url: url) {
    case .openai: return nil
    case .zhipu: return Zhipu.maxTokens
    default: return 4096
    }
  }

  /// OpenCode（Zen / Go，opencode.ai）对客户端的两条要求（官方文档 docs/go「Where can I use it」）：每个请求带
  /// 会话 ID `x-opencode-session`，不带就 400「Request is missing x-opencode-session and cannot be routed
  /// efficiently」；User-Agent 写自己的名字和版本。服务端按会话 ID 把请求固定到同一个后端、复用提示词缓存，每个 ID
  /// 记一行，所以一次运行从头到尾用同一个 ID，不是每次翻译换一个。别的地址什么都不加。
  /// 不进 AIVendor：那张表每一行都带一张内置 logo，OpenCode 的图标取自官网
  static func openCodeHeaders(_ url: URL) -> [String: String] {
    guard let host = url.host()?.lowercased(),
      host == "opencode.ai" || host.hasSuffix(".opencode.ai")
    else { return [:] }
    return ["x-opencode-session": openCodeSession, "User-Agent": userAgent]
  }

  /// 随机生成，不含任何用户信息
  private static let openCodeSession = UUID().uuidString
  private static let userAgent: String = {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    return "KittyTools/\(version ?? "0")"
  }()

  /// 关闭「思考」的参数档位（翻译不需要推理，开着会拖慢且可能占满输出额度），最后一档什么都不带
  static func tiers(_ url: URL, _ aiProtocol: TranslateService.AIProtocol, _ model: String)
    -> [[String: Any]]
  {
    let effort = { (level: String) -> [String: Any] in ["reasoning_effort": level] }
    let disabled: [String: Any] = ["thinking": ["type": "disabled"]]
    switch aiProtocol {
    case .anthropic: return [disabled, [:]]
    case .azure: return [effort("none"), effort("minimal"), effort("low"), [:]]
    case .openai:
      if HTTP.isLocalNetwork(url) {
        let kwargs: [String: Any] = ["chat_template_kwargs": ["enable_thinking": false]]
        return [kwargs.merging(effort("none")) { $1 }, kwargs, [:]]
      }
      switch AIVendor(url: url) {
      case .zhipu, .kimi, .doubao: return [disabled, effort("low"), [:]]
      case .deepseek: return [disabled, [:]]
      case .qwen, .siliconflow: return [["enable_thinking": false], [:]]
      case .openrouter:
        return [["reasoning": ["effort": "none"]], ["reasoning": ["effort": "low"]], [:]]
      case .gemini: return [effort("none"), effort("minimal"), effort("low"), [:]]
      case .openai:
        let model = model.lowercased()
        if ["gpt-4", "gpt-3.5", "chatgpt"].contains(where: model.hasPrefix) { return [[:]] }
        if ["o1", "o3", "o4"].contains(where: model.hasPrefix) { return [effort("low"), [:]] }
        return [effort("none"), effort("minimal"), effort("low"), [:]]
      default: return [effort("none"), [:]]
      }
    }
  }

  /// OpenAI 兼容：choices[0].delta.content；reasoning_content / reasoning 只用来标「在思考」，不显示；
  /// finish_reason = length 是输出到上限被截断（智谱同）
  @Sendable static func openAIDelta(_ object: [String: Any]) -> StreamDelta {
    let choice = (object["choices"] as? [[String: Any]])?.first
    let delta = choice?["delta"] as? [String: Any]
    let reasoning = ["reasoning_content", "reasoning"].contains {
      !((delta?[$0] as? String) ?? "").isEmpty
    }
    return StreamDelta(
      text: delta?["content"] as? String, isThinking: reasoning,
      isTruncated: choice?["finish_reason"] as? String == "length")
  }

  /// Anthropic：content_block_delta 里的 text_delta；thinking_delta 只标「在思考」；
  /// message_delta 的 stop_reason = max_tokens 是截断
  @Sendable static func anthropicDelta(_ object: [String: Any]) -> StreamDelta {
    let delta = object["delta"] as? [String: Any]
    switch object["type"] as? String {
    case "content_block_delta":
      switch delta?["type"] as? String {
      case "text_delta": return StreamDelta(text: delta?["text"] as? String)
      case "thinking_delta": return StreamDelta(isThinking: true)
      default: return StreamDelta()
      }
    case "message_delta":
      return StreamDelta(isTruncated: delta?["stop_reason"] as? String == "max_tokens")
    default:
      return StreamDelta()
    }
  }
}

/// 大模型厂商（第 13 批，一处定义）：按服务地址的 host 认，关思考分档、max_tokens、服务 logo（`ServiceTile`）都读它；
/// logo 在地址认不出时再按服务名里的关键词认（`init(service:)`）。原值 = `Assets.xcassets/ServiceLogo` 里的图名
/// （取自各家官网自己发布的图标，来源和日期见 PLAN「翻译服务 logo（第 13 批）」）。
/// 顺序 = 按名字认时的先后：聚合平台在前（「硅基流动 DeepSeek」是硅基流动），「gpt」这种宽的关键词在最后
nonisolated enum AIVendor: String, CaseIterable, Sendable {
  case openrouter, siliconflow, deepseek, kimi, qwen, doubao, ollama, mistral, grok, minimax
  case zhipu, gemini, anthropic, openai

  /// 地址的 host 等于其中一个、或以「.它」结尾就是这家
  var domains: [String] {
    switch self {
    case .openrouter: ["openrouter.ai"]
    case .siliconflow: ["siliconflow.cn", "siliconflow.com"]
    case .deepseek: ["deepseek.com"]
    case .kimi: ["moonshot.cn", "moonshot.ai"]
    case .qwen: ["dashscope.aliyuncs.com", "dashscope-intl.aliyuncs.com"]
    case .doubao: ["volces.com"]
    case .ollama: ["ollama.com"]
    case .mistral: ["mistral.ai"]
    case .grok: ["x.ai"]
    case .minimax: ["minimax.chat", "minimaxi.com", "minimax.io"]
    case .zhipu: ["bigmodel.cn", "z.ai"]
    case .gemini: ["generativelanguage.googleapis.com"]
    case .anthropic: ["anthropic.com"]
    case .openai: ["openai.com"]
    }
  }

  /// 服务名里出现就是这家（不分大小写）
  var keywords: [String] {
    switch self {
    case .openrouter: ["openrouter"]
    case .siliconflow: ["siliconflow", "硅基"]
    case .deepseek: ["deepseek", "深度求索"]
    case .kimi: ["kimi", "moonshot", "月之暗面"]
    case .qwen: ["qwen", "通义", "千问", "百炼", "dashscope"]
    case .doubao: ["doubao", "豆包", "火山方舟"]
    case .ollama: ["ollama"]
    case .mistral: ["mistral"]
    case .grok: ["grok", "xai"]
    case .minimax: ["minimax", "海螺"]
    case .zhipu: ["zhipu", "智谱", "glm", "bigmodel"]
    case .gemini: ["gemini"]
    case .anthropic: ["anthropic", "claude"]
    case .openai: ["openai", "gpt"]
    }
  }

  /// 按地址认（不分大小写）；端口只用来认 Ollama：本机 / 局域网上的 11434（它的默认端口）
  init?(url: URL) {
    guard
      let host = url.host(percentEncoded: false)?.lowercased()
        .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    else { return nil }
    if url.port == 11434, HTTP.isLocalNetwork(url) {
      self = .ollama
      return
    }
    guard
      let vendor = Self.allCases.first(where: {
        $0.domains.contains { host == $0 || host.hasSuffix("." + $0) }
      })
    else { return nil }
    self = vendor
  }

  /// 一个 AI 服务是哪家（服务 logo 用）：先按地址（经 `AIService.endpoint` 补全，Anthropic 空地址 = 官方），
  /// 再按服务名的关键词，都认不出而协议是 Anthropic 的算 Anthropic；内置服务、Azure 不归这里管（nil）
  init?(service: TranslateService) {
    guard service.kind == .ai, service.aiProtocol != .azure else { return nil }
    let aiProtocol = service.aiProtocol ?? .openai
    if let url = AIService.endpoint(service.baseURL ?? "", aiProtocol),
      let vendor = AIVendor(url: url)
    {
      self = vendor
      return
    }
    let name = service.name.lowercased()
    if let vendor = Self.allCases.first(where: { $0.keywords.contains(where: name.contains) }) {
      self = vendor
      return
    }
    guard aiProtocol == .anthropic else { return nil }
    self = .anthropic
  }
}

/// 一段 SSE 增量里有用的东西：正文增量、是不是在思考、是不是说输出到上限了
nonisolated struct StreamDelta: Equatable, Sendable {
  var text: String?
  var isThinking = false
  var isTruncated = false
}

/// 一次翻译请求：from 为 nil 表示交给服务自动识别
nonisolated struct TranslateRequest: Sendable {
  let text: String
  let from: Lang?
  let to: Lang
  /// 原文是单个词、且开着「单词模式」：大模型按词典格式回答（读音、词性释义、例句）
  var isWord = false
}
