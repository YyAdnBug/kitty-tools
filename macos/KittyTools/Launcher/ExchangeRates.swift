// 启动器计算器里的汇率换算（2026-11-04 用户要的；对标 Raycast 计算器里直接打「100 usd to cny」，不要关键词）：
// 「100 usd」「100 美元 转 人民币」「$100 in jpy」「100刀」：左边一个数加货币（ISO 代码；系统给的简体 / 繁体 / 英文名，159 种都有；
// 下面一张表里的口语叫法和符号），右边货币，连接词和
// 单位换算的一样（另加「兑」）；只写左边时换成本机地区的货币（中国大陆是人民币；左边就是它时换成美元）。结果大字「723.45 CNY」
// （分组，小数位按币种：日元 0 位、人民币 2 位，不到 1 的按 4 位有效数字；金额是 1 时是在看汇率，按汇率的精度 6.6714），↩ 粘贴 / Tab 写回的不分组（写回去还能接着换），
// 右侧小字「人民币 · 11-03 汇率」写目标货币的中文名（不认识代码的人看得懂）和数据源那天的日期，⌘K 另有「复制原始数字」
// 「复制汇率」（1 USD = 6.6714 CNY）。输「汇率」（huilv、currency）出一行用法提示，↩ / Tab 把示例「100 美元 转 日元」填进搜索框。
// 货币打到一半（「100 美元 转 英」「100 usd to gb」，或「转」后面还没打）列候选：中文名 + 代码 · 英文名，↩ / Tab 补全；
// 用过的货币（↩ / 复制过的换算）记在这台电脑上，候选里排最前（Prefs.launcherRecentCurrencies，不注册默认值）。
// 2026-11-05 用户「多考虑一些方面」补的写法：金额带倍数（100万日元、1.5k usd、2w 人民币）或写成算式（(100+50) 美元）；货币写在
// 前面（usd 100、US$100、JP¥100）；不写金额只问汇率（美元兑人民币、USD/CNY、usd cny、美元汇率，按 1 算）；口语问法（是多少、
// 等于多少、能换多少、多少钱、对）、繁体的连接词、结尾的「？」「汇率」。
// 汇率：jsDelivr 上的 fawazahmed0/currency-api（CC0、不要密钥，2026-11-04 本机实测 0.7 s、国内可达；表里另有加密货币和停用的
// 旧货币，只留系统认的常用 ISO 货币），连不上换它自己的备用地址。取到的表存进偏好（Prefs.launcherExchangeRates，不注册默认值：
// 不导出、不同步），过了 6 小时下次用到时后台再取一份，取到之前照旧用存着的；一份都没有时那一行先写「正在取汇率…」。
// 这里只有解析、换算、取表和存取（纯函数配单测），什么时候取在 LauncherModel（停 0.3 s 再取，打字路过时不发请求，同 ip）。

import Foundation

enum ExchangeRates {
  /// 一天的汇率：1 美元换 rates[代码] 那么多（代码是大写 ISO 4217）；date 是数据源那天（yyyy-MM-dd）
  nonisolated struct Table: Codable, Equatable, Sendable {
    var date: String
    var fetchedAt: Date
    var rates: [String: Double]
  }

  /// 一次换算：多少、从哪种换成哪种（to 是 nil = 没写，换成本机地区的货币）
  struct Request: Equatable {
    let amount: Double
    let from: String
    let to: String?
  }

  /// 输到汇率换算之后等多久才联网取
  static let fetchDelay = Duration.milliseconds(300)
  /// 存着的表过了多久，下次用到时再取一份（数据源一天一更）
  static let maxAge: TimeInterval = 6 * 3600

  /// 该取新的了：过了 maxAge，或者取的时刻比现在还晚（系统时钟往回调过）
  static func isStale(_ table: Table, now: Date) -> Bool {
    !(0..<maxAge).contains(now.timeIntervalSince(table.fetchedAt))
  }

  /// 本机地区的货币（只写左边时换成它）
  static var home: String { Locale.current.currency?.identifier ?? "CNY" }

  // MARK: 解析

  /// 两种货币之间的说法：英文的前后要有空格；中文的口语（换多少、是多少、等于多少、对、合）、繁体、外汇的「USD/CNY」。
  /// 同一处先对上长的。拆的时候每一处都试（「100/3 usd to cny」在「/」拆不开，接着试「to」）
  private static let connector =
    /\s+(?:to|in|into|as)\s+|换算成|換算成|转换成|轉換成|兑换成|兌換成|换成|換成|转成|轉成|兑换|兌換|换算|換算|折合|等于多少|等於多少|等于|等於|是多少|多少|对|對|换|換|转|轉|兑|兌|合|=|->|→|\//
    .ignoresCase()

