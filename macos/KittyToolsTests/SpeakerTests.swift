// 朗读读哪段字（R1）、单词卡的读音行（R2）、真人录音的地址（R3）、朗读速度的档位（issue #35）：Speaker 里的纯函数
import Foundation
import Testing

@testable import KittyTools

struct SpeakerTests {
  @Test func wordCardsReadOnlyTheMeaning() {
    let card = "美 /neɪm/  英 /neɪm/\nn. 名字；名称；名声\nv. 命名；任命\n例：What is your name? 你叫什么名字？"
    #expect(Speaker.speechText(card, wordStyle: true) == "名字；名称；名声")
    // 不是单词卡：整段，只去掉 Markdown 记号
    #expect(Speaker.speechText("**发布**吧\n- 上线", wordStyle: false) == "发布吧\n上线")
    // 汉译英：第一行是拼音，跳过
    let apple = "píngguǒ\nn. apple; apple tree\nExample: 我每天吃一个苹果。 I eat an apple every day."
    #expect(Speaker.speechText(apple, wordStyle: true) == "apple; apple tree")
    // 粗体的词性记号、只有读音行时退回整段
    #expect(Speaker.speechText("美 /rʌn/\n**v.** 跑；运转", wordStyle: true) == "跑；运转")
    #expect(Speaker.speechText("美 /rʌn/", wordStyle: true) == "美 /rʌn/")
  }

  @Test func phoneticLineIsSplitOff() throws {
    let line = try #require(Speaker.phoneticLine("美 /rʌn/  英 /rʌn/\nv. 跑"))
    #expect(line.phonetics == [.init(accent: .us, text: "rʌn"), .init(accent: .uk, text: "rʌn")])
    #expect(line.rest == "v. 跑")
    // 方括号写法也认；第一行还没出完、第一行不全是读音都不拆
    #expect(Speaker.phoneticLine("英 [neɪm] 美 [neɪm]\nn. 名字")?.phonetics.first?.accent == .uk)
    #expect(Speaker.phoneticLine("美 /rʌn/  英 /rʌ") == nil)
    #expect(Speaker.phoneticLine("美国 /rʌn/ 是\nv. 跑") == nil)
    #expect(Speaker.phoneticLine("v. 跑；运转\n例：…") == nil)
  }

  @Test func recordingsOnlyForEnglishWords() throws {
    let url = try #require(Speaker.recordingURL(word: "stuff", accent: .uk))
    #expect(url.absoluteString == "https://dict.youdao.com/dictvoice?audio=stuff&type=1")
    #expect(
      Speaker.recordingURL(word: "ice cream", accent: .us)?.query == "audio=ice%20cream&type=2")
    #expect(Speaker.recordingURL(word: "don't", accent: .us) != nil)
    #expect(Speaker.recordingURL(word: "名字", accent: .us) == nil)
    #expect(Speaker.recordingURL(word: "café", accent: .us) == nil)
    #expect(Speaker.recordingURL(word: "a b c d", accent: .us) == nil)
    #expect(Speaker.key(word: "run", accent: .us) != Speaker.key(word: "run", accent: .uk))
  }

  @Test func speechSpeedSnapsToAChoice() {
    #expect(Speaker.speed(1) == 1)
    #expect(Speaker.speed(0.5) == 0.6)  // 导入、同步来的怪值夹到最近的一档
    #expect(Speaker.speed(3) == 1.25)
    #expect(Speaker.utteranceRate(speed: 1) == 0.5)
    // 慢的几档 rate 要压得很低（0.3 才 0.82×，屏外合成量的），越慢 rate 越小
    let rates = Speaker.speeds.map { Speaker.utteranceRate(speed: $0) }
    #expect(rates == rates.sorted())
    #expect(Speaker.utteranceRate(speed: 0.6) < 0.1)
  }

  @Test func markdownIsStrippedBeforeReading() {
    #expect(
      Speaker.withoutMarkdown("# 标题\n> 引用\n* 一项\n[链接](https://a.b) `代码`") == "标题\n引用\n一项\n链接 代码")
    #expect(Speaker.withoutMarkdown("```\nlet a = 1\n```") == "let a = 1")
  }
}
