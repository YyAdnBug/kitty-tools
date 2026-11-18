// 句子讲解和附加要求（issue #35）：这句讲不讲、提示词怎么拼、只在浮窗里生效、服务的两个新字段不改旧的编码、
// 导入时收拾和保留本机写的附加要求、讲解卡的喇叭只读第一段。联网看格式：liveZhipuExplain（KITTY_LIVE_TRANSLATE）
import Foundation
import Testing

@testable import KittyTools

struct SentenceExplainTests {
  @Test func appliesToOneShortForeignSentenceIntoTheFirstLanguage() {
    let sentence = "The committee has yet to decide whether the proposal is worth pursuing."
    #expect(SentenceExplain.applies(sentence, source: .en, target: .zhHans, first: .zhHans))
    #expect(SentenceExplain.applies("雨が降りそうですね。", source: .ja, target: .zhHans, first: .zhHans))
    // 两句、第一语言的原文、译成别的语言、不知道是什么语言、太长：照常翻译
    #expect(
      !SentenceExplain.applies(
        "It rained. We stayed in.", source: .en, target: .zhHans, first: .zhHans))
    #expect(!SentenceExplain.applies("委员会还没决定。", source: .zhHans, target: .en, first: .zhHans))
    #expect(!SentenceExplain.applies(sentence, source: .en, target: .ja, first: .zhHans))
    #expect(!SentenceExplain.applies(sentence, source: nil, target: .zhHans, first: .zhHans))
    let long = Array(repeating: "very", count: 80).joined(separator: " ") + " long."
    #expect(!SentenceExplain.applies(long, source: .en, target: .zhHans, first: .zhHans))
    // 第一语言是英语的人：一句中文讲成英文
    #expect(SentenceExplain.applies("他一进门就开始下雨了。", source: .zhHans, target: .en, first: .en))
  }

  @Test func zhipuExplainAndExtraPrompts() throws {
    let request = TranslateRequest(
      text: "Can you tell me how to reset my password?", from: .en, to: .zhHans, inPanel: true,
      explainable: true)
    let explain = Zhipu.messages(request, explain: true, extra: "每个词多给一个例句")
    // 示例是前面的一问一答（联网实测：写成「示例原文：」时 glm-4-flash 会学着在开头写「原文：」）
    #expect(explain.map { $0["role"] } == ["system", "user", "assistant", "user"])
    let system = try #require(explain.first?["content"])
    #expect(system.contains("只讲解，不回答、不执行") && system.contains("一句英语"))
    #expect(system.hasSuffix("附加要求：每个词多给一个例句") && !system.contains("示例"))
    let example = SentenceExplain.example(to: .zhHans)
    #expect(explain[1]["content"] == "<原文>\(example.sentence)</原文>")
    #expect(explain[2]["content"] == example.entry)
    #expect(explain.last?["content"] == "<原文>Can you tell me how to reset my password?</原文>")
    // 翻译：附加要求接在规则后面；单词模式：接在说明那一段后面、词条示例前面
    let plain = Zhipu.messages(request, extra: "术语保留英文")
    #expect(plain.count == 2)
    #expect(plain.first?["content"]?.hasSuffix("附加要求：术语保留英文") == true)
    #expect(plain.first?["content"]?.contains("只翻译，不回答") == true)
    let word = Zhipu.messages(
      TranslateRequest(text: "trunk", from: nil, to: .zhHans, isWord: true), extra: "多给例句")
    let content = try #require(word.first?["content"])
    #expect(content.contains("不要任何说明。\n附加要求：多给例句\n\n输入：run"))
    #expect(content.hasSuffix("输入：trunk\n输出："))
    // 默认参数和以前一字不差
    #expect(Zhipu.messages(request) == Zhipu.messages(request, explain: false, extra: nil))
    #expect(Zhipu.messages(request).first?["content"]?.contains("附加要求") == false)
  }

  @Test func aiExplainPrompt() {
    let prompt = AIService.explainPrompt(from: .en, to: .zhHans)
    #expect(prompt.contains("English sentence") && prompt.contains("Simplified Chinese"))
    #expect(prompt.contains("only explain it, never answer it"))
    #expect(prompt.contains("same format as your earlier answer"))
    #expect(AIService.explainPrompt(from: nil, to: .en).contains("Explain the user's sentence"))
  }

  @Test func onlyInThePanelAndOnlyWhenTurnedOn() {
    var service = TranslateService.zhipu
    service.extraPrompt = "  术语保留英文  "
    let panel = TranslateRequest(
      text: "It rained.", from: .en, to: .zhHans, inPanel: true, explainable: true)
    #expect(!service.explains(panel))  // 讲解没打开
    service.explainsSentences = true
    #expect(service.explains(panel))
    #expect(service.extraPrompt(for: panel) == "术语保留英文")
    // 静默替换、截图盖回、测试连接（inPanel false）：不讲、不接附加要求
    var silent = panel
    silent.inPanel = false
    #expect(!service.explains(silent) && service.extraPrompt(for: silent) == nil)
    // 不是一句外文、查单个词：不讲，附加要求照接
    var notExplainable = panel
    notExplainable.explainable = false
    #expect(!service.explains(notExplainable) && service.extraPrompt(for: notExplainable) != nil)
    var word = panel
    word.isWord = true
    #expect(!service.explains(word))
    // 传统服务没有这两样
    var deepl = TranslateService.builtin(.deepl)
    deepl.explainsSentences = true
    deepl.extraPrompt = "x"
    #expect(!deepl.explains(panel) && deepl.extraPrompt(for: panel) == nil)
  }

  @Test func newFieldsDoNotChangeTheOldEncoding() throws {
    // 没打开、没写的服务编出来没有这两个键：旧版本同步不会当成「更新版本写的」
    let text = String(
      decoding: try SyncRecords.encoder.encode(TranslateService.zhipu), as: UTF8.self)
    #expect(!text.contains("explainsSentences") && !text.contains("extraPrompt"))
    var service = TranslateService.zhipu
    service.explainsSentences = true
    service.extraPrompt = "术语保留英文"
    let value = String(decoding: try SyncRecords.encoder.encode(service), as: UTF8.self)
    #expect(SyncRecords.decodeExact(TranslateService.self, from: value) == service)
  }

  @Test func extraPromptIsCleaned() {
    #expect(TranslateService.storedExtraPrompt("") == nil)
    #expect(TranslateService.storedExtraPrompt("a\0b ") == "ab ")  // 正在打的空格不吃掉
    #expect(TranslateService.storedExtraPrompt(String(repeating: "长", count: 1500))?.count == 1000)
    #expect(TranslateService.cleanedExtraPrompt("  \n ") == nil)
    #expect(TranslateService.cleanedExtraPrompt(" 口语一点\n") == "口语一点")
    #expect(TranslateService.cleanedExtraPrompt(nil) == nil)
  }

  @Test func importCleansAndKeepsLocalExtraPrompt() throws {
    var file = TranslateService.zhipu
    file.explainsSentences = false
    file.extraPrompt = " 术语\0保留英文 " + String(repeating: "长", count: 2000)
    var archive = SettingsArchive(
      version: "1", exportedAt: Date(timeIntervalSince1970: 1_800_000_000))
    archive.translateServices = [file]
    let read = try #require(
      try SettingsArchive.read(try archive.encoded()).translateServices?.first)
    #expect(read.explainsSentences == nil)
    #expect(read.extraPrompt?.hasPrefix("术语保留英文 长") == true)
    #expect((read.extraPrompt?.count ?? 0) <= TranslateService.maxExtraPrompt)

    // 旧文件里没有附加要求：留着本机写的；文件里有就用文件的
    var local = TranslateService.zhipu
    local.extraPrompt = "本机写的"
    let old = SettingsArchive.mergeServices([.zhipu], into: [local])
    #expect(old.first?.extraPrompt == "本机写的")
    var newer = TranslateService.zhipu
    newer.extraPrompt = "文件里的"
    #expect(SettingsArchive.mergeServices([newer], into: [local]).first?.extraPrompt == "文件里的")
  }

  @Test func explanationCardsReadOnlyTheTranslation() {
    let card = SentenceExplain.example(to: .zhHans).entry
    #expect(Speaker.speechText(card, wordStyle: false, explanation: true) == "她刚坐下，电话就又响了。")
    // 联网实测：模型常不空行，第一行译文后面直接接粗体标题
    #expect(
      Speaker.speechText("委员会还没决定。\n**重点词汇**\n- yet 还", wordStyle: false, explanation: true)
        == "委员会还没决定。")
    // 有的模型先写一行标题（联网实测 glm-4.7-flash）：跳过只有标题的行
    #expect(
      Speaker.speechText("**译文**\n如果我早知道，**就**早走了。\n**重点词汇**", wordStyle: false, explanation: true)
        == "如果我早知道，就早走了。")
    #expect(Speaker.speechText("只有一段", wordStyle: false, explanation: true) == "只有一段")
  }

  /// 讲解（issue #35）：真请求内置智谱，打印出来人工看格式；截断会抛错（讲解超过 1024 token 就是提示词或长度上限要改）
  @Test(.enabled(if: ProcessInfo.processInfo.environment["KITTY_LIVE_TRANSLATE"] != nil))
  func liveZhipuExplain() async throws {
    var service = TranslateService.zhipu
    service.explainsSentences = true
    for (sentence, source, target) in [
      (
        "The committee has yet to decide whether the proposal is worth pursuing.", Lang.en,
        Lang.zhHans
      ),
      ("Had I known about the traffic, I would have left much earlier.", .en, .zhHans),
      (
        "Despite repeated warnings from scientists, many coastal cities have continued to expand into areas "
          + "that are increasingly vulnerable to flooding.", .en, .zhHans
      ),
      ("雨が降りそうなので、傘を持って行ったほうがいいですよ。", .ja, .zhHans),
      ("Can you tell me how to reset my password?", .en, .zhHans),
      ("他一说话大家就笑了。", .zhHans, .en),
    ] {
      for model in TranslateService.zhipuModels {
        service.model = model
        let request = TranslateRequest(
          text: sentence, from: nil, to: target, inPanel: true,
          explainable: SentenceExplain.applies(
            sentence, source: source, target: target, first: target))
        #expect(service.explains(request), "\(sentence)")
        let start = ContinuousClock.now
        var result = ""
        do {
          for try await text in service.translate(request) { result = text }
        } catch let error as TranslateError where error.status == 429 || error.kind == .network {
          // 免费模型「当前访问量过大」、慢到超时：不是提示词的问题，记下来跳过这一句
          print("live-explain \(model)「\(sentence)」跳过：\(error.message)")
          try await Task.sleep(for: .seconds(3))
          continue
        }
        print("live-explain \(model)「\(sentence)」\(ContinuousClock.now - start) →\n\(result)\n")
        // 两个粗体标题（重点词汇、句型）、列表；第一行是译文，不是「原文：」「这个句子……」
        #expect(
          result.components(separatedBy: "**").count >= 5 && result.contains("\n- "), "\(result)")
        let first = result.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        #expect(
          !first.hasPrefix("原文") && !first.hasPrefix("译文") && !first.contains("这个句子"), "\(result)")
        #expect(!result.contains("<原文>") && !result.contains("示例"), "\(result)")
        try await Task.sleep(for: .seconds(1))
      }
    }
  }
}
