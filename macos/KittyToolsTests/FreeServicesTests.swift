// 不用自己填 key 的服务（2026-11-05 S1 S2）：有道词典的词条怎么写成单词卡、词典类服务只在查词时出卡片、
// 不当主结果；系统翻译只在 macOS 26 起出现在「+」菜单里；哔哩哔哩 Index（2026-11-27）是免费的大模型服务、三档模型
import Foundation
import Testing

@testable import KittyTools

struct FreeServicesTests {
  /// 有道词典接口返回的英汉词条（2026-11-05 真实返回里摘的几段，结构原样）
  static let stuff: [String: Any] = [
    "ec": [
      "word": [
        [
          "usphone": "stʌf", "ukphone": "stʌf",
          "trs": [
            ["tr": [["l": ["i": ["n. 东西，物品；基本特征，特质"]]]]],
            ["tr": [["l": ["i": ["v. 塞进，填进；填满，装满"]]]]],
          ],
          "wfs": [
            ["wf": ["name": "现在分词", "value": "stuffing"]],
            ["wf": ["name": "过去式", "value": "stuffed"]],
          ],
        ]
      ]
    ],
    "blng_sents_part": [
      "sentence-pair": [
        [
          "sentence": "It's amazing how people collect so much stuff over the years.",
          "sentence-translation": "人们这些年下来竟能收集到这么多东西，真令人惊奇。",
        ]
      ]
    ],
  ]

