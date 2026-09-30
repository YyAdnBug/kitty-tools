// 翻译相关单测：语言解析、流式文本清洗、AI 服务地址 / 参数、局域网判断、翻译历史（存储、撤销删除、列表分组与选中）、
// 「翻译 ↩」胶囊的出现条件、服务 logo 都在 asset catalog 里、按地址 / 名字认厂商与官网图标（第 13 批）、结果卡片正文的高度上限；
// 体检第 4 批：复制即译过滤、自动复制按来源、截断与思考的流约定、错误种类、划词没取到、输入翻译再打开、⌘D 收藏、
// 历史 ⌘K 与分页、浮窗跟随鼠标、历史保留档位升级、朗读声线；
// 以及按需启用的联网冒烟测试（TEST_RUNNER_KITTY_LIVE_TRANSLATE=1，用内置智谱 key 真翻一句）。

import AVFoundation
import AppKit
import Carbon.HIToolbox
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
    // 只能加在末尾（注册 id 是下标）：录屏（2026-09-30）接在划词翻译并替换后面，录音（录音第 5 批，不设默认键）再接在后面
    #expect(
      Array(HotKeyAction.allCases.suffix(3)) == [.translateReplace, .screenRecord, .audioRecord])
    #expect(HotKeyAction.audioRecord.defaultHotKey == nil)
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

