// 状态屏的退出密码（2026-10-11 用户要求，PLAN §10「状态屏」）：设了之后，按住 esc / 按住退出提示满两秒不直接退出，
// 先浮出一个输入框，输对了才退出。密码是 4–8 位数字，存在钥匙串里（mac-native §2：密钥只进钥匙串；不跟设置的导出、
// 备份走），会话进入时读一次。
// 输入是纯状态、时刻注入，配单测：数字**按键位认**（主键盘那一排和小键盘；不看输入法、键盘布局、大写锁定和 ⇧——
// 键盘鼠标被拦着的时候换不了输入法，认字符的话布局一变就再也输不对），打满位数当场比；⌫ 删一位，esc 取消，
// 连发不算，同一下按键从拦截和 key 面板各到一次时只算一次。每错满 maxMisses 次收起，要重新按住两秒。
// 它仍然不是安全措施：电源键、触控 ID 键、合盖拦不住——忘了密码就锁定屏幕再解锁，状态屏照旧结束。

import Carbon.HIToolbox
import Foundation

struct Passcode {
  /// 密码几位
  static let lengths = 4...8
  /// 每错满这么多次就收起输入框（收起再打开不清零）
  static let maxMisses = 5
  /// 输入框开着、这么久没按键就收起（秒）
  static let idle: TimeInterval = 10
  /// 同一个键隔得比这还近的两次按下当成同一下（拦截和 key 面板两条路都到了；人按不了这么快）
  static let echo: Duration = .milliseconds(50)
  /// 钥匙串里的条目名
  static let account = "statusScreenPasscode"

  enum Outcome: Equatable {
    /// 不归输入框管：别的键、鼠标、连发、松开
    case ignored
    /// 打了一位、删了一位
    case edited
    /// 打满了、不对：清空重来
    case wrong
    /// 又错满 maxMisses 次：该收起了
    case gaveUp
    case matched
    /// 按了 esc：不输了
    case cancelled
  }

  let digits: [Int]
  private(set) var typed: [Int] = []
  /// 这次会话一共错了几次：只增不减，画面的圆点每变一次晃一下（清零也算「变」，所以重新打开时不清）
  private(set) var misses = 0
  /// 刚输错、还没接着打：提示写「密码不对」
  private(set) var missed = false
  private var last: (code: Int, at: ContinuousClock.Instant)?

  /// 存着的 / 设置里填的文字 → 密码；不是 4–8 位数字就是 nil。typed、misses 是截图自检摆样子用的
  init?(_ text: String, typed: Int = 0, misses: Int = 0) {
    let digits = text.compactMap { $0.isASCII ? $0.wholeNumberValue : nil }
    guard digits.count == text.count, Self.lengths.contains(digits.count) else { return nil }
    self.digits = digits
    self.typed = Array(digits.prefix(typed))
    self.misses = misses
    missed = misses > 0 && typed == 0
  }

  /// 设置里填的两遍有什么问题（nil = 可以存）
  static func problem(_ text: String, confirmation: String) -> String? {
    if Passcode(text) == nil { return "密码是 \(lengths.lowerBound)–\(lengths.upperBound) 位数字" }
    return text == confirmation ? nil : "再输一次，两次要一样"
  }

  /// 键码 → 数字：主键盘那一排和小键盘的 0–9
  static func digit(for code: Int) -> Int? {
    if code == kVK_ANSI_0 || code == kVK_ANSI_Keypad0 { return 0 }
    return StatusPicker.digitKeys.firstIndex(of: code).map { $0 % 9 + 1 }
  }

  static func load() -> Passcode? { Keychain.get(account).flatMap { Passcode($0) } }

  /// nil = 移除
  static func save(_ text: String?) { Keychain.set(text, for: account) }

  /// 输入框打开：从头输
  mutating func begin() {
    typed = []
    missed = false
    last = nil
  }

  /// 输入框开着时来了一个事件。数字带不带 ⇧ 都认（有的键盘布局数字要按着 ⇧ 打）
  mutating func handle(_ event: InputBlock.Event, at now: ContinuousClock.Instant) -> Outcome {
    guard case .keyDown(let code, let isRepeat, let hasModifiers) = event, !isRepeat else {
      return .ignored
    }
    if let last, last.code == code, now - last.at < Self.echo { return .ignored }
    last = (code, now)
    if code == kVK_Escape { return hasModifiers ? .ignored : .cancelled }
    if code == kVK_Delete { return typed.popLast() == nil ? .ignored : .edited }
    guard let digit = Self.digit(for: code) else { return .ignored }
    typed.append(digit)
    missed = false
    guard typed.count == digits.count else { return .edited }
    if typed == digits { return .matched }
    typed = []
    misses += 1
    missed = true
    return misses % Self.maxMisses == 0 ? .gaveUp : .wrong
  }
}
