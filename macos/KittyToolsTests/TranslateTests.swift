// 翻译相关单测：语言解析、流式文本清洗、AI 服务地址 / 参数、局域网判断、翻译历史；
// 以及按需启用的联网冒烟测试（TEST_RUNNER_KITTY_LIVE_TRANSLATE=1，用内置智谱 key 真翻一句）。

import Foundation
import Testing

@testable import KittyTools

struct LanguageTests {
  private func resolve(_ source: Lang?, _ target: Lang?, detected: Lang?) -> Lang.Plan {
    Lang.resolve(source: source, target: target, detected: detected, first: .zhHans, second: .en)
  }

  @Test func autoTargetUsesFirstAndSecondLanguage() {
    #expect(resolve(nil, nil, detected: .zhHans) == .init(from: nil, to: .en))
    #expect(resolve(nil, nil, detected: .zhHant) == .init(from: nil, to: .en))  // 简繁算同一种
    #expect(resolve(nil, nil, detected: .ja) == .init(from: nil, to: .zhHans))
    #expect(resolve(nil, nil, detected: nil) == .init(from: nil, to: .zhHans))  // 纯数字等
    // 源自动时不把本地检测结果发给服务，让服务自己识别
    #expect(resolve(nil, .ja, detected: .en) == .init(from: nil, to: .ja))
  }

  @Test func fixedTargetEqualToTextFallsBackToAuto() {
    // 源自动、目标日语、原文日语：改译第一语言并标记，界面写「原文已是日语」
    #expect(resolve(nil, .ja, detected: .ja) == .init(from: nil, to: .zhHans, fellBack: true))
    #expect(resolve(nil, .zhHans, detected: .zhHans) == .init(to: .en, fellBack: true))
    // 简体原文、目标繁体是用户要的转换，照做
    #expect(resolve(nil, .zhHant, detected: .zhHans) == .init(from: nil, to: .zhHant))
  }

  @Test func fixedSourceIsTrusted() {
    // 「英文 → 日语」照所选发出（原文不符只在界面提示，不改方向）
    #expect(resolve(.en, .ja, detected: .zhHans) == .init(from: .en, to: .ja))
    #expect(resolve(.en, nil, detected: .zhHans) == .init(from: .en, to: .zhHans))
    #expect(resolve(.zhHans, nil, detected: .ja) == .init(from: .zhHans, to: .en))
    // 旧设置留下的「英 → 英」：目标按自动处理
    #expect(resolve(.en, .en, detected: .en) == .init(from: .en, to: .zhHans))
  }

  @Test func preferredPairNeverRepeats() {
    #expect(Lang.pair(first: nil, second: nil) == (.zhHans, .en))
    #expect(Lang.pair(first: "ja", second: "ja") == (.ja, .en))
    #expect(Lang.pair(first: "en", second: "en") == (.en, .zhHans))
    #expect(Lang.pair(first: "zh-Hans", second: "zh-Hant") == (.zhHans, .en))
  }

  @Test func detection() {
    let preferred: [Lang] = [.zhHans, .en]
    #expect(Lang.detect("今天天气很好，我们去公园散步吧") == .zhHans)
    #expect(Lang.detect("The quick brown fox jumps over the lazy dog") == .en)
    #expect(Lang.detect("こんにちは、元気ですか") == .ja)
    // 短文本靠第一 / 第二语言的先验：不加先验时「你好」判成繁体、「API」判成意大利语，「猫」会译成中文
    #expect(Lang.detect("你好", preferring: preferred) == .zhHans)
    #expect(Lang.detect("猫", preferring: preferred) == .zhHans)
    #expect(Lang.detect("API", preferring: preferred) == .en)
    // 证据足够时先验不会盖过实际语言
    #expect(Lang.detect("東京", preferring: preferred) == .ja)
    #expect(Lang.detect("頭髮", preferring: preferred) == .zhHant)
    #expect(Lang.detect("Bonjour", preferring: preferred) == .fr)
    #expect(Lang.detect("12345", preferring: preferred) == nil)
    // 中文里夹英文词：只看中文部分（否则判成英语 / 德语，自动模式会中译中）
    #expect(Lang.detect("请帮我 review 一下这个 PR", preferring: preferred) == .zhHans)
    #expect(Lang.detect("iPhone 17 Pro Max 发布了", preferring: preferred) == .zhHans)
    #expect(Lang.detect("このアプリは iPhone で動く", preferring: preferred) == .ja)
    #expect(Lang.detect("The word 猫 means cat in Chinese", preferring: preferred) == .en)
  }
}

struct StreamingTextTests {
  @Test func stripsLeadingThinkEvenWhenSplit() {
    var text = StreamingText()
    for piece in ["<thi", "nk>让我想想", "</think>\n\n你好"] { text.append(piece) }
    #expect(text.visible == "你好")
    var partial = StreamingText()
    partial.append("<th")
    #expect(partial.visible.isEmpty)  // 可能是开标签，先不显示
  }

