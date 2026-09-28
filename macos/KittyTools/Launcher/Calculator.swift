// 启动器计算器（纯函数，配单测）：+ - * /、mod（取模）、^ 或 **（幂，右结合）、括号、一元负号、
// sqrt abs round floor ceil sin cos tan log（常用对数）ln exp、常量 pi e、0x / 0b / 0o 字面量。
// % 是百分号（体检 A23，同 macOS 计算器）：200*15% = 30、100+10% = 110（a ± b% = a ×（1 ± b/100））、50% = 0.5。
// 中文输入法打出来的全角括号 / 数字 / 符号、× ÷、千分位逗号先归一（体检 B32），算式那一栏照常显示原文。
// 手写递归下降：NSExpression 遇到半截表达式会直接让进程崩溃。「2024-01-01」这类日期不当算式（修 §11 #37）。
// 体检 D11（全部离线）：单位换算「数字 单位 (to|in|=|转) 单位」用系统的 Measurement（长度、质量、温度、数据、时间、面积、
// 体积、速度；英文符号 + 中文名，下面一张表）；进制「255 in hex / bin / oct」「0xff in dec」；结果大字按千分位分组，
// ↩ 粘贴、Tab 写回的仍是不分组的原值，⌘K 另有「复制原始数字」、输入带 0x / 0b 时「复制十六进制 / 二进制」。汇率要联网，不做。

import Foundation

enum Calculator {
  /// 一条结果：卡片上的大字（千分位分组、带单位）、↩ 粘贴 / Tab 写回的（不分组）、⌘K 里多出来的复制项
  struct Result: Equatable {
    var display: String
    var payload: String
    var copies: [Copy] = []
  }

  struct Copy: Equatable {
    let title: String
    let text: String
  }

  static func item(for query: String) -> LauncherItem? {
    guard let result = result(for: query) else { return nil }
    return LauncherItem(
      kind: .calculation, target: query, title: result.display,
      subtitle: "计算结果 · ↩ 粘贴 · Tab 接着算", payload: result.payload, completion: result.payload)
  }

  /// 单位换算 → 进制 → 算式，都不是就 nil
  static func result(for query: String) -> Result? {
    if let result = convert(query) ?? convertRadix(query) { return result }
    guard looksLikeMath(query), let value = evaluate(query) else { return nil }
    var result = number(value)
    if hasRadixLiteral(query) { result.copies += radixCopies(value, except: 10) }
    return result
  }

  /// 算式的结果：大字分组，粘贴的不分组；两者不一样时 ⌘K 多一行「复制原始数字」
  static func number(_ value: Double) -> Result {
    let payload = format(value)
    let display = format(value, grouped: true)
    return Result(
      display: display, payload: payload,
      copies: display == payload ? [] : [Copy(title: "复制原始数字", text: payload)])
  }

  /// 中文输入法打出来的算式（体检 B32）：全角括号 / 数字 / ＋－＊／％ 转半角（和 Search.options 同一个口径），
  /// × ✕ 换成 *、÷ 换成 /，去掉数字之间的千分位逗号（1,299 → 1299）
  static func normalize(_ query: String) -> String {
    query.folding(options: .widthInsensitive, locale: nil)
      .replacing(/[×✕]/, with: "*").replacing("÷", with: "/")
      .replacing(/(\d)[,，](?=\d)/) { String($0.1) }
  }

