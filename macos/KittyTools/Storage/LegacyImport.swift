// 从旧版（Tauri 版 Kitty Tools）导入，可重复执行、不产生重复。顺序：偏好 → 密钥 → 分组 → 剪贴板条目
// （只要收藏 / 片段 / 已归组的，连同图片）→ 全部翻译历史；数据部分在一个事务里，导入时不做条数 / 天数裁剪。
// 旧库是 WAL 模式：直接只读打开会因为建不了 -shm 报 SQLITE_CANTOPEN，所以连同 -wal / -shm 拷到临时目录，
// 读写打开副本（SQLite 自动回放 WAL）并 quick_check；原文件只拷不开。任何读取失败都中止报错，绝不用默认值覆盖。
// 不导入：热键（与共存的旧版会冲突）、主题类设置、窗口位置、普通剪贴板历史（只留 7 天，原生版已自己采到）。

import Foundation

enum LegacyImport {
  struct Plan {
    var preferences: [String: Any] = [:]
    /// 钥匙串账户名 "<服务 id>.<字段>" → 值
    var secrets: [String: String] = [:]
    /// 旧版的全部服务（按旧顺序）；nil 表示旧配置里没有服务信息
    var services: [TranslateService]?
    /// 旧版开了开机自启：只写偏好不生效，要注册登录项
    var launchAtLogin = false
  }

  /// 数据部分的导入结果；跳过的按原因计数
  struct DataReport {
    var added = 0
    var merged = 0
    var skipped: [String: Int] = [:]
    var historyAdded = 0
    var historyMerged = 0
    /// 原文或译文为空的旧翻译记录
    var historySkipped = 0
  }

  struct Failure: LocalizedError {
    let errorDescription: String?
  }

  static let directory = URL.applicationSupportDirectory.appending(path: "com.yy.kitty-tools")

  /// 「设置 › 通用」的导入按钮：设置与密钥 → 剪贴板与翻译历史，遇错即停。返回逐行结果（✓ / ✗ 开头）
  static func run(
    services: TranslateServiceStore, clipboard: ClipboardStore, history: HistoryStore,
    db: Database
  ) async -> String {
    var lines: [String] = []
    do {
      lines.append("✓ " + (try importSettings(into: services)))
      let copy = try copyDatabase(named: "kitty-settings.db")
      defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
      let old = try Database(path: copy.path)
      defer { old.close() }
      let report = try await importData(
        from: old, images: directory.appending(path: "clipboard_images"),
        clipboard: clipboard, history: history, db: db,
        serviceNames: serviceNames(services.services))
      let skipped = report.skipped.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
      lines.append(
        "✓ 剪贴板：新增 \(report.added)、合并 \(report.merged)、跳过 \(report.skipped.values.reduce(0, +))"
          + (skipped.isEmpty ? "" : "（\(skipped.joined(separator: "、"))）"))
      lines.append(
        "✓ 翻译历史：新增 \(report.historyAdded)、合并 \(report.historyMerged)"
          + (report.historySkipped > 0 ? "、跳过 \(report.historySkipped)（原文或译文为空）" : ""))
    } catch {
      lines.append("✗ " + ((error as? LocalizedError)?.errorDescription ?? "\(error)"))
    }
    return lines.joined(separator: "\n")
  }

  /// 读旧配置并写入偏好与钥匙串；返回一句结果说明
  static func importSettings(into store: TranslateServiceStore) throws -> String {
    let plan = try plan(from: readConfig())
    for (key, value) in plan.preferences {
      // NSNull 表示「回到默认」（如自动检测）：UserDefaults 存不了 NSNull，直接 set 会崩
      if value is NSNull {
        UserDefaults.standard.removeObject(forKey: key)
      } else {
        UserDefaults.standard.set(value, forKey: key)
      }
    }
    for (account, value) in plan.secrets { Keychain.set(value, for: account) }
    if let services = plan.services { store.services = services }
    // 从 DMG 里运行时不注册（见 LaunchAtLogin）；失败不影响其余导入，通用页的开关会显示实际状态
    if plan.launchAtLogin, LaunchAtLogin.isInstalled { try? LaunchAtLogin.set(true) }
    return
      "已导入 \(plan.preferences.count) 项设置、\(plan.secrets.count) 个密钥、\(plan.services?.count ?? 0) 个翻译服务"
  }

