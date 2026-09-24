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

  @Test func storeAlwaysHasEveryBuiltin() {
    let services = TranslateServiceStore.withBuiltins([TranslateService.newAI()])
    #expect(services.count == 9)
    #expect(
      services.filter { $0.kind != .ai }.map(\.id)
        == TranslateService.Kind.allCases.filter { $0 != .ai }.map(\.rawValue))
    #expect(services.filter(\.isEnabled).map(\.id) == ["zhipu"])  // 新装默认只开智谱
  }
}
