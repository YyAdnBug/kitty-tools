// LegacyImport 单测：旧配置字段 → 新偏好 / 钥匙串 / 服务列表；旧库（内存里按旧表结构造）→ 剪贴板保留条目、
// 分组、图片与翻译历史，导两次验证不重复。不碰真实偏好、钥匙串和数据目录。

import AppKit
import Foundation
import Testing

@testable import KittyTools

struct LegacyImportTests {
  private let config: [String: Any] = [
    "sourceLang": "auto", "targetLang": "zh-TW",
    "bidirectionalLangA": "zh-CN", "bidirectionalLangB": "ja",
    "autoCopy": true, "translateHistoryMax": 1000, "clipboardHistoryMax": 500,
    "launchOnStartup": true,
    "clipboardExcludedApps": ["1Password"], "clipboardShortcut": "CommandOrControl+Shift+V",
    "translateServiceEnabled": ["builtin": false, "baidu": true],
    "translateServiceOrder": ["baidu", "ai:b", "builtin", "ai:a"],
    "zhipu": ["apiKey": "", "textModel": "glm-4.6v-flash"],
    "baidu": ["appId": "id1", "secret": "s1"],
    "youdao": ["appKey": "", "appSecret": ""],
    "aiServices": [
      [
        "id": "ai:a", "name": "", "protocol": "weird", "apiBaseUrl": "http://x", "apiKey": "k",
        "model": "m", "enabled": true,
      ],
      [
        "id": "ai:b", "name": "B", "protocol": "anthropic", "apiBaseUrl": "", "apiKey": "",
        "model": "c", "enabled": false,
      ],
      ["id": "bad", "name": "X"],
    ],
  ]

