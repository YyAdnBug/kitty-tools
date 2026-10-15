// 便签第 6 批「Markdown 边打边变样」的纯函数单测（PLAN §10「便签」）：
// - 扫描器（NoteMarkdown + NoteStyles.spans）：每种语法的正例和反例、那几条误伤（snake_case 的下划线、代码里的星号、
//   转义、没配对的、空的强调）、嵌套、链接（方括号套着、地址里的括号、图片不认、链接里不套链接）、和任务 / 列表 / 引用 /
//   标题叠着时只认行内的；开关关掉只剩任务的两种。
// - 叠样式（NoteStyles.runs）：标题里的粗体还是标题的字号、做完的任务里的粗体、标记在最上面。
// - 套用（NoteStyles.apply，只用一个文本存储、不建窗口）：各样式换成的属性、露着 / 藏着的标记、「一行一行排」和
//   「整篇排一遍」逐个属性一样、哪些行的标记露 / 藏得不对（outdated）。
// - 链接地址的白名单、标题和摘要里去掉标记。
// 编辑器里的行为（藏字形、光标行、输入法、点链接）在 NoteTextViewTests。

import AppKit
import Testing

@testable import KittyTools

struct NoteMarkdownTests {
  /// 一次改完的样子：全文和选区（比加标记、粘贴成链接的结果用）
  private struct Edit: Equatable {
    var text: String
    var selection: NSRange
    init(_ text: String, _ selection: NSRange) { (self.text, self.selection) = (text, selection) }
  }

  private func range(_ location: Int, _ length: Int = 0) -> NSRange {
    NSRange(location: location, length: length)
  }

  /// 一行的样式写成好认的样子：「种类@位置:那一段字」，按位置排（同一个位置长的在前，一样长的按名字）
  private func marks(_ line: String, markdown: Bool = true) -> [String] {
    NoteStyles.spans(in: line, markdown: markdown)
      .map { span -> (NSRange, String) in
        let name: String
        switch span.kind {
        case .heading(let level): name = "h\(level)"
        case .link(let address): name = "link(\(address))"
        default: name = "\(span.kind)"
        }
        return (
          span.range,
          "\(name)@\(span.range.location):\((line as NSString).substring(with: span.range))"
        )
      }
      .sorted { ($0.0.location, -$0.0.length, $0.1) < ($1.0.location, -$1.0.length, $1.1) }
      .map(\.1)
  }

  // MARK: 块

