// 不用 key 的两个服务（2026-11-05 S1 S2）：有道词典的词条怎么写成单词卡、词典类服务只在查词时出卡片、
// 不当主结果；系统翻译只在 macOS 26 起出现在「+」菜单里
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
    for kind in [TranslateService.Kind.apple, .youdaoDict] {
      #expect(TranslateService.builtin(kind).secretFields.isEmpty)
      #expect(TranslateService.builtin(kind).id == kind.rawValue)
    }
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