/// 翻译历史列表（N7）：按天分组、高亮前缀和、↑↓ 循环、⌘⌫ 删 / 收藏范围里取消收藏后选中下一条、⌘Z 插回、
/// 关历史时焦点回原文框
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

  /// 「收藏」范围里 ⌘D 取消收藏选中的一条：这行消失，选中和删除一样挪到下一条（不跳回第一条）
  @Test func unfavoriteInFavoritesScopeMovesSelection() throws {
    let store = try HistoryStore(db: Database(path: ":memory:"))
    for word in ["c", "b", "a"] {
      store.add(source: word, target: .en, result: word.uppercased(), service: "", limit: 0)
    }
    for entry in store.search("") { store.setFavorite(entry.id, true) }
    let list = HistoryList(store: store)
    list.favoritesOnly = true
    list.move(by: 1)
    let b = try #require(list.selected)
    #expect(b.source == "b")
    list.toggleFavorite(b)
    #expect(list.entries.map(\.source) == ["a", "c"])
    #expect(list.selected?.source == "c")
    list.toggleFavorite(try #require(list.selected))
    #expect(list.selected?.source == "a")  // 取消的是最后一条：挪到上一条
  }

  /// 关历史时焦点立刻回原文框；历史已关（搜索框还在淡出）时搜索框的命令一律交还，↩ 不会重译第一条、Esc 不被吞
  @Test func closingHistoryReturnsFocusAndReleasesCommands() throws {
    let coordinator = TranslateCoordinator(
      services: TranslateServiceStore(services: []),
      history: try HistoryStore(db: Database(path: ":memory:")))
    var focused = 0
    coordinator.focusSource = { focused += 1 }
    coordinator.showsHistory = true
    #expect(focused == 0)
    coordinator.showsHistory = false
    #expect(focused == 1)
    coordinator.showsHistory = false
    #expect(focused == 1)  // 本来就关着：不动焦点
    #expect(!coordinator.handleHistoryCommand(#selector(NSResponder.insertNewline(_:))))
    #expect(!coordinator.handleHistoryCommand(#selector(NSResponder.cancelOperation(_:))))
    #expect(!coordinator.handleHistoryCommand(#selector(NSResponder.moveDown(_:))))
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
    services += TranslateService.aiPresets.map { $0.make() }
    let named = services.compactMap(ServiceTile.logo(for:))
    #expect(named.count == services.count)
    for logo in named {
      #expect(NSImage(named: logo.name) != nil, "\(logo.name)")
    }
    // 每家厂商都有内置图（第 13 批）
    for vendor in AIVendor.allCases {
      #expect(NSImage(named: "ServiceLogo/" + vendor.rawValue) != nil, "\(vendor)")
    }
    #expect(ServiceTile.logo(for: .newAI()) == nil)
  }

  /// 按地址认厂商（第 13 批）：各家的 host（带不带 api.、端口、大小写）、Ollama 的本机 11434、认不出的
  @Test func vendorByHost() {
    let vendor = { (url: String) in AIVendor(url: URL(string: url)!) }
    let cases: [(String, AIVendor)] = [
      ("https://api.openai.com/v1/chat/completions", .openai),
      ("https://API.DeepSeek.com/v1", .deepseek), ("https://api.deepseek.com:443/v1", .deepseek),
      ("https://dashscope.aliyuncs.com/compatible-mode/v1", .qwen),
      ("https://dashscope-intl.aliyuncs.com/compatible-mode/v1", .qwen),
      ("https://api.moonshot.cn/v1", .kimi), ("https://api.moonshot.ai/v1", .kimi),
      ("https://ark.cn-beijing.volces.com/api/v3", .doubao),
      ("https://api.siliconflow.cn/v1", .siliconflow),
      ("https://api.siliconflow.com/v1", .siliconflow),
      ("https://openrouter.ai/api/v1", .openrouter), ("http://localhost:11434/v1", .ollama),
      ("http://127.0.0.1:11434/v1", .ollama), ("http://192.168.1.8:11434", .ollama),
      ("https://ollama.com/api", .ollama), ("https://api.mistral.ai/v1", .mistral),
      ("https://api.x.ai/v1", .grok), ("https://api.minimaxi.com/v1", .minimax),
      ("https://api.minimax.io/v1", .minimax), ("https://open.bigmodel.cn/api/paas/v4", .zhipu),
      ("https://api.z.ai/api/paas/v4", .zhipu),
      ("https://api.anthropic.com/v1/messages", .anthropic),
      ("https://generativelanguage.googleapis.com/v1beta/openai", .gemini),
    ]
    for (url, expected) in cases { #expect(vendor(url) == expected, "\(url)") }
    // 认不出：自建服务、只是名字像的主机、别的端口的本机服务、Azure
    for url in [
      "https://opencode.ai/zen/go", "https://notdeepseek.com/v1", "https://abcz.ai/v1",
      "http://127.0.0.1:8000/v1", "https://r.openai.azure.com/openai", "https://x.ai.example.com",
    ] {
      #expect(vendor(url) == nil, "\(url)")
    }
    // 厂商预设各认到自己
    #expect(
      TranslateService.aiPresets.map { AIVendor(service: $0.make()) } == [
        .openai, .deepseek, .qwen, .kimi, .siliconflow, .openrouter, .gemini, .anthropic, .ollama,
      ])
  }

  /// 地址认不出再看名字，都认不出时 Anthropic 协议算 Anthropic；Azure 用微软、不归厂商表
  @Test func vendorByNameAndProtocol() {
    var proxy = TranslateService.newAI()
    proxy.baseURL = "https://llm.example.com/v1"
    proxy.name = "Kimi（公司代理）"
    #expect(AIVendor(service: proxy) == .kimi)
    proxy.name = "我的服务"
    #expect(AIVendor(service: proxy) == nil)
    proxy.aiProtocol = .anthropic
    #expect(AIVendor(service: proxy) == .anthropic)
    // 地址先于名字：DeepSeek 的 Anthropic 兼容接口是 DeepSeek
    proxy.baseURL = "https://api.deepseek.com/anthropic"
    proxy.name = "Claude 兼容"
    #expect(AIVendor(service: proxy) == .deepseek)
    var azure = TranslateService.newAI()
    azure.name = "Azure OpenAI"
    azure.aiProtocol = .azure
    #expect(AIVendor(service: azure) == nil)
    #expect(ServiceTile.logo(for: azure)?.name == "ServiceLogo/microsoft")
    #expect(ServiceIcons.site(for: azure) == nil)
  }

  /// 官网推断：可注册域名；内置表认得的不推断；IP、本机、内网不取
  @Test func siteInference() {
    #expect(ServiceIcons.registrableDomain("api.deepseek.com") == "deepseek.com")
    #expect(ServiceIcons.registrableDomain("opencode.ai") == "opencode.ai")
    #expect(ServiceIcons.registrableDomain("API.Example.COM.") == "example.com")
    #expect(ServiceIcons.registrableDomain("llm.gw.example.com.cn") == "example.com.cn")
    for host in ["localhost", "127.0.0.1", "8.8.8.8", "192.168.1.5", "nas", "box.local", "com.cn"] {
      #expect(ServiceIcons.registrableDomain(host) == nil, "\(host)")
    }
    let service = { (baseURL: String) -> TranslateService in
      var service = TranslateService.newAI()
      service.baseURL = baseURL
      return service
    }
    #expect(
      ServiceIcons.site(for: service("https://opencode.ai/zen/go"))?.absoluteString
        == "https://opencode.ai/")
    #expect(
      ServiceIcons.site(for: service("api.llm.example.com/v1"))?.absoluteString
        == "https://example.com/")
    for baseURL in [
      "https://api.deepseek.com/v1", "https://dashscope.aliyuncs.com/compatible-mode/v1",
      "http://127.0.0.1:11434/v1", "http://192.168.1.5:8000/v1", "http://8.8.8.8/v1",
      "http://localhost:1234/v1", "",
    ] {
      #expect(ServiceIcons.site(for: service(baseURL)) == nil, "\(baseURL)")
    }
    #expect(ServiceIcons.site(for: .zhipu) == nil)
  }

  /// 磁盘缓存：<目录>/<官网主机>.png；四角透明（只有图形）垫白底，四角都实（满版）裁圆角
  @Test func cacheFileAndCorners() throws {
    let icons = ServiceIcons()
    icons.directory = URL(filePath: "/tmp/icons")
    #expect(icons.file(for: "opencode.ai").path == "/tmp/icons/opencode.ai.png")
    let image = { (full: Bool) throws -> CGImage in
      let context = try #require(
        CGContext(
          data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
      context.fill(
        full ? CGRect(x: 0, y: 0, width: 16, height: 16) : CGRect(x: 4, y: 4, width: 8, height: 8))
      return try #require(context.makeImage())
    }
    #expect(ServiceIcons.hasTransparentCorners(try image(false)))
    #expect(!ServiceIcons.hasTransparentCorners(try image(true)))
    // 放进内存的图按四角决定垫不垫白底，不碰磁盘
    icons.remember(try image(true), for: "example.com")
    #expect(icons.icon(for: "example.com")?.onPlate == false)
  }

  /// 联网冒烟（TEST_RUNNER_KITTY_LIVE_LINK=1 才跑）：真取 OpenCode、DeepSeek 官网的图标，长边不超过 128，不写磁盘
  @Test(.enabled(if: ProcessInfo.processInfo.environment["KITTY_LIVE_LINK"] != nil))
  func liveSiteIcons() async throws {
    for site in ["https://opencode.ai/", "https://deepseek.com/"] {
      let fetched = await LinkPreview.shared.siteIcon(
        URL(string: site)!, maxPixel: ServiceIcons.maxPixel)
      let image = try #require(fetched, "\(site)")
      #expect(max(image.width, image.height) <= ServiceIcons.maxPixel)
      print(site, image.width, image.height, "透明四角", ServiceIcons.hasTransparentCorners(image))
    }
  }
}

