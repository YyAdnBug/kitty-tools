// 启动器计算器（纯函数，配单测）：+ - * / %（取模）^ 或 **（幂，右结合）、括号、一元负号、
// sqrt abs round floor ceil sin cos tan log（常用对数）ln exp、常量 pi e、0x / 0b 字面量。
// 手写递归下降：NSExpression 遇到半截表达式会直接让进程崩溃。「2024-01-01」这类日期不当算式（修 §11 #37）。

import Foundation

enum Calculator {
  static func item(for query: String) -> LauncherItem? {
    guard looksLikeMath(query), let value = evaluate(query) else { return nil }
    let result = format(value)
    return LauncherItem(
      kind: .calculation, target: query, title: "= \(result)", subtitle: "计算结果 · ↩ 复制",
      payload: result)
  }

  static func looksLikeMath(_ query: String) -> Bool {
    let text = query.trimmingCharacters(in: .whitespaces)
    guard text.count >= 3, text.wholeMatch(of: /[\d\s+\-*\/%.()^a-zA-Z]+/) != nil,
      text.contains(/\d/) || text.contains(/\b(pi|e)\b/),
      text.contains(/[+\-*\/%^]/) || text.contains(/[a-z]+\s*\(/),
      text.wholeMatch(of: /\d{2,4}-\d{1,2}-\d{1,4}/) == nil
    else { return false }
    return true
  }

  /// 解析失败、结果不是有限数时返回 nil
  static func evaluate(_ input: String) -> Double? {
    var parser = Parser(
      Array(input.lowercased().replacing("**", with: "^").filter { !$0.isWhitespace }))
    guard let value = parser.expression(), parser.isAtEnd, value.isFinite else { return nil }
    return value
  }

  /// 整数原样；其余最多 12 位有效数字、去掉末尾的 0
  static func format(_ value: Double) -> String {
    if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
    return value.formatted(
      .number.precision(.significantDigits(1...12)).grouping(.never)
        .locale(Locale(identifier: "en_US_POSIX")))
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

    /// expression := term (('+' | '-') term)*
    mutating func expression() -> Double? {
      guard var value = term() else { return nil }
      while let op = current, op == "+" || op == "-" {
        index += 1
        guard let rhs = term() else { return nil }
        value = op == "+" ? value + rhs : value - rhs
      }
      return value
    }

    /// term := unary (('*' | '/' | '%') unary)*
    private mutating func term() -> Double? {
      guard var value = unary() else { return nil }
      while let op = current, "*/%".contains(op) {
        index += 1
        guard let rhs = unary() else { return nil }
        switch op {
        case "*": value *= rhs
        case "/": value /= rhs
        default: value = value.truncatingRemainder(dividingBy: rhs)
        }
      }
      return value
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
      return Double(text)
    }
  }
}
