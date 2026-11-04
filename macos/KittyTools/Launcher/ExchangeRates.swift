// 启动器计算器里的汇率换算（2026-11-04 用户要的；对标 Raycast 计算器里直接打「100 usd to cny」，不要关键词）：
// 「100 usd」「100 美元 转 人民币」「$100 in jpy」「100刀」：左边一个数加货币（ISO 代码；系统给的简体 / 繁体 / 英文名，159 种都有；
// 下面一张表里的口语叫法和符号），右边货币，连接词和
// 单位换算的一样（另加「兑」）；只写左边时换成本机地区的货币（中国大陆是人民币；左边就是它时换成美元）。结果大字「723.45 CNY」
// （分组，小数位按币种：日元 0 位、人民币 2 位，不到 1 的按 4 位有效数字），↩ 粘贴 / Tab 写回的不分组（写回去还能接着换），
// 右侧小字「人民币 · 11-03 汇率」写目标货币的中文名（不认识代码的人看得懂）和数据源那天的日期，⌘K 另有「复制原始数字」
// 「复制汇率」（1 USD = 6.6714 CNY）。输「汇率」（huilv、currency）出一行用法提示，↩ / Tab 把示例「100 美元」填进搜索框。
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

  /// 「100 usd」「100美元转人民币」「$100 in jpy」；不是汇率换算（没有货币、右边写的不是货币）就 nil
  static func request(for query: String) -> Request? {
    let text = Calculator.normalize(query).trimmingCharacters(in: .whitespaces)
    let parts = text.wholeMatch(
      of: /(.+?)\s*(?:\s(?:to|in|as)\s|转换成|兑换成|转成|换成|兑换|转|兑|=|->|→)\s*(.+)/.ignoresCase())
    guard let (amount, from) = parse(parts.map { String($0.1) } ?? text) else { return nil }
    guard let parts else { return Request(amount: amount, from: from, to: nil) }
    return currency(String(parts.2)).map { Request(amount: amount, from: from, to: $0) }
  }

  /// 「$100」「100 usd」「100美元」「100$」→（数，代码）
  private static func parse(_ text: String) -> (Double, String)? {
    let match =
      text.wholeMatch(of: /(?<name>[$€£¥₩₹₽฿])\s*(?<value>\d+(?:\.\d+)?)/).map {
        (String($0.name), $0.value)
      }
      ?? text.wholeMatch(of: /(?<value>\d+(?:\.\d+)?)\s*(?<name>.+)/).map {
        (String($0.name), $0.value)
      }
    guard let (name, digits) = match, let value = Double(digits), let code = currency(name) else {
      return nil
    }
    return (value, code)
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
      ("CNY", ["人民币", "元", "块", "块钱", "rmb", "yuan", "¥"]),
      ("USD", ["美元", "美金", "刀", "$", "us$", "dollar", "dollars"]),
      ("EUR", ["欧元", "欧", "€", "euro", "euros"]),
      ("JPY", ["日元", "日币", "円", "yen"]),
      ("GBP", ["英镑", "£"]),
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
      ("VND", ["越南盾"]),
      ("PHP", ["菲律宾比索"]),
      ("IDR", ["印尼盾"]),
      ("NZD", ["新西兰元", "纽币"]),
      ("SEK", ["瑞典克朗"]),
      ("NOK", ["挪威克朗"]),
      ("DKK", ["丹麦克朗"]),
      ("TRY", ["土耳其里拉"]),
      ("AED", ["迪拉姆"]),
      ("BRL", ["雷亚尔"]),
      ("MXN", ["墨西哥比索"]),
      ("ZAR", ["兰特"]),
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

  /// 搜索框里输这些（不分大小写、空格）出用法提示
  private static let keywords: Set<String> = ["汇率", "汇率换算", "huilv", "currency", "exchangerate"]

  /// 用法提示那一行的 target（面板按它取色块和右侧「汇率」）
  static let promptTarget = "currency"

  /// 输「汇率」：一行用法提示，↩ / Tab 把示例「100 美元」填进搜索框（同 fy、open 的提示）
  static func promptItems(for query: String) -> [LauncherItem] {
    guard keywords.contains(LauncherMatch.fold(query).filter { !$0.isWhitespace }) else {
      return []
    }
    return [
      LauncherItem(
        kind: .prompt, target: promptTarget, title: "汇率换算…",
        subtitle: "输入「100 美元」或「100 美元 转 日元」，↩ 或 Tab 填进示例", completion: "100 美元")
    ]
  }

  // MARK: 换算

  /// 按表换算；表里没有这两种货币就 nil
  static func result(_ request: Request, table: Table, home: String) -> Calculator.Result? {
    let to = request.to ?? (request.from != home ? home : home == "USD" ? "EUR" : "USD")
    guard let fromRate = table.rates[request.from], let toRate = table.rates[to] else { return nil }
    let rate = toRate / fromRate
    let value = request.amount * rate
    guard value.isFinite else { return nil }
    let plain = amount(value, code: to, grouped: false)
    return Calculator.Result(
      display: amount(value, code: to, grouped: true) + " " + to, payload: plain + " " + to,
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