struct ResultCardCapTests {
  /// 结果卡片正文最高 8 行 + 7 个行距，行高按正文字体（系统字体 15 × 字号）算，每档字号一个常数
  @Test func capIsEightLinesOfBodyFont() {
    // 默认 15 pt：一行 19（和 SwiftUI 实排一致）
    #expect(ProviderCardView.bodyLineHeight(fontSize: 15) == 19)
    // 先定类型再比（AVFoundation 带进来的 CMTime 运算符会让类型推断超时）
    let expected: CGFloat = 8 * 19 + 7 * 3.5
    #expect(ProviderCardView.bodyCap(fontSize: 15) == expected)
    var previous: CGFloat = 0
    for step in 8...16 {  // 字号 80%–160%
      let size = 15 * CGFloat(step) / 10
      let line = ProviderCardView.bodyLineHeight(fontSize: size)
      let cap = ProviderCardView.bodyCap(fontSize: size)
      #expect(cap == 8 * line + 7 * ProviderCardView.bodyLineSpacing)
      // 行高来自字体度量：不小于 ascender + descender，取整最多多 2 pt
      let font = NSFont.systemFont(ofSize: size)
      let natural = font.ascender - font.descender + font.leading
      #expect(line >= natural && line < natural + 2, "\(size)")
      #expect(cap > previous, "\(size)")  // 字号越大上限越高
      previous = cap
    }
  }
}

