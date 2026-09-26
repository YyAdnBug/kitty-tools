// 翻译相关单测：语言解析、流式文本清洗、AI 服务地址 / 参数、局域网判断、翻译历史（存储、撤销删除、列表分组与选中）、
// 「翻译 ↩」胶囊的出现条件、服务 logo 都在 asset catalog 里；
// 以及按需启用的联网冒烟测试（TEST_RUNNER_KITTY_LIVE_TRANSLATE=1，用内置智谱 key 真翻一句）。

import AppKit
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

  /// 单词模式（D4）：按词典格式回答——有音标行、词性行、例句行，打印出来人工看格式
  @Test(.enabled(if: ProcessInfo.processInfo.environment["KITTY_LIVE_TRANSLATE"] != nil))
  func liveZhipuWordMode() async throws {
    for (word, target) in [("serendipity", Lang.zhHans), ("苹果", .en)] {
      let request = TranslateRequest(text: word, from: nil, to: target, isWord: true)
      var result = ""
      for try await text in TranslateService.zhipu.translate(request) { result = text }
      print("单词模式「\(word)」→\n\(result)\n")
      #expect(result.split(separator: "\n").count >= 2, "\(result)")
    }
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

  @Test func favoritesWithoutHistoryAndFilter() throws {
    let store = try HistoryStore(db: Database(path: ":memory:"))
    // 关了历史（库里没有这条）也能收藏：连译文一起记一条
    #expect(!store.isFavorite(source: " apple ", target: .zhHans))
    store.setFavorite(source: " apple ", target: .zhHans, result: "苹果", service: "智谱", true)
    #expect(store.isFavorite(source: "apple", target: .zhHans))  // 和 add 一样去首尾空白
    store.add(source: "banana", target: .zhHans, result: "香蕉", service: "智谱", limit: 0)
    // 再次写同一条译文不改收藏；取消收藏只改收藏
    store.add(source: "apple", target: .zhHans, result: "苹果（新）", service: "智谱", limit: 0)
    #expect(store.isFavorite(source: "apple", target: .zhHans))
    #expect(store.search("", favoritesOnly: true).map(\.source) == ["apple"])
    #expect(store.search("香", favoritesOnly: true).isEmpty)
    store.setFavorite(source: "apple", target: .zhHans, result: "苹果", service: "智谱", false)
    #expect(store.search("", favoritesOnly: true).isEmpty)
    #expect(store.search("", limit: 0).count == 2)
    store.remove(source: " apple", target: .zhHans)  // 关着历史时取消收藏：删掉这条
    #expect(store.search("", limit: 0).map(\.source) == ["banana"])
  }

  @Test func exportCSVAndAnkiTSV() {
    let entry = HistoryStore.Entry(
      id: UUID(), source: "say \"hi\", ok\r\nline2", target: .zhHans, result: "-ing\t<b>&",
      service: "智谱", createdAt: Date(timeIntervalSince1970: 0), favorite: true)
    let csv = HistoryStore.csv([entry], timeZone: TimeZone(identifier: "Asia/Shanghai")!)
    // 表头 + 一行；含逗号 / 引号 / 换行（包括 \r\n）的字段加引号、引号双写；- 开头的前面加 '（防 Excel 公式）；
    // 时间写本地时间；行尾 CRLF
    #expect(csv.hasPrefix("原文,译文,目标语言,服务,时间,收藏\r\n"))
    #expect(csv.contains("\"say \"\"hi\"\", ok\r\nline2\","))
    #expect(csv.contains(",'-ing\t<b>&,"))
    #expect(csv.hasSuffix(",1970-01-01 08:00:00,是\r\n"))
    // Anki：带 #separator / #html 头；HTML 转义、换行变 <br>、Tab 变空格；含引号、以 # 开头的字段加引号
    let tsv = HistoryStore.tsv([
      entry,
      HistoryStore.Entry(
        id: UUID(), source: "# Getting Started", target: .zhHans, result: "a\rb\u{2028}c",
        service: "", createdAt: .now, favorite: false),
    ])
    #expect(
      tsv
        == "#separator:tab\n#html:true\n"
        + "\"say \"\"hi\"\", ok<br>line2\"\t-ing &lt;b&gt;&amp;\n"
        + "\"# Getting Started\"\ta<br>b<br>c\n")
  }

  @Test func replacementKeepsSelectionWhitespace() {
    // 三击选中的整行带换行：替换后段落不能被接起来
    #expect(TranslateCoordinator.rewrap("你好，世界。 ", like: "Hello world.\n") == "你好，世界。\n")
    #expect(TranslateCoordinator.rewrap("你好", like: "  Hello  ") == "  你好  ")
    #expect(TranslateCoordinator.rewrap("你好", like: "\n\n") == "你好")
  }

  @Test func silentReplaceHasNoDefaultHotKey() {
    #expect(HotKeyAction.translateReplace.defaultHotKey == nil)
    #expect(HotKeyAction.allCases.last == .translateReplace)  // 只能加在末尾（注册 id 是下标）
  }

  /// 「翻译 ↩」胶囊（N5）：原文非空、且和上次翻译的原文（去首尾空白）不同才出现
  @Test func translateCapsuleOnlyAfterEditing() {
    #expect(TranslateCoordinator.isEdited("hello", since: nil))  // 输入翻译：打了字还没翻
    #expect(!TranslateCoordinator.isEdited("  \n", since: nil))
    #expect(!TranslateCoordinator.isEdited("hello \n", since: "hello"))  // 只多了空白不算改
    #expect(TranslateCoordinator.isEdited("hello world", since: "hello"))
    #expect(!TranslateCoordinator.isEdited("", since: "hello"))  // 清空了：没东西可翻
  }

  /// 撤销删除原样插回；这期间又翻译过同一句（同原文 + 同目标已有新记录）就不插
  @Test func restoreAfterDelete() throws {
    let store = try HistoryStore(db: Database(path: ":memory:"))
    store.add(source: "hello", target: .zhHans, result: "你好", service: "A", limit: 0)
    let entry = try #require(store.search("").first)
    store.setFavorite(entry.id, true)
    let favorite = try #require(store.search("").first)
    store.delete(favorite.id)
    #expect(store.search("").isEmpty)
    store.restore(favorite)
    #expect(store.search("") == [favorite])
    store.delete(favorite.id)
    store.add(source: "hello", target: .zhHans, result: "您好", service: "B", limit: 0)
    store.restore(favorite)
    #expect(store.search("").map(\.result) == ["您好"])
  }
}

