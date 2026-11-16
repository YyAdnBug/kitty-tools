// 启动器表情与符号：真实离线字符表、中英拼音匹配、完整 Unicode 序列、最近使用、别名 / 开关 / 命令快捷键。
// 模型用内存库与假 App 列表；最近使用写临时偏好，不按真实复制 / 粘贴，不碰系统剪贴板和用户偏好。

import Foundation
import Testing

@testable import KittyTools

struct EmojiSearchTests {
  private func model() throws -> LauncherModel {
    let model = LauncherModel(usage: try LauncherUsage(db: Database(path: ":memory:")), apps: [])
    model.engines = { [] }
    return model
  }

  @Test func catalogAndUnicodeSequences() throws {
    let catalog = EmojiSearch.catalog
    #expect(catalog.count > 3700)
    #expect(Set(catalog.map(\.target)).count == catalog.count)
    #expect(catalog.allSatisfy { $0.kind == .emoji && $0.payload == $0.target })
    for glyph in ["😂", "❤️", "👍🏽", "👩🏽‍💻", "👨‍👩‍👧‍👦", "∞", "⌘", "←"] {
      let item = try #require(catalog.first { $0.target == glyph }, "缺少 \(glyph)")
      #expect(Array(item.payload!.unicodeScalars) == Array(glyph.unicodeScalars))
      #expect(!item.title.isEmpty && !item.subtitle.isEmpty && !item.names.isEmpty)
    }
    #expect(Bundle.main.url(forResource: "unicode-LICENSE", withExtension: "txt") != nil)
  }

  @Test func commandBoundaryAndPrompt() throws {
    #expect(EmojiSearch.request("emoji") == nil)
    #expect(EmojiSearch.request("emojify 笑") == nil)
    #expect(EmojiSearch.request("emoji笑") == nil)
    #expect(EmojiSearch.request("emoji ") == "")
    #expect(EmojiSearch.request("EMOJI\t 笑  ") == "笑")
    let prompt = try #require(EmojiSearch.promptItems(for: "emoji").exact.first)
    #expect(prompt.completion == "emoji ")
    #expect(LauncherCommands.builtIn(forPrompt: prompt.target)?.id == EmojiSearch.commandID)
    for text in ["em", "表情", "符号", "biaoqing"] {
      #expect(EmojiSearch.promptItems(for: text).partial.first?.target == prompt.target)
    }
  }

  @Test func chineseEnglishPinyinAndSymbols() {
    for query in ["笑哭", "tears joy", "xiaoku", ":joy:"] {
      #expect(EmojiSearch.search(query, recent: []).contains { $0.target == "😂" }, "\(query)")
    }
    for query in ["无穷", "infinity", "wuqiong"] {
      #expect(EmojiSearch.search(query, recent: []).contains { $0.target == "∞" }, "\(query)")
    }
    #expect(EmojiSearch.search("command", recent: []).first?.target == "⌘")
    #expect(EmojiSearch.search("Ω", recent: []).first?.target == "Ω")
    #expect(EmojiSearch.search("左箭头", recent: []).contains { $0.target == "←" })
    #expect(EmojiSearch.search("❤", recent: []).first?.target == "❤️")
    #expect(EmojiSearch.search("©", recent: []).first?.target == "©")
    #expect(EmojiSearch.search("©️", recent: []).first?.target == "©️")
    #expect(EmojiSearch.search("👩🏽‍💻", recent: []).first?.target == "👩🏽‍💻")
    #expect(EmojiSearch.search("woman technologist", recent: []).contains { $0.target == "👩🏽‍💻" })
    #expect(EmojiSearch.search("笑 xyznotaword", recent: []).isEmpty)
    #expect(EmojiSearch.search("face", recent: []).count == EmojiSearch.limit)
  }