  @Test func headings() {
    #expect(marks("# 标题") == ["h1@0:# 标题", "marker@0:# "])
    #expect(marks("###### 六级") == ["h6@0:###### 六级", "marker@0:###### "])
    #expect(marks("##   多空几格") == ["h2@0:##   多空几格", "marker@0:##   "])
    // Tab、全角空格也算空白；前面最多 3 个空格
    #expect(marks("#\t制表") == ["h1@0:#\t制表", "marker@0:#\t"])
    #expect(marks("#\u{3000}全角") == ["h1@0:#\u{3000}全角", "marker@0:#\u{3000}"])
    #expect(marks("   ## 缩进") == ["h2@0:   ## 缩进", "marker@3:## "])
    #expect(marks("    # 四个空格").isEmpty)
    // 七个井号、没有空白、只有标记没有内容：都不是标题，原样显示
    #expect(marks("####### 七级").isEmpty && marks("#标签").isEmpty)
    #expect(marks("#").isEmpty && marks("# ").isEmpty && marks("##   ").isEmpty)
    // 标题的内容里认行内样式
    #expect(
      marks("## 有 **粗** 字")
        == ["h2@0:## 有 **粗** 字", "marker@0:## ", "marker@5:**", "bold@7:粗", "marker@8:**"])
    // 行中间的井号不算
    #expect(marks("说 # 不是标题").isEmpty)
  }

  @Test func quotesAndBullets() {
    #expect(marks("> 引用") == ["quote@0:> 引用", "marker@0:> "])
    #expect(marks(">紧挨着") == ["quote@0:>紧挨着", "marker@0:>"])
    // 空的引用也算（夹在几行引用中间的空行），它的 > 不藏、只变淡；只有一层，第二个 > 是内容
    #expect(marks(">") == ["bullet@0:>", "quote@0:>"])
    #expect(marks("> ") == ["bullet@0:> ", "quote@0:> "])
    #expect(marks(">  ") == ["quote@0:>  ", "marker@0:> "])
    #expect(marks("> > 套着") == ["quote@0:> > 套着", "marker@0:> "])
    #expect(
      marks("> 引用里的 *斜体*")
        == ["quote@0:> 引用里的 *斜体*", "marker@0:> ", "marker@7:*", "italic@8:斜体", "marker@10:*"])
    #expect(marks("说 > 不是引用").isEmpty && marks("    > 四个空格").isEmpty)
    // 无序列表：只有那个符号（变淡，不藏）；内容里认行内样式；行首的星号不是斜体的开头
    #expect(marks("- 列表") == ["bullet@0:-"] && marks("  + 缩进的") == ["bullet@2:+"])
    #expect(marks("* 星号 *斜*") == ["bullet@0:*", "marker@5:*", "italic@6:斜", "marker@7:*"])
    #expect(marks("-不是列表").isEmpty && marks("1. 有序的不加样式").isEmpty)
    #expect(marks("1. 有序里的 **粗**") == ["marker@8:**", "bold@10:粗", "marker@11:**"])
    // 列表项、标题的内容里不再认块：「- # x」不是标题
    #expect(marks("- # 不是标题") == ["bullet@0:-"])
    #expect(marks("# > 不是引用") == ["h1@0:# > 不是引用", "marker@0:# "])
  }

  // MARK: 行内

  @Test func emphasis() {
    #expect(marks("**粗**") == ["marker@0:**", "bold@2:粗", "marker@3:**"])
    #expect(marks("__粗__") == ["marker@0:__", "bold@2:粗", "marker@3:__"])
    #expect(marks("*斜*") == ["marker@0:*", "italic@1:斜", "marker@2:*"])
    #expect(marks("_斜_") == ["marker@0:_", "italic@1:斜", "marker@2:_"])
    #expect(marks("~~删~~") == ["marker@0:~~", "strike@2:删", "marker@3:~~"])
    #expect(
      marks("前 **粗** 中 *斜* 后")
        == [
          "marker@2:**", "bold@4:粗", "marker@5:**", "marker@10:*", "italic@11:斜", "marker@12:*",
        ])
    // 星号可以在词中间（中文里夹着的也行）
    #expect(marks("这是*斜体*的") == ["marker@2:*", "italic@3:斜体", "marker@5:*"])
    #expect(marks("un*frigging*believable") == ["marker@2:*", "italic@3:frigging", "marker@11:*"])
    // 又粗又斜：里面两个是粗体，外面一个是斜体
    #expect(
      marks("***又粗又斜***")
        == [
          "marker@0:*", "italic@1:**又粗又斜**", "marker@1:**", "bold@3:又粗又斜", "marker@7:**",
          "marker@9:*",
        ])
    // 套着的
    #expect(
      marks("**粗 *又斜* 粗**")
        == [
          "marker@0:**", "bold@2:粗 *又斜* 粗", "marker@4:*", "italic@5:又斜", "marker@7:*",
          "marker@10:**",
        ])
    #expect(
      marks("*斜 ~~删~~ 斜*")
        == [
          "marker@0:*", "italic@1:斜 ~~删~~ 斜", "marker@3:~~", "strike@5:删", "marker@6:~~",
          "marker@10:*",
        ])
    // 多出来的星号原样留着：** 开头、* 结尾 → 斜体，前面多一个星号
    #expect(marks("**斜*") == ["marker@1:*", "italic@2:斜", "marker@3:*"])
  }

  /// Noty 那几条正则的误伤，和别的「不该认」的
  @Test func thingsThatAreNotMarkup() {
    // 词中间的下划线不是斜体（英文、数字、汉字两边都算字）
    #expect(marks("snake_case_name").isEmpty && marks("a_b_ c").isEmpty)
    #expect(marks("中文_不是斜体_中文").isEmpty && marks("file__name__here").isEmpty)
    #expect(marks("__init__") == ["marker@0:__", "bold@2:init", "marker@6:__"])
    #expect(marks("(_斜_)") == ["marker@1:_", "italic@2:斜", "marker@3:_"])
    // 开头的标记后面、结尾的标记前面是空白：不认
    #expect(marks("2 * 3 * 4").isEmpty && marks("** 不是粗体 **").isEmpty)
    // 紧挨着的前一个字和后一个字都是 ASCII 数字的星号是乘号：既不开也不关
    for line in ["2*3*4", "箱子 60*40*30", "3*4=12", "2**3**4", "1*2 和 *3", "a*1*2"] {
      #expect(marks(line).isEmpty, "\(line)")
    }
    // 只有一边是数字的、两边是全角数字 / 汉字的照常
    #expect(marks("*3*") == ["marker@0:*", "italic@1:3", "marker@2:*"])
    #expect(marks("第**3**个") == ["marker@1:**", "bold@3:3", "marker@4:**"])
    #expect(marks("a*b*c") == ["marker@1:*", "italic@2:b", "marker@3:*"])
    #expect(marks("2*x*3") == ["marker@1:*", "italic@2:x", "marker@3:*"])
    #expect(marks("第*3*4*个") == ["marker@1:*", "italic@2:3*4", "marker@5:*"])
    #expect(marks("１*２*３") == ["marker@1:*", "italic@2:２", "marker@3:*"])
    #expect(marks("*后面是空白 *").isEmpty && marks("~~ 不是删除线 ~~").isEmpty)
    // 没配对的原样显示
    #expect(marks("**没关上").isEmpty && marks("没开头**").isEmpty && marks("*a").isEmpty)
    #expect(marks("~~x").isEmpty && marks("`没关上").isEmpty && marks("[字](没关上").isEmpty)
    #expect(marks("[只有方括号]").isEmpty && marks("](地址)").isEmpty)
    // 不同的字符不互相配
    #expect(marks("*a_").isEmpty && marks("**a__").isEmpty)
    // 空的强调：一整串标记自己配不了自己
    #expect(marks("****").isEmpty && marks("__").isEmpty && marks("a **** b").isEmpty)
    #expect(marks("~~~~").isEmpty && marks("** **").isEmpty)
    // 删除线只认正好两个波浪号
    #expect(marks("~删~").isEmpty && marks("~~~删~~~").isEmpty)
    // 反斜杠后面的标记字符不算标记（反斜杠照常显示，所以没有任何样式）
    #expect(marks("\\*不是斜体\\*").isEmpty && marks("\\_也不是\\_").isEmpty)
    #expect(marks("\\**斜\\**") == ["marker@2:*", "italic@3:斜\\*", "marker@6:*"])
    #expect(marks("\\`不是代码`").isEmpty && marks("\\[字](https://a.b)").isEmpty)
    #expect(marks("\\# 不是标题").isEmpty && marks("[字\\](https://a.b)").isEmpty)
    // 两个反斜杠是「一个反斜杠」，后面的星号照常算
    #expect(marks("\\\\*斜*") == ["marker@2:*", "italic@3:斜", "marker@4:*"])
    // 样式不交叉：粗体收尾之后，夹在里面的那个下划线开头作废
    #expect(marks("**a _b** c_") == ["marker@0:**", "bold@2:a _b", "marker@6:**"])
  }

  @Test func inlineCode() {
    #expect(marks("`代码`") == ["marker@0:`", "code@1:代码", "marker@3:`"])
    // 代码里的 * _ ~ [ 都不是标记；代码外面的照常
    #expect(
      marks("`a*b*c_d_~~e~~[f](g)` *斜*")
        == [
          "marker@0:`", "code@1:a*b*c_d_~~e~~[f](g)", "marker@20:`", "marker@22:*", "italic@23:斜",
          "marker@24:*",
        ])
    // 强调的标记落在代码里：配不上
    #expect(marks("*a `b* c`") == ["marker@3:`", "code@4:b* c", "marker@8:`"])
    // 两个反引号开的要两个关：里面可以有单个反引号
    #expect(marks("``a`b``") == ["marker@0:``", "code@2:a`b", "marker@5:``"])
    #expect(marks("``没关上`").isEmpty)
    // 代码里的反斜杠就是反斜杠
    #expect(marks("`a\\`") == ["marker@0:`", "code@1:a\\", "marker@3:`"])
    // 粗体里的代码
    #expect(
      marks("**粗 `码`**")
        == ["marker@0:**", "bold@2:粗 `码`", "marker@4:`", "code@5:码", "marker@6:`", "marker@7:**"])
  }

  @Test func links() {
    #expect(
      marks("[字](https://a.b)")
        == ["marker@0:[", "link(https://a.b)@1:字", "marker@2:](https://a.b)"])
    #expect(
      marks("看 [这里](mailto:a@b.c) 和 [那里](x)")
        == [
          "marker@2:[", "link(mailto:a@b.c)@3:这里", "marker@5:](mailto:a@b.c)", "marker@23:[",
          "link(x)@24:那里", "marker@26:](x)",
        ])
    // 地址里的括号成对就行；方括号可以套
    #expect(
      marks("[猫](https://zh.wikipedia.org/wiki/猫_(消歧义))")
        == [
          "marker@0:[", "link(https://zh.wikipedia.org/wiki/猫_(消歧义))@1:猫",
          "marker@2:](https://zh.wikipedia.org/wiki/猫_(消歧义))",
        ])
    #expect(marks("[a [b] c](u)") == ["marker@0:[", "link(u)@1:a [b] c", "marker@8:](u)"])
    // 字是空的、地址是空的、地址里有空白（带标题的写法）：不认
    #expect(marks("[](https://a.b)").isEmpty && marks("[ ](https://a.b)").isEmpty)
    #expect(marks("[字]()").isEmpty && marks("[字](地址 \"标题\")").isEmpty)
    #expect(marks("[字] (https://a.b)").isEmpty)
    // 图片（下一批）：原样显示，里面的强调也不认；外面的照常
    #expect(marks("![图](x.png)").isEmpty && marks("![**粗**](x.png)").isEmpty)
    #expect(marks("![图 *a](x.png) *斜*") == ["marker@15:*", "italic@16:斜", "marker@17:*"])
    // 链接的字里认行内样式；外面的强调可以把整个链接包起来，但不能一头在里面一头在外面
    #expect(
      marks("[**粗**](u)")
        == [
          "marker@0:[", "link(u)@1:**粗**", "marker@1:**", "bold@3:粗", "marker@4:**",
          "marker@6:](u)",
        ])
    #expect(
      marks("*看 [字](u)*")
        == [
          "marker@0:*", "italic@1:看 [字](u)", "marker@3:[", "link(u)@4:字", "marker@5:](u)",
          "marker@9:*",
        ])
    #expect(marks("*a [b* c](u)") == ["marker@3:[", "link(u)@4:b* c", "marker@8:](u)"])
    // 链接里不套链接：里面那个成了，外面的方括号原样
    #expect(marks("[a [b](u) c](v)") == ["marker@3:[", "link(u)@4:b", "marker@5:](u)"])
    // 字里的代码可以带方括号
    #expect(
      marks("[`]`](u)")
        == ["marker@0:[", "link(u)@1:`]`", "marker@1:`", "code@2:]", "marker@3:`", "marker@4:](u)"])
    // 地址太长的不当链接（免得一行怪文字越扫越慢）
    let long = String(repeating: "a", count: NoteMarkdown.addressLimit + 1)
    #expect(marks("[字](\(long))").isEmpty)
    #expect(marks("[字](\(long.dropLast()))").last == "marker@2:](\(long.dropLast()))")
  }

  /// 能打开的地址：http、https（要有主机名）、mailto；别的只有下划线
  @Test func linkAddressesThatOpen() {
    #expect(NoteMarkdown.url("https://example.com/a?b=c")?.host == "example.com")
    #expect(NoteMarkdown.url("http://example.com") != nil)
    #expect(NoteMarkdown.url("HTTPS://EXAMPLE.COM") != nil)
    #expect(NoteMarkdown.url("mailto:someone@example.com") != nil)
    #expect(NoteMarkdown.url("https://zh.wikipedia.org/wiki/猫_(消歧义)") != nil)
    for address in [
      "file:///etc/passwd", "javascript:alert(1)", "x-apple.systempreferences:com.apple.x",
      "kitty://x", "ftp://example.com", "example.com", "/usr/bin", "", "mailto:", "https://",
      "http:example.com", "tel:10086", "data:text/html,x", "smb://server/share",
    ] {
      #expect(NoteMarkdown.url(address) == nil, "\(address)")
    }
  }

  /// 和任务叠着：任务行的内容里只认行内样式；开关关掉只剩任务的两种
  @Test func tasksAndTheSwitch() {
    #expect(marks("☐ **粗** 字") == ["box@0:☐", "marker@2:**", "bold@4:粗", "marker@5:**"])
    #expect(
      marks("  ☑ 做完的 `码`")
        == ["box@2:☑", "done@4:做完的 `码`", "marker@8:`", "code@9:码", "marker@10:`"])
    // 任务行里不认标题、引用、列表
    #expect(marks("☐ # 不是标题") == ["box@0:☐"] && marks("☐ > 不是引用") == ["box@0:☐"])
    #expect(marks("☑ - 不是列表") == ["box@0:☑", "done@2:- 不是列表"])
    // 标题里的方框只是一个字
    #expect(marks("# ☐ 不是任务") == ["h1@0:# ☐ 不是任务", "marker@0:# "])
    // 开关关掉：没有 Markdown 的种类，任务照常
    for line in ["# 标题", "**粗** *斜* ~~删~~ `码`", "[字](https://a.b)", "> 引用", "- 列表"] {
      #expect(marks(line, markdown: false).isEmpty, "\(line)")
    }
    #expect(marks("☑ **粗**", markdown: false) == ["box@0:☑", "done@2:**粗**"])
    #expect(marks("☐ [字](u)", markdown: false) == ["box@0:☐"])
  }

  /// 不会越界、不会卡：各种怪输入扫一遍；位置都在这一行里
  @Test func oddInputsStayInBounds() {
    let lines = [
      "", " ", "*", "**", "***", "_", "`", "``", "[", "]", "![", "](", "[](", "[]()", "\\", "#",
      ">", "> ", "~~", "🙂*🙂*🙂", "[🙂](https://a.b)", "*a**b**c*", "**a*b*c**", "*a**b*c**",
      "[[[[[[", "]]]]]]", "![![![a](b)", "[a](b)[c](d)[e", "`a``b```c", "**__~~`x`~~__**",
      String(repeating: "[", count: 20_000), String(repeating: "*a ", count: 20_000),
      String(repeating: "](", count: 20_000), String(repeating: "_a* ", count: 20_000),
      String(repeating: "![", count: 5000) + String(repeating: "[a](u)", count: 5000),
    ]
    for line in lines {
      let length = (line as NSString).length
      let spans = NoteStyles.spans(in: line, markdown: true)
      #expect(spans.allSatisfy { $0.range.location >= 0 && NSMaxRange($0.range) <= length })
      // 标记互不相交
      let markers = spans.filter { $0.kind == .marker }.map(\.range)
        .sorted { $0.location < $1.location }
      #expect(zip(markers, markers.dropFirst()).allSatisfy { NSMaxRange($0) <= $1.location })
      // 叠出来的段从前到后、互不相交、都在这一行里
      let runs = NoteStyles.runs(of: spans)
      #expect(runs.allSatisfy { $0.range.length > 0 && NSMaxRange($0.range) <= length })
      #expect(
        zip(runs, runs.dropFirst()).allSatisfy { NSMaxRange($0.range) <= $1.range.location })
    }
    // 紧挨着的写法按就近配对（没做 CommonMark 的「3 的倍数」规则）：三段都是斜体
    #expect(marks("*a**b**c*").filter { $0.hasPrefix("italic") }.count == 3)
  }

  // MARK: 叠起来

  /// 标题里的粗体还是标题的字号（一段字同时在标题和粗体里）；做完的任务里的粗体；标记压在别的上面
  @Test func looksAreLayered() {
    func looks(_ line: String) -> [String: NoteStyles.Look] {
      var result: [String: NoteStyles.Look] = [:]
      for run in NoteStyles.runs(of: NoteStyles.spans(in: line, markdown: true)) {
        result[(line as NSString).substring(with: run.range)] = run.look
      }
      return result
    }
    let heading = looks("## 有 **粗** 和 `码`")
    #expect(heading["## "] == NoteStyles.Look(heading: 2, isMarker: true))
    #expect(heading["有 "] == NoteStyles.Look(heading: 2))
    #expect(heading["粗"] == NoteStyles.Look(heading: 2, isBold: true))
    #expect(heading["**"] == NoteStyles.Look(heading: 2, isMarker: true))
    #expect(heading["码"] == NoteStyles.Look(heading: 2, isCode: true))
    let done = looks("☑ 做完 **粗** ~~删~~")
    #expect(done["☑"] == NoteStyles.Look(isBox: true))
    #expect(done["做完 "] == NoteStyles.Look(isDone: true))
    #expect(done["粗"] == NoteStyles.Look(isBold: true, isDone: true))
    #expect(done["删"] == NoteStyles.Look(isStruck: true, isDone: true))
    #expect(done["~~"] == NoteStyles.Look(isDone: true, isMarker: true))
    let nested = looks("> ***x*** [**y**](https://a.b)")
    #expect(nested["x"] == NoteStyles.Look(isBold: true, isItalic: true, isQuote: true))
    #expect(nested["y"] == NoteStyles.Look(isBold: true, isQuote: true, link: "https://a.b"))
    #expect(nested["](https://a.b)"] == NoteStyles.Look(isQuote: true, isMarker: true))
    #expect(looks("- 项")["-"] == NoteStyles.Look(isBullet: true) && looks("- 项")["项"] == nil)
    // 没有样式的段不给；空区间不算
    #expect(NoteStyles.runs(of: []).isEmpty)
    #expect(NoteStyles.runs(of: [NoteStyles.Span(range: range(3, 0), kind: .bold)]).isEmpty)
  }

  // MARK: 套用

  private let theme = NoteStyles.Theme(
    paper: NotePaper.all[0], fontSize: 15, markdown: true, spacing: .standard)
  /// 中英混排：字体的断言都落在英文上（汉字的字体可能被系统换成后备字体，只核对字号）
  private let sample = """
    # One **Two** 一级
    ### Three `four`
    Body **bold** *ital* ~~gone~~ `mono` ***both*** snake_case_name 正文
    [能点 open](https://example.com) [不能点](file:///x) ![图](x.png)
    > 引用 quote *斜*
    > 第二行
    - 列表 item **粗**
    ☐ 任务 **task**
    ☑ 做完 done **heavy** [链 link](https://a.b)
    普通的一行 plain

    """

  private func styled(_ text: String, shown: [NSRange] = [], theme: NoteStyles.Theme? = nil)
    -> NSTextStorage
  {
    let storage = NSTextStorage(string: text)
    NoteStyles.apply(
      to: storage, lines: range(0, storage.length), theme: theme ?? self.theme, shown: shown,
      blocks: NoteMarkdown.codeBlocks(in: storage.mutableString))
    return storage
  }

  private func attribute<Value>(
    _ key: NSAttributedString.Key, of text: String, in storage: NSTextStorage,
    as type: Value.Type = Value.self
  ) -> Value? {
    let found = storage.mutableString.range(of: text)
    guard found.location != NSNotFound else { return nil }
    return storage.attribute(key, at: found.location, effectiveRange: nil) as? Value
  }

  /// 各样式换成的属性；别的行不受影响
  @Test func attributesOfEachStyle() throws {
    let storage = styled(sample)
    func font(_ text: String) -> NSFont? { attribute(.font, of: text, in: storage) }
    func color(_ text: String) -> NSColor? { attribute(.foregroundColor, of: text, in: storage) }
    func has(_ key: NSAttributedString.Key, _ text: String) -> Bool {
      let found = storage.mutableString.range(of: text)
      return found.location != NSNotFound
        && storage.attribute(key, at: found.location, effectiveRange: nil) != nil
    }
    let base = NSFont.systemFont(ofSize: 15)
    // 标题：加粗、按级别放大（整点）；标题里的粗体还是标题的字号、更粗；标题里的代码等宽、跟着大
    #expect(font("One") == NSFont.systemFont(ofSize: 24, weight: .bold))
    #expect(font("Two") == NSFont.systemFont(ofSize: 24, weight: .heavy))
    #expect(font("一级")?.pointSize == 24)
    #expect(font("Three") == NSFont.systemFont(ofSize: 19, weight: .bold))
    #expect(font("four") == NSFont.monospacedSystemFont(ofSize: 17, weight: .bold))
    #expect(NoteStyles.headingSize(1, base: 13) == 21 && NoteStyles.headingSize(4, base: 13) == 15)
    #expect(NoteStyles.headingSize(5, base: 20) == 20 && NoteStyles.headingSize(6, base: 17) == 17)
    #expect(NoteStyles.headingSize(2, base: 17) == 24 && NoteStyles.headingSize(3, base: 20) == 25)
    // 正文里：粗体是系统字体的粗体；斜体不换字体、只倾斜；删除线；代码等宽小一号带底
    #expect(font("Body") == base && color("Body") == theme.ink)
    #expect(font("正文")?.pointSize == 15 && color("正文") == theme.ink)
    #expect(font("bold") == NSFont.systemFont(ofSize: 15, weight: .bold))
    #expect(font("ital") == base)
    #expect(attribute(.obliqueness, of: "ital", in: storage, as: Double.self) == 0.2)
    #expect(has(.strikethroughStyle, "gone") && !has(.strikethroughStyle, "~~gone"))
    #expect(!has(.strikethroughStyle, "~~ `mono"))
    #expect(font("mono") == NSFont.monospacedSystemFont(ofSize: 14, weight: .regular))
    #expect(attribute(.backgroundColor, of: "mono", in: storage) == theme.codeFill)
    #expect(!has(.backgroundColor, "` ***"))
    #expect(font("both") == NSFont.systemFont(ofSize: 15, weight: .bold))
    #expect(has(.obliqueness, "both"))
    #expect(font("snake_case_name") == base && !has(.obliqueness, "_case_"))
    // 链接：下划线、墨色；能打开的记着地址，别的只有下划线；图片原样；不用系统的 .link
    #expect(has(.underlineStyle, "open") && color("open") == theme.ink)
    #expect(
      attribute(NoteStyles.linkKey, of: "能点", in: storage, as: URL.self)
        == URL(string: "https://example.com"))
    #expect(has(.underlineStyle, "不能点") && !has(NoteStyles.linkKey, "不能点"))
    #expect(!has(.underlineStyle, "图") && !has(NoteStyles.hiddenKey, "![图"))
    #expect(!has(.link, "open"))
    // 引用：次要的墨、缩进，连行尾的换行都记着（两行连成一段）
    #expect(color("quote") == theme.secondary && has(NoteStyles.quoteKey, "quote"))
    let style: NSParagraphStyle = try #require(attribute(.paragraphStyle, of: "quote", in: storage))
    #expect(style.headIndent == 14 && style.firstLineHeadIndent == 14)
    var quote = NSRange()
    let start = storage.mutableString.range(of: "> 引用").location
    _ = storage.attribute(
      NoteStyles.quoteKey, at: start, longestEffectiveRange: &quote,
      in: range(0, storage.length))
    #expect(storage.mutableString.substring(with: quote) == "> 引用 quote *斜*\n> 第二行\n")
    let list: NSParagraphStyle = try #require(attribute(.paragraphStyle, of: "- 列表", in: storage))
    #expect(list.headIndent == 0 && !has(NoteStyles.quoteKey, "Body"))
    // 列表的符号变淡、不藏
    #expect(color("- 列表") == theme.faded && !has(NoteStyles.hiddenKey, "- 列表"))
    #expect(color("item") == theme.ink)
    // 任务：方框还是 Apple Symbols × 1.1；任务行里的粗体；做完的任务里的粗体和链接——划线、变淡叠着
    #expect(font("☐")?.fontName == "AppleSymbols" && font("☐")?.pointSize == 17)
    #expect(
      font("task") == NSFont.systemFont(ofSize: 15, weight: .bold) && color("task") == theme.ink)
    #expect(font("heavy") == NSFont.systemFont(ofSize: 15, weight: .bold))
    #expect(color("heavy") == theme.faded && has(.strikethroughStyle, "heavy"))
    #expect(has(.underlineStyle, "link]") && has(.strikethroughStyle, "link]"))
    #expect(color("done") == theme.faded && color("☑") == theme.ink)
    #expect(font("☑")?.fontName == "AppleSymbols" && !has(.strikethroughStyle, "☑"))
    // 引用里的行内代码用墨色（次要的墨压在代码的底上对比度不够），反引号是标记；做完的任务里的代码照旧跟着变淡
    let coded = styled("> 引用 `code` 后面\n☑ 做完 `mono`\n> **粗 `both`**", shown: [range(0, 1)])
    func tone(_ text: String) -> NSColor? { attribute(.foregroundColor, of: text, in: coded) }
    #expect(tone("code") == theme.ink && tone("引用") == theme.secondary)
    #expect(tone("后面") == theme.secondary && tone("`code") == theme.marker)
    #expect(tone("mono") == theme.faded && tone("both") == theme.ink)
    #expect(tone("粗") == theme.secondary)
    #expect(attribute(.backgroundColor, of: "code", in: coded) == theme.codeFill)
    #expect(theme.ink != theme.secondary && theme.ink != theme.faded)
    // 标记：没有露着的行，全都藏着
    for marker in [
      "# One", "**bold** *ital*", "~~gone", "`mono` ***", "[能点", "](https://example.com)",
    ] {
      #expect(has(NoteStyles.hiddenKey, marker) && !has(NoteStyles.shownKey, marker), "\(marker)")
    }
    #expect(!has(NoteStyles.hiddenKey, "普通的一行") && !has(NoteStyles.hiddenKey, "Body"))
  }

  /// 露着的行：标记不藏，是淡的墨；别的行照样藏着。shown 说的是「行首落在里面」
  @Test func shownLinesFadeTheirMarkers() {
    let text = "**粗** 一\n*斜* 二\n`码` 三"
    let second = (text as NSString).lineRange(for: range(8, 0))
    let storage = styled(text, shown: [second])
    func keys(_ index: Int) -> (hidden: Bool, shown: Bool) {
      (
        storage.attribute(NoteStyles.hiddenKey, at: index, effectiveRange: nil) != nil,
        storage.attribute(NoteStyles.shownKey, at: index, effectiveRange: nil) != nil
      )
    }
    #expect(keys(0) == (true, false) && keys(3) == (true, false))
    #expect(keys(8) == (false, true) && keys(10) == (false, true))
    #expect(keys(14) == (true, false) && keys(9) == (false, false))
    #expect(
      storage.attribute(.foregroundColor, at: 8, effectiveRange: nil) as? NSColor == theme.marker)
    // 露着的标记不倾斜，里面的字照常
    #expect(storage.attribute(.obliqueness, at: 8, effectiveRange: nil) == nil)
    #expect(storage.attribute(.obliqueness, at: 9, effectiveRange: nil) != nil)
    // 哪些行不对：现在该露第三行 → 第二行要收、第三行要露，挨着的并成一段
    let third = (text as NSString).lineRange(for: range(text.utf16.count, 0))
    #expect(NoteStyles.outdated(in: storage, shown: [third]) == [range(8, 11)])
    #expect(NoteStyles.outdated(in: storage, shown: [second]).isEmpty)
    #expect(NoteStyles.outdated(in: storage, shown: []) == [second])
    // 不挨着的两段各是各的
    let first = (text as NSString).lineRange(for: range(0, 0))
    let far = styled(text, shown: [first])
    #expect(NoteStyles.outdated(in: far, shown: [third]) == [first, third])
    // 该露的行里没有标记：不用动
    let plain = styled("没有标记\n**有**")
    #expect(NoteStyles.outdated(in: plain, shown: [range(0, 5)]).isEmpty)
    #expect(NoteStyles.outdated(in: plain, shown: [range(0, 10)]) == [range(0, 10)])
  }

  /// 所有语法都不跨行：一行一行排（每次编辑走的路）和整篇排一遍，逐个属性一样；重排一遍也不变。
  /// 语法删坏之后那一行的下划线、链接、隐藏都清干净
  @Test func lineByLineEqualsWholeText() {
    let whole = styled(sample)
    let piecewise = NSTextStorage(string: sample)
    // 倒着一行一行排：前面的行排没排不影响后面的
    var lines: [NSRange] = []
    var location = 0
    while location < piecewise.length {
      let line = piecewise.mutableString.lineRange(for: range(location, 0))
      lines.append(line)
      location = NSMaxRange(line)
    }
    for line in lines.reversed() {
      NoteStyles.apply(to: piecewise, lines: line, theme: theme, shown: [], blocks: [])
    }
    #expect(piecewise.isEqual(to: whole))
    NoteStyles.apply(
      to: piecewise, lines: range(0, piecewise.length), theme: theme, shown: [], blocks: [])
    #expect(piecewise.isEqual(to: whole))
    // 关着开关排出来的，和「只有任务」的一样：没有任何 Markdown 的属性
    let off = styled(
      sample,
      theme: NoteStyles.Theme(
        paper: NotePaper.all[0], fontSize: 15, markdown: false, spacing: .standard))
    for key in [
      NoteStyles.hiddenKey, NoteStyles.shownKey, NoteStyles.linkKey, NoteStyles.quoteKey,
      NoteStyles.roleKey, .underlineStyle, .obliqueness, .backgroundColor,
    ] {
      var found = false
      off.enumerateAttribute(key, in: range(0, off.length)) { value, _, _ in
        found = found || value != nil
      }
      #expect(!found, "\(key.rawValue)")
    }
    // 段落样式每一行都有（行高是排版）：关着时都是正文那一种，没有缩进、段前段后
    off.enumerateAttribute(.paragraphStyle, in: range(0, off.length)) { value, _, _ in
      #expect(
        value as? NSParagraphStyle == off.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
          as? NSParagraphStyle)
    }
    #expect(
      (off.attribute(.font, at: off.mutableString.range(of: "☐").location, effectiveRange: nil)
        as? NSFont)?.fontName == "AppleSymbols")
    #expect(
      off.attribute(
        .strikethroughStyle, at: off.mutableString.range(of: "做完").location, effectiveRange: nil)
        != nil)
    // 把链接的「]」删掉再排那一行：残留的下划线、地址、隐藏都没了
    let broken = styled("前一行 **粗**\n看 [字](https://a.b) 后\n后一行")
    let bracket = broken.mutableString.range(of: "]")
    broken.replaceCharacters(in: bracket, with: "")
    let line = NoteStyles.lines(covering: range(bracket.location, 0), in: broken.mutableString)
    NoteStyles.apply(to: broken, lines: line, theme: theme, shown: [], blocks: [])
    #expect(broken.mutableString.substring(with: line) == "看 [字(https://a.b) 后\n")
    for key in [NoteStyles.hiddenKey, NoteStyles.linkKey, .underlineStyle] {
      var found = false
      broken.enumerateAttribute(key, in: line) { value, _, _ in found = found || value != nil }
      #expect(!found, "\(key.rawValue)")
    }
    // 前一行没动
    #expect(broken.attribute(NoteStyles.hiddenKey, at: 4, effectiveRange: nil) != nil)
  }

  // MARK: 标题和摘要

  /// 标题、摘要里不带 Markdown 的标记（不看设置里的开关）；不是标记的原样
  @Test func titlesAndPreviewsDropMarkers() {
    func note(_ body: String) -> Note {
      Note(id: "x", body: body, createdAt: .now, modifiedAt: .now)
    }
    #expect(note("**粗** 和 *斜* 和 ~~删~~ 和 `码`").displayTitle == "粗 和 斜 和 删 和 码")
    #expect(note("看 [这里](https://example.com/很长的地址) 的").displayTitle == "看 这里 的")
    #expect(note("# 标题里的 **粗**").displayTitle == "标题里的 粗")
    #expect(note("> 引用的一句").displayTitle == "引用的一句")
    #expect(note("- 牛奶").displayTitle == "牛奶" && note("  * 鸡蛋").displayTitle == "鸡蛋")
    #expect(note("☐ **买** 牛奶").displayTitle == "买 牛奶")
    // 不是标记的不动：词里的下划线、代码里的星号、转义的、没配对的、图片、有序列表的序号
    #expect(note("snake_case_name").displayTitle == "snake_case_name")
    #expect(note("`a*b*c`").displayTitle == "a*b*c")
    #expect(note("\\*不是斜体\\*").displayTitle == "\\*不是斜体\\*")
    #expect(note("2 * 3 * 4 和 **没关上").displayTitle == "2 * 3 * 4 和 **没关上")
    // 数字中间的星号是乘号：标题里原样（原来被当成斜体去掉，读成「234」）
    #expect(note("2*3*4").displayTitle == "2*3*4")
    #expect(note("# 箱子 60*40*30").displayTitle == "箱子 60*40*30")
    // 贴进来没转成方框的任务（- [ ] / - [x]，NoteTasks 认的那种写法）：连符号一起去；后面没跟空格的不算
    #expect(note("- [ ] 买牛奶").displayTitle == "买牛奶" && note("  * [x] 做完的").displayTitle == "做完的")
    #expect(note("+ [X] **粗** 的").displayTitle == "粗 的" && note("- [ ]\n第二行").displayTitle == "第二行")
    #expect(note("标题\n- [ ] 买牛奶\n- [x] 鸡蛋").preview == "买牛奶 鸡蛋")
    #expect(note("- [ ]紧挨着").displayTitle == "[ ]紧挨着" && note("- [y] 别的").displayTitle == "[y] 别的")
    #expect(note("# - [ ] 标题里的").displayTitle == "- [ ] 标题里的")
    #expect(note("![图](x.png)").displayTitle == "![图](x.png)")
    #expect(note("1. 第一条").displayTitle == "1. 第一条")
    // 标题、任务的内容里不再去行首的 > 和 -（它们在那里只是字）
    #expect(note("# > 大于号").displayTitle == "> 大于号")
    #expect(note("☑ - 横线").displayTitle == "- 横线")
    // 去掉标记之后是空的那一行跳过
    #expect(note(">\n- \n真正的第一行").displayTitle == "真正的第一行")
    #expect(
      note("标题\n- **牛奶**\n> 引用 `码`\n[字](https://a.b)").preview == "牛奶 引用 码 字")
    #expect(NoteMarkdown.plain("**粗** > 不在行首", blocks: true) == "粗 > 不在行首")
    #expect(NoteMarkdown.plain("> 引用", blocks: false) == "> 引用")
    #expect(NoteMarkdown.plain("没有标记", blocks: true) == "没有标记")
  }

  /// 开关是一个注册了默认值的偏好（默认开）：跟着设置的导出 / 导入走。行距同样（默认「标准」）
  @Test func theSwitchIsARegisteredPreference() {
    #expect(Prefs.defaults[Prefs.notesMarkdown] as? Bool == true)
    #expect(SettingsArchive.kinds[Prefs.notesMarkdown] != nil)
    #expect(Prefs.defaults[Prefs.notesLineSpacing] as? String == "standard")
    #expect(SettingsArchive.kinds[Prefs.notesLineSpacing] != nil)
    #expect(NoteStyles.Spacing.allCases.map(\.rawValue) == ["compact", "standard", "relaxed"])
    #expect(NoteStyles.Spacing.allCases.map(\.multiple) == [1.2, 1.45, 1.7])
    #expect(NoteStyles.Spacing.allCases.map(\.title) == ["紧凑", "标准", "宽松"])
  }

  // MARK: 手测反馈第 4 批：代码块、行距、加标记的快捷键、粘贴成链接

  /// 围栏行的认法：三个以上同一种的反引号或波浪号、前面最多 3 个空格、后面可以跟语言名（反引号的语言名里不能再有
  /// 反引号）；只有空白的才能收尾
  @Test func fences() {
    func fence(_ line: String) -> NoteMarkdown.Fence? {
      let units = Array(line.utf16)
      return NoteMarkdown.fence(count: units.count) { units[$0] }
    }
    let (tick, tilde): (UInt16, UInt16) = (0x60, 0x7E)
    #expect(fence("```") == NoteMarkdown.Fence(mark: tick, count: 3, isBare: true))
    #expect(fence("````swift") == NoteMarkdown.Fence(mark: tick, count: 4, isBare: false))
    #expect(fence("~~~") == NoteMarkdown.Fence(mark: tilde, count: 3, isBare: true))
    #expect(fence("   ```  ") == NoteMarkdown.Fence(mark: tick, count: 3, isBare: true))
    #expect(fence("``` js") == NoteMarkdown.Fence(mark: tick, count: 3, isBare: false))
    #expect(fence("~~~ 带`反引号`的") == NoteMarkdown.Fence(mark: tilde, count: 3, isBare: false))
    // 不是围栏：四个空格、不够三个、两种混着、行内代码、前面有字、Tab 缩进、空行
    #expect(fence("    ```") == nil && fence("``") == nil && fence("~~") == nil)
    #expect(fence("`~~") == nil && fence("```a```") == nil && fence("``` `x`") == nil)
    #expect(fence("a```") == nil && fence("\t```") == nil && fence("") == nil)
  }

  /// 配对：开头往后找第一行「同一种字符、不少于开头的个数、后面只有空白」的围栏收尾；中间夹着的围栏是块里的字；
  /// 没关上的开头不算（照普通的一行），接着往下找；挨着的两块各是各的
  @Test func codeBlocksPair() {
    func blocks(_ text: String) -> [String] {
      let source = text as NSString
      return NoteMarkdown.codeBlocks(in: source).map { source.substring(with: $0.range) }
    }
    #expect(blocks("前\n```swift\nlet a = 1\n```\n后") == ["```swift\nlet a = 1\n```\n"])
    // 收尾在正文末尾（没有换行）、空的块
    #expect(blocks("```\nx\n```") == ["```\nx\n```"])
    #expect(blocks("```\n```\n") == ["```\n```\n"])
    // 没关上：不算——刚打出开头的三个反引号，后面不会突然都成了代码
    #expect(blocks("```\nx\n# 标题\n**粗**").isEmpty)
    // 个数不够、带语言名、另一种字符的都不能收尾
    #expect(blocks("````\na\n```\nb\n````") == ["````\na\n```\nb\n````"])
    #expect(blocks("```\na\n```js\n```") == ["```\na\n```js\n```"])
    #expect(blocks("~~~\n```\n~~~") == ["~~~\n```\n~~~"])
    // 没关上的开头跳过之后，后面的照样配
    #expect(blocks("~~~~\n```\nx\n```") == ["```\nx\n```"])
    #expect(blocks("```\na\n```\n```\nb\n```") == ["```\na\n```\n", "```\nb\n```"])
    // 每一行的角色：开头、块里、收尾；块外 nil
    // x 0 换行 1 | ``` 2-4 换行 5 | a 6 换行 7 | 换行 8 | ``` 9-11 换行 12 | y 13
    let text = "x\n```\na\n\n```\ny" as NSString
    let found = NoteMarkdown.codeBlocks(in: text)
    #expect(
      [0, 2, 6, 8, 9, 13].map { NoteMarkdown.role(at: $0, in: found) } == [
        nil, .open, .content, .content, .close, nil,
      ])
    // 很多没关上的开头（一路往下都找不到收尾）：不会越来越慢——同一种字符、不少于这么多的，后面直接跳过
    let many = String(repeating: "```a\n", count: 20_000) as NSString
    #expect(NoteMarkdown.codeBlocks(in: many).isEmpty)
  }

  /// 代码块里的行：等宽、按原文——标题、强调、链接、任务的方框、列表符号都不认；围栏行墨色、不藏；整行（连换行）
  /// 记着角色、主字体是等宽的字；块外照常
  @Test func codeBlockLinesAreVerbatim() throws {
    let text = "前面 **粗**\n```swift\n# 不是标题 **不粗** [不是](https://a.b)\n☐ 不是任务\n- 不是列表\n```\n后面 *斜*"
    let storage = styled(text)
    let source = storage.mutableString
    func at(_ fragment: String) -> Int { source.range(of: fragment).location }
    func value<Value>(_ key: NSAttributedString.Key, _ fragment: String) -> Value? {
      storage.attribute(key, at: at(fragment), effectiveRange: nil) as? Value
    }
    let code = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    // 字体按字号认：等宽字体里没有方框、汉字，文本存储会换成后备字体（名字会变，字号不变）
    for fragment in ["# 不是", "不是标题", "**不粗", "[不是]", "☐ 不是", "- 不是", "```swift", "```\n后"] {
      #expect((value(.font, fragment) as NSFont?)?.pointSize == 14, "\(fragment)")
      #expect(value(NoteStyles.lineFontKey, fragment) == code, "\(fragment)")
      for key in [NoteStyles.hiddenKey, NoteStyles.shownKey, NoteStyles.linkKey, .underlineStyle] {
        #expect(storage.attribute(key, at: at(fragment), effectiveRange: nil) == nil, "\(fragment)")
      }
    }
    #expect(
      value(.foregroundColor, "不是标题") == theme.ink && value(.foregroundColor, "- 不是") == theme.ink)
    // 围栏行是墨（标记那一档、次要的墨压在代码的底上都不够 4.5:1，语言名读不出）
    #expect(value(.foregroundColor, "```swift") == theme.ink)
    #expect(value(.foregroundColor, "```\n后") == theme.ink)
    // 角色：开头 1、块里 2、收尾 3（连行尾的换行），块外没有
    #expect(value(NoteStyles.roleKey, "```swift") == 1 && value(NoteStyles.roleKey, "不是标题") == 2)
    #expect(value(NoteStyles.roleKey, "\n- 不是") == 2 && value(NoteStyles.roleKey, "```\n后") == 3)
    #expect(
      storage.attribute(NoteStyles.roleKey, at: at("```\n后") + 3, effectiveRange: nil) as? Int == 3)
    #expect(
      value(NoteStyles.roleKey, "前面") as Int? == nil
        && value(NoteStyles.roleKey, "后面") as Int? == nil)
    // 段落：行高按代码的字（14 × 1.45 → 20）、左右缩进、Tab 是四个空格宽；开头那行上面、收尾那行下面留一点
    // （四分之一行 6，再加上画出来的底多出的 3）
    let line: NSParagraphStyle = try #require(value(.paragraphStyle, "不是标题"))
    #expect(line.minimumLineHeight == 20 && line.maximumLineHeight == 20)
    #expect(line.headIndent == 8 && line.firstLineHeadIndent == 8 && line.tailIndent == -8)
    let space = (" " as NSString).size(withAttributes: [.font: code]).width
    #expect(line.defaultTabInterval == space * 4 && line.tabStops.isEmpty)
    let open: NSParagraphStyle = try #require(value(.paragraphStyle, "```swift"))
    let close: NSParagraphStyle = try #require(value(.paragraphStyle, "```\n后"))
    #expect(open.paragraphSpacingBefore == 9 && open.paragraphSpacing == 0)
    #expect(close.paragraphSpacingBefore == 0 && close.paragraphSpacing == 9)
    #expect(line.paragraphSpacingBefore == 0 && line.paragraphSpacing == 0)
    // 块外照常：粗体、斜体，标记藏着
    #expect((value(.font, "粗") as NSFont?)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    #expect(storage.attribute(NoteStyles.hiddenKey, at: at("**粗"), effectiveRange: nil) != nil)
    #expect(storage.attribute(.obliqueness, at: at("斜"), effectiveRange: nil) != nil)
    // 没配上对的围栏行照普通的一行（行内扫：三个反引号没有关上的，原样）
    let open2 = styled("```js\n# 标题")
    #expect(open2.attribute(NoteStyles.roleKey, at: 0, effectiveRange: nil) == nil)
    #expect((open2.attribute(.font, at: 7, effectiveRange: nil) as? NSFont)?.pointSize == 24)
  }

  /// 行距：每一行的行高定死 = 这一行的字号 × 倍数（整点）——任务行和普通行一样高；标题按它放大后的字号，上方留
  /// 半行、下方留四分之一行；连着的引用整块上下各留四分之一行（中间的行不留）；代码按代码的字。三档都对
  @Test func lineHeightsFollowTheSpacing() throws {
    let text = "# 标题\n普通的一行\n☐ 任务\n> 引用一\n> 引用二\n后面\n```\ncode\n```"
    for spacing in NoteStyles.Spacing.allCases {
      let theme = NoteStyles.Theme(
        paper: NotePaper.all[0], fontSize: 15, markdown: true, spacing: spacing)
      let storage = styled(text, theme: theme)
      func style(_ fragment: String) throws -> NSParagraphStyle {
        try #require(
          storage.attribute(
            .paragraphStyle, at: storage.mutableString.range(of: fragment).location,
            effectiveRange: nil) as? NSParagraphStyle)
      }
      let body = (15 * spacing.multiple).rounded()
      let margin = (body * 0.25).rounded()
      for fragment in ["普通", "☐", "任务", "后面"] {
        #expect(try style(fragment).minimumLineHeight == body, "\(spacing) \(fragment)")
        #expect(try style(fragment).maximumLineHeight == body, "\(spacing) \(fragment)")
        #expect(try style(fragment).paragraphSpacingBefore == 0, "\(spacing) \(fragment)")
      }
      let heading = try style("标题")
      #expect(heading.minimumLineHeight == (24 * spacing.multiple).rounded())
      #expect(heading.paragraphSpacingBefore == (body * 0.5).rounded())
      #expect(heading.paragraphSpacing == margin)
      #expect(try style("引用一").paragraphSpacingBefore == margin)
      #expect(try style("引用一").paragraphSpacing == 0 && style("引用二").paragraphSpacingBefore == 0)
      #expect(try style("引用二").paragraphSpacing == margin && style("引用二").headIndent == 14)
      #expect(try style("code").minimumLineHeight == (14 * spacing.multiple).rounded())
      #expect(theme.baseParagraph == (try style("普通")))
    }
    // 标准档的数：正文 22、一级标题 35（上 11、下 6）、代码 20
    let standard = NoteStyles.Theme(
      paper: NotePaper.all[0], fontSize: 15, markdown: true, spacing: .standard)
    #expect(
      standard.lineHeight(15) == 22 && standard.lineHeight(24) == 35
        && standard.lineHeight(14) == 20)
    // 主字体：标题行是标题的字、任务行是正文的字（方框另算）
    let storage = styled(text)
    let font = { (fragment: String) in
      storage.attribute(
        NoteStyles.lineFontKey, at: storage.mutableString.range(of: fragment).location,
        effectiveRange: nil) as? NSFont
    }
    #expect(font("标题") == NSFont.systemFont(ofSize: 24, weight: .bold))
    #expect(
      font("☐") == NSFont.systemFont(ofSize: 15) && font("任务") == NSFont.systemFont(ofSize: 15))
    // 占位和第一个字对齐：字在行里居中让出来的那点
    let system = NSFont.systemFont(ofSize: 15)
    let box = system.ascender - system.descender
    let top = NoteStyles.textTop(fontSize: 15, spacing: .standard)
    #expect(top == ((22 - box) / 2 + system.ascender).rounded() - system.ascender)
  }

  /// 加标记的快捷键（纯函数）：没有选区插一对、光标在中间，再按一次（中间还空着）删掉；有选区两头加上，选中的字
  /// 自己带着标记、或者紧挨着的两边就是这种标记时去掉；每一行各自包、跳过行首的块标记和两头的空白；几段里有没包的就
  /// 都包上，都包着才都去掉；斜体只认单数个星号（两个是粗体）
  @Test func wrapToggles() {
    func run(_ wrap: NoteMarkdown.Wrap, _ text: String, _ selection: NSRange) -> Edit? {
      guard let change = NoteMarkdown.toggle(wrap, in: text, selection: selection) else {
        return nil
      }
      let result = NSMutableString(string: text)
      for replacement in change.replacements.reversed() {
        result.replaceCharacters(in: replacement.range, with: replacement.text)
      }
      return Edit(result as String, change.selection)
    }
    // 没有选区：插一对、光标在中间；中间还空着再按：删掉
    #expect(run(.bold, "周报", range(2)) == Edit("周报****", range(4)))
    #expect(run(.bold, "周报****", range(4)) == Edit("周报", range(2)))
    #expect(run(.italic, "ab", range(1)) == Edit("a**b", range(2)))
    #expect(run(.italic, "a**b", range(2)) == Edit("ab", range(1)))
    #expect(run(.strike, "", range(0)) == Edit("~~~~", range(2)))
    #expect(run(.code, "x``", range(2)) == Edit("x", range(1)))
    // 光标在行首的块标记里：挪到内容开头再插
    #expect(run(.bold, "- 牛奶", range(0)) == Edit("- ****牛奶", range(4)))
    #expect(run(.code, "# 标题", range(1)) == Edit("# ``标题", range(3)))
    // 有选区：两头加上、选中的还是那几个字；再按一次去掉（选中的是里面的字、或连标记一起选的都认）
    #expect(run(.bold, "看周报了", range(1, 2)) == Edit("看**周报**了", range(3, 2)))
    #expect(run(.bold, "看**周报**了", range(3, 2)) == Edit("看周报了", range(1, 2)))
    #expect(run(.bold, "看**周报**了", range(1, 6)) == Edit("看周报了", range(1, 2)))
    #expect(run(.strike, "去掉 this", range(3, 4)) == Edit("去掉 ~~this~~", range(5, 4)))
    #expect(run(.code, "a `b` c", range(3, 1)) == Edit("a b c", range(2, 1)))
    // 斜体只认单数个：粗体里再按 ⌘I 是又粗又斜，又粗又斜里按 ⌘I 去掉斜体
    #expect(run(.italic, "**粗**", range(2, 1)) == Edit("***粗***", range(3, 1)))
    #expect(run(.italic, "***粗***", range(3, 1)) == Edit("**粗**", range(2, 1)))
    #expect(run(.bold, "***粗***", range(3, 1)) == Edit("*粗*", range(1, 1)))
    // 两头的空白、行首的块标记不包进去
    #expect(run(.bold, "  周报 ", range(0, 5)) == Edit("  **周报** ", range(4, 2)))
    #expect(run(.bold, "- 牛奶", range(0, 4)) == Edit("- **牛奶**", range(4, 2)))
    #expect(run(.italic, "☐ 任务", range(0, 4)) == Edit("☐ *任务*", range(3, 2)))
    #expect(run(.bold, "> 引用", range(0, 4)) == Edit("> **引用**", range(4, 2)))
    // 每一行各自包；空行、只有空白的跳过；都包着才都去掉，有一行没包就都包上（包着的那行不动）
    #expect(
      run(.bold, "一行\n\n  \n二行", range(0, 9)) == Edit("**一行**\n\n  \n**二行**", range(2, 13)))
    #expect(run(.bold, "**一行**\n**二行**", range(0, 13)) == Edit("一行\n二行", range(0, 5)))
    #expect(run(.bold, "**一行**\n二行", range(0, 9)) == Edit("**一行**\n**二行**", range(2, 9)))
    // 选了几行包上之后再按：选区盖着「第一行的字……最后一行的字」，中间的标记一半在里面也连起来数
    #expect(run(.bold, "**一行**\n**二行**", range(2, 9)) == Edit("一行\n二行", range(0, 5)))
    // 都是空白、选中的只有块标记：没有可包的
    #expect(run(.bold, "   ", range(0, 3)) == nil && run(.bold, "- ", range(0, 2)) == nil)
    // 「已经包着」问扫描器、不数字符（评审的反例）：数字中间的星号是乘号，不当成斜体删掉——包上（两个乘号旁边的
    // 星号扫描器也不认，只是不丢字）
    #expect(run(.italic, "箱子 60*40*30", range(6, 2)) == Edit("箱子 60**40**30", range(7, 2)))
    #expect(run(.italic, "2*3*4", range(2, 1)) == Edit("2**3**4", range(3, 1)))
    // 光标夹在挨着的两段中间：中间那两对标记各归各的，不当成一对空的删掉（两段不并成一段），照常插一对
    #expect(run(.bold, "**a****b**", range(5)) == Edit("**a********b**", range(7)))
    #expect(run(.code, "`x``y`", range(3)) == Edit("`x````y`", range(4)))
    #expect(run(.italic, "*a**b*", range(3)) == Edit("*a****b*", range(4)))
  }

  /// 粘贴成链接（纯函数）：一个能打开的网址（两头的空白、换行去掉）、选中的是一行里的一段字 → 「[字](网址)」，光标在
  /// 后面；几个网址、一段话、打不开的地址（file:）、选中的在行内代码里、拼出来认不出是链接（括号不成对）的：nil
  @Test func pastedURLsBecomeLinks() {
    func paste(_ pasted: String, _ line: String, _ selection: NSRange) -> Edit? {
      guard let change = NoteMarkdown.linkPaste(pasted, in: line, selection: selection) else {
        return nil
      }
      let result = NSMutableString(string: line)
      for replacement in change.replacements.reversed() {
        result.replaceCharacters(in: replacement.range, with: replacement.text)
      }
      return Edit(result as String, change.selection)
    }
    #expect(
      paste("https://example.com/a", "看这里吧", range(1, 2))
        == Edit("看[这里](https://example.com/a)吧", range(28)))
    #expect(paste(" https://a.b \n", "点我", range(0, 2)) == Edit("[点我](https://a.b)", range(17)))
    #expect(paste("mailto:x@y.z", "写信", range(0, 2)) == Edit("[写信](mailto:x@y.z)", range(18)))
    #expect(paste("https://a.b/(x)", "维基", range(0, 2)) == Edit("[维基](https://a.b/(x))", range(21)))
    // 任务行、列表行的内容里照样
    #expect(paste("https://a.b", "☐ 看文档", range(3, 2)) == Edit("☐ 看[文档](https://a.b)", range(20)))
    // 不是一个能打开的网址
    #expect(paste("https://a.b https://c.d", "两个", range(0, 2)) == nil)
    #expect(paste("看看 https://a.b", "一段", range(0, 2)) == nil)
    #expect(paste("file:///etc/hosts", "本地", range(0, 2)) == nil)
    #expect(paste("example.com", "没协议", range(0, 3)) == nil && paste("", "空", range(0, 1)) == nil)
    // 没有选区、选中的只有空白、在行内代码里、括号不成对、选中的字带方括号拼不成链接
    #expect(paste("https://a.b", "字", range(1)) == nil)
    #expect(paste("https://a.b", "a  b", range(1, 2)) == nil)
    #expect(paste("https://a.b", "看 `代码` 后", range(3, 2)) == nil)
    #expect(paste("https://a.b/)", "括号", range(0, 2)) == nil)
    #expect(paste("https://a.b", "[半个", range(0, 3)) == nil)
  }

  /// 标题和摘要：围栏行不当标题、不进摘要；块里的字照原文（不去标记）；没关上的围栏行就是普通的一行
  @Test func titlesSkipFences() {
    func note(_ body: String) -> Note {
      Note(id: "x", body: body, createdAt: .now, modifiedAt: .now)
    }
    #expect(note("```swift\nlet a = **1**\n```\n后面").displayTitle == "let a = **1**")
    #expect(note("```swift\nlet a = 1\n```\n后面").preview == "后面")
    #expect(note("标题\n```\n# 注释\n```\n**正文**").preview == "# 注释 正文")
    #expect(note("~~~\n~~~\n真正的标题").displayTitle == "真正的标题")
    #expect(note("```js\n没关上").displayTitle == "```js")
  }
}
