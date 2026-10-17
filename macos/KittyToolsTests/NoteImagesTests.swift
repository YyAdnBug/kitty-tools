// 便签正文里的图片令牌（Notes/NoteImages.swift，第 7 批）单测：拼 / 认 / 写坏的不认（当普通文字，绝不碰文件系统）/
// 宽度越界当没写 / 一行里好几张 / 摘要里换「[图片]」/ 只有图片的行 / 找引用的编号 / 插图的落点；
// 还有随机生成的正文往返（生成 → 认出来 → 拼回去逐字一样）。

import Foundation
import Testing

@testable import KittyTools

/// 固定种子的伪随机数（同 NoteEditorFuzzTests 的 LCG；失败了能复现，F25）
private struct SeededRandom: RandomNumberGenerator {
  var state: UInt64
  init(seed: Int) { state = UInt64(bitPattern: Int64(seed)) | 1 }
  mutating func next() -> UInt64 {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return state
  }
}

struct NoteImagesTests {
  private let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
  private let other = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

  private func token(_ id: UUID, _ ext: String = "png", width: Int? = nil) -> String {
    NoteImages.token(NoteImages.Image(id: id, ext: ext, width: width))
  }

  // MARK: 拼和认

  @Test func tokenRoundTrips() {
    let plain = token(id)
    #expect(plain == "![image](kitty-note-image://11111111-2222-3333-4444-555555555555.png)")
    let sized = token(id, "jpg", width: 240)
    #expect(sized == "![image|240](kitty-note-image://11111111-2222-3333-4444-555555555555.jpg)")
    for text in [plain, sized] {
      let found = NoteImages.matches(in: text as NSString)
      #expect(found.count == 1)
      #expect(found.first.map { NoteImages.token($0.image) } == text)
    }
    #expect(NoteImages.matches(in: plain as NSString).first?.image.id == id)
    #expect(NoteImages.matches(in: sized as NSString).first?.image.width == 240)
    #expect(NoteImages.matches(in: sized as NSString).first?.image.ext == "jpg")
  }

  @Test func widthOutOfRangeCountsAsNoWidth() {
    // 写坏了（< 40 或 > 4000）的宽度按没写处理，但令牌本身照认
    for width in [0, 1, 39, 4001, 999999, 123_456_789] {
      let text = "![image|\(width)](kitty-note-image://\(id.uuidString).png)"
      let found = NoteImages.matches(in: text as NSString)
      #expect(found.count == 1, "宽度 \(width) 应该还认得出是令牌")
      #expect(found.first?.image.width == nil, "宽度 \(width) 应该当没写")
    }
    #expect(NoteImages.width(40) == 40)
    #expect(NoteImages.width(4000) == 4000)
    #expect(NoteImages.width(39) == nil)
    #expect(NoteImages.width(nil) == nil)
  }

