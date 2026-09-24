// 剪贴板条目模型（clips 表的一行；富文本数据除外，它只在粘贴时按需读）。

import Foundation

struct ClipItem: Identifiable, Hashable, Sendable {
  enum Kind: String, Sendable {
    case text, image, file
  }

  var id = UUID()
  var kind: Kind
  /// kind == .text 的正文
  var text: String?
  /// kind == .file 的文件路径
  var filePaths: [String]?
  /// kind == .image：图片存在 ImageStore 里，文件名就是 id
  var image: ImageInfo?
  /// 图片里识别出的文字：nil = 还没识别，"" = 识别过、没有文字
  var ocrText: String?
  /// 带格式文本的类型（rtf / html）；nil 表示纯文本
  var richType: RichType?
  var sourceName: String?
  var sourceBundleID: String?
  var copiedAt = Date.now
  var favorite = false
  var isSnippet = false
  var note: String?
  var groupID: UUID?

  struct ImageInfo: Hashable, Sendable {
    var width: Int
    var height: Int
    var byteCount: Int
    /// PNG 字节的 SHA256，去重用
    var sha256: String
  }

  enum RichType: String, Sendable {
    case rtf, html
  }

  /// 用户显式留下的条目（收藏 / 片段 / 已归组）：条数上限、保留天数、退出与锁屏清空都不动它们。
  /// 这条规则只在这里定义一次
  var isRetained: Bool { favorite || isSnippet || groupID != nil }

  /// 是否是同一份剪贴板内容：文本比正文，文件比路径列表，图片比 PNG 哈希
  func hasSameContent(as other: ClipItem) -> Bool {
    switch (kind, other.kind) {
    case (.text, .text): text == other.text
    case (.file, .file): filePaths == other.filePaths
    case (.image, .image): image?.sha256 == other.image?.sha256
    default: false
    }
  }
}

/// 用户自建的剪贴板分组
struct ClipGroup: Identifiable, Hashable, Sendable {
  let id: UUID
  var name: String
  let createdAt: Date
}