  /// 一次换算是怎么写的（解析的中间结果）：金额没写时是 nil
  private struct Side {
    let amount: Double?
    let code: String
  }

  /// 「100 usd」「100美元转人民币」「$100 in jpy」「美元兑人民币」「100万日元是多少人民币」；不是汇率换算就 nil。
  /// 没写金额（只问汇率）按 1 算，但两边都要是确定的货币（见 confident）
  static func request(for query: String) -> Request? {
    let (text, asksRate) = clean(query)
    guard !text.isEmpty else { return nil }
    for match in text.matches(of: connector) {
      let right = trimmedTarget(text[match.range.upperBound...])
      if let request = pair(String(text[..<match.range.lowerBound]), right) { return request }
    }
    // 空格隔开的两种货币：「usd cny」「100 usd cny」
    if let space = text.lastIndex(where: \.isWhitespace),
      let request = pair(String(text[..<space]), String(text[text.index(after: space)...]))
    {
      return request
    }
    guard let side = parse(text), side.amount != nil || (asksRate && confident(text, side.code))
    else { return nil }
    return Request(amount: side.amount ?? 1, from: side.code, to: nil)
  }

  /// 左边一个金额加货币（或只有货币）、右边一种货币
  private static func pair(_ left: String, _ right: String) -> Request? {
    guard let to = currency(right), let side = parse(left) else { return nil }
    if side.amount == nil, !confident(left, side.code) || !confident(right, to) { return nil }
    return Request(amount: side.amount ?? 1, from: side.code, to: to)
  }

  /// 没写金额时只认确定是货币的写法：中文名、符号、口语叫法、大写代码，小写代码只认常用的那些——「all to try」「pen cup」
  /// 是英文，不是阿尔巴尼亚列克换土耳其里拉
  private static func confident(_ token: String, _ code: String) -> Bool {
    let token = token.trimmingCharacters(in: .whitespaces)
    guard token.lowercased() == code.lowercased() else { return true }
    return token == code || common.contains(code)
  }

  /// 问法里不影响意思的字（请问、能、可以、大概、大约、现在、今天、的、呢、吗、？），开头的「汇率」、结尾的「汇率 / rate」和
  /// 「多少钱 / 是多少 / 等于多少 / 多少 / 等于 / =」去掉；后两种说明是在问汇率（没写金额也行）
  private static func clean(_ query: String) -> (text: String, asksRate: Bool) {
    var text = Calculator.normalize(query)
    for filler in ["请问", "可以", "大概", "大约", "现在", "今天", "能", "的", "呢", "吗", "?"] {
      text = text.replacing(filler, with: "")
    }
    text = text.trimmingCharacters(in: .whitespaces)
    let before = text
    text = text.replacing(/^(?:汇率|匯率)\s*/, with: "")
      .replacing(/\s*(?:汇率|匯率|exchange\s*rates?|rates?)$/.ignoresCase(), with: "")
      .replacing(/\s*(?:多少钱|是多少|等于多少|等於多少|多少|等于|等於|=)$/, with: "")
      .trimmingCharacters(in: .whitespaces)
    return (text, text != before)
  }

  /// 右边的货币前面的「多少」「成」（「换多少人民币」「转成日元」里连接词后面剩下的）
  private static func trimmedTarget(_ text: Substring) -> String {
    String(text).trimmingCharacters(in: .whitespaces).replacing(/^(?:多少|成)\s*/, with: "")
  }

