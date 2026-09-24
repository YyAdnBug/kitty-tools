// 翻译相关单测：语言解析、流式文本清洗、AI 服务地址 / 参数、局域网判断、翻译历史；
// 以及按需启用的联网冒烟测试（TEST_RUNNER_KITTY_LIVE_TRANSLATE=1，用内置智谱 key 真翻一句）。

import Foundation
import Testing

@testable import KittyTools

struct LanguageTests {
  @Test func smartTarget() {
    let resolve = { (detected: Lang?) in
      Lang.resolve(source: nil, target: nil, detected: detected, native: .zhHans, foreign: .en)
    }
    #expect(resolve(.zhHans) == (.zhHans, .en))
    #expect(resolve(.zhHant) == (.zhHant, .en))  // 繁体也算母语
    #expect(resolve(.ja) == (.ja, .zhHans))
    #expect(resolve(nil) == (nil, .zhHans))  // 检测不出：交给服务识别，译成母语
  }

  @Test func fixedTargetSwapsWhenSameLanguage() {
    let result = Lang.resolve(
      source: nil, target: .zhHans, detected: .zhHant, native: .zhHans, foreign: .en)
    #expect(result == (.zhHant, .en))
    #expect(
      Lang.resolve(source: .fr, target: .de, detected: .en, native: .zhHans, foreign: .en) == (
        .fr, .de
      ))
  }

  @Test func detection() {
    #expect(Lang.detect("今天天气很好，我们去公园散步吧") == .zhHans)
    #expect(Lang.detect("The quick brown fox jumps over the lazy dog") == .en)
    #expect(Lang.detect("こんにちは、元気ですか") == .ja)
    #expect(Lang.detect("a") == nil)
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
