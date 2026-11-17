// 长文分段翻译（第四轮体检 X2，2026-11-17）：大模型一次只能出 max_tokens 那么多（内置智谱 1024，`Zhipu.maxTokens`），
// 原文估出来的译文超过它的六成时，按段（空行、换行）切开、一段太长再按句、还长就硬切，依次翻、接着显示在同一张卡里。
// 流的约定照旧：每次给出到目前为止的整段译文（前面翻完的段 + 段间原来的空白 + 这一段到目前为止的）；某一段被截断（.truncated）
// 或出错就停在那里抛出来（截断的卡照常显示半截、标「只翻了前一部分」）。单词模式、传统接口（没有输出 token 上限）不切。
// ponytail: 译文 token 按「中日韩泰文一字一个、别的字三个一个」估，阿拉伯文、印地文这类一个字更费 token 的语言还可能被截断（卡片照常标出来）；
// 真要准就按各家的分词器算。段与段各翻各的，前后文不互相看到。

import Foundation

nonisolated enum LongText {
  /// 切开的一段：发给服务的字 + 它后面原文里的空白（拼译文时原样接回去）
  struct Piece: Equatable, Sendable {
    var text: String
    var separator: String
  }

  /// 一段最多估多少 token 的译文：输出上限的六成（留出译文比原文长、估得不准的余量）
  static func budget(outputTokens: Int) -> Double { Double(outputTokens) * 0.6 }

  /// 估这段字翻出来大约多少 token
  static func weight<S: StringProtocol>(_ text: S) -> Double {
    // 按三分之一个 token 数整数再除，免得一个个 1/3 加出 1.9999…
    let thirds = text.unicodeScalars.reduce(0) { sum, scalar in
      if scalar.properties.isWhitespace { return sum }
      return sum + (isDense(scalar) ? 3 : 1)
    }
    return Double(thirds) / 3
  }

  /// 一个字差不多就是一个 token 的文字：汉字、假名、谚文、泰文
  private static func isDense(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0x0E00...0x0E7F,
      0xF900...0xFAFF, 0x20000...0x2FA1F:
      true
    default: false
    }
  }

  /// 切成每段都不超过 budget 的几段；不超过的整段返回一段。各段 text + separator 依次拼起来就是原文
  static func split(_ text: String, budget: Double) -> [Piece] {
    guard weight(text) > budget else { return [Piece(text: text, separator: "")] }
    var pieces: [Piece] = []
    var current = ""
    for atom in atoms(text, budget: budget) {
      if !current.isEmpty, weight(current) + weight(atom) > budget {
        pieces.append(piece(current))
        current = ""
      }
      current += atom
    }
    if !current.isEmpty { pieces.append(piece(current)) }
    return pieces
  }

  /// 把末尾的空白拆成 separator
  private static func piece(_ chunk: String) -> Piece {
    let body = chunk.reversed().drop { $0.isWhitespace || $0.isNewline }
    let end = chunk.index(chunk.startIndex, offsetBy: body.count)
    return Piece(text: String(chunk[..<end]), separator: String(chunk[end...]))
  }

  /// 最小的单位：一行（带后面的换行）；一行超过 budget 的拆成句子，一句还超过的按字硬切。每个单位带着它后面的空白
  private static func atoms(_ text: String, budget: Double) -> [String] {
    var lines: [String] = []
    var line = ""
    for character in text {
      if character.isNewline {
        line.append(character)
      } else {
        if line.last?.isNewline == true {
          lines.append(line)
          line = ""
        }
        line.append(character)
      }
    }
    if !line.isEmpty { lines.append(line) }
    return lines.flatMap {
      weight($0) > budget ? sentences($0).flatMap { hardSplit($0, budget) } : [$0]
    }
  }

  /// 按句末标点切：中日文的 。！？ 直接切；. ! ? 后面跟空白才算句末（3.14、e.g.x 不切）。句末的引号、括号和后面的空白跟着这一句
  private static func sentences(_ line: String) -> [String] {
    var result: [String] = []
    var current = ""
    var ended = false
    let characters = Array(line)
    for (index, character) in characters.enumerated() {
      if ended, !(character.isWhitespace || "”’」』)）\"'".contains(character)) {
        result.append(current)
        current = ""
        ended = false
      }
      current.append(character)
      if "。！？".contains(character) {
        ended = true
      } else if ".!?".contains(character) {
        let next = index + 1 < characters.count ? characters[index + 1] : " "
        if next.isWhitespace || "”’\"')".contains(next) { ended = true }
      }
    }
    if !current.isEmpty { result.append(current) }
    return result
  }

  /// 一句还超过 budget：按字切成几块（尽量在空白处断）
  private static func hardSplit(_ sentence: String, _ budget: Double) -> [String] {
    guard weight(sentence) > budget else { return [sentence] }
    var result: [String] = []
    var current = ""
    var size = 0.0
    for character in sentence {
      let cost = weight(String(character))
      if size + cost > budget, !current.isEmpty {
        // 往回找最近的空白，在那里断（找不到就在这里断）
        if let space = current.lastIndex(where: \.isWhitespace), space > current.startIndex {
          let rest = String(current[current.index(after: space)...])
          result.append(String(current[...space]))
          current = rest
        } else {
          result.append(current)
          current = ""
        }
        size = weight(current)
      }
      current.append(character)
      size += cost
    }
    if !current.isEmpty { result.append(current) }
    return result
  }

  /// 依次翻各段、接着给出整段译文。translate 是发一段的那个服务调用
  static func stream(
    _ request: TranslateRequest, pieces: [Piece],
    translate: @escaping @Sendable (TranslateRequest) -> AsyncThrowingStream<String, Error>
  ) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        var done = ""
        var last: String?
        do {
          for piece in pieces {
            var latest = ""
            let part = TranslateRequest(text: piece.text, from: request.from, to: request.to)
            for try await text in translate(part) {
              latest = text
              // 后面几段开头的「思考中」（空串）只是没新字，不再让卡片回到「思考中」
              let whole = done + text
              if whole != last {
                continuation.yield(whole)
                last = whole
              }
            }
            try Task.checkCancellation()
            done += latest + piece.separator
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
