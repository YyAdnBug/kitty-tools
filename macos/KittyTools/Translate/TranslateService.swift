// 翻译服务配置：内置智谱 + 用户自建 AI 实例（OpenAI 兼容 / Azure / Anthropic），列表顺序即结果卡片顺序。
// 非密钥配置以 JSON 存 UserDefaults，密钥存钥匙串（账户名 "<服务 id>.<字段>"）。

import Foundation
import Observation

nonisolated struct TranslateService: Codable, Identifiable, Hashable, Sendable {
  enum Kind: String, Codable, Sendable {
    case zhipu, ai
  }

  enum AIProtocol: String, Codable, CaseIterable, Sendable {
    case openai, azure, anthropic

    var title: String {
      switch self {
      case .openai: "OpenAI 兼容"
      case .azure: "Azure OpenAI"
      case .anthropic: "Anthropic"
      }
    }
  }

  /// 内置服务 = kind 原值；AI 实例 = "ai:<8 位>"
  var id: String
  var kind: Kind
  var name: String
  var isEnabled = true
  /// 智谱文本模型 / AI 模型（Azure 填部署名）
  var model: String?
  /// AI 服务地址
  var baseURL: String?
  var aiProtocol: AIProtocol?

  static let zhipuModels = ["glm-4-flash", "glm-4.6v-flash"]

  static var zhipu: TranslateService {
    TranslateService(id: "zhipu", kind: .zhipu, name: "智谱 GLM（免费）", model: zhipuModels[0])
  }

  static func newAI() -> TranslateService {
    TranslateService(
      id: "ai:" + UUID().uuidString.prefix(8).lowercased(), kind: .ai, name: "AI 服务",
      isEnabled: false, model: "", baseURL: "", aiProtocol: .openai)
  }

  /// 流式输出（逐字显示）的服务
  var isStreaming: Bool { true }

  var symbol: String {
    switch kind {
    case .zhipu: "sparkles"
    case .ai: "cpu"
    }
  }

  /// 服务分发：翻译会话和设置页「测试连接」共用这一个 switch
  func translate(_ request: TranslateRequest) -> AsyncThrowingStream<String, Error> {
    switch kind {
    case .zhipu: Zhipu.stream(request, service: self)
    case .ai: AIService.stream(request, service: self)
    }
  }

  func secret(_ field: String = "apiKey") -> String? { Keychain.get("\(id).\(field)") }

  func setSecret(_ value: String?, _ field: String = "apiKey") {
    Keychain.set(value, for: "\(id).\(field)")
  }
}

/// 服务列表（设置页编辑，翻译时读）
@Observable final class TranslateServiceStore {
  private static let key = "translateServices"

  var services: [TranslateService] {
    didSet {
      if let data = try? JSONEncoder().encode(services) {
        UserDefaults.standard.set(data, forKey: Self.key)
      }
    }
  }

  var enabled: [TranslateService] { services.filter(\.isEnabled) }

  init() {
    let saved = UserDefaults.standard.data(forKey: Self.key).flatMap {
      try? JSONDecoder().decode([TranslateService].self, from: $0)
    }
    services = saved ?? [.zhipu]
  }

  /// 删除服务连同它的密钥
  func remove(_ id: String) {
    services.first { $0.id == id }?.setSecret(nil)
    services.removeAll { $0.id == id }
  }
}