/// 体检第 4 批（翻译）的纯逻辑：复制即译过滤、自动复制、截断 / 思考的流约定、错误种类、划词没取到、输入翻译再打开、
/// 浮窗跟随鼠标的位置、历史保留档位升级、朗读声线
struct TranslateBatch4Tests {
  private func key(_ code: Int, _ flags: NSEvent.ModifierFlags = .command) throws -> NSEvent {
    try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
        context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
        keyCode: UInt16(code)))
  }

  /// 复制即译不挑内容的问题（体检 A12）：网址、路径、数字、超长、目标自动时的第一语言静默跳过；同一段不重翻（B20）
  @Test func copyToTranslateSkipsNonText() {
    func worth(_ text: String, translated: String? = nil, autoTarget: Bool = true) -> Bool {
      TranslateCoordinator.worthTranslating(
        copied: text, translated: translated, first: .zhHans, second: .en, autoTarget: autoTarget)
    }
    #expect(worth("The quick brown fox jumps over the lazy dog."))
    #expect(!worth("https://example.com/a?b=c"))
    #expect(!worth("file:///Users/yy/a.txt"))
    #expect(worth("see https://example.com for details"))  // 句子里带网址照翻
    #expect(!worth("/usr/local/bin/swift"))
    #expect(!worth("~/Library/Application Support"))
    #expect(!worth("123 456.78 %"))
    #expect(!worth("  \n "))
    #expect(!worth(String(repeating: "a ", count: TranslateCoordinator.maxSourceBytes)))
    #expect(!worth("这是一段中文"))  // 目标自动时第一语言不翻
    #expect(worth("这是一段中文", autoTarget: false))  // 固定了目标就照翻
    #expect(!worth(" Ship it \n", translated: "Ship it"))  // 刚翻过的同一段
    #expect(worth("Ship it", translated: "Ship"))
  }

  /// 自动复制按来源（体检 A19）：复制即译带来、没改过的不复制；改过了、别的入口照设置；查词不复制
  @Test func autoCopyFollowsSessionOrigin() {
    #expect(
      TranslateCoordinator.autoCopies(enabled: true, isWord: false, copied: nil, translated: "a"))
    #expect(
      !TranslateCoordinator.autoCopies(enabled: true, isWord: false, copied: "a", translated: "a"))
    #expect(
      TranslateCoordinator.autoCopies(enabled: true, isWord: false, copied: "a", translated: "ab"))
    #expect(
      !TranslateCoordinator.autoCopies(enabled: true, isWord: true, copied: nil, translated: "a"))
    #expect(
      !TranslateCoordinator.autoCopies(enabled: false, isWord: false, copied: nil, translated: "a"))
  }

  /// 截断（体检 B19）：已出来的字照常显示成 .truncated（primaryResult 不认它），没有字就是错误；
  /// 其余错误原样、不是 TranslateError 的包成服务类
  @Test func truncatedStreamsAreNotDone() throws {
    #expect(
      TranslateCoordinator.state(after: TranslateError.truncated, latest: "前半截")
        == .truncated("前半截"))
    #expect(
      TranslateCoordinator.state(after: TranslateError.truncated, latest: "") == .failed(.truncated)
    )
    #expect(
      TranslateCoordinator.state(after: TranslateError.config("缺 Key"), latest: "x")
        == .failed(.config("缺 Key")))
    let wrapped = TranslateCoordinator.state(after: CocoaError(.fileNoSuchFile), latest: "")
    guard case .failed(let error) = wrapped else {
      Issue.record("不是失败")
      return
    }
    #expect(error.kind == .service)
    let coordinator = TranslateCoordinator(
      services: TranslateServiceStore(services: []),
      history: try HistoryStore(db: Database(path: ":memory:")))
    coordinator.cards = [.init(service: .zhipu, state: .truncated("半截"))]
    #expect(coordinator.primaryResult == nil && !coordinator.isRunning)
    #expect(coordinator.cards[0].state.text == "半截")  // 能复制已出来的部分
    #expect(TranslateCoordinator.CardState.running("").isThinking)
    #expect(!TranslateCoordinator.CardState.running("字").isThinking)
  }

  /// 流的增量解析（体检 B19 B25）：reasoning_content / thinking_delta 只标「在思考」；finish_reason = length、
  /// stop_reason = max_tokens 是截断
  @Test func deltaParsingMarksThinkingAndTruncation() {
    #expect(
      AIService.openAIDelta(["choices": [["delta": ["content": "你好"]]]]) == StreamDelta(text: "你好"))
    #expect(
      AIService.openAIDelta(["choices": [["delta": ["reasoning_content": "想一想"]]]])
        == StreamDelta(isThinking: true))
    #expect(
      AIService.openAIDelta(["choices": [["delta": ["reasoning": "hmm", "content": ""]]]])
        == StreamDelta(text: "", isThinking: true))
    #expect(
      AIService.openAIDelta(["choices": [["delta": [String: Any](), "finish_reason": "length"]]])
        == StreamDelta(isTruncated: true))
    #expect(
      AIService.openAIDelta(["choices": [["delta": [String: Any](), "finish_reason": "stop"]]])
        == StreamDelta())
    #expect(
      AIService.anthropicDelta([
        "type": "content_block_delta", "delta": ["type": "text_delta", "text": "Hi"],
      ]) == StreamDelta(text: "Hi"))
    #expect(
      AIService.anthropicDelta([
        "type": "content_block_delta", "delta": ["type": "thinking_delta", "thinking": "…"],
      ]) == StreamDelta(isThinking: true))
    #expect(
      AIService.anthropicDelta(["type": "message_delta", "delta": ["stop_reason": "max_tokens"]])
        == StreamDelta(isTruncated: true))
    #expect(
      AIService.anthropicDelta(["type": "message_delta", "delta": ["stop_reason": "end_turn"]])
        == StreamDelta())
  }

  /// 开头的 <think> 段里是「在思考」（开标签还没凑齐也算），闭合后、或正文不是这样开头的都不算
  @Test func streamingTextThinking() {
    var text = StreamingText()
    #expect(!text.isThinking)
    text.append("  <thi")
    #expect(text.isThinking && text.visible.isEmpty)
    text.append("nk>想一想")
    #expect(text.isThinking)
    text.append("</think>你好")
    #expect(!text.isThinking && text.visible == "你好")
    var plain = StreamingText()
    plain.append("<b>bold</b>")
    #expect(!plain.isThinking)
  }

  /// 划词没取到文字（体检 A16）：占位换成说明，开始输入、翻译、再清空都复位
  @Test func missedSelectionHintClears() throws {
    let coordinator = TranslateCoordinator(
      services: TranslateServiceStore(services: []),
      history: try HistoryStore(db: Database(path: ":memory:")))
    coordinator.beginInput(missedSelection: true)
    #expect(coordinator.missedSelection)
    coordinator.sourceText = "h"
    #expect(!coordinator.missedSelection)
    coordinator.beginInput(missedSelection: true)
    coordinator.beginInput()
    #expect(!coordinator.missedSelection)
  }

  /// 输入翻译再打开（体检 A14）：保留原文和卡片、收起提示和历史，被中断的卡片重跑（AI 服务没填地址，
  /// 马上报配置错误，不联网）
  @Test func resumeInputKeepsSessionAndReruns() async throws {
    // 地址、模型都空：流一开始就报「请先在设置里填写服务地址和模型」。在 init 里给（改 services 会写进用户偏好）
    var ai = TranslateService.newAI()
    ai.isEnabled = true
    let coordinator = TranslateCoordinator(
      services: TranslateServiceStore(services: [ai]),
      history: try HistoryStore(db: Database(path: ":memory:")))
    coordinator.translate("Hello there")
    coordinator.cancel()
    #expect(coordinator.cards.map(\.state) == [.failed(.interrupted)])
    coordinator.showsHistory = true
    coordinator.resumeInput()
    #expect(coordinator.sourceText == "Hello there" && !coordinator.showsHistory)
    #expect(coordinator.cards.map(\.state) == [.waiting])  // 重跑了
    for _ in 0..<50 where coordinator.isRunning { try await Task.sleep(for: .milliseconds(10)) }
    guard case .failed(let error) = coordinator.cards.first?.state else {
      Issue.record("没报错：\(String(describing: coordinator.cards.first?.state))")
      return
    }
    #expect(error.kind == .config)  // 配置类：橙卡、只给「打开设置」
    coordinator.resumeInput()
    #expect(coordinator.cards.map(\.state) == [.failed(error)])  // 不是中断的不重跑
  }

  /// ⌘D 收藏（体检 A31）：浮窗和历史都认 ⌘D，⌘S 不再响应（交还系统）
  @Test func favoriteIsCommandD() throws {
    let history = try HistoryStore(db: Database(path: ":memory:"))
    history.add(source: "hello", target: .zhHans, result: "你好", service: "A", limit: 0)
    let coordinator = TranslateCoordinator(
      services: TranslateServiceStore(services: []), history: history)
    #expect(!coordinator.handleKeyEquivalent(try key(kVK_ANSI_S)))
    coordinator.showsHistory = true
    #expect(!coordinator.handleKeyEquivalent(try key(kVK_ANSI_S)))
    #expect(coordinator.handleKeyEquivalent(try key(kVK_ANSI_D)))
    #expect(history.search("").first?.favorite == true)
    #expect(coordinator.handleKeyEquivalent(try key(kVK_ANSI_D)))
    #expect(history.search("").first?.favorite == false)
  }

  /// 历史 ⌘K（体检 C6）：单条操作 ｜ 导出 ›（四项）/ 清空历史…（有非收藏时才有）；↩ 进子列表、Esc 先回上一级再关
  @Test func historyActionMenu() throws {
    let history = try HistoryStore(db: Database(path: ":memory:"))
    history.add(source: "hello", target: .zhHans, result: "你好", service: "A", limit: 0)
    let coordinator = TranslateCoordinator(
      services: TranslateServiceStore(services: []), history: history)
    let list = coordinator.historyList
    coordinator.showsHistory = true
    let entry = try #require(list.selected)
    let items = list.actions(for: entry)
    #expect(items.map(\.title) == ["重新翻译", "复制译文", "复制原文", "收藏", "删除", "导出", "清空历史…"])
    #expect(items.map(\.shortcut) == ["↩", "⌘C", "⇧⌘C", "⌘D", "⌘⌫", nil, nil])
    #expect(items.map(\.section) == [0, 0, 0, 0, 0, 1, 1])
    #expect(items[5].submenu?.count == 4 && items[4].isDestructive)
    #expect(coordinator.handleKeyEquivalent(try key(kVK_ANSI_K)))
    #expect(list.showsActions)
    list.actionSelection = 5
    #expect(coordinator.handleHistoryCommand(#selector(NSResponder.insertNewline(_:))))
    #expect(list.showsActions && list.submenuTitle == "导出" && list.filteredActions.count == 4)
    list.actionQuery = "anki"
    #expect(list.filteredActions.count == 2)
    #expect(coordinator.handleHistoryCommand(#selector(NSResponder.cancelOperation(_:))))
    #expect(list.submenuTitle == nil && list.actionSelection == 5 && list.showsActions)
    #expect(coordinator.handleHistoryCommand(#selector(NSResponder.cancelOperation(_:))))
    #expect(!list.showsActions && coordinator.showsHistory)
    // 清空只在有非收藏的时候列出来；收藏 ⌘D 走菜单也行
    list.toggleFavorite(entry)
    let favorite = try #require(list.selected)
    #expect(!list.actions(for: favorite).map(\.title).contains("清空历史…"))
    var confirmed = false
    list.confirmClear = { confirmed = true }
    history.add(source: "b", target: .en, result: "B", service: "A", limit: 0)
    let selected = try #require(list.selected)
    let clear = try #require(list.actions(for: selected).last)
    list.run(clear)
    #expect(confirmed && !list.showsActions)
  }

  /// 历史里 → 在搜索词末尾（单测里没有字段编辑器：搜索词为空才算）打开动作菜单，同剪贴板 / 启动器；有字时照常移光标
  @Test func historyMoveRightOpensActions() throws {
    let history = try HistoryStore(db: Database(path: ":memory:"))
    history.add(source: "hello", target: .zhHans, result: "你好", service: "A", limit: 0)
    let coordinator = TranslateCoordinator(
      services: TranslateServiceStore(services: []), history: history)
    let list = coordinator.historyList
    coordinator.showsHistory = true
    list.query = "hel"
    #expect(!coordinator.handleHistoryCommand(#selector(NSResponder.moveRight(_:))))
    #expect(!list.showsActions)
    list.query = ""
    #expect(coordinator.handleHistoryCommand(#selector(NSResponder.moveRight(_:))))
    #expect(list.showsActions)
  }

  /// 清空历史之后 ⌘Z 不再插回清空前删掉的记录（设置页清空时历史可能还开着）；清空之后删的照常能撤
  @Test func clearDropsHistoryUndo() throws {
    let history = try HistoryStore(db: Database(path: ":memory:"))
    for word in ["c", "b", "a"] {
      history.add(source: word, target: .en, result: word.uppercased(), service: "", limit: 0)
    }
    let list = HistoryList(store: history)
    list.delete(try #require(list.entries.first))
    HistoryMenu.clear(history, island: nil)
    #expect(!list.undoDelete() && list.entries.isEmpty)
    history.add(source: "d", target: .en, result: "D", service: "", limit: 0)
    list.delete(try #require(list.entries.first))
    #expect(list.undoDelete() && list.entries.map(\.source) == ["d"])
  }

  /// 历史分页 + 缓存（体检 B22）：一页 500 条，取下一页（滚到底 / ↓ 走过最后一条），搜索词变了回到第一页
  @Test func historyPages() throws {
    let history = try HistoryStore(db: Database(path: ":memory:"))
    for index in 0..<1001 {
      history.add(
        source: "s\(index)", target: .en, result: "r\(index)", service: "", limit: 0)
    }
    let list = HistoryList(store: history)
    #expect(list.entries.count == 500 && list.hasMore)
    list.loadMore()
    #expect(list.entries.count == 1000 && list.hasMore)
    list.select(try #require(list.entries.last))
    list.move(by: 1)  // 走过最后一条：先取下一页再往下
    #expect(list.entries.count == 1001 && list.selected?.id == list.entries.last?.id)
    #expect(!list.hasMore)
    list.move(by: 1)  // 真到底了：首尾循环
    #expect(list.selected?.id == list.entries.first?.id)
    list.query = "s1"
    #expect(list.pages == 1)
    history.add(source: "new", target: .en, result: "新", service: "", limit: 0)
    list.query = ""
    #expect(list.entries.first?.source == "new")  // revision 变了不用旧缓存
  }

  /// 浮窗跟随鼠标（体检 A13）：光标右下 12 pt，右 / 下放不下翻到另一侧，比可见区还大时左上角露在里面
  @Test func panelFollowsMouse() {
    let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
    let size = NSSize(width: 420, height: 300)
    #expect(
      OverlayPanel.frame(near: NSPoint(x: 500, y: 500), size: size, in: visible)
        == NSRect(x: 512, y: 188, width: 420, height: 300))
    #expect(
      OverlayPanel.frame(near: NSPoint(x: 1400, y: 500), size: size, in: visible).minX == 968)
    #expect(
      OverlayPanel.frame(near: NSPoint(x: 500, y: 100), size: size, in: visible).maxY == 412)
    let huge = OverlayPanel.frame(
      near: NSPoint(x: 500, y: 500), size: NSSize(width: 2000, height: 1000), in: visible)
    #expect(huge.minX == 8 && huge.maxY == 892)
    // 上次的位置换算到另一块屏：左上角相对位置不变
    let moved = OverlayPanel.relocated(
      NSRect(x: 144, y: 510, width: 420, height: 300), from: visible,
      to: NSRect(x: 1440, y: 0, width: 2880, height: 1800))
    #expect(abs(moved.minX - 1728) < 0.001 && abs(moved.maxY - 1620) < 0.001 && moved.width == 420)
    #expect(
      OverlayPanel.relocated(NSRect(x: 1, y: 2, width: 3, height: 4), from: visible, to: visible)
        == NSRect(x: 1, y: 2, width: 3, height: 4))
    // 不带锚点（输入翻译、「上次位置」）：回到用户拖到的左上角和宽度，高度用当前内容高，
    // 不管上次跟随鼠标弹在哪（placeForShow 不读当前位置）
    let user = (topLeft: NSPoint(x: 100, y: 800), width: CGFloat(500))
    #expect(
      OverlayPanel.lastFrame(user: user, size: size, screens: [visible], in: visible)
        == NSRect(x: 100, y: 500, width: 500, height: 300))
    // 拖到的位置在副屏、鼠标在主屏：换算到主屏同一相对位置
    let side = NSRect(x: 1440, y: 0, width: 1440, height: 900)
    let there = (topLeft: NSPoint(x: 1540, y: 800), width: CGFloat(420))
    #expect(
      OverlayPanel.lastFrame(user: there, size: size, screens: [visible, side], in: visible)
        == NSRect(x: 100, y: 500, width: 420, height: 300))
    // 没拖过、或那块屏已拔掉：居中到鼠标所在屏
    #expect(
      OverlayPanel.lastFrame(user: nil, size: size, screens: [visible], in: visible)
        == NSRect(x: 510, y: 300, width: 420, height: 300))
    #expect(
      OverlayPanel.lastFrame(user: there, size: size, screens: [visible], in: visible).midX == 720)
  }

  /// 翻译历史保留条数（体检 A18）：旧档位挪到下一档（100–1000 → 1000，2000 → 5000），新档位和不限不动
  @Test func historyLimitMigration() throws {
    let suite = "kitty-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    for (old, new) in [(100, 1000), (500, 1000), (1000, 1000), (2000, 5000), (5000, 5000), (0, 0)] {
      defaults.set(old, forKey: Prefs.translateHistoryLimit)
      Prefs.migrate(defaults, domainName: suite)
      #expect(defaults.integer(forKey: Prefs.translateHistoryLimit) == new, "\(old)")
    }
  }

  /// 挤压入场从启动器页挪到通用页、三块面板共用（2026-09-29）：开过的旧开关搬到新键，旧键删掉；已有新键的不被旧键覆盖
  @Test func squeezeEntranceMigration() throws {
    let suite = "kitty-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: Prefs.launcherSqueezeEntranceLegacy)
    Prefs.migrate(defaults, domainName: suite)
    #expect(defaults.object(forKey: Prefs.panelSqueezeEntrance) as? Bool == true)
    #expect(defaults.object(forKey: Prefs.launcherSqueezeEntranceLegacy) == nil)
    defaults.set(false, forKey: Prefs.panelSqueezeEntrance)
    defaults.set(true, forKey: Prefs.launcherSqueezeEntranceLegacy)
    Prefs.migrate(defaults, domainName: suite)
    #expect(defaults.object(forKey: Prefs.panelSqueezeEntrance) as? Bool == false)
  }

  /// 朗读挑声线（体检 B23）：不比系统默认的差（下载过高音质的就用它）
  @Test func speechVoiceIsBestQuality() {
    for code in ["en-US", "zh-CN"] {
      guard let voice = Speaker.voice(for: code) else { continue }
      #expect(voice.language == code)
      let fallback = AVSpeechSynthesisVoice(language: code)?.quality.rawValue ?? 0
      #expect(voice.quality.rawValue >= fallback)
    }
    let speaker = Speaker()
    speaker.stop()
    #expect(speaker.speaking == nil)
  }
}
