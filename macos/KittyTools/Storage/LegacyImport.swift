// 从旧版（Tauri 版 Kitty Tools）导入，可重复执行。M4：偏好与密钥；M6 再加收藏 / 片段 / 分组条目与翻译历史。
// 旧库是 WAL 模式：直接只读打开会因为建不了 -shm 报 SQLITE_CANTOPEN，所以连同 -wal / -shm 拷到临时目录，
// 读写打开副本（SQLite 自动回放 WAL）并 quick_check；原文件只拷不开。任何读取失败都中止报错，绝不用默认值覆盖。
// 不导入：热键（与共存的旧版会冲突）、主题类设置、窗口位置。

import Foundation

enum LegacyImport {
  struct Plan {
    var preferences: [String: Any] = [:]
    /// 钥匙串账户名 "<服务 id>.<字段>" → 值
    var secrets: [String: String] = [:]
    /// 旧版的全部服务（按旧顺序）；nil 表示旧配置里没有服务信息
    var services: [TranslateService]?
  }

  struct Failure: LocalizedError {
    let errorDescription: String?
  }

  static let directory = URL.applicationSupportDirectory.appending(path: "com.yy.kitty-tools")

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
    return
      "已导入 \(plan.preferences.count) 项设置、\(plan.secrets.count) 个密钥、\(plan.services?.count ?? 0) 个翻译服务"
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
    let check = try Database(path: copy.path).query("PRAGMA quick_check") { $0.text(0) }
    guard check.first ?? nil == "ok" else {
      try? FileManager.default.removeItem(at: temp)
      throw Failure(errorDescription: "旧版数据正在写入或已损坏，请先退出旧版再导入")
    }
    return copy
  }
}