  @Test func malformedTokensArePlainText() {
    let bad = [
      "![image](kitty-note-image://11111111-2222-3333-4444-555555555555)",  // 没有扩展名
      "![image](kitty-note-image://11111111-2222-3333-4444-55555555555.png)",  // UUID 短一位
      "![image](kitty-note-image://11111111-2222-3333-4444-55555555555g.png)",  // UUID 里有 g
      "![image](kitty-note-image://11111111-2222-3333-4444-555555555555.PNG)",  // 大写的扩展名
      "![image](kitty-note-image://11111111222233334444555555555555.png)",  // UUID 没有短横线
      "![image](kitty-note-image://11111111-2222-3333-4444-555555555555.png",  // 少了右括号
      "[image](kitty-note-image://11111111-2222-3333-4444-555555555555.png)",  // 少了感叹号
      "![image](kitty-note-image:/11111111-2222-3333-4444-555555555555.png)",  // 地址前缀不对
      "![image|](kitty-note-image://11111111-2222-3333-4444-555555555555.png)",  // 空宽度
      "![image](kitty-note-image://11111111-2222-3333-4444-555555555555.abcdefghijk)",
      // 扩展名太长
      "![image](kitty-note-image://11111111-2222-3333-4444-555555555555.p-ng)",  // 扩展名里有短横线
    ]
    for text in bad {
      // containsToken 只是「有没有 !\[image」的便宜预筛（认不认由 match 决定），所以只比 matches
      #expect(NoteImages.matches(in: text as NSString).isEmpty, Comment(rawValue: text))
      #expect(NoteImages.ids(in: text).isEmpty, Comment(rawValue: text))
      #expect(NoteImages.display(text) == text, Comment(rawValue: text))
    }
    // 令牌后面紧跟着别的字照认（令牌到右括号为止，后面的是普通文字）
    let followed = "![image](kitty-note-image://\(id.uuidString).png)x"
    let matches = NoteImages.matches(in: followed as NSString)
    #expect(matches.count == 1)
    #expect(NoteImages.display(followed) == "[图片]x")
    // 小写 UUID 也不认（存的一律大写）
    #expect(
      NoteImages.matches(
        in: "![image](kitty-note-image://11111111-2222-3333-4444-55555555555a.png)" as NSString
      ).isEmpty)
  }

  @Test func findsSeveralTokensInOneLine() {
    let text = "前面\(token(id))中间\(token(other, "gif", width: 80))后面"
    let found = NoteImages.matches(in: text as NSString)
    #expect(found.count == 2)
    #expect(found.map(\.image.id) == [id, other])
    #expect(NoteImages.ids(in: text) == [id, other])
    #expect(NoteImages.first(in: text)?.id == id)
    #expect(NoteImages.containsToken(text))
    #expect(!NoteImages.containsToken("没有图片的一段话"))
    #expect(NoteImages.ids(in: "没有图片").isEmpty)
    #expect(NoteImages.first(in: "没有图片") == nil)
  }

  @Test func imageCoveringAnIndex() {
    let text = "ab\(token(id))cd" as NSString
    #expect(NoteImages.image(in: text, covering: 0) == nil)
    #expect(NoteImages.image(in: text, covering: 2)?.id == id)  // 令牌的第一个字
    #expect(NoteImages.image(in: text, covering: 20)?.id == id)  // 令牌中间
    #expect(NoteImages.image(in: text, covering: text.length - 1) == nil)
  }

  @Test func displayReplacesTokens() {
    let text = "第一行\n\(token(id))\n前面\(token(other, "jpg", width: 120))后面"
    #expect(NoteImages.display(text) == "第一行\n[图片]\n前面[图片]后面")
    #expect(NoteImages.display("没有图片") == "没有图片")
    #expect(NoteImages.display(token(id)) == "[图片]")
  }

  @Test func imageOnlyLines() {
    #expect(NoteImages.isImageOnly(token(id)))
    #expect(NoteImages.isImageOnly("  \(token(id))  "))
    #expect(NoteImages.isImageOnly("\(token(id))\(token(other))"))
    #expect(!NoteImages.isImageOnly("文字\(token(id))"))
    #expect(!NoteImages.isImageOnly("\(token(id))文字"))
    #expect(!NoteImages.isImageOnly("普通的行"))
    #expect(!NoteImages.isImageOnly("![image](写坏的)"))
  }

  /// 墙卡片那段字：只有图片的行整行去掉（连换行）、行内的令牌换成「[图片]」——**在截取之前做**（F11）
  @Test func displayLinesDropsImageOnlyLines() {
    let body = "买菜\n\(token(id))\n前面\(token(other))后面\n\n末行"
    #expect(NoteImages.displayLines(body) == "买菜\n前面[图片]后面\n\n末行")
    // 整条只有图：出来是空的（不会在 1200 个字处把令牌截成两半）
    #expect(NoteImages.displayLines("\(token(id))\n\(token(other))") == "")
    #expect(NoteImages.displayLines("没有图片") == "没有图片")
    // 令牌紧贴行尾 / 行首
    #expect(NoteImages.displayLines("\(token(id))买菜") == "[图片]买菜")
    #expect(NoteImages.displayLines("买菜\(token(id))") == "买菜[图片]")
    // 去掉令牌（字数、搜索用）
    #expect(NoteImages.stripping("前面\(token(id))后面") == "前面后面")
    #expect(NoteImages.stripping("\(token(id))") == "")
    #expect(NoteImages.stripping("没有图片") == "没有图片")
  }

  /// 宽度写法被规范化的行为：`|0040` 认得出、拼回去是 `|40`；`|39` 越界当没写、拼回去没有那一段（F25）
  @Test func widthNotationIsNormalised() {
    let padded = "![image|0040](kitty-note-image://\(id.uuidString).png)"
    let found = NoteImages.matches(in: padded as NSString)
    #expect(found.count == 1 && found.first?.image.width == 40)
    #expect(found.first.map { NoteImages.token($0.image) } == token(id, width: 40))
    let tooSmall = "![image|39](kitty-note-image://\(id.uuidString).png)"
    #expect(NoteImages.matches(in: tooSmall as NSString).first?.image.width == nil)
    #expect(
      NoteImages.matches(in: tooSmall as NSString).first.map { NoteImages.token($0.image) }
        == token(id))
  }

  // MARK: 插图插在哪

  @Test func insertionOnItsOwnLine() {
    let text = "第一行\n第二行\n第三行" as NSString
    // 行首：前面不用换行；图后面**总要**有一个换行（光标落到下一行的行首，F16①）
    var plan = NoteImages.insertion(in: text, replacing: NSRange(location: 4, length: 0), count: 1)
    #expect(plan == NoteImages.Insertion(lead: false, trail: true, caret: 2))
    // 行中：前后都要换行
    plan = NoteImages.insertion(in: text, replacing: NSRange(location: 6, length: 0), count: 1)
    #expect(plan == NoteImages.Insertion(lead: true, trail: true, caret: 3))
    // 行尾（换行之前）：前面要换行、后面也补一个换行
    plan = NoteImages.insertion(in: text, replacing: NSRange(location: 7, length: 0), count: 1)
    #expect(plan == NoteImages.Insertion(lead: true, trail: true, caret: 3))
    // 连插三张：图之间两个换行、末尾一个
    plan = NoteImages.insertion(in: text, replacing: NSRange(location: 7, length: 0), count: 3)
    // 1 个前导换行 + 3 个附件字符 + 2 个图之间的换行 + 末尾 1 个换行
    #expect(plan == NoteImages.Insertion(lead: true, trail: true, caret: 7))
  }

  @Test func insertionReplacesSelectionAndHandlesEmptyText() {
    let text = "abc" as NSString
    // 有选区：整段换掉（选到行尾），图后面补一个换行（光标落到下一行）
    let plan = NoteImages.insertion(in: text, replacing: NSRange(location: 0, length: 3), count: 1)
    #expect(plan == NoteImages.Insertion(lead: false, trail: true, caret: 2))
    // 空的正文
    let empty = "" as NSString
    #expect(
      NoteImages.insertion(in: empty, replacing: NSRange(location: 0, length: 0), count: 1)
        == NoteImages.Insertion(lead: false, trail: true, caret: 2))
    // 只有空白的一行：不改出多余的空行（图后面照补一个换行）
    let spaces = "   " as NSString
    #expect(
      NoteImages.insertion(in: spaces, replacing: NSRange(location: 2, length: 0), count: 1)
        == NoteImages.Insertion(lead: false, trail: true, caret: 2))
  }

  /// 光标夹在 `\r\n` 两个字中间时（getLineStart 给的 contentsEnd 在光标前面）：不许算出负的长度、
  /// 不许抛 NSRangeException（随机编辑测试种子 2001 跑出来的，F1）
  @Test func insertionBetweenCarriageReturnAndNewline() {
    let text = "a\r\nb" as NSString
    // 光标挪到 \n 之后（下一行的行首）：图独占一行、不拆开这对行尾，也不多出一个空行
    let plan = NoteImages.insertion(in: text, replacing: NSRange(location: 2, length: 0), count: 1)
    #expect(plan == NoteImages.Insertion(lead: false, trail: true, caret: 2))
    // 别的几个位置也不崩
    for at in 0...4 {
      _ = NoteImages.insertion(in: text, replacing: NSRange(location: at, length: 0), count: 2)
    }
    #expect(
      NoteImages.insertion(
        in: "\r\n" as NSString, replacing: NSRange(location: 1, length: 0), count: 1
      ).caret == 2)
  }

  /// 任务行里可以贴图：行首的方框 / 列表符号不算「前面有字」（R5、F15）
  @Test func insertionAfterATaskBoxGoesOnTheSameLine() {
    let text = "☐ 买菜" as NSString
    // 光标在方框后面（「☐」之后、「 」之前）：前面没有正文，图就在这一行、方框后面
    let afterBox = NoteImages.insertion(
      in: text, replacing: NSRange(location: 1, length: 0), count: 1)
    #expect(afterBox == NoteImages.Insertion(lead: false, trail: true, caret: 2))
    // 光标在「☐ 」之后、字之前（位置 2）：前面还是没有正文
    let afterSpace = NoteImages.insertion(
      in: text, replacing: NSRange(location: 2, length: 0), count: 1)
    #expect(afterSpace == NoteImages.Insertion(lead: false, trail: true, caret: 2))
    // 光标在「买」后面：前面有字，图另起一行
    let afterText = NoteImages.insertion(
      in: text, replacing: NSRange(location: 4, length: 0), count: 1)
    #expect(afterText == NoteImages.Insertion(lead: true, trail: true, caret: 3))
    // 无序列表的符号也一样
    #expect(
      NoteImages.insertion(
        in: "- 一" as NSString, replacing: NSRange(location: 2, length: 0), count: 1)
        == NoteImages.Insertion(lead: false, trail: true, caret: 2))
    #expect(!NoteImages.hasContent("☐ "))
    #expect(NoteImages.hasContent("☐ 买"))
    #expect(NoteImages.hasContent("买菜"))
    #expect(!NoteImages.hasContent("  "))
  }

  // MARK: 标题和摘要里的图片

  @Test func titlesAndPreviewsShowImages() {
    func note(_ body: String, title: String = "") -> Note {
      Note(
        id: "n", title: title, body: body, createdAt: Date(timeIntervalSince1970: 0),
        modifiedAt: Date(timeIntervalSince1970: 0))
    }
    let image = token(id)
    // 整条便签只有图片：标题是「[图片]」
    #expect(note(image).displayTitle == NoteImages.placeholder)
    #expect(note("\(image)\n\(token(other))").displayTitle == NoteImages.placeholder)
    // 只有图片的行跳过，标题用下一行有字的
    #expect(note("\(image)\n买菜").displayTitle == "买菜")
    #expect(note("第一行\n\(image)\n第三行").displayTitle == "第一行")
    // 行内的图片写成「[图片]」
    #expect(note("前面\(image)后面").displayTitle == "前面[图片]后面")
    #expect(note("标题行", title: "").displayTitle == "标题行")
    // 摘要：图片写成「[图片]」；**第一行是图时先跳过只有图片的行、再跳过标题那一行**（不重复标题，F10）
    #expect(note("\(image)\n买菜\n牛奶").preview == "[图片] 牛奶")
    #expect(note("买菜\n\(image)\n牛奶").preview == "[图片] 牛奶", "图片行照留，标题那一行不重复")
    // 摘要是「标题那一行之后的」（原来就有的规矩：标题取自第一行时不重复它）
    #expect(note("买菜\n\(image)后面").preview == "[图片]后面")
    #expect(note("买菜\n\(image)").preview == "[图片]")
    // 整条只有图片：标题已经是「[图片]」，摘要空着（不再重复一遍「[图片]」；复查时那叠的预览卡上看到的）
    #expect(note(image).preview == "")
    #expect(note("\(image)\n\(token(other))").preview == "")
    // 写坏的令牌当普通文字（原样去标记）
    #expect(note("![image](写坏的)").displayTitle == "![image](写坏的)")
    // F11：代码块**内容行**里的令牌也不许露原文（列表、标签、预览卡、墙卡片都走这里）
    #expect(note("```\n\(image)\n```").displayTitle == NoteImages.placeholder)
    #expect(note("```\n买菜\(image)\n```").displayTitle == "买菜[图片]")
    // F11：最近删除里只读的那份正文（令牌换成「[图片]」）
    #expect(note(image).readOnlyBody == NoteImages.placeholder)
    #expect(note("前面\(image)后面\n第二行").readOnlyBody == "前面[图片]后面\n第二行")
    // 自己起了标题就用自己起的
    #expect(note(image, title: "我起的").displayTitle == "我起的")
  }

  // MARK: 随机往返

  @Test func randomTextRoundTrips() {
    // 固定种子：失败了能照着同一个种子复现（F25）
    var generator = SeededRandom(seed: 20_261_016)
    let pieces = [
      "abc", "中文", "\n", " ", "![", "](", "kitty-note-image://", "**粗**", "- [ ] ",
      "2*3*4", "（《", "\u{1F600}",
    ]
    for step in 0..<3000 {
      var text = ""
      for _ in 0..<Int.random(in: 0...8, using: &generator) {
        if Bool.random(using: &generator) {
          text += token(
            UUID(), ["png", "jpg", "gif", "heic"].randomElement(using: &generator) ?? "png",
            width: Bool.random(using: &generator)
              ? Int.random(in: 40...4000, using: &generator) : nil)
        } else {
          text += pieces.randomElement(using: &generator) ?? "x"
        }
      }
      let found = NoteImages.matches(in: text as NSString)
      // 认出来的令牌拼回去，和原文一模一样（认出来的位置互不相交、按顺序）
      var rebuilt = ""
      var last = 0
      let string = text as NSString
      for match in found {
        #expect(match.range.location >= last, "第 \(step) 条：区间应该从前到后")
        rebuilt += string.substring(
          with: NSRange(location: last, length: match.range.location - last))
        rebuilt += NoteImages.token(match.image)
        last = NSMaxRange(match.range)
      }
      rebuilt += string.substring(from: last)
      #expect(rebuilt == text, "第 \(step) 条：往返不一样")
      // display 把每一段令牌都换成「[图片]」
      #expect(
        NoteImages.display(text).utf16.count == text.utf16.count
          - found.reduce(0) { $0 + ($1.range.length - 4) })
    }
  }
}
