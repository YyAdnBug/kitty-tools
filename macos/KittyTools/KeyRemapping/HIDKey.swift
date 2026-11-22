// 源键和目标键共用的 HID 用法目录。显示键帽名，保存完整的用法页和用法编号。

import Foundation

nonisolated struct HIDKey: Identifiable {
  let id: UInt64
  let title: String

  private static func keyboard(_ usage: UInt64, _ title: String) -> HIDKey {
    HIDKey(id: 0x7_0000_0000 | usage, title: title)
  }

  static let globe = HIDKey(id: 0xFF_0000_0003, title: "🌐 Globe / Fn")

  static let functionKeys = (1...24).map { number in
    let usage = number <= 12 ? 0x3A + number - 1 : 0x68 + number - 13
    return keyboard(UInt64(usage), "F\(number)")
  }

  static let modifiers = [
    globe, keyboard(0x39, "Caps Lock"),
    keyboard(0xE0, "Left Control"), keyboard(0xE1, "Left Shift"),
    keyboard(0xE2, "Left Option"), keyboard(0xE3, "Left Command"),
    keyboard(0xE4, "Right Control"), keyboard(0xE5, "Right Shift"),
    keyboard(0xE6, "Right Option"), keyboard(0xE7, "Right Command"),
  ]

  static let typing =
    zip(
      UInt64(0x04)...UInt64(0x27), "ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890"
    ).map { keyboard($0, String($1)) } + [
      keyboard(0x28, "Return"), keyboard(0x29, "Esc"), keyboard(0x2A, "Delete ⌫"),
      keyboard(0x2B, "Tab"), keyboard(0x2C, "Space"),
      keyboard(0x2D, "-"), keyboard(0x2E, "="), keyboard(0x2F, "["), keyboard(0x30, "]"),
      keyboard(0x31, "\\"), keyboard(0x32, "Non-US #"), keyboard(0x33, ";"),
      keyboard(0x34, "'"), keyboard(0x35, "`"), keyboard(0x36, ","),
      keyboard(0x37, "."), keyboard(0x38, "/"), keyboard(0x64, "Non-US \\"),
    ]

  static let navigation =
    zip(
      UInt64(0x46)...UInt64(0x52),
      [
        "Print Screen", "Scroll Lock", "Pause", "Insert", "Home", "Page Up", "Forward Delete ⌦",
        "End", "Page Down", "→", "←", "↓", "↑",
      ]
    ).map(keyboard) + [keyboard(0x65, "Application")]

  static let keypad =
    zip(
      UInt64(0x53)...UInt64(0x63),
      [
        "Num Lock", "Keypad /", "Keypad *", "Keypad -", "Keypad +", "Keypad Enter",
        "Keypad 1", "Keypad 2", "Keypad 3", "Keypad 4", "Keypad 5", "Keypad 6", "Keypad 7",
        "Keypad 8", "Keypad 9", "Keypad 0", "Keypad .",
      ]
    ).map(keyboard) + [keyboard(0x67, "Keypad ="), keyboard(0x85, "Keypad ,")]

  /// 键帽上的名字照写英文（同快捷键速查表）；媒体键是功能的说法，跟界面语言
  static let media = [
    HIDKey(
      id: 0xC_0000_006F, title: String(localized: "hidKey.brightnessUp", defaultValue: "亮度 +")),
    HIDKey(
      id: 0xC_0000_0070, title: String(localized: "hidKey.brightnessDown", defaultValue: "亮度 −")),
    HIDKey(id: 0xC_0000_00B5, title: String(localized: "hidKey.nextTrack", defaultValue: "下一首")),
    HIDKey(
      id: 0xC_0000_00B6, title: String(localized: "hidKey.previousTrack", defaultValue: "上一首")),
    HIDKey(
      id: 0xC_0000_00CD, title: String(localized: "hidKey.playPause", defaultValue: "播放 / 暂停")),
    HIDKey(id: 0xC_0000_00E2, title: String(localized: "hidKey.mute", defaultValue: "静音")),
    HIDKey(id: 0xC_0000_00E9, title: String(localized: "hidKey.volumeUp", defaultValue: "音量 +")),
    HIDKey(id: 0xC_0000_00EA, title: String(localized: "hidKey.volumeDown", defaultValue: "音量 −")),
  ]

  private static let titles = Dictionary(
    uniqueKeysWithValues: (functionKeys + modifiers + typing + navigation + keypad + media).map {
      ($0.id, $0.title)
    })

  static func title(_ id: UInt64) -> String {
    titles[id] ?? "0x" + String(id, radix: 16, uppercase: true)
  }

  static func isValid(_ id: UInt64) -> Bool {
    (1...0xFFFF).contains(id >> 32) && (1...0xFFFF).contains(id & 0xFFFF_FFFF)
  }

  static func customID(_ text: String) -> UInt64? {
    let hex = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard let id = UInt64(hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex, radix: 16),
      isValid(id)
    else { return nil }
    return id
  }
}
