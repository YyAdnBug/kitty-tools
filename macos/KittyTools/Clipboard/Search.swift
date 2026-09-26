// 剪贴板搜索（纯函数，配单测）：空白分词，每个词都要命中（AND）；不区分大小写、全半角、变音符号。
// 排序：各词命中字段的权重之和（备注 3，正文 / 图片文字 / 文件路径 2，来源 App 1），同分按复制时间新→旧。
// 命中摘录（excerpt）：行标题和透镜正文从第一个命中处截取，调用方只对屏上可见的行算。
// 性能：每条先折叠成 UTF-8 字节（Key，由调用方缓存），之后每次搜索只做 memmem 字节查找。
// 直接用 range(of:options:) 做不区分大小写 / 全半角的比较，5000 条要 1 秒（M2 实测）。

import Foundation

nonisolated enum Search {
  struct Key: Sendable {
    /// 按权重从高到低：备注、正文 + 图片文字 + 文件路径、来源 App
    let fields: [(bytes: [UInt8], weight: Int)]
  }

  /// ponytail: 正文只索引前 2 万字，超长文本后面的内容搜不到；真有需要再改成分段索引
  static let maxIndexedCharacters = 20_000

  /// 搜索和预览高亮共用的比较口径
  static let options: String.CompareOptions = [
    .caseInsensitive, .diacriticInsensitive, .widthInsensitive,
  ]

  static func fold(_ text: String) -> [UInt8] {
    Array(text.folding(options: options, locale: nil).utf8)
  }

  static func key(for item: ClipItem) -> Key {
    let body =
      [item.text.map { String($0.prefix(maxIndexedCharacters)) }, item.ocrText]
      + (item.filePaths ?? []).map(Optional.some)
    return Key(fields: [
      (fold(item.note ?? ""), 3),
      (fold(body.compactMap { $0 }.joined(separator: "\n")), 2),
      (fold(item.sourceName ?? ""), 1),
    ])
  }

  /// key 传缓存查找函数；不传则现算（单测用）
  static func rank(
    _ items: [ClipItem], query: String, key: (ClipItem) -> Key = Search.key(for:)
  ) -> [ClipItem] {
    let tokens = query.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }
    guard !tokens.isEmpty else { return items }
    return items.compactMap { item -> (ClipItem, Int)? in
      let fields = key(item).fields
      var total = 0
      for token in tokens {
        guard let best = fields.first(where: { contains($0.bytes, token) }) else { return nil }
        total += best.weight
      }
      return (item, total)
    }
    .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.copiedAt > $1.0.copiedAt }
    .map(\.0)
  }

  static func tokens(_ query: String) -> [String] {
    query.split(whereSeparator: \.isWhitespace).map(String.init)
  }

  /// 各词第一次命中里最靠前的那个（比较口径同搜索）
  static func firstHit(in text: String, query: String) -> Range<String.Index>? {
    tokens(query).compactMap { text.range(of: $0, options: options) }
      .min { $0.lowerBound < $1.lowerBound }
  }

  /// 命中摘录：命中前留 before 个字、命中后留 after 个字，截掉的那头补「…」。
  /// 没有搜索词、没有命中，或命中就在开头 before 个字以内（照常从头显示就能看到）时返回 nil
  static func excerpt(of text: String, query: String, before: Int = 40, after: Int = 40)
    -> String?
  {
    guard let hit = firstHit(in: text, query: query),
      let start = text.index(hit.lowerBound, offsetBy: -before, limitedBy: text.startIndex),
      start > text.startIndex
    else { return nil }
    let end =
      text.index(hit.upperBound, offsetBy: after, limitedBy: text.endIndex) ?? text.endIndex
    return "…" + text[start..<end] + (end < text.endIndex ? "…" : "")
  }

  /// UTF-8 自同步：完整字符的字节序列只会在字符边界上匹配，字节查找等价于字符查找
  static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
    guard !needle.isEmpty, haystack.count >= needle.count else { return false }
    return haystack.withUnsafeBytes { hay in
      needle.withUnsafeBytes { memmem(hay.baseAddress, hay.count, $0.baseAddress, $0.count) != nil }
    }
  }
}
