// 启动器计算器（纯函数，配单测）：+ - * /、mod（取模）、^ 或 **（幂，右结合）、括号、一元负号、
// sqrt abs round floor ceil sin cos tan log（常用对数）ln exp、常量 pi e、0x / 0b 字面量。
// % 是百分号（体检 A23，同 macOS 计算器）：200*15% = 30、100+10% = 110（a ± b% = a ×（1 ± b/100））、50% = 0.5。
// 中文输入法打出来的全角括号 / 数字 / 符号、× ÷、千分位逗号先归一（体检 B32），算式那一栏照常显示原文。
// 手写递归下降：NSExpression 遇到半截表达式会直接让进程崩溃。「2024-01-01」这类日期不当算式（修 §11 #37）。

import Foundation

enum Calculator {
  static func item(for query: String) -> LauncherItem? {
    guard looksLikeMath(query), let value = evaluate(query) else { return nil }
    let result = format(value)
    return LauncherItem(
      kind: .calculation, target: query, title: "= \(result)", subtitle: "计算结果 · ↩ 粘贴 · Tab 接着算",
      payload: result, completion: result)
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
      text.contains(/[+\-*\/%^]/) || text.contains(/[a-z]+\s*\(/) || text.contains(/\bmod\b/),
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
  /// 其余最多 12 位有效数字、去掉末尾的 0
  static func format(_ value: Double) -> String {
    if value == value.rounded(), abs(value) <= 9_007_199_254_740_992 { return String(Int64(value)) }
    let style = FloatingPointFormatStyle<Double>.number.precision(.significantDigits(1...12))
      .grouping(.never).locale(Locale(identifier: "en_US_POSIX"))
    return abs(value) >= 1e15 || abs(value) < 1e-9
      ? value.formatted(style.notation(.scientific)) : value.formatted(style)
  }

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
      if current == "0", index + 1 < characters.count, "xb".contains(characters[index + 1]) {
        let radix = characters[index + 1] == "x" ? 16 : 2
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