  /// 旧库副本 → 剪贴板保留条目、分组、图片与全部翻译历史。先把要写的全读出来，再在一个事务里写；
  /// 失败时回滚并删掉这次拷进来的图片。oldImages 是旧版的 clipboard_images 目录
  static func importData(
    from old: Database, images oldImages: URL, clipboard: ClipboardStore, history: HistoryStore,
    db: Database, serviceNames: [String: String]
  ) async throws -> DataReport {
    var report = DataReport()

    let groups = try old.query("SELECT id, name, created_at FROM clipboard_groups") { row in
      let name = (row.text(1) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(24)
      return (
        oldID: row.text(0) ?? "",
        group: ClipGroup(
          id: UUID(uuidString: row.text(0) ?? "") ?? UUID(),
          name: name.isEmpty ? "未命名分组" : String(name), createdAt: date(ms: row.int(2)))
      )
    }
    let groupIDs = Dictionary(groups.map { ($0.oldID, $0.group.id) }) { first, _ in first }

    let rows = try old.query(
      """
      SELECT h.id, h.type, h.content, h.file_paths, h.timestamp, h.source_app, h.source_app_path,
        h.favorited, h.note, h.kind, h.group_id, o.text, r.format, r.payload
      FROM clipboard_history h
        LEFT JOIN clipboard_image_ocr o ON o.id = h.id
        LEFT JOIN clipboard_rich_text r ON r.id = h.id
      WHERE h.favorited = 1 OR h.kind = 'snippet' OR h.group_id IS NOT NULL
      ORDER BY h.timestamp DESC
      """
    ) { row in
      // 旧版不认识的类型按文本处理
      let kind = ClipItem.Kind(rawValue: row.text(1) ?? "") ?? .text
      var item = ClipItem(
        id: UUID(uuidString: row.text(0) ?? "") ?? UUID(), kind: kind,
        copiedAt: date(ms: row.int(4)))
      item.sourceName = row.text(5).flatMap { $0.isEmpty ? nil : $0 }
      item.sourceBundleID = row.text(6).flatMap { Bundle(path: $0)?.bundleIdentifier }
      item.favorite = row.int(7) == 1
      item.note = row.text(8).flatMap { $0.isEmpty ? nil : $0 }
      item.isSnippet = row.text(9) == "snippet"
      // ponytail: 指向已删分组的条目按未分组导入（旧版删分组会清归属，正常不会出现）
      item.groupID = row.text(10).flatMap { groupIDs[$0] }
      var rich: Data?
      switch kind {
      case .text:
        item.text = row.text(2)
        item.richType = row.text(12).flatMap(ClipItem.RichType.init(rawValue:))
        rich = item.richType == nil ? nil : row.blob(13)
        if rich == nil { item.richType = nil }
      case .file:
        item.filePaths = row.text(3).flatMap {
          try? JSONDecoder().decode([String].self, from: Data($0.utf8))
        }
      case .image:
        item.ocrText = row.text(11)
      }
      return (oldID: row.text(0) ?? "", item: item, rich: rich)
    }

    let native = UserDefaults.standard.string(forKey: Prefs.translateNative).flatMap(Lang.init)
    let foreign = UserDefaults.standard.string(forKey: Prefs.translateForeign).flatMap(Lang.init)
    let translations = try old.query(
      """
      SELECT id, source_text, translated_text, source_lang, target_lang, provider, favorited, timestamp
      FROM translate_history ORDER BY timestamp DESC
      """
    ) { row -> HistoryStore.Entry? in
      let source = (row.text(1) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      let result = row.text(2) ?? ""
      guard !source.isEmpty, !result.isEmpty else { return nil }
      let provider = row.text(5) ?? ""
      return HistoryStore.Entry(
        id: UUID(uuidString: row.text(0) ?? "") ?? UUID(), source: String(source.prefix(10_000)),
        target: historyTarget(
          stored: row.text(4) ?? "", sourceLang: row.text(3) ?? "", result: result,
          native: native ?? .zhHans, foreign: foreign ?? .en),
        result: result, service: serviceNames[provider] ?? provider,
        createdAt: date(ms: row.int(7)), favorite: row.int(6) == 1)
    }
    let entries = translations.compactMap { $0 }
    report.historySkipped = translations.count - entries.count

    // 撤销窗口里还没真删的条目先删掉：否则下面按 id 判断「已导入过」会漏看，删除又会带走刚拷的图片
    clipboard.commitDeletion()
    // 图片：旧文件以 PNG 签名开头就原样存成新图片（本机全是 PNG，不写旧格式解析），哈希按新规则重算
    var saved: [UUID] = []
    var clips: [(item: ClipItem, rich: Data?)] = []
    for row in rows {
      var item = row.item
      switch item.kind {
      case .text:
        guard !(item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          report.skipped["内容为空", default: 0] += 1
          continue
        }
      case .file:
        guard !(item.filePaths ?? []).isEmpty else {
          report.skipped["文件路径无法读取", default: 0] += 1
          continue
        }
      case .image:
        // 上次导入过、文件也还在的：按 id 并入，不再拷文件（文件丢了就重拷一次）
        if let existing = clipboard.items.first(where: { $0.id == item.id }),
          FileManager.default.fileExists(atPath: clipboard.images.url(for: item.id).path)
        {
          item.image = existing.image
          break
        }
        guard let data = try? Data(contentsOf: oldImages.appending(path: "\(row.oldID).kchi"))
        else {
          report.skipped["图片文件缺失", default: 0] += 1
          continue
        }
        guard data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else {
          report.skipped["图片不是 PNG", default: 0] += 1
          continue
        }
        guard let info = await clipboard.images.save(data, isPNG: true, id: item.id) else {
          report.skipped["图片无法解码或过大", default: 0] += 1
          continue
        }
        saved.append(item.id)
        item.image = info
      }
      clips.append((item, row.rich))
    }

    // 上面的 await 期间用户可能删了条目、上限可能清掉了图片：到这里（之后不再 await）再对一次账。
    // commitDeletion 自己开事务，不能嵌在下面的事务里
    clipboard.commitDeletion()
    clips.removeAll { clip in
      guard clip.item.kind == .image,
        !FileManager.default.fileExists(atPath: clipboard.images.url(for: clip.item.id).path)
      else { return false }
      report.skipped["图片文件缺失", default: 0] += 1
      return true
    }
    do {
      try db.transaction {
        (report.added, report.merged) = try clipboard.importLegacy(
          clips, groups: groups.map(\.group))
        (report.historyAdded, report.historyMerged) = try history.importLegacy(entries)
      }
    } catch {
      for id in saved { clipboard.images.delete(id) }
      try? clipboard.reload()
      throw error
    }
    try clipboard.reload()
    // 并入了已有图片的，这次拷进来的文件用不上了
    let kept = Set(clipboard.items.map(\.id))
    for id in saved where !kept.contains(id) { clipboard.images.delete(id) }
    clipboard.recognizePendingImages()
    return report
  }

  /// 旧版记的是设置里的目标语言（常是 auto，双向互译时也不是实际方向），新版要记实际译成的语言：
  /// 以译文的检测结果为准（和记录值同属一种语言时取记录值，保住简繁）；检测不出退回记录值，再退回按原文推断
  static func historyTarget(
    stored: String, sourceLang: String, result: String, native: Lang, foreign: Lang
  ) -> Lang {
    let recorded = lang(stored)
    guard let detected = Lang.detect(result) else {
      return recorded
        ?? Lang.resolve(
          source: lang(sourceLang), target: nil, detected: nil, native: native, foreign: foreign
        ).to
    }
    if let recorded, recorded.isSameLanguage(as: detected) { return recorded }
    return detected
  }

  /// 旧服务 id → 新版显示名（旧版的 builtin 就是智谱）；翻译历史里记的是显示名
  static func serviceNames(_ services: [TranslateService]) -> [String: String] {
    var names = Dictionary(services.map { ($0.id, $0.name) }) { first, _ in first }
    names["builtin"] = names[TranslateService.Kind.zhipu.rawValue]
    return names
  }

  /// 旧库的时间是 1970 起的毫秒
  private static func date(ms: Int64?) -> Date {
    Date(timeIntervalSince1970: Double(ms ?? 0) / 1000)
  }

  /// 旧配置（camelCase JSON）→ 导入计划。纯函数，配单测
  static func plan(from config: [String: Any]) -> Plan {
    var plan = Plan()
    let copy = { (old: String, new: String) in
      if let value = config[old], !(value is NSNull) { plan.preferences[new] = value }
    }
    for (old, new) in [
      ("clipboardHideOnUnfocus", Prefs.clipboardHideOnUnfocus),
      ("clipboardHistoryMax", Prefs.clipboardHistoryMax),
      ("clipboardHistoryRetentionDays", Prefs.clipboardRetentionDays),
      ("clipboardImageCacheMaxMb", Prefs.clipboardImageBudgetMB),
      ("clipboardExcludedApps", Prefs.clipboardExcludedApps),
      ("clipboardBlockSensitive", Prefs.clipboardBlockSensitive),
      ("clipboardKeepRichText", Prefs.clipboardKeepRichText),
      ("clipboardImageOcr", Prefs.clipboardImageOCR),
      ("clipboardClearOnExit", Prefs.clipboardClearOnQuit),
      ("clipboardClearOnLock", Prefs.clipboardClearOnLock),
      ("clipboardShowPreview", Prefs.clipboardShowPreview),
      ("floatingPinned", Prefs.floatingPinned),
      ("autoCopy", Prefs.translateAutoCopy),
      ("translateDeleteNewline", Prefs.translateRemoveNewlines),
      ("translateHistoryEnabled", Prefs.translateHistoryEnabled),
      ("translateHistoryMax", Prefs.translateHistoryLimit),
      ("translateClipboardMonitor", Prefs.translateCopyToTranslate),
    ] {
      copy(old, new)
    }

    // 语言：旧版 auto → 新版「自动」/「智能」；双向互译的 A / B → 母语 / 常用外语
    if let source = config["sourceLang"] as? String {
      plan.preferences[Prefs.translateSource] = lang(source)?.rawValue ?? NSNull()
    }
    if let target = config["targetLang"] as? String {
      plan.preferences[Prefs.translateTarget] = lang(target)?.rawValue ?? NSNull()
    }
    if let native = (config["bidirectionalLangA"] as? String).flatMap(lang) {
      plan.preferences[Prefs.translateNative] = native.rawValue
    }
    if let foreign = (config["bidirectionalLangB"] as? String).flatMap(lang) {
      plan.preferences[Prefs.translateForeign] = foreign.rawValue
    }
    plan.launchAtLogin = config["launchOnStartup"] as? Bool ?? false

    // 密钥：账户名沿用旧字段名，后续补的服务（百度、有道等）直接按这个名字读
    for (provider, fields) in [
      ("zhipu", ["apiKey"]), ("baidu", ["appId", "secret"]), ("youdao", ["appKey", "appSecret"]),
      ("google", ["apiKey"]), ("deepl", ["authKey"]), ("microsoft", ["subscriptionKey"]),
      ("volcengine", ["accessKey", "secretKey"]), ("tencent", ["secretId", "secretKey"]),
    ] {
      let values = config[provider] as? [String: Any] ?? [:]
      for field in fields {
        if let value = values[field] as? String, !value.isEmpty {
          plan.secrets["\(provider).\(field)"] = value
        }
      }
    }

    // 服务：8 个内置服务 + AI 实例，按旧顺序（旧版的 builtin 就是智谱）
    guard let enabled = config["translateServiceEnabled"] as? [String: Any] else { return plan }
    var available: [String: TranslateService] = [:]
    for kind in TranslateService.Kind.allCases where kind != .ai {
      let oldID = kind == .zhipu ? "builtin" : kind.rawValue
      var service = TranslateService.builtin(kind)
      service.isEnabled = enabled[oldID] as? Bool ?? (kind == .zhipu)
      available[oldID] = service
    }
    if let model = (config["zhipu"] as? [String: Any])?["textModel"] as? String,
      TranslateService.zhipuModels.contains(model)
    {
      available["builtin"]?.model = model
    }
    if let deepl = config["deepl"] as? [String: Any] {
      available["deepl"]?.usesDeepLX = deepl["apiType"] as? String == "deeplx"
      available["deepl"]?.baseURL = deepl["deeplxUrl"] as? String
    }
    available["microsoft"]?.region = (config["microsoft"] as? [String: Any])?["region"] as? String
    for raw in config["aiServices"] as? [[String: Any]] ?? [] {
      guard let id = raw["id"] as? String, id.hasPrefix("ai:"), available[id] == nil else {
        continue
      }
      let name = (raw["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "AI 服务"
      let aiProtocol =
        TranslateService.AIProtocol(rawValue: raw["protocol"] as? String ?? "") ?? .openai
      available[id] = TranslateService(
        id: id, kind: .ai, name: name, isEnabled: raw["enabled"] as? Bool ?? true,
        model: raw["model"] as? String, baseURL: raw["apiBaseUrl"] as? String,
        aiProtocol: aiProtocol)
      if let key = raw["apiKey"] as? String, !key.isEmpty { plan.secrets["\(id).apiKey"] = key }
    }
    let order = config["translateServiceOrder"] as? [String] ?? []
    let ordered = order.compactMap { available[$0] }
    let rest = available.filter { !order.contains($0.key) }.sorted { $0.key < $1.key }.map(\.value)
    plan.services = TranslateServiceStore.withBuiltins(ordered + rest)
    return plan
  }

  /// 旧语言码 → 新语言；auto 等未知值为 nil
  static func lang(_ code: String) -> Lang? {
    switch code.lowercased() {
    case "zh-cn", "zh", "zh-hans": .zhHans
    case "zh-tw", "cht", "zh-hant": .zhHant
    default: Lang(rawValue: code.lowercased())
    }
  }

  private static func readConfig() throws -> [String: Any] {
    let copy = try copyDatabase(named: "app_config.sqlite3")
    defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
    let db = try Database(path: copy.path)
    defer { db.close() }
    let payload = try db.query("SELECT payload FROM app_config WHERE singleton = 1") { $0.text(0) }
    guard let json = payload.first ?? nil,
      let config = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
      config["translateServiceEnabled"] != nil
    else {
      throw Failure(errorDescription: "旧版配置格式不认识。请先用旧版 v0.1.13 启动一次再导入")
    }
    return config
  }

  /// 把旧库（含 -wal / -shm）拷到临时目录并校验；返回副本路径
  static func copyDatabase(named name: String) throws -> URL {
    let source = directory.appending(path: name)
    guard FileManager.default.fileExists(atPath: source.path) else {
      throw Failure(errorDescription: "没找到旧版数据（\(name)）")
    }
    let temp = FileManager.default.temporaryDirectory.appending(path: "legacy-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    for suffix in ["", "-wal", "-shm"] {
      let file = directory.appending(path: name + suffix)
      if FileManager.default.fileExists(atPath: file.path) {
        try FileManager.default.copyItem(at: file, to: temp.appending(path: name + suffix))
      }
    }
    let copy = temp.appending(path: name)
    // 旧版运行中拷到半截的副本：打开或校验时可能直接抛错（不是 NOTADB 就是 CORRUPT），一律按同一句提示
    do {
      let db = try Database(path: copy.path)
      defer { db.close() }
      guard try db.query("PRAGMA quick_check", row: { $0.text(0) }).first ?? nil == "ok" else {
        throw Failure(errorDescription: nil)
      }
    } catch {
      try? FileManager.default.removeItem(at: temp)
      throw Failure(errorDescription: "旧版数据正在写入或已损坏，请先退出旧版再导入")
    }
    return copy
  }
}