  /// 一边：金额在前（「100 usd」「100万日元」「(100+50) 美元」）、货币在前（「usd 100」「US$100」「¥100」），或者只有货币
  private static func parse(_ text: String) -> Side? {
    let text = text.trimmingCharacters(in: .whitespaces)
    if let code = currency(text) { return Side(amount: nil, code: code) }
    if let match = text.wholeMatch(of: /(?<name>[^\d(]*[^\d\s(])\s*(?<value>[\d(].*)/),
      let code = currency(String(match.name)), let value = value(String(match.value))
    {
      return Side(amount: value, code: code)
    }
    // 金额在前：金额后面紧跟的 k / m / w / 千 / 万 / 亿 先当货币名的一部分试（「1 mop」是澳门元），不是再当倍数（「5m usd」）
    guard let end = text.firstIndex(where: { !amountCharacters.contains($0) }),
      end > text.startIndex
    else { return nil }
    let name = text[end...]
    if let code = currency(String(name)), let value = value(String(text[..<end])) {
      return Side(amount: value, code: code)
    }
    guard multipliers[name.first ?? " "] != nil,
      let code = currency(String(name.dropFirst())), let value = value(String(text[...end]))
    else { return nil }
    return Side(amount: value, code: code)
  }

  private static let amountCharacters = Set("0123456789. +-*/()%^")
  /// 金额结尾的倍数：k / 千、w / 万、m（百万）、亿
  private static let multipliers: [Character: Double] = [
    "k": 1e3, "K": 1e3, "千": 1e3, "w": 1e4, "W": 1e4, "万": 1e4, "m": 1e6, "M": 1e6, "亿": 1e8,
  ]

  /// 金额：数字或算式（交给计算器算），结尾可以带倍数；要有数字
  private static func value(_ text: String) -> Double? {
    var text = text.filter { !$0.isWhitespace }
    var scale = 1.0
    if let last = text.last, let multiplier = multipliers[last] {
      scale = multiplier
      text.removeLast()
    }
    guard text.contains(where: \.isNumber), let value = Calculator.evaluate(text) else {
      return nil
    }
    return value * scale
  }

  /// 货币名（不分大小写）→ 代码：系统认的常用 ISO 代码（三个字母），或者系统给的名字、下面这张表里的叫法
  static func currency(_ name: String) -> String? {
    let key = name.trimmingCharacters(in: .whitespaces).lowercased()
    if key.count == 3, isoCodes.contains(key.uppercased()) { return key.uppercased() }
    return names[key]
  }

  /// 系统认的常用 ISO 货币（159 种，没有加密货币、停用的旧货币和贵金属）
  nonisolated static let isoCodes = Set(Locale.commonISOCurrencyCodes)

  /// 先是系统给的名字（简体「沙特里亚尔」、繁体「港幣」、英文「Japanese Yen」，159 种都有），再是下面这张表：
  /// ponytail: 常用的二十几种货币的口语叫法、简称和符号；¥ 当人民币（日元写 jpy / 日元 / 円），「比索」「克朗」这类几国同名的
  /// 要写全；缺了往表里加一行。pound 不收（和磅撞，「1 pound to kg」是单位换算）
  private static let names: [String: String] = {
    var names: [String: String] = [:]
    for locale in ["zh_Hans", "zh_Hant", "en_US"].map(Locale.init(identifier:)) {
      for code in isoCodes {
        if let name = locale.localizedString(forCurrencyCode: code) {
          names[name.lowercased()] = code
        }
      }
    }
    let table: [(String, [String])] = [
      ("CNY", ["人民币", "元", "块", "块钱", "rmb", "yuan", "¥", "cn¥", "rmb¥"]),
      ("USD", ["美元", "美金", "刀", "美刀", "$", "us$", "dollar", "dollars", "buck", "bucks"]),
      ("EUR", ["欧元", "欧", "€", "euro", "euros"]),
      ("JPY", ["日元", "日币", "円", "yen", "jp¥"]),
      ("GBP", ["英镑", "£", "quid"]),
      ("HKD", ["港币", "港元", "港纸", "hk$"]),
      ("TWD", ["台币", "新台币", "nt$"]),
      ("MOP", ["澳门元", "澳门币", "葡币"]),
      ("KRW", ["韩元", "韩币", "₩", "won"]),
      ("AUD", ["澳元", "澳币", "a$"]),
      ("CAD", ["加元", "加币", "c$"]),
      ("SGD", ["新加坡元", "新币", "坡币", "s$"]),
      ("CHF", ["瑞士法郎", "瑞郎"]),
      ("RUB", ["卢布", "₽"]),
      ("INR", ["卢比", "印度卢比", "₹"]),
      ("THB", ["泰铢", "฿"]),
      ("MYR", ["林吉特", "马币", "令吉"]),
      ("VND", ["越南盾", "₫"]),
      ("PHP", ["菲律宾比索", "₱"]),
      ("IDR", ["印尼盾"]),
      ("NZD", ["新西兰元", "纽币"]),
      ("SEK", ["瑞典克朗"]),
      ("NOK", ["挪威克朗"]),
      ("DKK", ["丹麦克朗"]),
      ("TRY", ["土耳其里拉", "₺"]),
      ("AED", ["迪拉姆"]),
      ("BRL", ["雷亚尔", "r$"]),
      ("MXN", ["墨西哥比索"]),
      ("ZAR", ["兰特"]),
      ("ILS", ["₪", "谢克尔", "新谢克尔"]),
      ("UAH", ["₴", "格里夫纳"]),
    ]
    for (code, aliases) in table {
      for alias in aliases { names[alias.lowercased()] = code }
    }
    return names
  }()

  /// 货币的中文名（结果右侧小字写它）：系统的简体名，「人民币」「新台币」「沙特里亚尔」
  static func name(_ code: String) -> String {
    Locale(identifier: "zh_Hans").localizedString(forCurrencyCode: code) ?? code
  }

  /// 搜索框里输这些（不分大小写、空格）出用法提示；打了开头也出（LauncherMatch.promptMatch）
  private static let keywords = ["currency", "汇率", "汇率换算", "huilv", "exchangerate"]

  /// 用法提示那一行的 target（面板按它取色块和右侧「汇率」）
  static let promptTarget = "currency"

  /// 输「汇率」：一行用法提示（同 open / kill 的提示：标题写做什么、副标题写怎么用），↩ / Tab 把示例「100 美元 转 日元」
  /// 填进搜索框，填进去就看到结果和写法。整个打对了排在最前面，只打了开头（「curr」「汇」）排在本地结果后面
  static func promptItems(for query: String) -> (exact: [LauncherItem], partial: [LauncherItem]) {
    let item = LauncherItem(
      kind: .prompt, target: promptTarget, title: "汇率换算…",
      subtitle: "输入「100 美元 转 日元」，↩ 或 Tab 填进示例", completion: "100 美元 转 日元")
    switch LauncherMatch.promptMatch(query, keywords: keywords) {
    case .exact: return ([item], [])
    case .partial: return ([], [item])
    case nil: return ([], [])
    }
  }

  // MARK: 货币候选

  /// 候选行的 target 前缀（面板按它取色块和右侧「货币」）
  static let suggestionPrefix = "currency-"

  /// 常用的货币：候选同分时排前面，「转」后面还没打字时列前 6 种
  private static let common = [
    "CNY", "USD", "EUR", "JPY", "GBP", "HKD", "TWD", "KRW", "AUD", "CAD", "SGD", "CHF", "MOP",
    "THB",
    "MYR", "RUB", "INR", "NZD", "VND", "PHP", "IDR",
  ]

  /// 每种货币能用来搜的叫法（小写、去空格）：代码、系统的简体 / 繁体 / 英文名和英文名里的每个词、简体名的全拼、口语叫法
  private static let searchKeys: [(code: String, keys: [String])] = {
    var aliases: [String: [String]] = [:]
    for (name, code) in names { aliases[code, default: []].append(name) }
    return isoCodes.sorted().map { code in
      var keys = [code.lowercased()] + (aliases[code] ?? [])
      let chinese = name(code)
      keys.append(chinese)
      if let pinyin = AppCatalog.pinyin(chinese) { keys.append(pinyin.full) }
      if let english = Locale(identifier: "en_US").localizedString(forCurrencyCode: code) {
        let words = english.lowercased().split(separator: " ").map(String.init)
        keys += [words.joined()] + words
      }
      return (code, keys)
    }
  }()

  /// 打货币打到一半时的候选（用户 2026-11-04：「能不能有点货币的提示」）：「100 美元 转 英」「100 usd to gb」「100 美」
  /// 「100万日」「美元兑英」，和「100 美元 转」后面还没打字（先列用过的，再列常用的）。每行中文名 + 代码 · 英文名，
  /// ↩ / Tab 把打了的那一截换成它（打的是字母就换成代码，否则换成中文名）。已经是一种货币了不出（那时出结果）；
  /// 左边打的正好是单位名（「10 km」「100 g」「5 m」，是在换算单位）不出，别的打 1 个字母就出（用户 2026-11-05：「100 u」）。
  /// recents：用过的货币，排在同一档的最前面。调用方只在没有计算结果时用它（「10 km to m」是单位换算，不出候选）
  static func suggestions(for query: String, recents: [String] = []) -> [LauncherItem] {
    let raw = query.trimmingCharacters(in: .whitespaces)
    let text = Calculator.normalize(raw)
    var partial: String?
    var exclude: String?
    // 连接词后面：从最后一处往前试，左边要是一个（确定的）金额加货币
    for match in text.matches(of: connector).reversed() {
      let left = clean(String(text[..<match.range.lowerBound])).text
      guard let side = parse(left), side.amount != nil || confident(left, side.code) else {
        continue
      }
      partial = trimmedTarget(text[match.range.upperBound...])
      exclude = side.code
      break
    }
    // 金额后面：「100 u」「100万日」（倍数后面跟着空格或汉字才当倍数，「1 mo」是在打澳门元）
    if partial == nil, let end = text.firstIndex(where: { !amountCharacters.contains($0) }),
      end > text.startIndex, value(String(text[..<end])) != nil
    {
      var rest = text[end...]
      // 带了倍数就是在说钱：「100万日」的「日」不当成天
      var scaled = false
      if let first = rest.first, multipliers[first] != nil,
        rest.dropFirst().first.map({ $0.isWhitespace || !$0.isASCII }) ?? false
      {
        rest = rest.dropFirst()
        scaled = true
      }
      let name = rest.trimmingCharacters(in: .whitespaces)
      guard !name.isEmpty, scaled || Calculator.unit(name) == nil else { return [] }
      partial = name
    }
    guard let partial, currency(partial) == nil else { return [] }
    let key = partial.lowercased().filter { !$0.isWhitespace }
    let recent = { (code: String) in recents.firstIndex(of: code) ?? recents.count }
    let usual = { (code: String) in common.firstIndex(of: code) ?? common.count }
    let codes: [String]
    if key.isEmpty {
      var seen = Set([exclude ?? ""])
      codes = Array((recents + common).filter { seen.insert($0).inserted }.prefix(6))
    } else {
      let ascii = key.allSatisfy(\.isASCII)
      let ranked = searchKeys.compactMap { entry -> (rank: Int, code: String)? in
        let hits = entry.keys.compactMap { name -> Int? in
          if name == key { return 0 }
          if name.hasPrefix(key) { return 1 }
          return !ascii && name.contains(key) ? 2 : nil
        }
        return hits.min().map { ($0, entry.code) }
      }
      codes = ranked.sorted {
        ($0.rank, recent($0.code), usual($0.code), $0.code)
          < ($1.rank, recent($1.code), usual($1.code), $1.code)
      }.map(\.code).prefix(6).map { $0 }
    }
    let before = raw.dropLast(partial.count)
    let prefix = before.trimmingCharacters(in: .whitespaces)
    let joiner = partial.isEmpty || before.last?.isWhitespace == true ? " " : ""
    let typedLetters = !key.isEmpty && key.allSatisfy(\.isASCII)
    return codes.map { code in
      let english = Locale(identifier: "en_US").localizedString(forCurrencyCode: code) ?? code
      return LauncherItem(
        kind: .prompt, target: suggestionPrefix + code, title: name(code),
        subtitle: "\(code) · \(english)",
        completion: prefix + joiner + (typedLetters ? code : name(code)))
    }
  }

  // MARK: 用过的货币

  /// 记几种
  static let recentLimit = 8

  /// 用了一次换算（↩ 粘贴、复制）：它的两种货币挪到最前面（目标在前），最多留 recentLimit 种
  static func remembering(_ query: String, in recents: [String], home: String = home) -> [String] {
    guard let request = request(for: query) else { return recents }
    let used = [target(of: request, home: home), request.from]
    var seen = Set<String>()
    return Array((used + recents).filter { seen.insert($0).inserted }.prefix(recentLimit))
  }

  static func loadRecents(from defaults: UserDefaults = .standard) -> [String] {
    (defaults.stringArray(forKey: Prefs.launcherRecentCurrencies) ?? []).filter(isoCodes.contains)
  }

  static func saveRecents(_ recents: [String], to defaults: UserDefaults = .standard) {
    defaults.set(recents, forKey: Prefs.launcherRecentCurrencies)
  }

  // MARK: 换算

  /// 换成哪种：写了就是它；只写了一种时是本机地区的货币，左边就是它时换成美元（美国是欧元）
  static func target(of request: Request, home: String) -> String {
    request.to ?? (request.from != home ? home : home == "USD" ? "EUR" : "USD")
  }

  /// 按表换算；表里没有这两种货币就 nil
  static func result(_ request: Request, table: Table, home: String) -> Calculator.Result? {
    let to = target(of: request, home: home)
    guard let fromRate = table.rates[request.from], let toRate = table.rates[to] else { return nil }
    let rate = toRate / fromRate
    let value = request.amount * rate
    guard value.isFinite else { return nil }
    // 1 个（「美元兑人民币」「1 usd」）是在看汇率：按汇率的精度（6.6714、0.149893），不按币种的小数位（6.67）
    let format = { (grouped: Bool) in
      request.amount == 1
        ? Calculator.quantity(value, grouped: grouped) : amount(value, code: to, grouped: grouped)
    }
    let plain = format(false)
    return Calculator.Result(
      display: format(true) + " " + to, payload: plain + " " + to,
      copies: [
        Calculator.Copy(title: "复制原始数字", text: plain),
        Calculator.Copy(
          title: "复制汇率",
          text: "1 \(request.from) = \(Calculator.quantity(rate, grouped: false)) \(to)"),
      ],
      note: "\(name(to)) · \(table.date.suffix(5)) 汇率")
  }

  /// 金额：小数位按币种（日元 0 位、人民币 2 位、科威特第纳尔 3 位）；不到 1 的按 4 位有效数字（100 韩元 = 0.07459 美元，
  /// 按 2 位小数就成了 0.07，1 印尼盾成了 0.00）
  static func amount(_ value: Double, code: String, grouped: Bool) -> String {
    let style = FloatingPointFormatStyle<Double>.number.grouping(grouped ? .automatic : .never)
      .locale(Locale(identifier: "en_US"))
    if value != 0, abs(value) < 1 {
      return value.formatted(style.precision(.significantDigits(1...4)))
    }
    return value.formatted(style.precision(.fractionLength(fractionDigits(code))))
  }

  private static func fractionDigits(_ code: String) -> Int {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US")
    formatter.numberStyle = .currency
    formatter.currencyCode = code
    return formatter.maximumFractionDigits
  }

  /// 还没有汇率时那一行（不能粘贴、不能补全，同 ip 的占位行）：正在取 / 没取到
  static func placeholder(for query: String, failed: Bool) -> LauncherItem {
    LauncherItem(
      kind: .calculation, target: query, title: failed ? "没取到汇率，检查一下网络" : "正在取汇率…",
      subtitle: "汇率")
  }

  // MARK: 取表和存取

  /// 数据源：1 美元换多少别的货币（键是小写代码）；jsDelivr 连不上换项目自己的备用地址
  nonisolated static let sources = [
    URL(
      string:
        "https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1/currencies/usd.min.json")!,
    URL(string: "https://latest.currency-api.pages.dev/v1/currencies/usd.min.json")!,
  ]

  /// 依次问数据源：5 秒没回、不是 200、回的不是一张像样的表都换下一家；都不成就 nil
  nonisolated static func fetch() async -> Table? {
    for url in sources {
      let request = URLRequest(
        url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
      guard let (data, response) = try? await URLSession.shared.data(for: request),
        (response as? HTTPURLResponse)?.statusCode == 200,
        let table = table(from: data, fetchedAt: .now)
      else { continue }
      return table
    }
    return nil
  }

  private nonisolated struct Reply: Decodable {
    let date: String
    let usd: [String: Double]
  }

  /// 数据源回的 JSON → 表：只留常用的 ISO 货币、正的有限数；日期不像 yyyy-MM-dd、没有美元、不到 20 种的不要
  /// （被劫持到登录页、格式变了）
  nonisolated static func table(from data: Data, fetchedAt: Date) -> Table? {
    guard let reply = try? JSONDecoder().decode(Reply.self, from: data),
      reply.date.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil
    else { return nil }
    var rates: [String: Double] = [:]
    for (key, value) in reply.usd where value > 0 && value.isFinite {
      let code = key.uppercased()
      if isoCodes.contains(code) { rates[code] = value }
    }
    guard rates["USD"] != nil, rates.count >= 20 else { return nil }
    return Table(date: reply.date, fetchedAt: fetchedAt, rates: rates)
  }

  static func load(from defaults: UserDefaults = .standard) -> Table? {
    defaults.data(forKey: Prefs.launcherExchangeRates).flatMap {
      try? JSONDecoder().decode(Table.self, from: $0)
    }
  }

  static func save(_ table: Table, to defaults: UserDefaults = .standard) {
    guard let data = try? JSONEncoder().encode(table) else { return }
    defaults.set(data, forKey: Prefs.launcherExchangeRates)
  }
}
