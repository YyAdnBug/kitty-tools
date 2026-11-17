// 翻译服务配置：列表里只有加进来的服务（体检 B21）——10 个内置服务（智谱、百度、有道、Google、DeepL、微软、火山、腾讯，
// 2026-11-05 加了不用 key 的系统翻译（macOS 26 起）和有道词典（只查单词））
// 可删、在设置「+」里加回来，外加用户自建的 AI 实例（OpenAI 兼容 / Azure / Anthropic，「+」里有厂商预设，D15）。
// 从没存过列表时默认只有智谱（启用）。列表顺序即结果卡片顺序。
// 非密钥配置以 JSON 存 UserDefaults，密钥存钥匙串（账户名 "<服务 id>.<字段>"，字段名已定，改名会读不到已存的密钥）。
// 删内置服务保留它的密钥（加回来还在），删 AI 服务连同密钥一起删。

import Foundation
import Observation

nonisolated struct TranslateService: Codable, Identifiable, Hashable, Sendable {
  enum Kind: String, Codable, CaseIterable, Sendable {
    // 新的种类只能加在 ai 前面的末尾：原值就是存下来的 id，顺序是设置「+」菜单的顺序
    case zhipu, baidu, youdao, google, deepl, microsoft, volcengine, tencent, apple, youdaoDict, ai

    /// 只查单词和短语的词典类服务：不是单词时不开卡片，不当主结果、不进静默替换（S2）
    var isDictionary: Bool { self == .youdaoDict }

    /// 不花钱、不用自己申请 key 就能用的（2026-11-15）：智谱内置的免费模型、微软的 Edge 接口（没填 Key 时）、系统翻译、
    /// 有道词典。设置「+」菜单里排最前、服务行标「免费」
    var isFree: Bool { [.zhipu, .microsoft, .apple, .youdaoDict].contains(self) }

    /// 默认名（显示用，跟界面语言）。存进 name 的是 defaultName（中文原文）
    var nameResource: LocalizedStringResource {
      switch self {
      case .zhipu: "智谱 GLM（免费）"
      case .baidu: "百度翻译"
      case .youdao: "有道翻译"
      case .google: "Google 翻译"
      case .deepl: "DeepL"
      case .microsoft: "微软翻译"
      case .volcengine: "火山翻译"
      case .tencent: "腾讯翻译"
      case .apple: "系统翻译"
      case .youdaoDict: "有道词典"
      case .ai: "AI 服务"
      }
    }

    /// 存进 name 的默认名：永远是中文原文（跟着同步、导出走；显示时按它认出没改过名的内置服务再翻，多语言第 4 批）
    var defaultName: String { nameResource.key }

    /// 卡片、「+」菜单、标着「免费」的服务行里用的短默认名：去掉括号里的说明（智谱 GLM（免费）→ 智谱 GLM）
    var shortNameResource: LocalizedStringResource {
      self == .zhipu ? "智谱 GLM" : nameResource
    }
  }

  enum AIProtocol: String, Codable, CaseIterable, Sendable {
    case openai, azure, anthropic

    var titleResource: LocalizedStringResource {
      switch self {
      case .openai: "OpenAI 兼容"
      case .azure: "Azure OpenAI"
      case .anthropic: "Anthropic"
      }
    }

    var title: String { String(localized: titleResource) }
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

  /// 没改过名（存的还是中文默认名）时不是用户写的字：显示跟界面语言（存的不动）。AI 服务没改名的「AI 服务」也算
  private var isDefaultName: Bool { name == kind.defaultName }

  /// 显示的名字：没改过名的换成当前语言的默认名；改过的是用户的（AI 服务的预设名按建的那一刻的语言写），原样
  var displayName: String { isDefaultName ? String(localized: kind.nameResource) : name }

  /// 卡片标题、主结果播报、设置「+」菜单里的短名字：默认名去掉括号里的说明，AI 服务名字末尾全角括号里的说明也去掉
  var shortName: String {
    isDefaultName ? String(localized: kind.shortNameResource) : name.replacing(/（.*）$/, with: "")
  }

  /// 存在翻译历史里的服务名（写入那一刻的 name）显示时同样翻：是内置服务的中文默认名就换成当前语言的
  static func displayName(stored: String) -> String {
    Kind.allCases.first { $0.defaultName == stored }.map {
      String(localized: $0.nameResource)
    } ?? stored
  }

  static var zhipu: TranslateService { builtin(.zhipu) }

  static func builtin(_ kind: Kind) -> TranslateService {
    TranslateService(
      id: kind.rawValue, kind: kind, name: kind.defaultName, isEnabled: kind == .zhipu,
      model: kind == .zhipu ? zhipuModels[0] : nil)
  }

  static func newAI() -> TranslateService {
    TranslateService(
      // 名字是用户的：按建的那一刻的界面语言写
      id: "ai:" + UUID().uuidString.prefix(8).lowercased(), kind: .ai,
      name: String(localized: Kind.ai.nameResource),
      isEnabled: false, model: "", baseURL: "", aiProtocol: .openai)
  }

  /// 「+ › AI 服务」里的厂商预设（D15）：只用来填好名称、协议和地址（经 AIService.endpoint 补全），不持久化；
  /// 模型留空（进详情页后填了 Key 自动取模型列表）。名称是加进去那一刻界面语言的写法（通义千问 / Qwen），之后是用户的数据
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
      name: String(localized: "通义千问"), aiProtocol: .openai,
      baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1"),
    AIPreset(name: "Kimi", aiProtocol: .openai, baseURL: "https://api.moonshot.cn/v1"),
    AIPreset(
      name: String(localized: "硅基流动"), aiProtocol: .openai,
      baseURL: "https://api.siliconflow.cn/v1"),
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
    case .zhipu:
      [SecretField(name: "apiKey", label: "API Key", prompt: String(localized: "留空使用内置免费额度"))]
    case .ai: [SecretField(name: "apiKey", label: "API Key", prompt: String(localized: "本机模型可留空"))]
    case .baidu:
      [
        SecretField(name: "appId", label: "App ID"),
        SecretField(
          // 百度的「密钥」是一格（英文 Secret Key），和详情页那一节的标题「密钥」（Keys）分开
          name: "secret", label: String(localized: "translate.baidu.secret", defaultValue: "密钥")),
      ]
    case .youdao:
      [
        SecretField(name: "appKey", label: String(localized: "应用 ID")),
        SecretField(name: "appSecret", label: String(localized: "应用密钥")),
      ]
    case .google: [SecretField(name: "apiKey", label: "API Key")]
    case .deepl:
      [SecretField(name: "authKey", label: "Auth Key", prompt: String(localized: "免费版以 :fx 结尾"))]
    case .microsoft:
      [
        SecretField(
          name: "subscriptionKey", label: "Key", prompt: String(localized: "留空使用免费的 Edge 接口"))
      ]
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
    case .apple, .youdaoDict: []
    }
  }

  /// 翻译会话、静默替换、截图翻译和设置页「测试连接」都从这里发：大模型的原文太长时先按段切开、依次翻（X2，`LongText`）
  func translate(_ request: TranslateRequest) -> AsyncThrowingStream<String, Error> {
    if !request.isWord, let tokens = outputTokens {
      let pieces = LongText.split(request.text, budget: LongText.budget(outputTokens: tokens))
      if pieces.count > 1 {
        return LongText.stream(request, pieces: pieces) { [self] in dispatch($0) }
      }
    }
    return dispatch(request)
  }

  /// 一次最多出多少 token 的译文（大模型才有；传统接口按字数限、整段一次给）：智谱 1024，AI 服务同它发的 max_tokens，
  /// 没传 max_tokens 的（OpenAI 官方、Azure）由模型自己定、不切
  var outputTokens: Int? {
    switch kind {
    case .zhipu: return Zhipu.maxTokens
    case .ai:
      let aiProtocol = aiProtocol ?? .openai
      if aiProtocol == .anthropic { return 4096 }
      return AIService.endpoint(baseURL ?? "", aiProtocol).flatMap {
        AIService.maxTokens($0, aiProtocol)
      }
    default: return nil
    }
  }

  /// 服务分发：只有这一个 switch
  private func dispatch(_ request: TranslateRequest) -> AsyncThrowingStream<String, Error> {
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
    case .apple: AppleTranslation.stream(request, service: self)
    case .youdaoDict: YoudaoDict.stream(request, service: self)
    }
  }

  /// 一个字段在钥匙串里的账户名（设置的导出 / 导入也按它认，SettingsArchive）
  func account(_ field: String) -> String { "\(id).\(field)" }

  /// 钥匙串里的值（去掉首尾空白，空串当没有）
  func secret(_ field: String = "apiKey") -> String? {
    Keychain.get(account(field)).flatMap {
      let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
      return value.isEmpty ? nil : value
    }
  }

  func setSecret(_ value: String?, _ field: String = "apiKey") {
    Keychain.set(value, for: account(field))
  }
}

/// 服务列表（设置页编辑，翻译时读）。从没存过时只有智谱（启用）；存过的原样用，删掉的内置服务不再补回来（体检 B21）
@Observable final class TranslateServiceStore {
  nonisolated static let key = "translateServices"

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
        && (kind != .apple || AppleTranslation.isAvailable)
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
