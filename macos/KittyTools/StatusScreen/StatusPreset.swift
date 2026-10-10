// 状态屏的一个「状态」（PLAN §10「状态屏」Z3 Z4）：标题、说明、图标、样式、电源、自动结束六项，加一个不变的 id。
// 自带三个：清洁屏幕、请勿触碰、马上回来；用户改过的整张列表存在一个偏好键里（Prefs.statusScreenPresets，JSON），
// 没存过 / 解不出 / 为空时用自带的。读出来和导入的都过 sanitized：文件、偏好里的值按不可信输入对待。
// 设置 › 状态屏改列表用的几个纯函数（加、删、挪、恢复自带的、详情页改一个）和列表行的摘要也在这里。
// nonisolated：设置导出文件里的值（SettingsArchive.Value，不绑主线程）要编解码它。

import Foundation

nonisolated struct StatusPreset: Codable, Hashable, Identifiable {
  /// 样式（Z5）。类型不叫 Style：免得在这个类型里把全 App 的设计刻度 `Style` 挡住
  enum Look: String, Codable, CaseIterable {
    /// 熄屏：纯黑，什么都不显示
    case blackout
    /// 告示：深色底 + 大字
    case sign
    /// 透出：屏幕压暗 + 大字
    case dim

    var title: String {
      switch self {
      case .blackout: "熄屏"
      case .sign: "告示"
      case .dim: "透出"
      }
    }

    /// 设置里选中这一种时下面的一句话
    var explanation: String {
      switch self {
      case .blackout: "纯黑，什么都不显示，适合擦屏幕"
      case .sign: "黑底大字，看不到屏幕内容"
      case .dim: "屏幕压暗，还看得见后面的窗口"
      }
    }
  }

  enum Power: String, Codable, CaseIterable {
    /// 照常：按系统设置睡眠、熄屏
    case normal
    /// 不睡眠（显示器照常熄）
    case awake
    /// 不睡眠且屏幕常亮
    case displayOn

    var title: String {
      switch self {
      case .normal: "照常"
      case .awake: "不睡眠"
      case .displayOn: "不睡眠且屏幕常亮"
      }
    }
  }

  /// 启动器使用记录、收藏按它认（改了会丢记录）：自带的固定 clean / busy / back
  var id: String
  var title: String
  var detail: String?
  /// SF Symbol 名（symbols 里的一个）；空 = 不要图标
  var symbol: String
  /// 菜单栏子菜单、启动器、设置列表里这一行的图标：没选图标的用一个「只有几行字」的符号垫着（菜单项没图会和别的行对不齐）。
  /// 不用 textformat：它在中文系统上画成「格式」两个字（mac-whisker §3「图标」，设置页的截图自检里看到的就是）
  var rowSymbol: String { symbol.isEmpty ? "text.alignleft" : symbol }
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

  /// 导入时并进本机的列表：按 id 更新和添加、顺序先照文件里的，本机独有的接在后面（不删：那是用户自己写的东西，
  /// 同翻译服务、网页搜索两张列表的做法）；超过 maxCount 的由 sanitized 截掉后面的
  static func merged(_ incoming: [StatusPreset], into local: [StatusPreset]) -> [StatusPreset] {
    sanitized(incoming + local.filter { kept in !incoming.contains { $0.id == kept.id } })
  }

  /// 存进偏好的数据：收拾过的列表的 JSON
  static func encoded(_ presets: [StatusPreset]) -> Data? {
    try? JSONEncoder().encode(sanitized(presets))
  }

  static func save(_ presets: [StatusPreset], to defaults: UserDefaults = .standard) {
    defaults.set(encoded(presets), forKey: Prefs.statusScreenPresets)
  }

  // MARK: 设置 › 状态屏（纯函数；存之前 encoded 再收拾一遍）

  /// 「几分钟后自动结束」的叫法：「不结束」「5 分钟」「1 小时」
  static func autoEndTitle(_ minutes: Int) -> String {
    minutes == 0 ? "不结束" : minutes % 60 == 0 ? "\(minutes / 60) 小时" : "\(minutes) 分钟"
  }

  /// 列表行的一行小字：样式 · 电源 · 自动结束，照常、不结束的那一段不写（「透出 · 屏幕常亮」「熄屏 · 5 分钟后结束」）
  var summary: String {
    let power: String? =
      switch power {
      case .normal: nil
      case .awake: "不睡眠"
      case .displayOn: "屏幕常亮"
      }
    let end = autoEndMinutes == 0 ? nil : Self.autoEndTitle(autoEndMinutes) + "后结束"
    return [style.title, power, end].compactMap { $0 }.joined(separator: " · ")
  }

  /// 新加的状态：标题「新状态」、告示样式、不睡眠、不自动结束、不带图标
  static func new(id: String = UUID().uuidString) -> StatusPreset {
    StatusPreset(
      id: id, title: "新状态", detail: nil, symbol: "", style: .sign, power: .awake,
      autoEndMinutes: 0)
  }

  /// 加到末尾；已经有 maxCount 个就不加
  static func adding(_ preset: StatusPreset, to list: [StatusPreset]) -> [StatusPreset] {
    list.count < maxCount ? list + [preset] : list
  }

  /// 删掉一个；至少留一个（只剩一个时不删）
  static func removing(_ id: String, from list: [StatusPreset]) -> [StatusPreset] {
    list.count > 1 ? list.filter { $0.id != id } : list
  }

  /// 上移（-1）/ 下移（+1）一格；到头了、找不到都原样返回
  static func moving(_ id: String, by offset: Int, in list: [StatusPreset]) -> [StatusPreset] {
    guard let index = list.firstIndex(where: { $0.id == id }), list.indices.contains(index + offset)
    else { return list }
    var list = list
    list.swapAt(index, index + offset)
    return list
  }

  /// 列表里缺的自带状态（按 id 认：改过标题的也算还在）
  static func missingBuiltIns(in list: [StatusPreset]) -> [StatusPreset] {
    builtIn.filter { preset in !list.contains { $0.id == preset.id } }
  }

  /// 恢复自带的状态：缺的补到末尾，已有的不动；补到 maxCount 为止
  static func restoringBuiltIns(in list: [StatusPreset]) -> [StatusPreset] {
    Array((list + missingBuiltIns(in: list)).prefix(maxCount))
  }

  /// 删之前要不要确认：和自带的一模一样的不用（「恢复自带的状态」能原样加回来），自己加的、改过的要
  var isPristine: Bool { Self.builtIn.contains(self) }

  /// 详情页改了一个：按 id 换掉。标题只有空白时留着原来的标题——空标题存不下（sanitized 会把整条丢掉），
  /// 而输入框里删光了重打是常事
  static func updating(_ list: [StatusPreset], with draft: StatusPreset) -> [StatusPreset] {
    list.map { stored in
      guard stored.id == draft.id else { return stored }
      var next = draft
      if oneLine(draft.title).isEmpty { next.title = stored.title }
      return next
    }
  }

  /// 详情页里正在改的这一份有什么问题（页头的橙字；nil = 没问题）。不拦着改：存进去的是收拾过的
  var problem: String? {
    let title = Self.oneLine(title)
    if title.isEmpty { return "还没填标题" }
    if title.count > Self.maxTitle { return "标题最多 \(Self.maxTitle) 个字，后面的不会保存" }
    if Self.oneLine(detail ?? "").count > Self.maxDetail {
      return "说明最多 \(Self.maxDetail) 个字，后面的不会保存"
    }
    return nil
  }
}
