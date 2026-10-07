// 设置的导出与导入（设置 › 通用，2026-10-07）：把各页的设置、全局快捷键、翻译服务、网页搜索与快捷链接，加上用户自己留下的
// 文字——片段、文字类的收藏和收藏夹、生词本——存成一个 JSON 文件，换电脑、重装或给别人一份时导回来。
// 对标 Raycast「Export Settings & Data」（一个文件、密钥加密、导入时按类别勾选；它也带片段）和
// Rectangle 的 JSON 配置；Alfred 同步时故意不带每台机器各自的东西，这里同理——不进文件的：窗口位置、上次截图区域、
// 「进行中」标记、授权状态、更新检查记录（这些状态都没有注册默认值）、截图的存储文件夹（这台电脑上的路径；别人给的文件
// 也不该能改截图存到哪）、登录时打开（系统的登录项）；数据库里的普通剪贴板历史和没收藏的翻译历史（它们有保留天数、
// 退出 / 锁屏清空这些隐私控制，不该靠导出留下来，和每日备份同样的取舍）、图片和文件类的收藏（图片太大、文件只是这台电脑上的
// 路径）、文字的格式、启动器收藏。
//
// 文件里有什么（format 1，六类都可以不带）：
// - preferences：Prefs.defaults 里的键 + 两个没有默认值的字符串键（kinds），只写用户改过的（持久域里有的）；
// - hotkeys：存过的全局快捷键（动作 → 组合，null = 清除了）；没存过的不写，跟默认；
// - translateServices / searchEngines：两张列表现在的样子；
// - clips + clipGroups：片段和文字类的收藏（正文、备注、所在收藏夹的名字、复制时间），收藏夹的名字按顺序；
// - vocabulary：生词本（收藏的翻译）；这两类是明文；
// - secrets：翻译服务的密钥，默认不带；要带就用密码加密（PBKDF2-HMAC-SHA256 → AES-256-GCM），文件里没有明文密钥。
//   密钥平时只在钥匙串里（mac-native §2），这是它唯一出钥匙串的地方：用户自己勾选、自己设密码。密钥和各服务往哪发请求
//   （routing）绑在一起校验：文件里某个服务的地址被人改过，密钥就解不开，不会带着密钥连到改过的地址。
//
// 导入：文件可能是别人给的、手改过的，read 把不认识、类型不对、超出范围的项都丢掉，后面的 apply 只见查过的。
// 「设置」「快捷键」整类换成文件里的样子（文件里没有的键删掉 = 回到默认）；两张列表按 id 更新和添加，本机独有的不删
// （删 AI 服务会连钥匙串里的密钥一起丢）；片段、收藏、生词本合并进库（ClipboardStore.adopt、HistoryStore.adoptFavorites：
// 同样的正文不重复加，只补标记），不删本机的。这里只管文件、偏好和加解密；让运行中的东西跟上在 AppDelegate.settingsImported。
// 和 C API 打交道的只有 key(password:salt:rounds:) 里的 CCKeyDerivationPBKDF（CryptoKit 没有按密码算密钥的函数）。

import CommonCrypto
import CryptoKit
import Foundation

struct SettingsArchive: Codable, Equatable {
  /// 能分开勾选的六类（顺序即导出、导入表单里的顺序）
  enum Section: String, CaseIterable, Identifiable {
    case preferences, hotkeys, services, engines, clips, vocabulary

    var id: String { rawValue }

    var title: String {
      switch self {
      case .preferences: "设置"
      case .hotkeys: "快捷键"
      case .services: "翻译服务"
      case .engines: "网页搜索与快捷链接"
      case .clips: "片段与收藏"
      case .vocabulary: "生词本"
      }
    }
  }

  /// 剪贴板里用户留下的一条文字：片段或收藏（图片、文件类的收藏和文字的格式不进文件）
  struct Clip: Codable, Equatable {
    var text: String
    var note: String?
    var favorite: Bool
    var snippet: Bool
    /// 所在收藏夹的名字
    var group: String?
    var copiedAt: Date
  }

  /// 生词本的一条（收藏的翻译）
  struct Word: Codable, Equatable {
    var source: String
    /// 目标语言（Lang.rawValue）
    var target: String
    var result: String
    var service: String
    var createdAt: Date
  }

