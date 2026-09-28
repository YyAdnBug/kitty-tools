// 翻译服务配置：列表里只有加进来的服务（体检 B21）——8 个内置服务（智谱、百度、有道、Google、DeepL、微软、火山、腾讯）
// 可删、在设置「+」里加回来，外加用户自建的 AI 实例（OpenAI 兼容 / Azure / Anthropic，「+」里有厂商预设，D15）。
// 从没存过列表时默认只有智谱（启用）。列表顺序即结果卡片顺序。
// 非密钥配置以 JSON 存 UserDefaults，密钥存钥匙串（账户名 "<服务 id>.<字段>"，字段名已定，改名会读不到已存的密钥）。
// 删内置服务保留它的密钥（加回来还在），删 AI 服务连同密钥一起删。

import Foundation
import Observation

nonisolated struct TranslateService: Codable, Identifiable, Hashable, Sendable {
  enum Kind: String, Codable, CaseIterable, Sendable {
    case zhipu, baidu, youdao, google, deepl, microsoft, volcengine, tencent, ai

    var defaultName: String {
      switch self {
      case .zhipu: "智谱 GLM（免费）"
      case .baidu: "百度翻译"
      case .youdao: "有道翻译"
      case .google: "Google 翻译"
      case .deepl: "DeepL"
      case .microsoft: "微软翻译"
      case .volcengine: "火山翻译"
      case .tencent: "腾讯翻译"
      case .ai: "AI 服务"
      }
    }
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

  /// 一个要存进钥匙串的字段
  struct SecretField: Hashable, Sendable {
    let name: String
    let label: String
    var prompt = ""
  }

  /// 内置服务 = kind 原值；AI 实例 = "ai:<8 位>"
  var id: String
  var kind: Kind
  var name: String
  var isEnabled = true
  /// 智谱文本模型 / AI 模型（Azure 填部署名）
  var model: String?
  /// AI 服务地址 / DeepLX 地址
  var baseURL: String?
  var aiProtocol: AIProtocol?
  /// 微软翻译（填了 key 时）的区域
  var region: String?
  /// DeepL 走自建的 DeepLX 而不是官方接口
  var usesDeepLX: Bool?

  /// 内置智谱的两档免费纯文本模型（体检 A17，查智谱开放文档 2026-09：GLM-4.7-Flash 是免费模型、纯文本、能关思考，
  /// 替代了 GLM-4.5-Flash）。以前的第二档是识图用的 glm-4.6v-flash，读到它（或别的不认识的）回落第一档
  static let zhipuModels = ["glm-4-flash", "glm-4.7-flash"]

  static func zhipuModel(_ stored: String?) -> String {
    stored.flatMap { zhipuModels.contains($0) ? $0 : nil } ?? zhipuModels[0]
  }

  static var zhipu: TranslateService { builtin(.zhipu) }

  static func builtin(_ kind: Kind) -> TranslateService {
    TranslateService(
      id: kind.rawValue, kind: kind, name: kind.defaultName, isEnabled: kind == .zhipu,
      model: kind == .zhipu ? zhipuModels[0] : nil)
  }

  static func newAI() -> TranslateService {
    TranslateService(
      id: "ai:" + UUID().uuidString.prefix(8).lowercased(), kind: .ai, name: "AI 服务",
      isEnabled: false, model: "", baseURL: "", aiProtocol: .openai)
  }

  /// 「+ › AI 服务」里的厂商预设（D15）：只用来填好名称、协议和地址（经 AIService.endpoint 补全），不持久化；
  /// 模型留空（进详情页后填了 Key 自动取模型列表）
  struct AIPreset: Identifiable, Sendable {
    let name: String
    let aiProtocol: AIProtocol
    let baseURL: String
    var id: String { name }

    func make() -> TranslateService {
      var service = TranslateService.newAI()
      service.name = name
      service.aiProtocol = aiProtocol
      service.baseURL = baseURL
      return service
    }
  }

  static let aiPresets = [
    AIPreset(name: "OpenAI", aiProtocol: .openai, baseURL: "https://api.openai.com/v1"),
    AIPreset(name: "DeepSeek", aiProtocol: .openai, baseURL: "https://api.deepseek.com/v1"),
    AIPreset(
      name: "通义千问", aiProtocol: .openai,
      baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1"),
    AIPreset(name: "Kimi", aiProtocol: .openai, baseURL: "https://api.moonshot.cn/v1"),
    AIPreset(name: "硅基流动", aiProtocol: .openai, baseURL: "https://api.siliconflow.cn/v1"),
    AIPreset(name: "OpenRouter", aiProtocol: .openai, baseURL: "https://openrouter.ai/api/v1"),
    AIPreset(
      name: "Gemini", aiProtocol: .openai,
      baseURL: "https://generativelanguage.googleapis.com/v1beta/openai"),
    AIPreset(name: "Anthropic", aiProtocol: .anthropic, baseURL: ""),
    AIPreset(name: "Ollama", aiProtocol: .openai, baseURL: "http://127.0.0.1:11434/v1"),
  ]

  /// 流式输出（逐字显示、按行内 Markdown 渲染）的服务：大模型类
  var isStreaming: Bool { kind == .zhipu || kind == .ai }

  var secretFields: [SecretField] {
    switch kind {
    case .zhipu: [SecretField(name: "apiKey", label: "API Key", prompt: "留空使用内置免费额度")]
    case .ai: [SecretField(name: "apiKey", label: "API Key", prompt: "本机模型可留空")]
    case .baidu:
      [SecretField(name: "appId", label: "App ID"), SecretField(name: "secret", label: "密钥")]
    case .youdao:
      [SecretField(name: "appKey", label: "应用 ID"), SecretField(name: "appSecret", label: "应用密钥")]
    case .google: [SecretField(name: "apiKey", label: "API Key")]
    case .deepl: [SecretField(name: "authKey", label: "Auth Key", prompt: "免费版以 :fx 结尾")]
    case .microsoft:
      [SecretField(name: "subscriptionKey", label: "Key", prompt: "留空使用免费的 Edge 接口")]
    case .volcengine:
      [
        SecretField(name: "accessKey", label: "Access Key"),
        SecretField(name: "secretKey", label: "Secret Key"),
      ]
    case .tencent:
      [
        SecretField(name: "secretId", label: "SecretId"),
        SecretField(name: "secretKey", label: "SecretKey"),
      ]
    }
  }

  /// 服务分发：翻译会话和设置页「测试连接」共用这一个 switch
  func translate(_ request: TranslateRequest) -> AsyncThrowingStream<String, Error> {
    switch kind {
    case .zhipu: Zhipu.stream(request, service: self)
    case .ai: AIService.stream(request, service: self)
    case .baidu: Baidu.stream(request, service: self)
    case .youdao: Youdao.stream(request, service: self)
    case .google: Google.stream(request, service: self)
    case .deepl: DeepL.stream(request, service: self)
    case .microsoft: Microsoft.stream(request, service: self)
    case .volcengine: Volcengine.stream(request, service: self)
    case .tencent: Tencent.stream(request, service: self)
    }
  }

  /// 钥匙串里的值（去掉首尾空白，空串当没有）
  func secret(_ field: String = "apiKey") -> String? {
    Keychain.get("\(id).\(field)").flatMap {
      let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
      return value.isEmpty ? nil : value
    }
  }

  func setSecret(_ value: String?, _ field: String = "apiKey") {
    Keychain.set(value, for: "\(id).\(field)")
  }
}

/// 服务列表（设置页编辑，翻译时读）。从没存过时只有智谱（启用）；存过的原样用，删掉的内置服务不再补回来（体检 B21）
@Observable final class TranslateServiceStore {
  private static let key = "translateServices"

  var services: [TranslateService] {
    didSet {
      guard persists, let data = try? JSONEncoder().encode(services) else { return }
      UserDefaults.standard.set(data, forKey: Self.key)
    }
  }

  var enabled: [TranslateService] { services.filter(\.isEnabled) }

  /// 从偏好读出来的才写回偏好：单测、设置自检传进来的一份怎么改都不碰用户的服务列表
  /// （详情页里的输入框出现 / 收起时会把绑定写一遍，传进来的列表就这样盖掉过 Dev 版的真实列表）
  private let persists: Bool

  /// services：不传就读偏好（单测传一份，不读也不写用户的偏好）
  init(services: [TranslateService]? = nil) {
    persists = services == nil
    let saved =
      services
      ?? UserDefaults.standard.data(forKey: Self.key).flatMap {
        try? JSONDecoder().decode([TranslateService].self, from: $0)
      }
    self.services = saved ?? Self.defaults
  }

  /// 从没存过列表时的默认：只有内置智谱（启用），别的在设置「+」里加
  static let defaults = [TranslateService.zhipu]

  /// 还没加进列表的内置服务（设置「+」菜单里列出来）
  var missingBuiltins: [TranslateService.Kind] {
    TranslateService.Kind.allCases.filter { kind in
      kind != .ai && !services.contains { $0.id == kind.rawValue }
    }
  }

  /// 删一个服务：AI 服务连同钥匙串里的密钥一起删；内置服务只拿出列表、密钥留着（从「+」加回来还在）
  func remove(_ id: String) {
    guard let service = services.first(where: { $0.id == id }) else { return }
    if service.kind == .ai {
      for field in service.secretFields { service.setSecret(nil, field.name) }
    }
    services.removeAll { $0.id == id }
  }
}