  @Test func preferencesAndLanguages() {
    let plan = LegacyImport.plan(from: config)
    #expect(plan.preferences[Prefs.translateSource] is NSNull)  // auto → 回到默认
    #expect(plan.preferences[Prefs.translateTarget] as? String == Lang.zhHant.rawValue)
    #expect(plan.preferences[Prefs.translateFirst] as? String == Lang.zhHans.rawValue)
    #expect(plan.preferences[Prefs.translateSecond] as? String == Lang.ja.rawValue)
    #expect(plan.preferences[Prefs.translateAutoCopy] as? Bool == true)
    #expect(plan.preferences[Prefs.translateHistoryLimit] as? Int == 1000)
    #expect(plan.launchAtLogin)
    #expect(
      // 不导热键
      plan.preferences.keys.contains { $0.localizedCaseInsensitiveContains("shortcut") } == false)
  }

  @Test func secretsSkipEmptyValues() {
    let plan = LegacyImport.plan(from: config)
    #expect(plan.secrets == ["baidu.appId": "id1", "baidu.secret": "s1", "ai:a.apiKey": "k"])
  }

  @Test func servicesFollowOldOrderAndNormalize() throws {
    let services = try #require(LegacyImport.plan(from: config).services)
    // 旧顺序在前（旧版的 builtin 就是智谱），没排过序的内置服务按名字补在后面；非法 id 丢弃
    #expect(Array(services.map(\.id).prefix(4)) == ["baidu", "ai:b", "zhipu", "ai:a"])
    #expect(services.count == 10)
    #expect(services[0].isEnabled && !services[2].isEnabled)
    #expect(services[1].aiProtocol == .anthropic && !services[1].isEnabled)
    #expect(services[2].model == "glm-4.6v-flash")
    #expect(services[3].name == "AI 服务" && services[3].aiProtocol == .openai)  // 空名、未知协议兜底
  }

  @Test func languagePairIsNormalized() {
    // 旧版允许 A / B 选成简繁：规整成新版实际使用的一对
    let plan = LegacyImport.plan(from: [
      "bidirectionalLangA": "zh-CN", "bidirectionalLangB": "zh-TW",
    ])
    #expect(plan.preferences[Prefs.translateFirst] as? String == Lang.zhHans.rawValue)
    #expect(plan.preferences[Prefs.translateSecond] as? String == Lang.en.rawValue)
  }

  @Test func unknownConfigHasNoServices() {
    #expect(LegacyImport.plan(from: ["autoCopy": false]).services == nil)
  }

  @Test func historyTargetIsTheActualLanguage() {
    let target = { (stored: String, source: String, result: String) in
      LegacyImport.historyTarget(
        stored: stored, sourceLang: source, result: result, first: .zhHans, second: .en)
    }
    #expect(target("auto", "en", "敏捷的棕色狐狸跳过了那只懒狗") == .zhHans)
    // 双向互译时记录值不是实际方向：以译文为准
    #expect(target("zh-CN", "auto", "The quick brown fox jumps over the lazy dog") == .en)
    // 和记录值同属中文时取记录值，保住简繁
    #expect(target("zh-TW", "en", "這是一個簡單的測試句子，看看繁體") == .zhHant)
    // 译文检测不出：退回记录值，再退回按原文推断
    #expect(target("ja", "en", "12345") == .ja)
    #expect(target("auto", "en", "12345") == .zhHans)
    #expect(target("auto", "zh-CN", "12345") == .en)
    // 短译文按记录值做先验，不被第一 / 第二语言拉成英语
    #expect(target("fr", "zh-CN", "Paris") == .fr)
  }

  @Test func importsRetainedClipsAndHistoryWithoutDuplicates() async throws {
    let old = try Database(path: ":memory:")
    for sql in Self.oldSchema { try old.execute(sql) }
    let ids = (0..<9).map { _ in UUID().uuidString.lowercased() }
    let (work, legacyGroup) = (UUID().uuidString.lowercased(), UUID().uuidString.lowercased())
    try old.execute(
      "INSERT INTO clipboard_groups VALUES (?, '工作', 1), (?, ' 旧分组 ', 2)", [work, legacyGroup])
    let clip = {
      (id: String, type: String, content: String, fav: Int, kind: String, group: String?) in
      try old.execute(
        """
        INSERT INTO clipboard_history(id, type, content, file_paths, timestamp, source_app, favorited,
          note, kind, group_id) VALUES (?, ?, ?, ?, ?, 'Safari', ?, ?, ?, ?)
        """,
        [
          id, type, content, type == "file" ? #"["/tmp/a.txt"]"# : nil, 1_700_000_000_000, fav,
          fav == 1 ? "备注" : "", kind, group,
        ])
    }
    try clip(ids[0], "text", "收藏的文字", 1, "history", nil)
    try clip(ids[1], "text", "片段 {date}", 0, "snippet", nil)
    try clip(ids[2], "text", "两边都有", 0, "history", work)  // 并入新版已有条目
    try clip(ids[3], "image", "图片 2×2", 1, "history", nil)
    try clip(ids[4], "image", "图片", 1, "history", nil)  // 不是 PNG
    try clip(ids[5], "image", "图片", 1, "history", nil)  // 文件缺失
    try clip(ids[6], "file", "a.txt", 0, "history", legacyGroup)
    try clip(ids[7], "color", "#ffffff", 1, "history", nil)  // 不认识的类型按文本
    try clip(ids[8], "text", "  ", 1, "history", nil)  // 空内容
    try clip(UUID().uuidString, "text", "普通历史", 0, "history", nil)  // 不导入
    try old.execute(
      "INSERT INTO clipboard_rich_text VALUES (?, 'html', ?, 3)", [ids[0], Data("<b>".utf8)])
    try old.execute("INSERT INTO clipboard_image_ocr VALUES (?, '图中文字', 1)", [ids[3]])
    try old.execute(
      """
      INSERT INTO translate_history VALUES
        (?, 'Good morning everyone', '大家早上好，今天天气很好', 'en', 'auto', 'builtin', 'selection', 1, 3),
        (?, '世界和平是大家共同的愿望', 'World peace is a common wish of everyone', 'zh-CN', 'zh-CN', 'youdao', 'screenshot', 0, 2),
        (?, '空译文', '', 'auto', 'auto', 'baidu', 'selection', 0, 1)
      """, [UUID().uuidString, UUID().uuidString, UUID().uuidString])

    let oldImages = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let newImages = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    for directory in [oldImages, newImages] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let bitmap = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
      ))
    try #require(bitmap.representation(using: .png, properties: [:]))
      .write(to: oldImages.appending(path: "\(ids[3]).kchi"))
    try Data("GIF89a".utf8).write(to: oldImages.appending(path: "\(ids[4]).kchi"))

    let db = try Database(path: ":memory:")
    let clipboard = try ClipboardStore(db: db, images: ImageStore(directory: newImages))
    let history = try HistoryStore(db: db)
    var shared = ClipItem(kind: .text)
    shared.text = "两边都有"
    clipboard.record(shared)
    let workGroup = try #require(clipboard.createGroup(named: "工作"))
    history.add(
      source: "Good morning everyone", target: .zhHans, result: "早上好", service: "智谱", limit: 0)

    let run = {
      try await LegacyImport.importData(
        from: old, images: oldImages, clipboard: clipboard, history: history, db: db,
        serviceNames: ["builtin": "智谱", "youdao": "有道翻译"])
    }
    let first = try await run()
    #expect((first.added, first.merged) == (5, 1))
    #expect(first.skipped == ["图片不是 PNG": 1, "图片文件缺失": 1, "内容为空": 1])
    #expect((first.historyAdded, first.historyMerged, first.historySkipped) == (1, 1, 1))

    #expect(clipboard.items.count == 6)
    #expect(Set(clipboard.groups.map(\.name)) == ["工作", "旧分组"])  // 同名并入，名字去空白
    let legacy = try #require(clipboard.groups.first { $0.name == "旧分组" })
    let merged = try #require(clipboard.items.first { $0.id == shared.id })
    #expect(merged.groupID == workGroup.id && merged.isRetained)
    let favorite = try #require(clipboard.items.first { $0.text == "收藏的文字" })
    #expect(favorite.id.uuidString == ids[0].uppercased())  // 原 id，大写存储才能被 WHERE id = ? 命中
    #expect(favorite.favorite && favorite.note == "备注" && favorite.richType == .html)
    #expect(favorite.copiedAt == Date(timeIntervalSince1970: 1_700_000_000))
    #expect(clipboard.items.contains { $0.text == "片段 {date}" && $0.isSnippet && $0.note == nil })
    #expect(clipboard.items.contains { $0.kind == .text && $0.text == "#ffffff" })
    let file = try #require(clipboard.items.first { $0.kind == .file })
    #expect(file.filePaths == ["/tmp/a.txt"] && file.groupID == legacy.id)
    let image = try #require(clipboard.items.first { $0.kind == .image })
    #expect(image.image?.width == 2 && image.ocrText == "图中文字")
    #expect(FileManager.default.fileExists(atPath: clipboard.images.url(for: image.id).path))
    #expect(history.counts == (2, 1))  // 旧收藏并入已有记录
    #expect(history.search("世界").first?.target == .en)

    let second = try await run()
    #expect((second.added, second.merged) == (0, 6))
    #expect((second.historyAdded, second.historyMerged) == (0, 2))
    #expect(clipboard.items.count == 6 && clipboard.groups.count == 2 && history.counts.total == 2)
    let files = try FileManager.default.contentsOfDirectory(atPath: newImages.path)
    #expect(files == ["\(image.id.uuidString).png"])

    // 撤销窗口里刚删掉的图片再导入：要连文件一起回来，不能留下一条没有 PNG 的记录
    clipboard.deleteWithUndo([image.id])
    let third = try await run()
    #expect((third.added, third.merged) == (1, 5))
    #expect(clipboard.items.contains { $0.id == image.id })
    #expect(FileManager.default.fileExists(atPath: clipboard.images.url(for: image.id).path))
  }

  /// 用本机真实旧库演练（只拷贝旧库，导进内存库和临时目录，不碰真实数据）。按需开启：
  /// TEST_RUNNER_KITTY_LEGACY_DRY_RUN=1 xcodebuild … test -only-testing:KittyToolsTests/LegacyImportTests
  @Test(.enabled(if: ProcessInfo.processInfo.environment["KITTY_LEGACY_DRY_RUN"] != nil))
  func dryRunWithRealLegacyData() async throws {
    let copy = try LegacyImport.copyDatabase(named: "kitty-settings.db")
    let old = try Database(path: copy.path)
    defer {
      old.close()
      try? FileManager.default.removeItem(at: copy.deletingLastPathComponent())
    }
    let count = { (sql: String) in try old.query(sql) { Int($0.int(0) ?? 0) }[0] }
    let retained = try count(
      "SELECT count(*) FROM clipboard_history WHERE favorited = 1 OR kind = 'snippet' OR group_id IS NOT NULL"
    )
    let translations = try count("SELECT count(*) FROM translate_history")
    let images = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: images) }
    let db = try Database(path: ":memory:")
    let clipboard = try ClipboardStore(db: db, images: ImageStore(directory: images))
    let history = try HistoryStore(db: db)
    let run = {
      try await LegacyImport.importData(
        from: old, images: LegacyImport.directory.appending(path: "clipboard_images"),
        clipboard: clipboard, history: history, db: db,
        serviceNames: LegacyImport.serviceNames(TranslateServiceStore().services))
    }
    let first = try await run()
    print("旧库保留条目 \(retained)、翻译记录 \(translations)；第一次：\(first)")
    #expect(first.added + first.merged + first.skipped.values.reduce(0, +) == retained)
    #expect(first.historyAdded + first.historyMerged + first.historySkipped == translations)
    let second = try await run()
    print("第二次：\(second)")
    #expect(second.added == 0 && second.merged == first.added + first.merged)
    #expect(second.historyAdded == 0 && history.counts.total == first.historyAdded)
    #expect(clipboard.items.count == first.added)
  }

  /// 旧版 kitty-settings.db 里用到的表（sqlite3 .schema 读出来的，列顺序一致）
  private static let oldSchema = [
    """
    CREATE TABLE clipboard_history (id TEXT PRIMARY KEY NOT NULL, type TEXT NOT NULL,
      content TEXT NOT NULL DEFAULT '', content_hash TEXT, image_byte_size INTEGER,
      file_byte_sizes TEXT, file_paths TEXT, image_width INTEGER, image_height INTEGER,
      timestamp INTEGER NOT NULL, source_app TEXT, source_app_path TEXT,
      favorited INTEGER NOT NULL DEFAULT 0, note TEXT, kind TEXT NOT NULL DEFAULT 'history',
      plain_text_alt TEXT, group_id TEXT)
    """,
    "CREATE TABLE clipboard_groups (id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, created_at INTEGER NOT NULL)",
    "CREATE TABLE clipboard_image_ocr (id TEXT PRIMARY KEY NOT NULL, text TEXT NOT NULL, updated_at INTEGER NOT NULL)",
    """
    CREATE TABLE clipboard_rich_text (id TEXT PRIMARY KEY NOT NULL, format TEXT NOT NULL,
      payload BLOB NOT NULL, byte_size INTEGER NOT NULL)
    """,
    """
    CREATE TABLE translate_history (id TEXT PRIMARY KEY NOT NULL, source_text TEXT NOT NULL,
      translated_text TEXT NOT NULL DEFAULT '', source_lang TEXT NOT NULL DEFAULT 'auto',
      target_lang TEXT NOT NULL DEFAULT 'auto', provider TEXT NOT NULL DEFAULT '',
      mode TEXT NOT NULL DEFAULT 'selection', favorited INTEGER NOT NULL DEFAULT 0,
      timestamp INTEGER NOT NULL)
    """,
    "CREATE UNIQUE INDEX idx_translate_history_dedup ON translate_history(source_text, target_lang)",
  ]
}
