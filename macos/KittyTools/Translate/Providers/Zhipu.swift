// 智谱 GLM 翻译（内置免费服务，可填自己的 key），SSE 流式。
// 接口硬约束：max_tokens 合法范围 [1, 1024]；混合推理模型默认开思考，必须显式关闭，否则 content 可能为空；
// 目标语言必须是具体语言（提示词里不能出现「自动」）。提示词用中文，与大模型服务的英文提示词分开。

import Foundation

nonisolated enum Zhipu {
  static let endpoint = URL(string: "https://open.bigmodel.cn/api/paas/v4/chat/completions")!
  /// 智谱 chat/completions 的 max_tokens 上限，超出直接报「max_tokens参数非法」
  static let maxTokens = 1024

  /// 编进 App 的内置 key（来自不入库的 Secrets.xcconfig）
  static var builtinKey: String? {
    (Bundle.main.object(forInfoDictionaryKey: "KittyBuiltinZhipuKey") as? String).flatMap {
      $0.isEmpty ? nil : $0
    }
  }

  static func stream(_ request: TranslateRequest, service: TranslateService)
    -> AsyncThrowingStream<String, Error>
  {
    guard let key = service.secret().flatMap({ $0.isEmpty ? nil : $0 }) ?? builtinKey else {
      return AsyncThrowingStream { $0.finish(throwing: TranslateError(message: "没有可用的智谱 API Key")) }
    }
    let from = request.from.map { "\($0.title)" } ?? ""
    let target = request.to.title
    let prompt =
      request.isWord
      ? """
      你是一部简明词典。把输入的词写成一条词条，释义用\(target)，格式和示例完全一样：第一行读音，\
      然后每个词性一行，最后一到两行例句。只输出词条本身，不要任何说明。

      输入：\(WordLookup.example(to: request.to).word)
      输出：
      \(WordLookup.example(to: request.to).entry)

      输入：\(request.text)
      输出：
      """
      : "请把下面的\(from)文本翻译成\(target)。只输出译文，不要解释，不要加引号，保留原文的换行和段落。\n\n"
        + request.text
    let model = service.model ?? TranslateService.zhipuModels[0]
    let body: [String: Any] = [
      "model": model, "max_tokens": maxTokens, "stream": true,
      "messages": [["role": "user", "content": prompt]],
    ]
    return AIService.chatStream(
      url: endpoint, headers: ["Authorization": "Bearer \(key)"], body: body,
      tiers: [["thinking": ["type": "disabled"]], ["reasoning_effort": "low"], [:]], model: model,
      delta: AIService.openAIDelta)
  }
}
