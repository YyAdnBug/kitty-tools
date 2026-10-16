// 便签正文里的图片令牌（Notes/NoteImages.swift，第 7 批）单测：拼 / 认 / 写坏的不认（当普通文字，绝不碰文件系统）/
// 宽度越界当没写 / 一行里好几张 / 摘要里换「[图片]」/ 只有图片的行 / 找引用的编号 / 插图的落点；
// 还有随机生成的正文往返（生成 → 认出来 → 拼回去逐字一样）。

import Foundation
import Testing

@testable import KittyTools

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

  // MARK: 插图插在哪

  @Test func insertionOnItsOwnLine() {
    let text = "第一行\n第二行\n第三行" as NSString
    // 行首：前面不用换行
    var plan = NoteImages.insertion(in: text, replacing: NSRange(location: 4, length: 0), count: 1)
    #expect(plan == NoteImages.Insertion(lead: false, trail: true, caret: 1))
    // 行中：前后都要换行
    plan = NoteImages.insertion(in: text, replacing: NSRange(location: 6, length: 0), count: 1)
    #expect(plan == NoteImages.Insertion(lead: true, trail: true, caret: 2))
    // 行尾（换行之前）：前面要换行、后面不用
    plan = NoteImages.insertion(in: text, replacing: NSRange(location: 7, length: 0), count: 1)
    #expect(plan == NoteImages.Insertion(lead: true, trail: false, caret: 2))
    // 连插三张：图之间两个换行
    plan = NoteImages.insertion(in: text, replacing: NSRange(location: 7, length: 0), count: 3)
    // 1 个前导换行 + 3 个附件字符 + 2 个图之间的换行
    #expect(plan == NoteImages.Insertion(lead: true, trail: false, caret: 6))
  }

  @Test func insertionReplacesSelectionAndHandlesEmptyText() {
    let text = "abc" as NSString
    // 有选区：整段换掉（选到行尾）
    let plan = NoteImages.insertion(in: text, replacing: NSRange(location: 0, length: 3), count: 1)
    #expect(plan == NoteImages.Insertion(lead: false, trail: false, caret: 1))
    // 空的正文
    let empty = "" as NSString
    #expect(
      NoteImages.insertion(in: empty, replacing: NSRange(location: 0, length: 0), count: 1)
        == NoteImages.Insertion(lead: false, trail: false, caret: 1))
    // 只有空白的一行：不改出多余的空行
    let spaces = "   " as NSString
    #expect(
      NoteImages.insertion(in: spaces, replacing: NSRange(location: 2, length: 0), count: 1)
        == NoteImages.Insertion(lead: false, trail: false, caret: 1))
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
    // 摘要：图片写成「[图片]」，第一行是图片时按「跳过标题那一行」处理
    #expect(note("\(image)\n买菜\n牛奶").preview == "买菜 牛奶")
    // 摘要是「标题那一行之后的」（原来就有的规矩：标题取自第一行时不重复它）
    #expect(note("买菜\n\(image)后面").preview == "[图片]后面")
    #expect(note("买菜\n\(image)").preview == "[图片]")
    // 写坏的令牌当普通文字（原样去标记）
    #expect(note("![image](写坏的)").displayTitle == "![image](写坏的)")
    // 自己起了标题就用自己起的
    #expect(note(image, title: "我起的").displayTitle == "我起的")
  }

  // MARK: 随机往返

  @Test func randomTextRoundTrips() {
    var generator = SystemRandomNumberGenerator()
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