  @Test func keepsInnerTagsAndStripsOuterQuotes() {
    var text = StreamingText()
    text.append("“你好，世界”")
    #expect(text.final == "你好，世界")
    var inner = StreamingText()
    inner.append("用 <think> 标签")
    #expect(inner.final == "用 <think> 标签")
    var quoted = StreamingText()
    quoted.append("\"a\" and \"b\"")
    #expect(quoted.final == "\"a\" and \"b\"")  // 不是整段包一层，不动
  }
}

struct AIServiceTests {
  @Test func endpoints() {
    let url = { (raw: String, proto: TranslateService.AIProtocol) in
      AIService.endpoint(raw, proto)?.absoluteString
    }
    #expect(
      url("https://api.openai.com/v1", .openai) == "https://api.openai.com/v1/chat/completions")
    #expect(url("api.deepseek.com", .openai) == "https://api.deepseek.com/v1/chat/completions")
    #expect(
      url("http://127.0.0.1:11434/v1/", .openai) == "http://127.0.0.1:11434/v1/chat/completions")
    #expect(
      url("https://x.com/v1/chat/completions", .openai) == "https://x.com/v1/chat/completions")
    #expect(
      url("https://r.openai.azure.com/openai/v1", .azure)
        == "https://r.openai.azure.com/openai/v1/chat/completions")
    #expect(
      url("https://api.ohmygpt.com/v1beta", .openai)
        == "https://api.ohmygpt.com/v1beta/chat/completions")
    #expect(url("", .anthropic) == "https://api.anthropic.com/v1/messages")
    #expect(url("", .openai) == nil)
  }

  @Test func maxTokensAndTiers() throws {
    let zhipu = try #require(URL(string: "https://open.bigmodel.cn/api/paas/v4/chat/completions"))
    let openAI = try #require(URL(string: "https://api.openai.com/v1/chat/completions"))
    let local = try #require(URL(string: "http://192.168.1.8:8000/v1/chat/completions"))
    #expect(AIService.maxTokens(zhipu, .openai) == 1024)
    #expect(AIService.maxTokens(openAI, .openai) == nil)
    #expect(AIService.maxTokens(local, .openai) == 4096)
    #expect(AIService.tiers(openAI, .openai, "gpt-4o").count == 1)  // 老模型什么都不带
    #expect(AIService.tiers(zhipu, .openai, "glm-4-flash").first?["thinking"] != nil)
    #expect(AIService.tiers(local, .openai, "qwen3").first?["chat_template_kwargs"] != nil)
    #expect(AIService.tiers(openAI, .openai, "gpt-5").last?.isEmpty == true)  // 最后一档兜底
  }

  @Test func localNetwork() {
    for host in [
      "http://localhost:1234", "http://127.0.0.1", "http://10.0.0.2", "http://172.20.1.1",
      "http://192.168.0.5", "http://nas.local", "http://mybox", "http://[::1]:8080",
    ] {
      #expect(HTTP.isLocalNetwork(URL(string: host)!), "\(host)")
    }
    for host in [
      "https://api.openai.com", "http://172.32.0.1", "https://8.8.8.8", "https://fcdn.example.com",
    ] {
      #expect(!HTTP.isLocalNetwork(URL(string: host)!), "\(host)")
    }
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["KITTY_LIVE_TRANSLATE"] != nil))
  func liveZhipu() async throws {
    let request = TranslateRequest(text: "Hello, world", from: .en, to: .zhHans)
    var result = ""
    for try await text in TranslateService.zhipu.translate(request) { result = text }
    #expect(result.contains("你好"), "\(result)")
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["KITTY_LIVE_TRANSLATE"] != nil))
  func liveMicrosoftEdge() async throws {
    let request = TranslateRequest(text: "Good morning", from: nil, to: .zhHans)
    var result = ""
    for try await text in TranslateService.builtin(.microsoft).translate(request) { result = text }
    #expect(result.contains("早"), "\(result)")
  }
}

struct HistoryStoreTests {
  @Test func upsertKeepsFavoriteAndLimitSkipsFavorites() throws {
    let store = try HistoryStore(db: Database(path: ":memory:"))
    store.add(source: "hello", target: .zhHans, result: "你好", service: "A", limit: 2)
    let first = try #require(store.search("").first)
    store.setFavorite(first.id, true)
    store.add(source: "hello", target: .zhHans, result: "您好", service: "B", limit: 2)
    #expect(store.search("").count == 1)
    #expect(store.search("").first?.result == "您好" && store.search("").first?.favorite == true)
    for word in ["a", "b", "c"] {
      store.add(source: word, target: .en, result: word, service: "A", limit: 2)
    }
    #expect(Set(store.search("").map(\.source)) == ["hello", "b", "c"])  // 收藏不占名额
    #expect(store.counts == (3, 1))
  }

  @Test func searchEscapesWildcards() throws {
    let store = try HistoryStore(db: Database(path: ":memory:"))
    store.add(source: "100% sure", target: .zhHans, result: "百分百", service: "A", limit: 0)
    store.add(source: "1000 sure", target: .zhHans, result: "一千", service: "A", limit: 0)
    #expect(store.search("100%").map(\.result) == ["百分百"])
    #expect(store.search("百分").count == 1)
    store.clearNonFavorites()
    #expect(store.counts.total == 0)
  }
}