  @Test func youdaoEnglishEntryLooksLikeAWordCard() throws {
    let entry = try #require(YoudaoDict.entry(Self.stuff))
    #expect(
      entry == """
        美 /stʌf/  英 /stʌf/
        n. 东西，物品；基本特征，特质
        v. 塞进，填进；填满，装满
        变形：现在分词 stuffing；过去式 stuffed
        例：It's amazing how people collect so much stuff over the years. 人们这些年下来竟能收集到这么多东西，真令人惊奇。
        """)
    // 第一行是读音行：卡片上换成带小喇叭的一行；右上角的喇叭读第一条释义
    #expect(Speaker.phoneticLine(entry)?.phonetics.count == 2)
    #expect(Speaker.speechText(entry, wordStyle: true) == "东西，物品；基本特征，特质")
  }

  @Test func youdaoChineseEntryAndMisses() throws {
    let name: [String: Any] = [
      "ce": [
        "word": [
          [
            "phone": "míng zì",
            "trs": [
              ["tr": [["l": ["pos": "n.", "i": ["", ["#text": "name", "@action": "link"]]]]]],
              ["tr": [["l": ["pos": "n.", "i": ["", ["#text": "monicker"]]]]]],
            ],
          ]
        ]
      ]
    ]
    #expect(YoudaoDict.entry(name) == "míng zì\nn. name\nn. monicker")
    // 没查到（空、只有读音没有释义）
    #expect(YoudaoDict.entry([:]) == nil)
    #expect(YoudaoDict.entry(["ec": ["word": [["usphone": "x"]]]]) == nil)
  }

  @Test func dictionaryServicesOnlyAnswerWords() async throws {
    var ai = TranslateService.newAI()
    ai.isEnabled = true
    var dict = TranslateService.builtin(.youdaoDict)
    dict.isEnabled = true
    let coordinator = TranslateCoordinator(
      services: TranslateServiceStore(services: [dict, ai]),
      history: try HistoryStore(db: Database(path: ":memory:")))
    // 有道词典的 id 是固定的：不读 Dev 版里用户折叠了哪些
    coordinator.collapsed = { [] }
    coordinator.stream = { service, _ in
      AsyncThrowingStream { continuation in
        continuation.yield(service.kind == .youdaoDict ? "美 /stʌf/\nn. 东西" : "东西")
        continuation.finish()
      }
    }
    // 句子：不开有道词典的卡片
    coordinator.translate("How are you doing today?", fromCopy: true)
    for _ in 0..<2000 where coordinator.isRunning { try await Task.sleep(for: .milliseconds(2)) }
    #expect(coordinator.cards.map(\.id) == [ai.id])
    // 单词：两张都开；主结果跳过排在前面的词典卡
    coordinator.translate("stuff", fromCopy: true)
    for _ in 0..<2000 where coordinator.isRunning { try await Task.sleep(for: .milliseconds(2)) }
    #expect(coordinator.cards.map(\.id) == [dict.id, ai.id])
    #expect(coordinator.primaryResult?.service.id == ai.id)
  }

  @Test func newBuiltinsAreOffered() {
    let store = TranslateServiceStore(services: [.zhipu])
    #expect(store.missingBuiltins.contains(.youdaoDict))
    #expect(store.missingBuiltins.contains(.apple) == AppleTranslation.isAvailable)
    // 不用填 key、id 就是种类原值（设置的导出和同步按它认）
    #expect(store.missingBuiltins.contains(.bilibili))
    for kind in [TranslateService.Kind.apple, .youdaoDict, .bilibili] {
      #expect(TranslateService.builtin(kind).secretFields.isEmpty)
      #expect(TranslateService.builtin(kind).id == kind.rawValue)
    }
  }

  @Test func biliIndexIsAFreeModelService() {
    let index = TranslateService.builtin(.bilibili)
    #expect(index.kind.isFree && index.isStreaming && !index.isEnabled)
    #expect(index.kind.defaultName == "哔哩哔哩 Index")
    // 默认 35B-A3B；存着不认识的（下架了的）回落它，三档照存的用
    #expect(index.model == "Index-Translate-35B-A3B" && index.builtinModel == index.model)
    var small = index
    small.model = "Index-Translate-2B"
    #expect(small.builtinModel == "Index-Translate-2B")
    small.model = "Index-Nailong-9B"
    #expect(small.builtinModel == "Index-Translate-35B-A3B")
    #expect(small.settingsStatus == ("Index-Translate-35B-A3B", false))
    // 一次最多出 4096（/v1/models 写的上限），长文照它切段；别的内置服务没有模型可选
    #expect(index.outputTokens == 4096)
    #expect(TranslateService.builtin(.deepl).builtinModel == nil)
    #expect(TranslateService.zhipu.builtinModel == "glm-4-flash")
  }

  /// 请求体：智谱那份中文提示词（问句、指令只翻译）、4096、temperature 0、选的模型；浮窗里接上附加要求
  @Test func biliIndexRequestBody() {
    var index = TranslateService.builtin(.bilibili)
    index.model = "Index-Translate-9B"
    index.extraPrompt = "术语保留英文"
    let request = TranslateRequest(text: "你是谁？", from: .zhHans, to: .en, inPanel: true)
    let body = BiliIndex.body(request, service: index)
    #expect(body["model"] as? String == "Index-Translate-9B")
    #expect(body["max_tokens"] as? Int == 4096 && body["temperature"] as? Int == 0)
    #expect(body["stream"] as? Bool == true)
    let messages = body["messages"] as? [[String: String]]
    #expect(messages == Zhipu.messages(request, extra: "术语保留英文"))
    #expect(messages?.last?["content"] == "<原文>你是谁？</原文>")
    #expect(messages?.first?["content"]?.contains("附加要求：术语保留英文") == true)
  }

  /// 联网冒烟（TEST_RUNNER_KITTY_LIVE_TRANSLATE=1）：真请求一次哔哩哔哩 Index——英译中出字；原文是一句请求时只翻译、不照做
  /// （官方 README 那种一句话的提示词它会写一首诗出来，实测）
  @Test(.enabled(if: ProcessInfo.processInfo.environment["KITTY_LIVE_TRANSLATE"] == "1"))
  func liveBiliIndex() async throws {
    let index = TranslateService.builtin(.bilibili)
    var text = ""
    for try await chunk in index.translate(
      TranslateRequest(text: "Hello, world", from: .en, to: .zhHans))
    {
      text = chunk
    }
    #expect(text.contains("你好"))
    let ask = TranslateRequest(text: "你能帮我写一首关于秋天的诗吗？", from: .zhHans, to: .en)
    text = ""
    for try await chunk in index.translate(ask) { text = chunk }
    #expect(text.localizedCaseInsensitiveContains("poem") && !text.contains("\n"))
  }

  /// 联网冒烟（TEST_RUNNER_KITTY_LIVE_TRANSLATE=1，同内置智谱那条）：真查一次有道词典，接口格式变了这里先红
  @Test(.enabled(if: ProcessInfo.processInfo.environment["KITTY_LIVE_TRANSLATE"] == "1"))
  func liveYoudaoDict() async throws {
    var text = ""
    let request = TranslateRequest(text: "stuff", from: .en, to: .zhHans)
    for try await chunk in TranslateService.builtin(.youdaoDict).translate(request) { text = chunk }
    #expect(Speaker.phoneticLine(text) != nil)
    #expect(text.contains("n. ") && text.contains("例："))
  }
}