  /// 导入做了什么（刘海岛据此说一句）
  struct Outcome: Equatable {
    /// 存进钥匙串的密钥数
    var secrets = 0
    /// 新建的片段 / 收藏、给已有条目补上标记的
    var clipsAdded = 0
    var clipsUpdated = 0
    /// 新增的生词
    var wordsAdded = 0
  }

  /// 偏好的值：布尔、整数、小数、字符串、字符串数组；别的（新版本多出来的类型）读成 unsupported，导入时丢掉
  nonisolated enum Value: Codable, Equatable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case strings([String])
    case unsupported

    init(from decoder: Decoder) throws {
      let container = try decoder.singleValueContainer()
      // JSON 里 true / 1 / 1.5 分得清（JSONDecoder 不把数字当布尔）；1.0 写出来是 1，按整数读回，小数的键收下时再转
      if let value = try? container.decode(Bool.self) {
        self = .bool(value)
      } else if let value = try? container.decode(Int.self) {
        self = .int(value)
      } else if let value = try? container.decode(Double.self) {
        self = .double(value)
      } else if let value = try? container.decode(String.self) {
        self = .string(value)
      } else if let value = try? container.decode([String].self) {
        self = .strings(value)
      } else {
        self = .unsupported
      }
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.singleValueContainer()
      switch self {
      case .bool(let value): try container.encode(value)
      case .int(let value): try container.encode(value)
      case .double(let value): try container.encode(value)
      case .string(let value): try container.encode(value)
      case .strings(let value): try container.encode(value)
      case .unsupported: try container.encodeNil()
      }
    }
  }

  /// 一个偏好键存的是哪种值（取自它的默认值）
  nonisolated enum Kind {
    case bool, int, double, string, strings

    init?(defaultValue: Any) {
      switch defaultValue {
      case is Bool: self = .bool
      case is Int: self = .int
      case is Double: self = .double
      case is String: self = .string
      case is [String]: self = .strings
      default: return nil
      }
    }

    /// 偏好里存的值 → 文件里的值（类型对不上的不导出）
    func value(of stored: Any?) -> Value? {
      switch self {
      case .bool: (stored as? Bool).map(Value.bool)
      case .int: (stored as? Int).map(Value.int)
      case .double: (stored as? Double).map(Value.double)
      case .string: (stored as? String).map(Value.string)
      case .strings: (stored as? [String]).map(Value.strings)
      }
    }

    /// 文件里的值 → 写进偏好的值；类型不对、超出范围的给 nil。整数只收 0…100 万（图片上限按 MB 乘成字节，
    /// 太大会溢出闪退）；字符串、数组有长度上限
    func plist(_ value: Value) -> Any? {
      switch (self, value) {
      case (.bool, .bool(let flag)): flag
      case (.int, .int(let number)) where (0...1_000_000).contains(number): number
      case (.double, .double(let number)) where number.isFinite: number
      case (.double, .int(let number)): Double(number)
      case (.string, .string(let text)) where text.count <= 4096: text
      case (.strings, .strings(let list))
      where list.count <= 1000 && list.allSatisfy({ $0.count <= 512 }):
        list
      default: nil
      }
    }
  }

  /// 加密的密钥：钥匙串账户名（"<服务 id>.<字段>"）→ 值 的 JSON，用密码算出的密钥封好
  struct Sealed: Codable, Equatable {
    static let algorithm = "pbkdf2-hmac-sha256"

    var kdf = Sealed.algorithm
    var rounds: Int
    var salt: Data
    /// AES-256-GCM 的 combined：随机数 12 字节 + 密文 + 校验 16 字节
    var sealed: Data
  }

  nonisolated enum Failure: Error, Equatable {
    case notArchive, newer, unreadable, wrongPassword

    var message: String {
      switch self {
      case .notArchive: "这不是 Kitty Tools 导出的设置文件"
      case .newer: "这个文件来自更新版本的 Kitty Tools，先更新再导入"
      case .unreadable: "文件读不出来：可能被改动过，或者来自更新版本的 Kitty Tools"
      case .wrongPassword: "密码不对（也可能是文件里的翻译服务被改动过）"
      }
    }
  }

  static let marker = "Kitty Tools"
  /// 1 = 第一次发布（0.3.2）时的样子，六类都在里面。发布之后再加类别、改字段含义就升它：旧版本读到更新的文件会说「先更新」
  static let currentFormat = 1
  /// 文件再大就不读、不写（只有设置时几 KB；带上片段、收藏、生词本也很少过 1 MB，单条文字最大 5 MB）。
  /// ponytail: 读文件、解析、并进库都在主线程上，这个上限就是卡多久的上限——独立实测 32 MB 全是很短的片段（36 万条，
  /// 最坏情况）解析 0.6 s，同样大小的几条长文字 0.03 s；正常的文件是毫秒级。真有人的文件大到卡，再挪到主线程外
  static let maxFileSize = 32 << 20
  /// 一个文件里最多几条片段 / 收藏、几个收藏夹、几条生词：一条条并进库，太多会卡住。导出时超了直接不让导出
  /// （exportProblem），所以自己导出的文件不会被这里截掉；别人给的、手改过的超了只收前面的
  static let maxClips = 5000
  static let maxGroups = 200
  static let maxWords = 20_000
  /// 密码至少几位
  static let minPasswordLength = 8
  /// 按密码算密钥的轮数（OWASP 2023 对 PBKDF2-HMAC-SHA256 的建议；本机 M3 实测约 0.09 s）。
  /// ponytail: 在主线程上算，只在带密钥导出 / 输密码导入时算一次；嫌卡再挪到 @concurrent（要改 mac-native §3 的白名单）
  static let rounds = 600_000
  /// 读文件时认的轮数范围：上限防别人给一个要算几分钟的文件
  static let acceptedRounds = 1...10_000_000

  /// 认文件用的标记
  var app = SettingsArchive.marker
  var format = SettingsArchive.currentFormat
  /// 导出时的 App 版本和时间（只给人看）
  var version: String
  var exportedAt: Date
  var preferences: [String: Value]?
  /// 动作（HotKeyAction.rawValue）→ 组合；null = 清除了
  var hotkeys: [String: HotKey?]?
  var translateServices: [TranslateService]?
  var searchEngines: [SearchEngine]?
  /// 片段和文字类的收藏（新→旧）
  var clips: [Clip]?
  /// 收藏夹的名字，按顺序（空的收藏夹也带上；和 clips 是同一类，一起带、一起不带）
  var clipGroups: [String]?
  /// 生词本（新→旧）
  var vocabulary: [Word]?
  var secrets: Sealed?

  /// 导出哪些偏好键、各是什么类型：注册了默认值的全部（类型取默认值的）+ 没有默认值的两个字符串键（翻译浮窗顶上选的
  /// 源 / 目标语言，没设 = 自动）。新加的设置只要进了 Prefs.defaults 就自动在这里
  static let kinds: [String: Kind] = {
    var kinds = Prefs.defaults.compactMapValues { Kind(defaultValue: $0) }
    for key in [Prefs.translateSource, Prefs.translateTarget] { kinds[key] = .string }
    return kinds
  }()

  /// 文件里有的类别（按 Section 的顺序）
  var sections: [Section] {
    Section.allCases.filter { section in
      switch section {
      case .preferences: preferences != nil
      case .hotkeys: hotkeys != nil
      case .services: translateServices != nil
      case .engines: searchEngines != nil
      case .clips: clips != nil
      case .vocabulary: vocabulary != nil
      }
    }
  }

  // MARK: 导出

  /// 现在的设置。偏好和快捷键只读用户自己存过的（持久域；registerDefaults 给的默认不在里面），所以以后默认值变了，
  /// 没改过的人导入后照样跟着新默认；services 是翻译服务列表现在的样子（TranslateServiceStore 手里那份）；
  /// clips / groups 是剪贴板的全部条目和收藏夹（这里只挑留下的文字），words 是生词本
  static func capture(
    from defaults: UserDefaults = .standard, domainName: String? = Bundle.main.bundleIdentifier,
    services: [TranslateService], clips: [ClipItem] = [], groups: [ClipGroup] = [],
    words: [HistoryStore.Entry] = [], version: String = AboutTab.version, now: Date = .now
  ) -> SettingsArchive {
    let domain = domainName.flatMap(defaults.persistentDomain(forName:)) ?? [:]
    var preferences: [String: Value] = [:]
    for (key, kind) in kinds {
      if let value = kind.value(of: domain[key]) { preferences[key] = value }
    }
    var hotkeys: [String: HotKey?] = [:]
    for action in HotKeyAction.allCases {
      guard let data = domain[action.prefsKey] as? Data else { continue }
      // 解不出来的当清除了（同 HotKeyAction.resolve）
      hotkeys.updateValue(
        try? JSONDecoder().decode(HotKey.self, from: data), forKey: action.rawValue)
    }
    return SettingsArchive(
      version: version, exportedAt: now, preferences: preferences, hotkeys: hotkeys,
      translateServices: services, searchEngines: engines(in: domain),
      clips: clips.compactMap { Clip($0, groups: groups) }, clipGroups: groups.map(\.name),
      vocabulary: words.filter(\.favorite).map(Word.init))
  }

  /// 只留勾选的类别
  func keeping(_ sections: Set<Section>) -> SettingsArchive {
    var kept = self
    if !sections.contains(.preferences) { kept.preferences = nil }
    if !sections.contains(.hotkeys) { kept.hotkeys = nil }
    if !sections.contains(.services) {
      kept.translateServices = nil
      kept.secrets = nil
    }
    if !sections.contains(.engines) { kept.searchEngines = nil }
    if !sections.contains(.clips) {
      kept.clips = nil
      kept.clipGroups = nil
    }
    if !sections.contains(.vocabulary) { kept.vocabulary = nil }
    return kept
  }

  /// 文件内容：缩进、键排好序，方便人看和比较
  func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(self)
  }

  /// 导出前查一遍：导入时不肯全收的就别写出去（不然导入时被悄悄截掉，没人知道少了）。encodedSize 是 encoded() 的字节数；
  /// 没问题是 nil，有问题给一句说给用户的话
  func exportProblem(encodedSize: Int) -> String? {
    if (clips?.count ?? 0) > Self.maxClips {
      return "片段和文字收藏超过 \(Self.maxClips) 条，先取消勾选「片段与收藏」"
    }
    if (clipGroups?.count ?? 0) > Self.maxGroups {
      return "收藏夹超过 \(Self.maxGroups) 个，先取消勾选「片段与收藏」"
    }
    if (vocabulary?.count ?? 0) > Self.maxWords {
      return "生词本超过 \(Self.maxWords) 条，先取消勾选「生词本」"
    }
    if encodedSize > Self.maxFileSize { return "内容太多，先取消勾选「片段与收藏」" }
    return nil
  }

  /// 存储面板里默认的文件名：「Kitty Tools 设置 2026-10-07.json」
  static func fileName(now: Date = .now) -> String {
    // 按本地时区取日期（ISO 8601 样式默认是格林尼治时间，半夜导出会差一天）
    let day = now.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
    return "Kitty Tools 设置 \(day).json"
  }

  // MARK: 密钥

  /// 这些服务存在钥匙串里的密钥：账户名 → 值。read 默认读钥匙串（单测传假的）
  static func secrets(
    of services: [TranslateService], read: (String) -> String? = Keychain.get
  ) -> [String: String] {
    var secrets: [String: String] = [:]
    for service in services {
      for field in service.secretFields {
        if let value = read(service.account(field.name)), !value.isEmpty {
          secrets[service.account(field.name)] = value
        }
      }
    }
    return secrets
  }

  /// 把密钥用密码封进文件（每次新的随机盐和随机数），连同 routing 一起校验。先设好 translateServices 再封
  mutating func seal(_ secrets: [String: String], password: String) throws {
    let salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
    let key = try Self.key(password: password, salt: salt, rounds: Self.rounds)
    let box = try AES.GCM.seal(JSONEncoder().encode(secrets), using: key, authenticating: routing)
    guard let sealed = box.combined else { throw Failure.unreadable }
    self.secrets = Sealed(rounds: Self.rounds, salt: salt, sealed: sealed)
  }

  /// 用密码解出密钥。校验过不了抛 wrongPassword：密码不对，或者密文、服务的地址被改过（两种分不出来）
  func unseal(password: String) throws -> [String: String] {
    guard let secrets, secrets.kdf == Sealed.algorithm,
      Self.acceptedRounds.contains(secrets.rounds),
      (8...64).contains(secrets.salt.count),
      let box = try? AES.GCM.SealedBox(combined: secrets.sealed)
    else { throw Failure.unreadable }
    let key = try Self.key(password: password, salt: secrets.salt, rounds: secrets.rounds)
    guard let plain = try? AES.GCM.open(box, using: key, authenticating: routing) else {
      throw Failure.wrongPassword
    }
    guard let decoded = try? JSONDecoder().decode([String: String].self, from: plain) else {
      throw Failure.unreadable
    }
    return decoded
  }

  /// 和密钥一起校验的内容（不加密、只防改）：每个服务往哪发请求——id、种类、协议、地址、走不走 DeepLX，
  /// 每项写成「字节数:内容」连起来（分得清边界，写法不随系统版本变）
  private var routing: Data {
    let fields = (translateServices ?? []).flatMap { service in
      [
        service.id, service.kind.rawValue, service.aiProtocol?.rawValue ?? "",
        service.baseURL ?? "", service.usesDeepLX == true ? "1" : "0",
      ]
    }
    return Data(fields.map { "\($0.utf8.count):\($0)" }.joined().utf8)
  }

  /// 解出来的密钥里只收这次导入的服务自己的字段：账户名是文件说的，不能让它写到别的账户上
  func accepted(_ secrets: [String: String]) -> [String: String] {
    var accepted: [String: String] = [:]
    for service in translateServices ?? [] {
      for field in service.secretFields {
        let account = service.account(field.name)
        if let value = secrets[account], !value.isEmpty, value.count <= 4096 {
          accepted[account] = value
        }
      }
    }
    return accepted
  }

  /// 密码 → 256 位密钥（PBKDF2-HMAC-SHA256）。密码先转成 NFC：同一个字不同输入法打出来的码位序列可能不一样
  static func key(password: String, salt: Data, rounds: Int) throws -> SymmetricKey {
    let password = password.precomposedStringWithCanonicalMapping
    var key = [UInt8](repeating: 0, count: 32)
    let status = salt.withUnsafeBytes { bytes in
      CCKeyDerivationPBKDF(
        CCPBKDFAlgorithm(kCCPBKDF2), password, password.utf8.count,
        bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count,
        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds), &key, key.count)
    }
    guard status == kCCSuccess else { throw Failure.unreadable }
    return SymmetricKey(data: key)
  }

  // MARK: 导入

  /// 读用户选的文件：最多读到上限多一个字节就停（文件系统报的大小不作数：符号链接、设备文件），再交给 read(_:)
  static func read(contentsOf url: URL) throws -> SettingsArchive {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    return try read(handle.read(upToCount: maxFileSize + 1) ?? Data())
  }

  /// 读一个导出的文件：认标记和版本、解析，再把不认识 / 不合规的项丢掉
  static func read(_ data: Data) throws -> SettingsArchive {
    struct Header: Decodable {
      var app: String?
      var format: Int?
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard data.count <= maxFileSize else { throw Failure.notArchive }
    // 正常的文件只解析这一遍（带着片段和收藏的文件可以有几十 MB）
    if let archive = try? decoder.decode(SettingsArchive.self, from: data),
      archive.app == marker, (1...currentFormat).contains(archive.format)
    {
      return archive.sanitized()
    }
    // 读不出来、或者标记 / 版本对不上：只看文件头，说清是哪一种
    guard let header = try? decoder.decode(Header.self, from: data), header.app == marker,
      let format = header.format, format >= 1
    else { throw Failure.notArchive }
    throw format > currentFormat ? Failure.newer : Failure.unreadable
  }

  /// 丢掉不该进偏好的：不认识的键和动作、类型或范围不对的值、过不了录制框规则的快捷键（重复的组合留给靠前的动作）、
  /// id 不合规或重复、字段长得离谱的服务和搜索（整条不要，不截断：截了地址就不是原来那个地址）。译文字号夹进滑块的范围
  private func sanitized() -> SettingsArchive {
    var clean = self
    clean.version = String(version.prefix(32))
    clean.preferences = preferences.map { values in
      var kept: [String: Value] = [:]
      for (key, value) in values {
        guard let kind = Self.kinds[key], kind.plist(value) != nil else { continue }
        kept[key] = value
      }
      if let scale = kept[Prefs.translateFontScale].flatMap(Kind.double.plist) as? Double {
        let range = TranslateCoordinator.fontScales
        kept[Prefs.translateFontScale] = .double(
          min(max(scale, range.lowerBound), range.upperBound))
      }
      return kept
    }
    clean.hotkeys = hotkeys.map { entries in
      var kept: [String: HotKey?] = [:]
      var taken: Set<HotKey> = []
      for action in HotKeyAction.allCases {
        guard let entry = entries[action.rawValue] else { continue }
        if let hotKey = entry {
          guard hotKey.isUsable, taken.insert(hotKey).inserted else { continue }
        }
        kept.updateValue(entry, forKey: action.rawValue)
      }
      return kept
    }
    clean.translateServices = translateServices.map { services in
      var ids: Set<String> = []
      return services.prefix(200).filter { service in
        let valid =
          service.kind == .ai
          ? service.id.wholeMatch(of: /ai:[0-9a-z]{4,32}/) != nil
          : service.id == service.kind.rawValue
        // 区域只进请求头（微软），只收字母、数字、连字符
        let fits =
          service.name.count <= 200 && (service.model ?? "").count <= 200
          && (service.baseURL ?? "").count <= 2048
          && (service.region ?? "").wholeMatch(of: /[A-Za-z0-9-]{0,64}/) != nil
        return valid && fits && ids.insert(service.id).inserted
      }
    }
    clean.searchEngines = searchEngines.map { engines in
      var ids: Set<String> = []
      return engines.prefix(500).filter { engine in
        !engine.id.isEmpty && engine.id.count <= 64 && engine.name.count <= 200
          && engine.keyword.count <= 64 && engine.urlTemplate.count <= 2048
          && ids.insert(engine.id).inserted
      }
    }
    // 收藏夹：名字合规、不重复；总数封顶——条目带出来的名字（导入时没有就会新建）也算在里面
    var groupNames: Set<String> = []
    clean.clipGroups = clipGroups.map { names in
      names.compactMap(Self.groupName).filter {
        groupNames.count < Self.maxGroups && groupNames.insert($0).inserted
      }
    }
    if clips == nil { clean.clipGroups = nil }
    // 片段 / 收藏：要有正文、不超过剪贴板单条文字的上限、确实是留下的；收藏夹的名字不合规、收藏夹已经够多的只是不归进去，
    // 备注长得离谱的只是不带备注
    clean.clips = clips.map { clips in
      clips.prefix(Self.maxClips).compactMap { clip in
        guard !clip.text.isEmpty, clip.text.utf8.count <= ClipboardWatcher.maxTextBytes,
          clip.favorite || clip.snippet
        else { return nil }
        var clip = clip
        clip.group = clip.group.flatMap(Self.groupName).flatMap { name in
          groupNames.contains(name)
            || (groupNames.count < Self.maxGroups && groupNames.insert(name).inserted)
            ? name : nil
        }
        if let note = clip.note, note.isEmpty || note.count > 10_000 { clip.note = nil }
        return clip
      }
    }
    clean.vocabulary = vocabulary.map { words in
      words.prefix(Self.maxWords).filter { word in
        !word.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && word.source.count <= 10_000 && !word.result.isEmpty && word.result.count <= 100_000
          && Lang(rawValue: word.target) != nil && word.service.count <= 200
      }
    }
    if translateServices == nil { clean.secrets = nil }
    return clean
  }

  /// 收藏夹的名字：去首尾空白，空的、超过上限的不要（同 ClipboardStore 建收藏夹时的规则）
  private static func groupName(_ raw: String) -> String? {
    let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty || name.count > ClipGroup.maxName ? nil : name
  }

  /// 把选中的类别写进偏好（self 得是 read 出来的）。「设置」「快捷键」整类换成文件里的样子：文件里有的写上，
  /// 没有的删掉（回到默认）；网页搜索按 id 合并。翻译服务不在这里写：列表在 TranslateServiceStore 手里（install）
  func apply(
    _ sections: Set<Section>, to defaults: UserDefaults = .standard,
    domainName: String? = Bundle.main.bundleIdentifier
  ) {
    if sections.contains(.preferences), let preferences {
      for (key, kind) in Self.kinds {
        if let value = preferences[key].flatMap(kind.plist) {
          defaults.set(value, forKey: key)
        } else {
          defaults.removeObject(forKey: key)
        }
      }
      // 旧档位（保留天数、历史条数）挪到现在的档位，免得设置页的选择器显示成空白
      Prefs.migrate(defaults, domainName: domainName)
    }
    if sections.contains(.hotkeys), let hotkeys {
      for action in HotKeyAction.allCases {
        if let entry = hotkeys[action.rawValue] {
          defaults.set(HotKeyAction.stored(entry), forKey: action.prefsKey)
        } else {
          defaults.removeObject(forKey: action.prefsKey)
        }
      }
    }
    if sections.contains(.engines), let searchEngines {
      let domain = domainName.flatMap(defaults.persistentDomain(forName:)) ?? [:]
      defaults.set(
        SearchEngineDetail.encode(Self.merge(searchEngines, into: Self.engines(in: domain))),
        forKey: Prefs.launcherWebSearchEngines)
    }
  }

  /// 导入选中的类别（self 得是 read 出来的）：先解密钥——密码不对就抛错，这时什么都还没写——再写偏好（apply）、
  /// 合并翻译服务、存密钥，片段 / 收藏和生词本并进各自的库（没给 clipboard / history 的那一类不导入）。
  /// password 空着 = 不导入密钥；store：存一个密钥（账户名、值；默认写钥匙串，单测传假的）
  @discardableResult
  func install(
    _ sections: Set<Section>, password: String = "", services: TranslateServiceStore,
    clipboard: ClipboardStore? = nil, history: HistoryStore? = nil,
    to defaults: UserDefaults = .standard,
    domainName: String? = Bundle.main.bundleIdentifier,
    store: (String, String) -> Void = { Keychain.set($1, for: $0) }
  ) throws -> Outcome {
    let importsServices = sections.contains(.services) && translateServices != nil
    var unsealed: [String: String] = [:]
    if importsServices, secrets != nil, !password.isEmpty {
      unsealed = accepted(try unseal(password: password))
    }
    apply(sections, to: defaults, domainName: domainName)
    if importsServices, let translateServices {
      services.services = Self.merge(translateServices, into: services.services)
      for (account, value) in unsealed { store(account, value) }
    }
    var outcome = Outcome(secrets: unsealed.count)
    if sections.contains(.clips), let clips, let clipboard {
      (outcome.clipsAdded, outcome.clipsUpdated) = clipboard.adopt(clips, groups: clipGroups ?? [])
    }
    if sections.contains(.vocabulary), let vocabulary, let history {
      outcome.wordsAdded = history.adoptFavorites(vocabulary)
    }
    return outcome
  }

  /// 按 id 合并两张列表：文件里的排前面（同 id 的换成文件里的），本机独有的接在后面、不删
  static func merge<Item: Identifiable>(_ incoming: [Item], into current: [Item]) -> [Item] {
    let ids = Set(incoming.map(\.id))
    return incoming + current.filter { !ids.contains($0.id) }
  }

  /// 文件里的翻译服务会把文字和密钥发到哪些自己填的地址（主机名，带端口的连端口）：AI 服务的地址、DeepL 的 DeepLX 地址；
  /// 内置服务的官方接口不算。导入前列给用户看——别人给的文件里，名字叫 OpenAI 的服务连的不一定是 OpenAI。
  /// 地址用发请求时的同一套解析（AIService.endpoint、DeepL.deepLXURL）；填了地址却认不出主机的，把填的原样列出来，不跳过；
  /// 启用的服务排前面（导入后马上会用到的）
  var customHosts: [String] {
    let services = translateServices ?? []
    var hosts: [String] = []
    for service in services.filter(\.isEnabled) + services.filter({ !$0.isEnabled }) {
      let url: URL?
      switch service.kind {
      case .ai: url = AIService.endpoint(service.baseURL ?? "", service.aiProtocol ?? .openai)
      case .deepl where service.usesDeepLX == true: url = DeepL.deepLXURL(service)
      default: continue
      }
      let raw = (service.baseURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      let name: String
      if let url, let host = url.host(percentEncoded: false), !host.isEmpty {
        name = url.port.map { "\(host):\($0)" } ?? host
      } else if !raw.isEmpty {
        name = raw
      } else {
        continue
      }
      if !hosts.contains(name) { hosts.append(name) }
    }
    return hosts
  }

  /// 导入「设置」后历史会不会保留得比现在少（保留天数、图片上限、翻译历史条数变小，或者新打开了退出 / 锁屏时清空）：
  /// 超出的普通历史会被清理，导入前要先说。文件里没有的键按默认值算（导入后它会回到默认）
  func keepsLessHistory(than defaults: UserDefaults = .standard) -> Bool {
    guard preferences != nil else { return false }
    let limits = [
      Prefs.clipboardRetentionDays, Prefs.clipboardImageBudgetMB, Prefs.translateHistoryLimit,
    ]
    let clears = [Prefs.clipboardClearOnQuit, Prefs.clipboardClearOnLock]
    return limits.contains { key in
      // 0 = 永久 / 不限
      let (new, old) = (incoming(key) as? Int ?? 0, defaults.integer(forKey: key))
      return new != 0 && (old == 0 || new < old)
    }
      || clears.contains { incoming($0) as? Bool == true && !defaults.bool(forKey: $0) }
  }

  /// 导入「设置」后哪些隐私保护会比现在弱（导入前橙字逐条说；没有就是空的）：不再过滤疑似密钥、剪贴板不记录的 App 变少、
  /// 新打开复制即译。文件里没有的键按默认值算
  func privacyLosses(comparedTo defaults: UserDefaults = .standard) -> [String] {
    guard preferences != nil else { return [] }
    var losses: [String] = []
    if incoming(Prefs.clipboardBlockSensitive) as? Bool == false,
      defaults.bool(forKey: Prefs.clipboardBlockSensitive)
    {
      losses.append("不再过滤疑似密钥和银行卡号")
    }
    let excluded = Set(incoming(Prefs.clipboardExcludedBundleIDs) as? [String] ?? [])
    let current = Set(defaults.stringArray(forKey: Prefs.clipboardExcludedBundleIDs) ?? [])
    if !current.isSubset(of: excluded) { losses.append("剪贴板「不记录」的 App 会变少") }
    if incoming(Prefs.translateCopyToTranslate) as? Bool == true,
      !defaults.bool(forKey: Prefs.translateCopyToTranslate)
    {
      losses.append("会打开复制即译（复制的外语文字自动发给翻译服务）")
    }
    return losses
  }

  /// 导入「设置」后这个键的值：文件里有就是文件里的，没有就是默认值（导入时它会回到默认）
  private func incoming(_ key: String) -> Any? {
    preferences?[key].flatMap { Self.kinds[key]?.plist($0) } ?? Prefs.defaults[key]
  }

  /// 偏好里的网页搜索列表（没存过用默认的）
  private static func engines(in domain: [String: Any]) -> [SearchEngine] {
    SearchEngineDetail.decode(domain[Prefs.launcherWebSearchEngines] as? Data)
  }
}

extension SettingsArchive.Clip {
  /// 留下的文字条目 → 文件里的样子（不是文字、没留下、正文为空的给 nil）
  init?(_ item: ClipItem, groups: [ClipGroup]) {
    guard item.kind == .text, item.isRetained, let text = item.text, !text.isEmpty else {
      return nil
    }
    self.init(
      text: text, note: item.note, favorite: item.favorite, snippet: item.isSnippet,
      group: groups.first { $0.id == item.groupID }?.name, copiedAt: item.copiedAt)
  }
}

extension SettingsArchive.Word {
  init(_ entry: HistoryStore.Entry) {
    self.init(
      source: entry.source, target: entry.target.rawValue, result: entry.result,
      service: entry.service, createdAt: entry.createdAt)
  }
}