  static func looksLikeMath(_ query: String) -> Bool {
    let text = normalize(query.trimmingCharacters(in: .whitespaces))
    guard text.count >= 3, text.wholeMatch(of: /[\d\s+\-*\/%.()^a-zA-Z]+/) != nil,
      text.contains(/\d/) || text.contains(/\b(pi|e)\b/),
      text.contains(/[+\-*\/%^]/) || text.contains(/[a-z]+\s*\(/) || text.contains(/\bmod\b/)
        // 单独一个 0x / 0b / 0o 字面量：出十进制（⌘K 能复制十六进制 / 二进制）
        || text.wholeMatch(of: /0[xbo][0-9a-fA-F]+/) != nil,
      text.wholeMatch(of: /\d{2,4}-\d{1,2}-\d{1,4}/) == nil
    else { return false }
    return true
  }

  /// 解析失败、结果不是有限数时返回 nil。mod 先换成一个字符（|）再去空白：去了空白「pi mod 2」会粘成一个名字
  static func evaluate(_ input: String) -> Double? {
    var parser = Parser(
      Array(
        normalize(input).lowercased().replacing("**", with: "^").replacing("mod", with: "|")
          .filter { !$0.isWhitespace }))
    guard let value = parser.expression(), parser.isAtEnd, value.isFinite else { return nil }
    return value
  }

  /// 能精确表示的整数（≤ 2^53）原样；太大太小用科学计数（2^60 以前被显示成末尾补 0 的「精确」整数）；
  /// 其余最多 12 位有效数字、去掉末尾的 0。grouped：千分位分组（卡片上的大字，体检 D11），粘贴 / 写回的不分组
  static func format(_ value: Double, grouped: Bool = false) -> String {
    let locale = Locale(identifier: "en_US")
    let grouping: NumberFormatStyleConfiguration.Grouping = grouped ? .automatic : .never
    if value == value.rounded(), abs(value) <= 9_007_199_254_740_992 {
      return Int64(value).formatted(.number.grouping(grouping).locale(locale))
    }
    let style = FloatingPointFormatStyle<Double>.number.precision(.significantDigits(1...12))
      .grouping(grouping).locale(locale)
    return abs(value) >= 1e15 || abs(value) < 1e-9
      ? value.formatted(style.notation(.scientific).grouping(.never)) : value.formatted(style)
  }

  // MARK: 进制（体检 D11）

  /// 「255 in hex」「0xff in dec」「255 转 二进制」：左边是算式（结果要是整数），右边是进制
  static func convertRadix(_ query: String) -> Result? {
    let text = normalize(query).trimmingCharacters(in: .whitespaces)
    guard
      let match = text.wholeMatch(
        of: /(.+?)\s*(?:\s(?:in|to|as)\s|转换成|转成|转|=)\s*(hex|bin|oct|dec|十六进制|二进制|八进制|十进制)/
          .ignoresCase()),
      let value = evaluate(String(match.1)), value == value.rounded(),
      abs(value) <= 9_007_199_254_740_992
    else { return nil }
    let base =
      switch match.2.lowercased() {
      case "hex", "十六进制": 16
      case "bin", "二进制": 2
      case "oct", "八进制": 8
      default: 10
      }
    guard base != 10 else {
      var result = number(value)
      result.copies += radixCopies(value, except: 10)
      return result
    }
    let converted = radix(Int64(value), base)
    return Result(display: converted, payload: converted, copies: radixCopies(value, except: base))
  }

  /// 0xFF / 0b1010 / 0o17（负数带 -）：写回输入框还能接着算
  static func radix(_ value: Int64, _ base: Int) -> String {
    let prefix = [16: "0x", 2: "0b", 8: "0o"][base] ?? ""
    return (value < 0 ? "-" : "") + prefix + String(value.magnitude, radix: base, uppercase: true)
  }

  /// ⌘K 里的「复制十进制 / 十六进制 / 二进制」（不是整数时没有；except 是结果本身的进制）
  static func radixCopies(_ value: Double, except base: Int) -> [Copy] {
    guard value == value.rounded(), abs(value) <= 9_007_199_254_740_992 else { return [] }
    return [(10, "复制十进制"), (16, "复制十六进制"), (2, "复制二进制")].filter { $0.0 != base }.map {
      Copy(title: $0.1, text: $0.0 == 10 ? format(value) : radix(Int64(value), $0.0))
    }
  }

  static func hasRadixLiteral(_ query: String) -> Bool {
    normalize(query).lowercased().contains(/(?:^|[^0-9a-z])0[xbo][0-9a-f]/)
  }

  // MARK: 单位换算（体检 D11）

  /// 「10 km to mi」「30 摄氏度 转 华氏度」「1.5GB in MB」：左边一个数加单位，右边单位；两边要是同一类量。
  /// 结果：大字「6.2137 mi」（分组）、↩ 粘贴 / Tab 写回「6.2137 mi」（不分组，接着能换算）、⌘K「复制原始数字」6.2137
  static func convert(_ query: String) -> Result? {
    let text = normalize(query).trimmingCharacters(in: .whitespaces)
    guard
      let match = text.wholeMatch(
        of:
          /([+\-]?\d+(?:\.\d+)?(?:e[+\-]?\d+)?)\s*(.+?)\s*(?:\s(?:to|in|as)\s|转换成|转成|换成|转|=|->|→)\s*(.+)/
          .ignoresCase()),
      let value = Double(match.1), let from = unit(String(match.2)), let to = unit(String(match.3)),
      from.family == to.family
    else { return nil }
    let converted = Measurement(value: value, unit: from.dimension).converted(to: to.dimension)
      .value
    guard converted.isFinite else { return nil }
    let plain = quantity(converted, grouped: false)
    return Result(
      display: quantity(converted, grouped: true) + " " + to.symbol,
      payload: plain + " " + to.symbol, copies: [Copy(title: "复制原始数字", text: plain)])
  }

  /// 换算结果的数：≥ 1 的最多 4 位小数（6.2137），小于 1 的 6 位有效数字（0.000621371）
  static func quantity(_ value: Double, grouped: Bool) -> String {
    let style = FloatingPointFormatStyle<Double>.number.grouping(grouped ? .automatic : .never)
      .locale(Locale(identifier: "en_US"))
    if abs(value) >= 1e15 || (value != 0 && abs(value) < 1e-9) {
      return value.formatted(style.precision(.significantDigits(1...6)).notation(.scientific))
    }
    return abs(value) >= 1
      ? value.formatted(style.precision(.fractionLength(0...4)))
      : value.formatted(style.precision(.significantDigits(1...6)))
  }

  struct UnitName {
    /// 同一类量才能换（长度、质量…）
    let family: String
    let dimension: Dimension
    /// 结果里写的符号
    let symbol: String
  }

  /// 单位名（不分大小写）→ 单位
  static func unit(_ name: String) -> UnitName? {
    units[name.trimmingCharacters(in: .whitespaces).lowercased()]
  }

  /// 每一类：(单位, 结果里写的符号, 能输入的名字)。名字不分大小写，所以 Mb（兆比特）也当 MB。
  /// ponytail: 常用的中英文名，没有复数变形规则、没有「平方」这类组合；缺了往表里加一行
  private static let table: [(family: String, units: [(Dimension, String, [String])])] = [
    (
      "length",
      [
        (UnitLength.meters, "m", ["m", "米", "meter", "meters", "metre", "metres"]),
        (UnitLength.kilometers, "km", ["km", "公里", "千米", "kilometer", "kilometers"]),
        (UnitLength.centimeters, "cm", ["cm", "厘米", "公分", "centimeter", "centimeters"]),
        (UnitLength.millimeters, "mm", ["mm", "毫米", "millimeter", "millimeters"]),
        (UnitLength.micrometers, "µm", ["µm", "μm", "um", "微米"]),
        (UnitLength.nanometers, "nm", ["nm", "纳米"]),
        (UnitLength.miles, "mi", ["mi", "mile", "miles", "英里"]),
        (UnitLength.feet, "ft", ["ft", "foot", "feet", "英尺", "'"]),
        (UnitLength.inches, "in", ["in", "inch", "inches", "英寸", "\""]),
        (UnitLength.yards, "yd", ["yd", "yard", "yards", "码"]),
        (UnitLength.nauticalMiles, "nmi", ["nmi", "海里"]),
        (
          UnitLength(symbol: "里", converter: UnitConverterLinear(coefficient: 500)), "里",
          ["里", "华里"]
        ),
        (
          UnitLength(symbol: "尺", converter: UnitConverterLinear(coefficient: 1.0 / 3)), "尺",
          ["尺", "市尺"]
        ),
        (
          UnitLength(symbol: "寸", converter: UnitConverterLinear(coefficient: 1.0 / 30)), "寸",
          ["寸", "市寸"]
        ),
      ]
    ),
    (
      "mass",
      [
        (UnitMass.grams, "g", ["g", "克", "gram", "grams"]),
        (UnitMass.kilograms, "kg", ["kg", "公斤", "千克", "kilogram", "kilograms", "kilo", "kilos"]),
        (UnitMass.milligrams, "mg", ["mg", "毫克"]),
        (UnitMass.metricTons, "t", ["t", "吨", "ton", "tons", "tonne", "tonnes"]),
        (UnitMass.pounds, "lb", ["lb", "lbs", "pound", "pounds", "磅"]),
        (UnitMass.ounces, "oz", ["oz", "ounce", "ounces", "盎司"]),
        (
          UnitMass(symbol: "斤", converter: UnitConverterLinear(coefficient: 0.5)), "斤", ["斤", "市斤"]
        ),
        (UnitMass(symbol: "两", converter: UnitConverterLinear(coefficient: 0.05)), "两", ["两"]),
      ]
    ),
    (
      "temperature",
      [
        (UnitTemperature.celsius, "°C", ["c", "°c", "℃", "celsius", "摄氏度", "摄氏", "度"]),
        (UnitTemperature.fahrenheit, "°F", ["f", "°f", "℉", "fahrenheit", "华氏度", "华氏"]),
        (UnitTemperature.kelvin, "K", ["k", "kelvin", "开尔文", "开"]),
      ]
    ),
    (
      "data",
      [
        (UnitInformationStorage.bytes, "B", ["b", "byte", "bytes", "字节"]),
        (UnitInformationStorage.bits, "bit", ["bit", "bits", "比特", "位"]),
        (UnitInformationStorage.kilobytes, "KB", ["kb", "千字节"]),
        (UnitInformationStorage.megabytes, "MB", ["mb", "兆字节", "兆"]),
        (UnitInformationStorage.gigabytes, "GB", ["gb", "吉字节", "g字节"]),
        (UnitInformationStorage.terabytes, "TB", ["tb"]),
        (UnitInformationStorage.petabytes, "PB", ["pb"]),
        (UnitInformationStorage.kibibytes, "KiB", ["kib"]),
        (UnitInformationStorage.mebibytes, "MiB", ["mib"]),
        (UnitInformationStorage.gibibytes, "GiB", ["gib"]),
        (UnitInformationStorage.tebibytes, "TiB", ["tib"]),
        (UnitInformationStorage.kilobits, "kbit", ["kbit", "kbps"]),
        (UnitInformationStorage.megabits, "Mbit", ["mbit", "mbps"]),
        (UnitInformationStorage.gigabits, "Gbit", ["gbit", "gbps"]),
      ]
    ),
    (
      "duration",
      [
        (UnitDuration.seconds, "s", ["s", "sec", "secs", "second", "seconds", "秒", "秒钟"]),
        (UnitDuration.milliseconds, "ms", ["ms", "毫秒", "millisecond", "milliseconds"]),
        (UnitDuration.minutes, "min", ["min", "mins", "minute", "minutes", "分钟", "分"]),
        (UnitDuration.hours, "h", ["h", "hr", "hrs", "hour", "hours", "小时", "钟头"]),
        (
          UnitDuration(symbol: "天", converter: UnitConverterLinear(coefficient: 86_400)), "天",
          ["d", "day", "days", "天", "日"]
        ),
        (
          UnitDuration(symbol: "周", converter: UnitConverterLinear(coefficient: 604_800)), "周",
          ["w", "wk", "week", "weeks", "周", "星期"]
        ),
      ]
    ),
    (
      "area",
      [
        (UnitArea.squareMeters, "m²", ["m2", "m²", "sqm", "平方米", "平米"]),
        (UnitArea.squareKilometers, "km²", ["km2", "km²", "平方公里", "平方千米"]),
        (UnitArea.squareCentimeters, "cm²", ["cm2", "cm²", "平方厘米"]),
        (UnitArea.squareFeet, "ft²", ["ft2", "ft²", "sqft", "平方英尺"]),
        (UnitArea.squareInches, "in²", ["in2", "in²", "平方英寸"]),
        (UnitArea.squareMiles, "mi²", ["mi2", "mi²", "平方英里"]),
        (UnitArea.hectares, "ha", ["ha", "hectare", "hectares", "公顷"]),
        (UnitArea.acres, "ac", ["ac", "acre", "acres", "英亩"]),
        (
          UnitArea(symbol: "亩", converter: UnitConverterLinear(coefficient: 2000.0 / 3)), "亩", ["亩"]
        ),
      ]
    ),
    (
      "volume",
      [
        (UnitVolume.liters, "L", ["l", "liter", "liters", "litre", "litres", "升", "公升"]),
        (UnitVolume.milliliters, "mL", ["ml", "milliliter", "milliliters", "毫升"]),
        (UnitVolume.cubicMeters, "m³", ["m3", "m³", "立方米", "方"]),
        (UnitVolume.cubicCentimeters, "cm³", ["cm3", "cm³", "cc", "立方厘米"]),
        (UnitVolume.gallons, "gal", ["gal", "gallon", "gallons", "加仑"]),
        (UnitVolume.quarts, "qt", ["qt", "quart", "quarts"]),
        (UnitVolume.pints, "pt", ["pt", "pint", "pints", "品脱"]),
        (UnitVolume.cups, "cup", ["cup", "cups", "杯"]),
        (UnitVolume.fluidOunces, "fl oz", ["fl oz", "floz", "液盎司"]),
        (UnitVolume.tablespoons, "tbsp", ["tbsp", "汤匙"]),
        (UnitVolume.teaspoons, "tsp", ["tsp", "茶匙"]),
      ]
    ),
    (
      "speed",
      [
        (UnitSpeed.metersPerSecond, "m/s", ["m/s", "mps", "米每秒", "米/秒"]),
        (UnitSpeed.kilometersPerHour, "km/h", ["km/h", "kmh", "kph", "公里每小时", "公里/小时", "千米每小时"]),
        (UnitSpeed.milesPerHour, "mph", ["mph", "英里每小时"]),
        (UnitSpeed.knots, "kn", ["kn", "knot", "knots", "节"]),
      ]
    ),
  ]

  private static let units: [String: UnitName] = {
    var units: [String: UnitName] = [:]
    for (family, entries) in table {
      for (dimension, symbol, names) in entries {
        for name in names {
          units[name.lowercased()] = UnitName(family: family, dimension: dimension, symbol: symbol)
        }
      }
    }
    return units
  }()

  private struct Parser {
    let characters: [Character]
    var index = 0

    init(_ characters: [Character]) { self.characters = characters }

    var isAtEnd: Bool { index == characters.count }
    private var current: Character? { index < characters.count ? characters[index] : nil }

    private mutating func eat(_ character: Character) -> Bool {
      guard current == character else { return false }
      index += 1
      return true
    }

    /// expression := term (('+' | '-') term)*；右边是单独一个百分数时 a ± b% = a ×（1 ± b/100）
    mutating func expression() -> Double? {
      guard var value = term()?.value else { return nil }
      while let op = current, op == "+" || op == "-" {
        index += 1
        guard let rhs = term() else { return nil }
        let amount = rhs.isPercent ? value * rhs.value : rhs.value
        value = op == "+" ? value + amount : value - amount
      }
      return value
    }

    /// term := factor (('*' | '/' | mod) factor)*。isPercent：整个 term 就是一个百分数（「10%」），给 a ± b% 用
    private mutating func term() -> (value: Double, isPercent: Bool)? {
      guard let first = factor() else { return nil }
      var (value, isPercent) = first
      while let op = current, "*/|".contains(op) {
        index += 1
        guard let rhs = factor()?.value else { return nil }
        isPercent = false
        switch op {
        case "*": value *= rhs
        case "/": value /= rhs
        default: value = value.truncatingRemainder(dividingBy: rhs)
        }
      }
      return (value, isPercent)
    }

    /// factor := unary '%'?：% 紧跟在数字 / 右括号后面、再往后是结尾、运算符或右括号时是百分号（b% = b/100）
    private mutating func factor() -> (value: Double, isPercent: Bool)? {
      guard let value = unary() else { return nil }
      let next = index + 1
      guard current == "%", next == characters.count || "+-*/^|)".contains(characters[next])
      else { return (value, false) }
      index = next
      return (value / 100, true)
    }

    /// unary := '-' unary | '+' unary | power
    private mutating func unary() -> Double? {
      if eat("-") { return unary().map { -$0 } }
      if eat("+") { return unary() }
      return power()
    }

    /// power := primary ('^' unary)?（右结合，指数可以带负号）
    private mutating func power() -> Double? {
      guard let base = primary() else { return nil }
      guard eat("^") else { return base }
      return unary().map { pow(base, $0) }
    }

    /// primary := number | constant | function '(' expression ')' | '(' expression ')'
    private mutating func primary() -> Double? {
      if eat("(") {
        let value = expression()
        return eat(")") ? value : nil
      }
      if let current, current.isLetter { return named() }
      return number()
    }

    private mutating func named() -> Double? {
      var name = ""
      while let current, current.isLetter {
        name.append(current)
        index += 1
      }
      switch name {
      case "pi": return .pi
      case "e": return M_E
      default: break
      }
      let functions: [String: (Double) -> Double] = [
        "sqrt": { $0.squareRoot() }, "abs": { abs($0) }, "round": { $0.rounded() },
        "floor": { $0.rounded(.down) }, "ceil": { $0.rounded(.up) }, "sin": { sin($0) },
        "cos": { cos($0) }, "tan": { tan($0) }, "log": { log10($0) }, "ln": { log($0) },
        "exp": { exp($0) },
      ]
      guard let function = functions[name], eat("("), let argument = expression(), eat(")") else {
        return nil
      }
      return function(argument)
    }

    private mutating func number() -> Double? {
      if current == "0", index + 1 < characters.count, "xbo".contains(characters[index + 1]) {
        let radix = ["x": 16, "b": 2, "o": 8][characters[index + 1]] ?? 10
        index += 2
        var digits = ""
        while let current, current.isHexDigit, Int(String(current), radix: radix) != nil {
          digits.append(current)
          index += 1
        }
        return Int(digits, radix: radix).map(Double.init)
      }
      var text = ""
      while let current, current.isNumber || current == "." {
        text.append(current)
        index += 1
      }
      // 科学计数（1.15e18、9e-13）：Tab 把很大 / 很小的结果写回输入框后要能接着算。
      // 只有 e 后面紧跟数字（或正负号加数字）才算指数，单独的 e 仍是常数
      if !text.isEmpty, current == "e" {
        var end = index + 1
        if end < characters.count, "+-".contains(characters[end]) { end += 1 }
        if end < characters.count, characters[end].isNumber {
          text += String(characters[index..<end])
          index = end
          while let current, current.isNumber {
            text.append(current)
            index += 1
          }
        }
      }
      return Double(text)
    }
  }
}
