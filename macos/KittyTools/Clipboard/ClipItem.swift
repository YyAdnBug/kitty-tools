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
  /// 备注：所有条目都能写，搜索能搜到；不影响保留（体检 A3）
  var note: String?
  /// 所在的收藏夹（命名收藏夹，体检 A1）。不变式：有 groupID 的条目一定 favorite = true
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

  /// 用户显式留下的条目（收藏 / 片段；收藏夹里的都是收藏）：保留天数、图片占用、退出与锁屏清空都不动它们。
  /// 这条规则只在这里定义一次（体检 A1：分组并进收藏，备注不算留下）
  var isRetained: Bool { favorite || isSnippet }
  /// 同一条规则在库里的写法（每日备份只留这些行，Backup.dropped）：改 isRetained 要连它一起改，BackupTests 核对两边挑出来的
  /// 是同一批。多带一个 group_id 是兜底：不变式保证归了收藏夹的一定是收藏，万一哪一行没跟上，备份宁可多留
  nonisolated static let retainedSQL = "favorite = 1 OR snippet = 1 OR group_id IS NOT NULL"

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

/// 命名收藏夹（库里仍叫 clip_groups）：收藏 = 默认收藏夹，这些是用户建的（体检 A1）
struct ClipGroup: Identifiable, Hashable, Sendable {
  /// 名字最多几个字（超出时输入框拦住并显示「24/24」，不悄悄截断）
  static let maxName = 24

  let id: UUID
  var name: String
  let createdAt: Date
}