  @Test func recentOrderingAndLocalStorage() throws {
    let recent = ["∞", "😂", "∞", "unknown"]
    let idle = EmojiSearch.search("", recent: recent)
    #expect(Array(idle.prefix(2).map(\.target)) == ["∞", "😂"])
    #expect(Set(idle.map(\.target)).count == idle.count)
    #expect(!idle.contains { $0.target == "unknown" })
    // 同分的最近使用优先；匹配质量仍排在最近使用之前。
    let a = LauncherItem(kind: .emoji, target: "a", title: "a", subtitle: "", names: ["face"])
    let b = LauncherItem(kind: .emoji, target: "b", title: "b", subtitle: "", names: ["face"])
    #expect(EmojiSearch.search("face", recent: ["b"], in: [a, b]).map(\.target) == ["b", "a"])
    var prefix = b
    prefix.names = ["face index"]
    #expect(EmojiSearch.search("face", recent: ["b"], in: [a, prefix]).first?.target == "a")
    #expect(EmojiSearch.recent(after: "😂", in: recent) == ["😂", "∞", "unknown"])
    #expect(EmojiSearch.recent(after: "new", in: (0..<50).map(String.init)).count == 24)
    let suite = "emoji-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(["😂", "", "😂", "∞"], forKey: Prefs.launcherRecentEmoji)
    #expect(EmojiSearch.loadRecents(defaults) == ["😂", "∞"])
    #expect(Prefs.defaults[Prefs.launcherRecentEmoji] == nil)
  }

  @Test func modelCompletionSearchAndActions() throws {
    let model = try model()
    model.query = "emoji"
    let prompt = try #require(model.results.first)
    #expect(prompt.target == EmojiSearch.promptTarget)
    model.execute(prompt)
    #expect(model.query == "emoji " && model.emojiRequest == "")
    #expect(model.groups.first?.title == "最近使用与常用表情")
    model.query = "emoji 笑哭"
    let result = try #require(model.results.first { $0.target == "😂" })
    #expect(model.results.allSatisfy { $0.kind == .emoji })
    #expect(LauncherModel.completion(for: result) == nil)
    #expect(model.primaryAction(for: result).title == "粘贴")
    #expect(model.commandReturnAction(for: result)?.title == "只复制，不粘贴")
    #expect(model.copyTitle(for: result) == "复制字符")
    #expect(!result.kind.isRecorded && !model.canFavorite(result))
    #expect(model.actions(for: result).map(\.title) == ["粘贴", "只复制，不粘贴"])
    model.query = "emoji xyznotaword"
    #expect(model.results.isEmpty && model.emptyText.contains("没有找到表情或符号"))
    model.query = ""
    #expect(model.emojiRequest == nil && model.isShowingRecent)
  }

  @Test func aliasesSwitchAndCommandHotKey() throws {
    let model = try model()
    var settings = LauncherCommands.Settings(aliases: [EmojiSearch.commandID: "em"])
    model.commandSettings = { settings }
    model.query = "em"
    let prompt = try #require(model.results.first { $0.target == EmojiSearch.promptTarget })
    #expect(prompt.completion == "em " && prompt.subtitle.contains("「em 空格"))
    model.complete(prompt)
    #expect(model.query == "em " && model.emojiRequest == "")
    model.query = "em infinity"
    #expect(model.results.contains { $0.target == "∞" })
    model.query = "emoji 笑"
    #expect(model.emojiRequest == nil && !model.results.contains { $0.kind == .emoji })
    var shown = 0
    model.showPanel = {
      shown += 1
      return true
    }
    #expect(model.hasCommand(EmojiSearch.commandID) && model.canRunHotKey(EmojiSearch.commandID))
    model.runHotKey(EmojiSearch.commandID)
    #expect(shown == 1 && model.query == "em " && model.emojiRequest == "")
    settings.off.insert(EmojiSearch.commandID)
    model.query = "em 笑"
    #expect(model.emojiRequest == nil && !model.canRunHotKey(EmojiSearch.commandID))
    model.query = "表情"
    #expect(!model.results.contains { $0.target == EmojiSearch.promptTarget })
    model.runHotKey(EmojiSearch.commandID)
    #expect(shown == 1)
  }

  /// 按需量首次读表和按键搜索；不设随机器浮动的耗时断言，不碰屏幕或偏好。
  @Test(.enabled(if: ProcessInfo.processInfo.environment["KITTY_EMOJI_PROBE"] == "1"))
  func performance() {
    let start = Date.timeIntervalSinceReferenceDate
    let count = EmojiSearch.catalog.count
    let loaded = Date.timeIntervalSinceReferenceDate
    let queries = ["笑", "smile", "xiaoku", "face", "箭头", "xyznotaword", "woman technologist"]
    var rows = 0
    for _ in 0..<10 {
      for query in queries { rows += EmojiSearch.search(query, recent: []).count }
    }
    let searched = Date.timeIntervalSinceReferenceDate
    print(
      "emoji-probe: \(count) 条，首次 \((loaded - start) * 1000) ms，每次搜索 \((searched - loaded) * 1000 / 70) ms，\(rows) 行"
    )
  }
}