/// 翻译历史列表（N7）：按天分组、高亮前缀和、↑↓ 循环、⌘⌫ 删后选中下一条、⌘Z 插回
struct HistoryListTests {
  @Test func groupsByDayAndOffsets() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
    // 2026-09-26 10:00（上海）
    let now = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 10)))
    func entry(_ hoursAgo: Double) -> HistoryStore.Entry {
      HistoryStore.Entry(
        id: UUID(), source: "s", target: .zhHans, result: "r", service: "",
        createdAt: now.addingTimeInterval(-hoursAgo * 3600), favorite: false)
    }
    // 今天 9:00、今天 0:30、昨天 23:00、9 月 20 日、去年 12 月 31 日
    let entries = [entry(1), entry(9.5), entry(11), entry(6 * 24), entry(269 * 24)]
    let sections = HistoryView.sections(entries, now: now, calendar: calendar)
    #expect(sections.map(\.title) == ["今天", "昨天", "9月20日", "2025年12月31日"])
    #expect(sections.map(\.entries.count) == [2, 1, 1, 1])
    // 标题 24 + 行 44 累加：第一条在 24，昨天那条在 24 + 88 + 24
    #expect(HistoryView.offset(of: entries[0].id, in: sections) == 24)
    #expect(HistoryView.offset(of: entries[2].id, in: sections) == 136)
    #expect(HistoryView.offset(of: entries[4].id, in: sections) == 272)  // 4 个标题 + 4 行
    #expect(HistoryView.offset(of: UUID(), in: sections) == nil)
  }

  @Test func moveDeleteUndo() throws {
    let store = try HistoryStore(db: Database(path: ":memory:"))
    for word in ["c", "b", "a"] {  // 新→旧：a b c
      store.add(source: word, target: .en, result: word.uppercased(), service: "", limit: 0)
    }
    let list = HistoryList(store: store)
    #expect(list.selected?.source == "a")  // 没选时是第一条
    list.move(by: -1)
    #expect(list.selected?.source == "c")  // 首尾循环
    list.move(by: -1)
    #expect(list.selected?.source == "b")
    let b = try #require(list.selected)
    list.delete(b)
    #expect(list.entries.map(\.source) == ["a", "c"])
    #expect(list.selected?.source == "c")  // 删掉选中的：挪到下一条
    let c = try #require(list.selected)
    list.delete(c)
    #expect(list.selected?.source == "a")  // 删的是最后一条：挪到上一条
    #expect(list.undoDelete())
    #expect(list.undoDelete())
    #expect(!list.undoDelete())
    #expect(list.entries.map(\.source) == ["a", "b", "c"])
    #expect(list.selected?.source == "b")  // 插回的那条被选中
    list.query = "c"
    #expect(list.selected?.source == "c")  // 搜索词变了：选中回到第一条
    list.reset()
    #expect(list.query.isEmpty && list.entries.count == 3)
  }
}

struct ServiceLogoTests {
  @Test func logosExistInAssetCatalog() throws {
    var services = TranslateService.Kind.allCases.filter { $0 != .ai }.map(TranslateService.builtin)
    for proto in [TranslateService.AIProtocol.anthropic, .azure] {
      var ai = TranslateService.newAI()
      ai.aiProtocol = proto
      services.append(ai)
    }
    for name in ["Gemini 2.5 Flash", "GPT-4o mini"] {
      var ai = TranslateService.newAI()
      ai.name = name
      services.append(ai)
    }
    let named = services.compactMap(ServiceTile.logo(for:))
    #expect(named.count == services.count)
    for logo in named {
      #expect(NSImage(named: logo.name) != nil, "\(logo.name)")
    }
    #expect(ServiceTile.logo(for: .newAI()) == nil)
  }
}
