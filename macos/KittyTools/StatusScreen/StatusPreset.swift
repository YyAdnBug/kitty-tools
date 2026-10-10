// 状态屏的一个「状态」（PLAN §10「状态屏」Z3 Z4）：标题、说明、图标、样式、电源、自动结束六项，加一个不变的 id。
// 自带三个：清洁屏幕、请勿触碰、马上回来；用户改过的整张列表存在一个偏好键里（Prefs.statusScreenPresets，JSON），
// 没存过 / 解不出 / 为空时用自带的。读出来和以后导入的都过 sanitized：文件、偏好里的值按不可信输入对待。

import Foundation

struct StatusPreset: Codable, Hashable, Identifiable {
  /// 样式（Z5）。类型不叫 Style：免得在这个类型里把全 App 的设计刻度 `Style` 挡住
  enum Look: String, Codable, CaseIterable {
    /// 熄屏：纯黑，什么都不显示
    case blackout
    /// 告示：深色底 + 大字
    case sign
    /// 透出：屏幕压暗 + 大字
    case dim
  }

  enum Power: String, Codable, CaseIterable {
    /// 照常：按系统设置睡眠、熄屏
    case normal
    /// 不睡眠（显示器照常熄）
    case awake
    /// 不睡眠且屏幕常亮
    case displayOn
  }

  /// 启动器使用记录、收藏按它认（改了会丢记录）：自带的固定 clean / busy / back
  var id: String
  var title: String
  var detail: String?
  /// SF Symbol 名（symbols 里的一个）；空 = 不要图标
  var symbol: String
  /// 菜单栏子菜单、启动器里这一行的图标：没选图标的用一个「只有字」的符号垫着（菜单项没图会和别的行对不齐）
  var rowSymbol: String { symbol.isEmpty ? "textformat" : symbol }
  var style: Look
  var power: Power
  /// 几分钟后自动结束（autoEndChoices 里的一个）；0 = 不结束
  var autoEndMinutes: Int

  static let autoEndChoices = [0, 5, 15, 30, 60]
  static let maxCount = 20
  static let maxTitle = 30
  static let maxDetail = 60
  /// id 的长度上限（它会进启动器的使用记录）
  static let maxID = 64

  /// 可选的图标（设置页的图标格子按这个顺序）；都要在 macOS 15 的 SF Symbols 里（单测锁住）
  static let symbols = [
    "sparkles", "hand.raised.fill", "clock.fill", "hourglass", "moon.fill", "zzz",
    "cup.and.saucer.fill", "fork.knife", "figure.walk", "phone.fill", "video.fill",
    "person.2.fill", "terminal.fill", "hammer.fill", "arrow.down.circle.fill", "bolt.fill",
    "exclamationmark.triangle.fill", "bell.slash.fill", "headphones", "gamecontroller.fill",
  ]

  static let builtIn = [
    StatusPreset(
      id: "clean", title: "清洁屏幕", detail: nil, symbol: "sparkles", style: .blackout,
      power: .normal, autoEndMinutes: 5),
    StatusPreset(
      id: "busy", title: "请勿触碰", detail: "电脑正在跑任务，别动键盘和鼠标", symbol: "hand.raised.fill",
      style: .dim, power: .displayOn, autoEndMinutes: 0),
    StatusPreset(
      id: "back", title: "马上回来", detail: nil, symbol: "clock.fill", style: .sign, power: .awake,
      autoEndMinutes: 0),
  ]

  /// 把一张列表收拾成能用的（纯函数）：标题去首尾空白、换行当空格，空的整条丢掉、超过 30 字截断；说明同样收拾、最多 60 字、
  /// 空了就是没有；图标不在清单里的置空；自动结束不是可选值的当「不结束」；id 为空、太长、重复的丢掉（留先出现的）；
  /// 最多 20 个。结果可能是空的——用的地方（decode）退回自带的
  static func sanitized(_ presets: [StatusPreset]) -> [StatusPreset] {
    var seen: Set<String> = []
    var result: [StatusPreset] = []
    for var preset in presets {
      preset.title = String(oneLine(preset.title).prefix(maxTitle))
      guard !preset.title.isEmpty, !preset.id.isEmpty, preset.id.count <= maxID,
        seen.insert(preset.id).inserted
      else { continue }
      let detail = String(oneLine(preset.detail ?? "").prefix(maxDetail))
      preset.detail = detail.isEmpty ? nil : detail
      if !symbols.contains(preset.symbol) { preset.symbol = "" }
      if !autoEndChoices.contains(preset.autoEndMinutes) { preset.autoEndMinutes = 0 }
      result.append(preset)
      if result.count == maxCount { break }
    }
    return result
  }

  private static func oneLine(_ text: String) -> String {
    text.components(separatedBy: .newlines).joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)
  }

  /// 偏好里存的数据 → 列表：没存过、解不出、收拾完一个不剩，都用自带的
  static func decode(_ data: Data?) -> [StatusPreset] {
    guard let data, let stored = try? JSONDecoder().decode([StatusPreset].self, from: data) else {
      return builtIn
    }
    let presets = sanitized(stored)
    return presets.isEmpty ? builtIn : presets
  }

  static func load(_ defaults: UserDefaults = .standard) -> [StatusPreset] {
    decode(defaults.data(forKey: Prefs.statusScreenPresets))
  }

  /// 存进偏好的数据：收拾过的列表的 JSON
  static func encoded(_ presets: [StatusPreset]) -> Data? {
    try? JSONEncoder().encode(sanitized(presets))
  }

  static func save(_ presets: [StatusPreset], to defaults: UserDefaults = .standard) {
    defaults.set(encoded(presets), forKey: Prefs.statusScreenPresets)
  }
}
