// 片段展开（2026-11-22）第 1 批：关键词的规矩（SnippetKeyword.check）、关键词落库往返和旧库补列、搜得到关键词、
// 同步记录（没关键词的那条编出来和 0.10.x 一字不差；有关键词的旧版本解不回来——那一类整个不落、说先更新，不会把关键词冲掉；
// 新版本落下来关键词跟着来、不合规的不带）、导出文件带关键词、导入只补本机没有的。内存库 + 临时目录，不碰真实数据。

import Foundation
import Testing

@testable import KittyTools

struct SnippetKeywordTests {
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

  private func makeStore(_ db: Database? = nil) throws -> ClipboardStore {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return try ClipboardStore(
      db: db ?? Database(path: ":memory:"), images: ImageStore(directory: directory))
  }

  private func snippet(_ text: String, in store: ClipboardStore, keyword: String? = nil) throws
    -> UUID
  {
    store.saveSnippet(text)
    let id = try #require(store.items.first { $0.text == text }).id
    if let keyword { store.update([id]) { $0.keyword = keyword } }
    return id
  }

  @Test func checksKeywords() {
    let others = [
      SnippetKeyword.Other(keyword: ";mail", title: "邮箱"),
      SnippetKeyword.Other(keyword: ";sig2", title: "签名"),
    ]
    // 空的 = 不设关键词，什么都不说
    #expect(SnippetKeyword.check("", others: others) == .init())
    #expect(SnippetKeyword.check("  ", others: others) == .init())
    #expect(SnippetKeyword.check(";", others: []).problem == .tooShort)
    #expect(
      SnippetKeyword.check(String(repeating: "a", count: SnippetKeyword.maxLength + 1), others: [])
        .problem == .tooLong)
    #expect(SnippetKeyword.duplicates([";a", ";b", ";a", ";a"]) == [";a"])
    #expect(SnippetKeyword.check("；邮", others: []).problem == .untypeable)
    #expect(SnippetKeyword.check("a b", others: []).problem == .untypeable)
    #expect(SnippetKeyword.check(" ;mail ", others: others).problem == .duplicate("邮箱"))
    // 大小写严格：不算重复
    #expect(SnippetKeyword.check(";MAIL", others: others) == .init())
    #expect(SnippetKeyword.check(";sig", others: others).warnings == [.hides("签名")])
    #expect(SnippetKeyword.check(";mail2", others: others).warnings == [.hiddenBy("邮箱")])
    #expect(SnippetKeyword.check("omyx", others: []).warnings == [.plainWord])
    #expect(SnippetKeyword.check(";omyx", others: []).warnings.isEmpty)
    #expect(SnippetKeyword.isValid(";mail"))
    #expect(!SnippetKeyword.isValid("x"))
    #expect(!SnippetKeyword.isValid(String(repeating: "a", count: SnippetKeyword.maxLength + 1)))
    #expect(SnippetKeyword.title(note: " 邮箱 ", text: "x") == "邮箱")
    #expect(SnippetKeyword.title(note: nil, text: "第一行\n第二行") == "第一行")
  }

  /// 0.10.x 的库没有 keyword 列：打开时补上（幂等）；存下的关键词重开还在；搜索搜得到它
  @Test func keywordPersistsAndOldDatabaseGetsColumn() throws {
    let db = try Database(path: ":memory:")
    try db.execute(
      """
      CREATE TABLE clips(
        id TEXT PRIMARY KEY, kind TEXT NOT NULL, text TEXT, file_paths TEXT,
        image_width INTEGER, image_height INTEGER, image_bytes INTEGER, image_sha256 TEXT,
        ocr_text TEXT, rich_type TEXT, rich_data BLOB, source_name TEXT, source_bundle_id TEXT,
        copied_at REAL NOT NULL, favorite INTEGER NOT NULL DEFAULT 0,
        snippet INTEGER NOT NULL DEFAULT 0, note TEXT, group_id TEXT)
      """)
    let id = UUID()
    try db.execute(
      "INSERT INTO clips(id, kind, text, copied_at, snippet) VALUES (?, 'text', '邮箱地址', 1, 1)",
      [id.uuidString])
    let store = try makeStore(db)
    #expect(store.items.first?.keyword == nil)
    store.update([id]) { $0.keyword = ";mail" }
    for _ in 0..<2 {
      let reopened = try makeStore(db)
      #expect(reopened.items.first { $0.id == id }?.keyword == ";mail")
      #expect(Search.filter(reopened.items, query: ";MAIL").map(\.id) == [id])
    }
  }

  /// 0.10.x 的同步记录长这样（没有 keyword）
  private struct OldSyncedClip: Codable {
    var text: String
    var favorite: Bool
    var snippet: Bool
    var note: String?
    var group: String?
  }

  @Test func syncRecordsStayCompatible() throws {
    let store = try makeStore()
    let plain = try snippet("签名", in: store)
    let keyed = try snippet("邮箱地址", in: store, keyword: ";mail")
    let values = store.syncValues()
    let plainValue = try #require(values[plain.uuidString])
    let keyedValue = try #require(values[keyed.uuidString])
    // 没关键词的不写这一项：和旧版本编出来一字不差，账本的哈希不变
    #expect(!plainValue.contains("keyword"))
    #expect(SyncRecords.decodeExact(OldSyncedClip.self, from: plainValue) != nil)
    // 有关键词的：旧版本解出来再编回去对不上 → 那一类整个不落（applySync 给 .newer），不会把关键词冲掉
    #expect(keyedValue.contains(";mail"))
    #expect(SyncRecords.decodeExact(OldSyncedClip.self, from: keyedValue) == nil)

    // 另一台新版本落下来：关键词跟着来
    let other = try makeStore()
    #expect(
      other.applySync([keyed.uuidString: keyedValue], ledger: .init(), library: "lib") == .saved)
    #expect(other.items.first { $0.id == keyed }?.keyword == ";mail")
    // 不合这一版规矩的关键词（更新的版本放宽了？）：同解不出来，整个不落，不收拾（收拾了会当成本机改的发出去、抹掉每一台的）
    let brokenValue = keyedValue.replacingOccurrences(of: ";mail", with: "邮 箱")
      .replacingOccurrences(of: "邮箱地址", with: "另一段")
    let third = try makeStore()
    #expect(
      third.applySync([UUID().uuidString: brokenValue], ledger: .init(), library: "lib") == .newer)
    #expect(third.items.isEmpty)
    // 不再是片段的收藏：留着的关键词不发出去（不起作用，发出去只会让旧版本那一类白停下）
    store.update([keyed]) {
      $0.isSnippet = false
      $0.favorite = true
    }
    #expect(store.syncValues()[keyed.uuidString]?.contains("keyword") == false)
  }

  /// 导出文件：只有片段带关键词；读文件时不合规的、不是片段的丢掉关键词；导入时本机这条没有关键词才用文件里的
  @Test func archiveCarriesKeywords() throws {
    let store = try makeStore()
    let keyed = try snippet("邮箱地址", in: store, keyword: ";mail")
    store.update([keyed]) { $0.favorite = true }
    let item = try #require(store.items.first { $0.id == keyed })
    #expect(SettingsArchive.Clip(item, groups: [])?.keyword == ";mail")
    // 移出片段后（还收藏着）导出的不带关键词
    store.update([keyed]) { $0.isSnippet = false }
    let unsnipped = try #require(store.items.first { $0.id == keyed })
    #expect(SettingsArchive.Clip(unsnipped, groups: [])?.keyword == nil)

    let suite = "kitty.test.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var archive = SettingsArchive.capture(
      from: defaults, domainName: suite, services: [], notes: [])
    archive.clips = [
      .init(text: "片段甲", favorite: false, snippet: true, copiedAt: .now, keyword: ";a1"),
      .init(text: "片段乙", favorite: false, snippet: true, copiedAt: .now, keyword: "坏 的"),
      .init(text: "收藏丙", favorite: true, snippet: false, copiedAt: .now, keyword: ";c1"),
    ]
    let clean = try #require(SettingsArchive.read(archive.encoded()).clips)
    #expect(clean.map(\.keyword) == [";a1", nil, nil])

    let target = try makeStore()
    let mine = try snippet("片段甲", in: target, keyword: ";mine")
    let none = try snippet("片段丁", in: target)
    target.adopt(
      clean + [.init(text: "片段丁", favorite: false, snippet: true, copiedAt: .now, keyword: ";d1")],
      groups: [])
    #expect(target.items.first { $0.id == mine }?.keyword == ";mine")
    #expect(target.items.first { $0.id == none }?.keyword == ";d1")
    // 文件里的关键词撞上本机已有片段的：不带；两条用同一个的只有一条拿到（读文件时 sanitize 已经只留第一条的）
    target.adopt(
      [
        .init(text: "片段戊", favorite: false, snippet: true, copiedAt: .now, keyword: ";mine"),
        .init(text: "片段己", favorite: false, snippet: true, copiedAt: .now, keyword: ";f1"),
        .init(text: "片段庚", favorite: false, snippet: true, copiedAt: .now, keyword: ";f1"),
      ], groups: [])
    let keyword = { (text: String) in target.items.first { $0.text == text }?.keyword }
    #expect(keyword("片段戊") == nil)
    #expect([keyword("片段己"), keyword("片段庚")].compactMap { $0 } == [";f1"])
  }

  /// 移出片段时关键词留着；再存成片段时它已经被别的片段用了：去掉，不让两条片段一个关键词
  @Test func resnippetDropsTakenKeyword() throws {
    let store = try makeStore()
    let first = try snippet("甲", in: store, keyword: ";a1")
    store.removeFromSnippets([first])
    #expect(store.items.first { $0.id == first }?.keyword == ";a1")
    _ = try snippet("乙", in: store, keyword: ";a1")
    store.markSnippet(first)
    #expect(store.items.first { $0.id == first }?.isSnippet == true)
    #expect(store.items.first { $0.id == first }?.keyword == nil)
    // 没撞上的照样回来
    let third = try snippet("丙", in: store, keyword: ";c1")
    store.removeFromSnippets([third])
    store.saveSnippet("丙")
    #expect(store.items.first { $0.id == third }?.keyword == ";c1")
  }
}
