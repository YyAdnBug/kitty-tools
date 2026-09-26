// 设置里有序列表（N12）的单测：网页搜索一条的问题提示（名称、网址、保留 / 重复关键词（只算搜索之间）、用不上）、
// 列表 JSON 读写（关键词去空白）、预置判断（删自定义的要确认）、翻译服务状态副标题（开着才标橙）；
// 另有通用页的外观偏好 → NSAppearance 名字。

import AppKit
import Testing

@testable import KittyTools

struct SettingsListTests {
  private func engine(
    _ id: String, name: String = "Name", keyword: String = "", url: String, fallback: Bool = false
  ) -> SearchEngine {
    SearchEngine(id: id, name: name, keyword: keyword, urlTemplate: url, enabled: fallback)
  }

  @Test func searchEngineProblems() {
    let problem = { (engine: SearchEngine, list: [SearchEngine]) in
      SearchEngineDetail.problem(of: engine, in: list)
    }
    let google = engine("g", keyword: "g", url: "https://www.google.com/search?q={query}")
    #expect(problem(google, [google]) == nil)
    // 没名称 / 默认的「https://」/ 没协议
    #expect(problem(engine("a", name: "  ", url: "https://a.com"), []) == "还没填名称")
    #expect(problem(engine("a", url: "https://"), []) == "网址不完整")
    #expect(problem(engine("a", keyword: "x", url: "example.com/?q={query}"), []) == "网址不完整")
    // 快捷链接可以是路径和自定义协议；搜索不收路径
    #expect(problem(engine("a", url: "~/Downloads"), []) == nil)
    #expect(problem(engine("a", url: "maps://?q=home"), []) == nil)
    #expect(problem(engine("a", keyword: "d", url: "/tmp/{query}"), []) == "网址不完整")
    // 保留关键词、和前面的重复（排在前面的那条没问题）
    #expect(
      problem(engine("a", keyword: "CB", url: "https://a.com/?q={query}"), [])
        == "关键词「cb」留给剪贴板指令")
    let copy = engine("b", name: "Google 2", keyword: "G", url: "https://b.com/?q={query}")
    #expect(problem(copy, [google, copy]) == "关键词和「Name」重复，用的是靠前的那个")
    #expect(problem(google, [google, copy]) == nil)
    // 快捷链接的关键词只参与名称匹配：和搜索同关键词、谁在前都不算重复
    let docLink = engine("l", keyword: "doc", url: "https://developer.apple.com")
    let docSearch = engine("s", keyword: "doc", url: "https://d.com/?q={query}")
    #expect(problem(docSearch, [docLink, docSearch]) == nil)
    let gLink = engine("l", keyword: "g", url: "https://g.com")
    #expect(problem(gLink, [google, gLink]) == nil)
    // 搜索没关键词也不兜底就用不上；勾了兜底就行
    #expect(problem(engine("a", url: "https://a.com/?q={query}"), []) == "没有关键词也不兜底，用不上")
    #expect(problem(engine("a", url: "https://a.com/?q={query}", fallback: true), []) == nil)
  }

  @Test func engineListCoding() throws {
    #expect(SearchEngineDetail.decode(nil) == WebSearch.defaults)
    #expect(SearchEngineDetail.decode(Data("garbage".utf8)) == WebSearch.defaults)
    let data = try #require(
      SearchEngineDetail.encode([engine("a", keyword: " g h ", url: "https://a.com/?q={query}")]))
    #expect(SearchEngineDetail.decode(data).first?.keyword == "gh")
  }

  @Test func engineTitles() {
    #expect(SearchEngineDetail.title(engine("a", name: " ", url: "https://a.com")) == "未命名")
    #expect(SearchEngineDetail.kindTitle(engine("a", url: "https://a.com")) == "快捷链接")
    #expect(
      SearchEngineDetail.kindTitle(engine("a", url: "https://a.com/?q={query}", fallback: true))
        == "搜索 · 没有本地结果时兜底")
    #expect(
      SearchEngineDetail.isPreset("google") && !SearchEngineDetail.isPreset("custom-1a2b3c4d"))
  }

  /// 不碰钥匙串的几种：智谱写模型，自建 AI 缺地址 / 模型；关着的服务缺配置不标橙
  @Test func serviceStatus() {
    var ai = TranslateService.newAI()
    #expect(ai.settingsStatus.text == "未填服务地址" && !ai.settingsStatus.isProblem)
    ai.isEnabled = true
    #expect(ai.settingsStatus == ("未填服务地址", true))
    ai.aiProtocol = .anthropic
    #expect(ai.settingsStatus == ("未填模型", true))
    ai.model = "claude-haiku"
    #expect(ai.settingsStatus == ("Anthropic · claude-haiku", false))
    #expect(TranslateService.zhipu.settingsStatus == ("glm-4-flash", false))
  }

  /// 没存过、存了认不得的值都跟随系统（nil = NSApp.appearance 不设）
  @Test func appearanceName() {
    #expect(AppAppearance.name(for: "system") == nil)
    #expect(AppAppearance.name(for: "light") == .aqua)
    #expect(AppAppearance.name(for: "dark") == .darkAqua)
    #expect(AppAppearance.name(for: nil) == nil)
    #expect(AppAppearance.name(for: "sepia") == nil)
  }
}
