// 各家翻译接口的签名与语言码单测。期望值来自官方文档示例（百度）或独立的 Python 实现（有道、火山、腾讯），
// 不是拿本实现自己算的结果回填。

import Foundation
import Testing

@testable import KittyTools

struct ProviderSigningTests {
  @Test func baiduMatchesOfficialExample() {
    // 百度翻译开放平台文档示例：appid=2015063000000001, q=apple, salt=1435660288, 密钥=12345678
    #expect(
      Baidu.sign(appID: "2015063000000001", text: "apple", salt: "1435660288", secret: "12345678")
        == "f89f9594663708c1605f3d736d01d2d4")
  }

  @Test func youdaoTruncatesLongInput() {
    let text = "这是一段超过二十个字的中文文本，用来测试有道签名的截断规则是否正确"
    #expect(
      Youdao.sign(
        appKey: "app123", text: text, salt: "salt-789", time: "1790000000", secret: "secret456")
        == "460d2560f033e6e5421c6dac276a5eedff8ff116a18054c0a1fb7c0caddde8ab")
  }

  @Test func volcengineSignature() {
    let headers = Volcengine.headers(
      accessKey: "AKLTexample", secretKey: "secretExample==",
      body: Data(#"{"TargetLanguage":"zh","TextList":["Hello"]}"#.utf8),
      date: Date(timeIntervalSince1970: 1_790_000_000))
    #expect(headers["X-Date"] == "20260921T141320Z")
    #expect(
      headers["Authorization"]
        == "HMAC-SHA256 Credential=AKLTexample/20260921/cn-north-1/translate/request, "
        + "SignedHeaders=content-type;host;x-content-sha256;x-date, "
        + "Signature=b4cb639f34c3dfde96cf8f999f0b73c489dfdd13ddb97c584ac223d61aaa9de7")
  }

  @Test func tencentSignature() {
    let headers = Tencent.headers(
      secretID: "AKIDexample", secretKey: "tencentSecret",
      body: Data(#"{"SourceText":"Hello","Source":"auto","Target":"zh","ProjectId":0}"#.utf8),
      timestamp: 1_790_000_000)
    #expect(
      headers["Authorization"]
        == "TC3-HMAC-SHA256 Credential=AKIDexample/2026-09-21/tmt/tc3_request, "
        + "SignedHeaders=content-type;host, "
        + "Signature=b2508c75f3a556c695d9ad2be875ee2c23d68274afc02489fe9ea255693d9403")
    #expect(headers["X-TC-Action"] == "TextTranslate" && headers["X-TC-Timestamp"] == "1790000000")
  }

  @Test func languageCodes() {
    #expect(Baidu.code(nil) == "auto" && Baidu.code(.zhHant) == "cht" && Baidu.code(.ja) == "jp")
    #expect(Youdao.code(.zhHans) == "zh-CHS" && Youdao.code(.en) == "en")
    // DeepL：源只收基础码，目标要带变体（旧版共用一张映射，繁体丢失）
    #expect(DeepL.sourceCode(.zhHant) == "ZH" && DeepL.sourceCode(.pt) == "PT")
    #expect(DeepL.targetCode(.zhHant) == "ZH-HANT" && DeepL.targetCode(.en) == "EN-US")
    #expect(Microsoft.code(.zhHans) == "zh-Hans" && Tencent.code(.zhHant) == "zh-TW")
    #expect(Google.code(.zhHans) == "zh-CN" && Volcengine.code(.zhHant) == "zh-Hant")
  }

  @Test func formEncodingEscapesReservedCharacters() {
    let body = String(decoding: Signing.form([("q", "a&b=c+d 中")]), as: UTF8.self)
    #expect(body == "q=a%26b%3Dc%2Bd%20%E4%B8%AD")
  }

  /// 服务列表只放加进来的（体检 B21）：从没存过时只有智谱（启用）；存过的原样用、删掉的内置服务不补回来，
  /// 「+」里列出没加的内置服务；删内置服务不碰钥匙串（加回来密钥还在）
  @Test func storeKeepsOnlyAddedServices() {
    #expect(TranslateServiceStore.defaults.map(\.id) == ["zhipu"])
    #expect(TranslateServiceStore.defaults.map(\.isEnabled) == [true])
    let ai = TranslateService.newAI()
    let store = TranslateServiceStore(services: [.builtin(.baidu), ai])
    #expect(store.services.map(\.id) == ["baidu", ai.id])  // 不再自动补齐 8 个内置
    #expect(store.missingBuiltins.count == 7 && !store.missingBuiltins.contains(.baidu))
    #expect(!store.missingBuiltins.contains(.ai))
    // 传进来的列表怎么改都不写用户的偏好（详情页的输入框会把绑定写一遍，曾经这样盖掉过 Dev 版的真实列表）
    let saved = UserDefaults.standard.data(forKey: "translateServices")
    store.services.removeAll()
    store.remove(ai.id)
    #expect(UserDefaults.standard.data(forKey: "translateServices") == saved)
  }

  /// 智谱两档免费纯文本模型（体检 A17）：旧的识图模型 glm-4.6v-flash 和不认识的值回落第一档
  @Test func zhipuModelsAreFreeTextModels() {
    #expect(TranslateService.zhipuModels == ["glm-4-flash", "glm-4.7-flash"])
    #expect(TranslateService.zhipuModel("glm-4.7-flash") == "glm-4.7-flash")
    #expect(TranslateService.zhipuModel("glm-4.6v-flash") == "glm-4-flash")
    #expect(TranslateService.zhipuModel(nil) == "glm-4-flash")
  }

  /// 「+ › AI 服务」的厂商预设（D15）：地址经 AIService.endpoint 补全成各家的对话接口，模型留空、默认关
  @Test func aiPresetsResolveEndpoints() throws {
    var endpoints: [String] = []
    for preset in TranslateService.aiPresets {
      let service = preset.make()
      #expect(service.kind == .ai && service.name == preset.name && !service.isEnabled)
      #expect(service.model == "")
      let url = AIService.endpoint(service.baseURL ?? "", service.aiProtocol ?? .openai)
      endpoints.append(try #require(url).absoluteString)
    }
    #expect(
      endpoints == [
        "https://api.openai.com/v1/chat/completions",
        "https://api.deepseek.com/v1/chat/completions",
        "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
        "https://api.moonshot.cn/v1/chat/completions",
        "https://api.siliconflow.cn/v1/chat/completions",
        "https://openrouter.ai/api/v1/chat/completions",
        "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
        "https://api.anthropic.com/v1/messages", "http://127.0.0.1:11434/v1/chat/completions",
      ])
    #expect(Set(TranslateService.aiPresets.map(\.id)).count == TranslateService.aiPresets.count)
  }

  /// 百度 / 有道的错误码译成中文（体检 B24）；密钥类是配置错误（橙色、去设置）
  @Test func providerErrorCodesAreReadable() {
    #expect(Baidu.error(code: "52003") == .config("App ID 或密钥不对"))
    #expect(
      Baidu.error(code: "54001").kind == .config && Baidu.error(code: "90107").kind == .config)
    #expect(Baidu.error(code: "54003").message == "请求太频繁，稍后再试")
    #expect(Baidu.error(code: "54003").kind == .service)
    #expect(Baidu.error(code: "58002").kind == .config)
    #expect(Baidu.error(code: "12345").message == "百度翻译出错（错误码 12345）")
    #expect(Youdao.error(code: "108") == .config("应用 ID 或应用密钥不对"))
    #expect(Youdao.error(code: "202").kind == .config && Youdao.error(code: "101").kind == .config)
    #expect(Youdao.error(code: "401").message == "有道翻译账户已欠费")
    #expect(Youdao.error(code: "999").message == "有道翻译出错（错误码 999）")
    // 缺密钥、HTTP 401 / 404 也是配置类；网络错误、5xx 不是
    #expect(TranslateError.config("x").kind == .config)
    #expect((HTTP.userFacing(URLError(.timedOut)) as? TranslateError)?.kind == .network)
  }
}
