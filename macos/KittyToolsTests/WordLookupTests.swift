import Foundation
import Testing

@testable import KittyTools

/// 查词（D4）：原文算不算一个词、系统词典纯文本的解析。样本是 DCSCopyTextDefinition 在本机（macOS 15，
/// 「词典」App 默认词典）返回的原文（长词条截短了，结构不变）
struct WordLookupTests {
  @Test func recognizesSingleWords() {
    for word in ["run", "well-being", "don't", "e-mail", "API", "苹果", "一丝不苟", "한국어"] {
      #expect(WordLookup.isWord(word), "\(word)")
    }
    for text in [
      "", "今天天气很好", "Hello, world", "iPhone 16", "a b c d", "line\nbreak", "3.14", "C++",
      "look up", "ice cream", "Sign in",
    ] {
      #expect(!WordLookup.isWord(text), "\(text)")
    }
  }

  /// 第四轮体检 U2：2–3 个词的只有系统词典查到同一个词头（不分大小写）才算查词
  @Test func phrasesNeedTheSameHeadword() {
    for text in [
      "Sign in", "Privacy Policy", "look up", "ice cream", "Ice  Cream", "point of view",
    ] {
      #expect(WordLookup.isPhrase(text), "\(text)")
    }
    for text in ["run", "well-being", "a b c d", "Hello, world", "苹果", ""] {
      #expect(!WordLookup.isPhrase(text), "\(text)")
    }
    func entry(_ headword: String, query: String? = nil) -> DictionaryEntry {
      DictionaryEntry(
        headword: headword, query: query, phonetic: nil,
        groups: [.init(partOfSpeech: "noun", forms: nil, senses: [.init(definition: "x")])])
    }
    #expect(WordLookup.sameHeadword(entry("ice cream"), "ice cream"))
    #expect(WordLookup.sameHeadword(entry("ice cream"), "Ice  Cream"))
    #expect(!WordLookup.sameHeadword(entry("lookup"), "look up"))
    #expect(!WordLookup.sameHeadword(entry("sign"), "Sign in"))
    #expect(!WordLookup.sameHeadword(entry("privacy"), "Privacy Policy"))
    // 词典按变形认回原形的（query 不为 nil）对词组不算
    #expect(!WordLookup.sameHeadword(entry("run into", query: "ran into"), "ran into"))
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
    #expect(verb.senses[0].examples.first == "the dog ran across the road")
    #expect(verb.senses[1].examples.first == "the rumor ran through the pack of photographers")
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

  // 双语词典（牛津英汉汉英）的原文：2026-11-05 本机「Simplified Chinese - English」词典的真实返回
  static let bilingualStuff =
    "stuff | BrE stʌf, AmE stəf | A. noun uncountable ① informal (unnamed substance or objects) 东西 dōngxi▸ the chairs were covered in some sort of plastic stuff 椅子都包了某种塑料膜▸ they sell stationery and stuff (like that) 他们销售文具之类的东西▸ this wine is good stuff 这葡萄酒不错▸ to do one's stuff 施展本领▸ go on! do your stuff! 快点！露一手吧！▸ the medicine has clearly done its stuff 这药显然起作用了▸ to know one's stuff 精通业务▸ that's the stuff! British 这就对啦！▸ I don't give a stuff! British 我一点也不在乎！ ② informal (personal items) 私人物品 sīrén wùpǐn▸ where’s all my stuff? 我的东西都哪儿去了？ ③ informal (unnamed activities) 事儿 shìr▸ I’ve got loads of stuff to do today 我今天有很多活儿要干▸ I like reading and stuff (like that) 我喜欢看书什么的 ④ informal (information, content, subject matter) 玩意儿 wányìr▸ I don’t believe in all that stuff about ghosts 我不信什么鬼呀魂呀的▸ I’m bored by history: dates and battles and all that stuff 我对历史很厌烦：都是日期、战役之类的东西▸ what’s all this ‘Mrs Smith’ stuff? — call me Anna 哪来的什么“史密斯夫人”那一套？叫我安娜好了▸ stuff and nonsense dated 胡说八道 ⑤ informal (work produced) 作品 zuòpǐn▸ this poem is good stuff 这首诗很不错▸ the band did some great stuff on their first album 这支乐队的首张专辑做得很棒 ⑥ (formal or literary) (main constituent) 要素 yàosù▸ let’s see what stuff you’re made of 我们来看看你是怎样一个人▸ parades and marches were the very stuff of politics in the region 游行示威是该地区政治生活的基本内容▸ the trip was magical: the stuff that dreams are made of 那次旅行非常奇妙：宛如梦境 ⑦ informal (drugs) 毒品 dúpǐn ⑧ informal (stolen goods) 赃物 zāngwù B. transitive verb ① (pack) 装满 zhuāngmǎn▸ the fridge is stuffed to bursting 冰箱满得都快撑破了▸ the cupboard was stuffed with old clothes 衣橱里塞满了旧衣服 ② (fill) 填入 tiánrù▸ the sofa was stuffed with horsehair 沙发里填充了马毛▸ she had 500 envelopes to stuff with leaflets informal 她得在500个信封里装上传单 ③ (cause to be filled with) 使充满 shǐ chōngmǎn▸ her head is stuffed with romantic notions 她满脑子都是不切实际的想法 ④ (block up) 堵塞 dǔsè▸ to stuff a crack with newspaper 用报纸塞住缝隙 ⑤ (shove) 把…塞进 bǎ… sāijìn▸ to stuff one's hands in one's pockets 把手插在口袋里▸ to stuff cotton wool in one's ears 用药棉堵住耳朵 ⑥ Cooking 给…装馅 gěi… zhuāng xiàn▸ to stuff a chicken with mushrooms 在鸡里面放蘑菇 ⑦ informal (cause to eat a lot) 使吃撑 shǐ chīchēng▸ don’t stuff the kids with or full of chocolate before dinner 饭前不要让孩子一个劲地吃巧克力▸ to stuff one's face 大吃特吃 dà chī tè chī ⑧ (in taxidermy) 把…制成标本 bǎ… zhìchéng biāoběn ‹animal›⑨ US Politics 把假选票投入 bǎ jiǎ xuǎnpiào tóurù ‹ballot box›⑩ British slang (expressing indifference or rejection) [表示不感兴趣或拒绝]▸ I told them they could stuff their job 我告诉他们让他们的工作见鬼去吧▸ get stuffed! 去你的！ informal ▸ she lost her temper and told him to get stuffed 她大发脾气，叫他滚蛋▸ stuff it! 去它的！ ⑪ British informal (defeat in sport) 彻底击败 chèdǐ jībài▸ we stuffed them in the second half 下半场我们把他们打得落花流水 C. to stuff oneself reflexive verb informal 大吃特吃 dà chī tè chī▸ they sat there stuffing themselves with ice cream 他们坐在那儿狼吞虎咽地大吃冰激凌 PHRASAL VERB stuff up: transitive verb [stuff sth up, stuff up sth] informal 堵塞 dǔsè ‹hole, crack›▸ the drain was stuffed up with leaves 排水沟被树叶堵住了"

  static let bilingualApple =
    "apple | BrE ˈapl, AmE ˈæp(ə)l | noun (fruit) 苹果 píngguǒ; (tree) 苹果树 píngguǒ shù▸ the apple of sb's eye figurative 掌上明珠▸ there's a bad apple in every bunch 哪儿都有害群之马▸ to upset the apple cart 打乱计划▸ an apple a day keeps the doctor away proverb 天天吃苹果，医生远离我"

  static let bilingualChildren =
    "child | BrE tʃʌɪld, AmE tʃaɪld | noun plural children ① (non-adult) 儿童 értóng, 小孩 xiǎohái▸ when I was a child 我小时候▸ a child of six 6岁的小孩▸ a child star/prodigy 童星/神童▸ to be child's play 是轻而易举的事▸ spare the rod and spoil the child proverb 孩子不打不成器▸ the child is father to the man proverb 三岁看到老▸ to be with child archaic 怀孕 ② 子女 zǐnǚ [可指儿子或女儿]▸ her mother's child 有其母必有其女 ③ (immature person) 孩子气的人 háiziqì de rén▸ don't be such a child! 别孩子气啦！ ④ (inexperienced person) 幼稚的人 yòuzhì de rén ⑤ figurative (product) 产物 chǎnwù▸ a child of the 60s/of nature 60年代的人/大自然之子 ⑥ children (descendants) 后代 hòudài"

  static let bilingualHello =
    "hello | BrE həˈləʊ, hɛˈləʊ, AmE həˈloʊ, hɛˈloʊ | A. noun 问候 wènhòu B. exclamation ① (greeting) 你好 nǐ hǎo; (on phone) 喂 wèi ② British (in surprise) 嘿 hēi"

  static let bilingualBeautiful =
    "beautiful | BrE ˈbjuːtɪf(ʊ)l, AmE ˈbjudəfəl | adjective ① (attractive) 美丽的 měilì de▸ she is the most beautiful woman I know 她是我认识的女人中最漂亮的▸ a beautiful Beethoven sonata 一首优美的贝多芬奏鸣曲 ② (wonderful) 令人愉悦的 lìng rén yúyuè de ‹weather, holiday, feeling›③ (skilful) 出色的 chūsè de▸ he's a beautiful writer 他写得一手好文章 ④ (superb) 完美的 wánměi de ‹specimen›▸ a beautiful example of sth 某事物的完美体现"

  static let bilingualName =
    "名字 mínɡzi noun name▸ 以发明者的名字命名 be named after its inventor ▸ 你叫什么名字？ What’s your name? ▸ 电影的名字 title of a film ▸ 公司的名字 name of a company"

  static let bilingualDongxi =
    "东西 dōnɡ-xī noun ① （东方和西方） east and west▸ 东西向的大街 street running east to west ② （从东到西） distance from east to west▸ 这座城东西约六公里，南北约八公里。 The city is about 6 kilometres from east to west and 8 kilometres from north to south."

  static let bilingualName2 =
    "那么 nàme A. pronoun ① （指程度、方式等） like that▸ 别那么干。 Don’t do it that way. ② （指数量） [used before numerals] around▸ 教室里只有那么七八个学生。 There are only about seven or eight students in the classroom. B. conjunction then▸ 你不想听，那么我就不说了。 If you don’t want to listen, then I have nothing more to say. ▸ 既然志向不同，那么咱们分道扬镳吧。 Since we’re going in different directions, let’s part company."

  static let bilingualRun =
    "闰 （閏） rùn noun ［Astronomy］ intercalation"

  @Test func parsesBilingualEnglishEntry() throws {
    let entry = try #require(WordLookup.parse(Self.bilingualStuff, query: "stuff"))
    #expect(entry.headword == "stuff" && entry.query == nil)
    #expect(
      entry.phonetics == [.init(accent: .uk, text: "stʌf"), .init(accent: .us, text: "stəf")])
    // A. B. C. 三段：名词、及物动词、反身动词；短语动词小节不要
    #expect(entry.groups.map(\.partOfSpeech) == ["名词", "及物动词", "反身动词"])
    let noun = entry.groups[0]
    #expect(noun.forms == "不可数" && noun.senses.count == 8)
    #expect(noun.senses[0].definition == "东西")
    #expect(noun.senses[0].note == "informal · unnamed substance or objects")
    #expect(noun.senses[0].examples.count == 9)
    #expect(
      noun.senses[0].examples[0]
        == "the chairs were covered in some sort of plastic stuff 椅子都包了某种塑料膜")
    #expect(
      noun.senses[1].definition == "私人物品" && noun.senses[1].note == "informal · personal items")
    #expect(noun.senses[5].note == "formal or literary · main constituent")
    let verb = entry.groups[1]
    #expect(verb.senses.count == 11)
    // ‹animal› 这种搭配词去掉；中文释义在方括号里的那条照样认出来
    #expect(verb.senses[7].definition == "把…制成标本" && verb.senses[7].note == "in taxidermy")
    #expect(verb.senses[9].definition == "表示不感兴趣或拒绝")
    #expect(verb.senses[9].note == "British slang · expressing indifference or rejection")
    #expect(verb.senses[5].definition == "给…装馅" && verb.senses[5].note == "Cooking")
    let reflexive = entry.groups[2]
    #expect(reflexive.forms == "to stuff oneself")
    #expect(reflexive.senses.map(\.definition) == ["大吃特吃"])
    #expect(!entry.groups.flatMap(\.senses).contains { $0.definition.contains("dǔsè") })
  }

  @Test func bilingualEntriesWithoutNumbersOrSections() throws {
    // 没有 ①：整段一条；中间的 (tree) 也收进注；拼音去掉、逗号分号换成全角
    let apple = try #require(WordLookup.parse(Self.bilingualApple, query: "apple"))
    #expect(apple.groups.map(\.partOfSpeech) == ["名词"])
    #expect(apple.groups[0].senses.count == 1)
    #expect(apple.groups[0].senses[0].definition == "苹果；苹果树")
    #expect(apple.groups[0].senses[0].note == "fruit · tree")
    #expect(apple.groups[0].senses[0].examples.count == 4)
    // 同一种口音的几个读法只取第一个
    let hello = try #require(WordLookup.parse(Self.bilingualHello, query: "hello"))
    #expect(hello.phonetics.map(\.text) == ["həˈləʊ", "həˈloʊ"])
    #expect(hello.groups.map(\.partOfSpeech) == ["名词", "感叹词"])
    #expect(hello.groups[0].senses[0].definition == "问候")
    #expect(hello.groups[1].senses[0].definition == "你好；喂")
    #expect(
      hello.groups[1].senses[1].definition == "嘿"
        && hello.groups[1].senses[1].note == "British · in surprise")
    // 「美丽的 měilì de」两个字的拼音都去掉
    let beautiful = try #require(WordLookup.parse(Self.bilingualBeautiful, query: "beautiful"))
    #expect(beautiful.groups[0].senses.map(\.definition) == ["美丽的", "令人愉悦的", "出色的", "完美的"])
  }

  @Test func bilingualInflectionsAndChineseHeadwords() throws {
    // 变形：plural children 进变形表那一栏，查 children 认回 child
    let child = try #require(WordLookup.parse(Self.bilingualChildren, query: "children"))
    #expect(child.headword == "child" && child.query == "children")
    #expect(child.groups[0].forms == "复数 children")
    #expect(child.groups[0].senses[0].definition == "儿童，小孩")
    #expect(
      child.groups[0].senses[1].definition == "子女" && child.groups[0].senses[1].note == "可指儿子或女儿")
    // 汉译英：拼音里的 ɡ 换成 g；词性是英文、释义是英文
    let name = try #require(WordLookup.parse(Self.bilingualName, query: "名字"))
    #expect(name.phonetic == "míngzi" && name.phonetics == [.init(accent: nil, text: "míngzi")])
    #expect(name.groups.map(\.partOfSpeech) == ["名词"])
    #expect(name.groups[0].senses[0].definition == "name")
    #expect(name.groups[0].senses[0].examples.first == "以发明者的名字命名 be named after its inventor")
    let dongxi = try #require(WordLookup.parse(Self.bilingualDongxi, query: "东西"))
    #expect(
      dongxi.groups[0].senses.map(\.definition) == ["east and west", "distance from east to west"])
    #expect(dongxi.groups[0].senses[0].note == "东方和西方")
    // 拼音模糊匹配到的别的词不要：name → 那么、run → 闰（繁体写法跟在词后面）
    #expect(WordLookup.parse(Self.bilingualName2, query: "name") == nil)
    #expect(WordLookup.parse(Self.bilingualRun, query: "run") == nil)
  }

  @Test func pinyinIsRemovedOnlyAfterChinese() {
    #expect(WordLookup.withoutPinyin("东西 dōngxi") == "东西")
    #expect(WordLookup.withoutPinyin("把…塞进 bǎ… sāijìn") == "把…塞进")
    #expect(WordLookup.withoutPinyin("大吃特吃 dà chī tè chī") == "大吃特吃")
    // 汉字前面的英文、没有声调的英文词不动
    #expect(WordLookup.withoutPinyin("Cooking 给…装馅 gěi… zhuāng xiàn") == "Cooking 给…装馅")
    #expect(WordLookup.withoutPinyin("东西 informal") == "东西 informal")
  }

  /// 联网以外的真查询（本机词典）：只要求查得到、不崩；没装对应词典时为 nil 也算过
  @Test func systemDictionaryLookupRuns() async {
    let entry = await WordLookup.systemDictionary("serendipity")
    #expect(entry == nil || entry?.headword == "serendipity")
  }
}
