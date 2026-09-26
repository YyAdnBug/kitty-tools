// 大模型翻译（用户自建 AI 实例：OpenAI 兼容 / Azure OpenAI / Anthropic），SSE 流式输出。
// 也提供智谱内置复用的流式请求：按服务地址分档关闭「思考」，只有 400 / 422 才降一档重试，
// 成功的档位按「地址 + 模型」记在内存里，下次直接从它开始。

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
      return AsyncThrowingStream { $0.finish(throwing: TranslateError(message: "请先在设置里填写服务地址和模型")) }
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
    delta: @escaping @Sendable ([String: Any]) -> String?
  ) -> AsyncThrowingStream<String, Error> {
    let cacheKey = "\(url.absoluteString)\n\(model)"
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
              for try await payload in events {
                guard
                  let object = (try? JSONSerialization.jsonObject(with: Data(payload.utf8)))
                    as? [String: Any]
                else { continue }
                if let message = HTTP.message(in: object) { throw TranslateError(message: message) }
                if let piece = delta(object) {
                  text.append(piece)
                  continuation.yield(text.visible)
                }
              }
              guard !text.final.isEmpty else { throw TranslateError.emptyResult }
              continuation.yield(text.final)
              continuation.finish()
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
    let host = url.host()?.lowercased() ?? ""
    if aiProtocol == .azure || host == "api.openai.com" { return nil }
    if host.hasSuffix("bigmodel.cn") || host.hasSuffix("z.ai") { return Zhipu.maxTokens }
    return 4096
  }

  /// 关闭「思考」的参数档位（翻译不需要推理，开着会拖慢且可能占满输出额度），最后一档什么都不带
  static func tiers(_ url: URL, _ aiProtocol: TranslateService.AIProtocol, _ model: String)
    -> [[String: Any]]
  {
    let host = url.host()?.lowercased() ?? ""
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
      if ["bigmodel.cn", "z.ai", "moonshot.cn", "moonshot.ai", "volces.com"].contains(where: {
        host.hasSuffix($0)
      }) {
        return [disabled, effort("low"), [:]]
      }
      if host.contains("deepseek") { return [disabled, [:]] }
      if host.contains("dashscope") || host.contains("siliconflow") {
        return [["enable_thinking": false], [:]]
      }
      if host.contains("openrouter") {
        return [["reasoning": ["effort": "none"]], ["reasoning": ["effort": "low"]], [:]]
      }
      if host.contains("generativelanguage.googleapis.com") {
        return [effort("none"), effort("minimal"), effort("low"), [:]]
      }
      if host == "api.openai.com" {
        let model = model.lowercased()
        if ["gpt-4", "gpt-3.5", "chatgpt"].contains(where: model.hasPrefix) { return [[:]] }
        if ["o1", "o3", "o4"].contains(where: model.hasPrefix) { return [effort("low"), [:]] }
        return [effort("none"), effort("minimal"), effort("low"), [:]]
      }
      return [effort("none"), [:]]
    }
  }

  /// OpenAI 兼容：choices[0].delta.content（reasoning 类字段忽略）
  @Sendable static func openAIDelta(_ object: [String: Any]) -> String? {
    let choice = (object["choices"] as? [[String: Any]])?.first
    return (choice?["delta"] as? [String: Any])?["content"] as? String
  }

  /// Anthropic：content_block_delta 里的 text_delta（thinking_delta 忽略）
  @Sendable static func anthropicDelta(_ object: [String: Any]) -> String? {
    guard object["type"] as? String == "content_block_delta",
      let delta = object["delta"] as? [String: Any], delta["type"] as? String == "text_delta"
    else { return nil }
    return delta["text"] as? String
  }
}

/// 一次翻译请求：from 为 nil 表示交给服务自动识别
nonisolated struct TranslateRequest: Sendable {
  let text: String
  let from: Lang?
  let to: Lang
  /// 原文是单个词、且开着「单词模式」：大模型按词典格式回答（读音、词性释义、例句）
  var isWord = false
}
