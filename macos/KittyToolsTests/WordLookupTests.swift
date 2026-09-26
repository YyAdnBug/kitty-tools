import Foundation
import Testing

@testable import KittyTools

/// 查词（D4）：原文算不算一个词、系统词典纯文本的解析。样本是 DCSCopyTextDefinition 在本机（macOS 15，
/// 「词典」App 默认词典）返回的原文（长词条截短了，结构不变）
struct WordLookupTests {
  @Test func recognizesSingleWords() {
    for word in ["run", "look up", "ice cream", "don't", "e-mail", "API", "苹果", "一丝不苟", "한국어"] {
      #expect(WordLookup.isWord(word), "\(word)")
    }
    for text in [
      "", "今天天气很好", "Hello, world", "iPhone 16", "a b c d", "line\nbreak", "3.14", "C++",
    ] {
      #expect(!WordLookup.isWord(text), "\(text)")
    }
  }

  static let run =
    "run | rən | verb (runs, running | ˈrəniNG |; past ran | ran |; past participle | rən |) 1 [no object] move at a speed faster than a walk, never having both or all the feet on the ground at the same time: the dog ran across the road | she ran the last few yards, breathing heavily. • run as a sport or for exercise: I run every morning. 2 pass or cause to pass quickly or smoothly in a particular direction: [no object, with adverbial of direction] : the rumor ran through the pack of photographers. noun 1 an act or spell of running: I usually go for a run in the morning | a cross-country run. 2 a journey accomplished or route taken by a vehicle, aircraft, or boat, especially on a regular basis: the New York-Washington run. • the distance covered in a specified period, especially by a ship: a record run of 398 miles from noon to noon. 3 an opportunity or attempt to achieve something: their absence means the Russians will have a clear run at the title. PHRASES come running be eager to do what someone wants: he had only to snap his fingers. ORIGIN Old English rinnan, irnan (verb), of Germanic origin."

  @Test func parsesEnglishEntry() throws {
    let entry = try #require(WordLookup.parse(Self.run, query: "run"))
    #expect(entry.headword == "run" && entry.query == nil && entry.phonetic == "rən")
    #expect(entry.groups.map(\.partOfSpeech) == ["verb", "noun"])
    let verb = entry.groups[0]
    #expect(verb.forms == "runs, running; past ran; past participle")
    #expect(verb.senses.count == 2)
    #expect(verb.senses[0].definition.hasPrefix("move at a speed faster than a walk"))
    #expect(verb.senses[0].example == "the dog ran across the road")
    #expect(verb.senses[1].example == "the rumor ran through the pack of photographers")
    // 义项编号只认依次递增的：「398 miles」不会切出第 398 条；短语、词源不要
    #expect(entry.groups[1].senses.count == 3)
    #expect(!entry.groups.flatMap(\.senses).contains { $0.definition.contains("snap his fingers") })
  }

  @Test func acceptsInflectionsAndHomographs() throws {
    // 查变形得到原形词条：显示「ran 的原形」
    let ran = try #require(WordLookup.parse(Self.run, query: "ran"))
    #expect(ran.headword == "run" && ran.query == "ran")
    let went = try #require(
      WordLookup.parse(
        "go 1 | ɡō | verb (third singular present goes; present participle going; past went; past participle gone) 1 [no object, usually with adverbial of direction] move from one place to another; travel: he went out to the store | she longs to go back home.",
        query: "went"))
    #expect(went.headword == "go" && went.query == "went" && went.senseCount == 1)
    let better = try #require(
      WordLookup.parse(
        "better 1 bet·ter | ˈbedər | adjective 1 of a more excellent or effective type or quality: hoping for better weather. 2 [predicative or as complement] partly or fully recovered from illness: I'm much better now.",
        query: "better"))
    #expect(better.headword == "better" && better.groups.first?.senses.count == 2)
  }

  @Test func handlesPhrasesAndMissingPartOfSpeech() throws {
    let iceCream = try #require(
      WordLookup.parse(
        "ice cream | ˌīs ˈkrēm, ˈīs ˌkrēm | noun a soft frozen food made with sweetened and flavored milk fat. • a portion of ice cream. ORIGIN late 17th century: from ice + cream.",
        query: "ice cream"))
    #expect(iceCream.headword == "ice cream" && iceCream.senseCount == 1)
    #expect(
      iceCream.groups[0].senses[0].definition
        == "a soft frozen food made with sweetened and flavored milk fat")
    // 开头是括号说明，词性跟在右括号后面
    let hello = try #require(
      WordLookup.parse(
        "hello hel·lo | həˈlō, heˈlō | (also hallo or hullo mainly British English) exclamation used as a greeting or to begin a phone conversation: hello there, Katie!. noun (plural hellos) an utterance of “hello”; a greeting: she was getting polite hellos.",
        query: "Hello"))
    #expect(hello.groups.map(\.partOfSpeech) == ["exclamation", "noun"])
    #expect(hello.groups[1].forms == "plural hellos")
  }

  @Test func rejectsFuzzyMatches() {
    // 词典会模糊匹配：look up → lookup、give up → give，都不是查的那个词
    #expect(
      WordLookup.parse(
        "lookup look·up | ˈlo͝okˌəp | noun [usually as modifier] the action of or a facility for systematic electronic information retrieval.",
        query: "look up") == nil)
    #expect(
      WordLookup.parse(
        "give | ɡiv | verb (past gave | ɡāv |; past participle given | ˈɡivən |) 1 [with two objects] freely transfer the possession of (something) to (someone): he gave the papers back.",
        query: "give up") == nil)
  }

  @Test func parsesChineseEntries() throws {
    let apple = try #require(
      WordLookup.parse("苹果 píngguǒ 名 落叶乔木，叶子椭圆形。花白色带有红晕。果实也叫苹果，圆形，味甜，是常见水果。", query: "苹果"))
    #expect(apple.phonetic == "píngguǒ" && apple.groups[0].partOfSpeech == "名")
    #expect(apple.groups[0].senses[0].definition.hasPrefix("落叶乔木"))
    let idiom = try #require(
      WordLookup.parse("一丝不苟 yīsī-bùgǒu 形容做事认真仔细，一点儿都不马虎。", query: "一丝不苟"))
    #expect(idiom.phonetic == "yīsī-bùgǒu" && idiom.groups[0].partOfSpeech == nil)
    #expect(idiom.groups[0].senses[0].definition == "形容做事认真仔细，一点儿都不马虎。")
  }

  /// 联网以外的真查询（本机词典）：只要求查得到、不崩；没装对应词典时为 nil 也算过
  @Test func systemDictionaryLookupRuns() async {
    let entry = await WordLookup.systemDictionary("serendipity")
    #expect(entry == nil || entry?.headword == "serendipity")
  }
}
