// 专注模式滤镜（2026-11-17 拍板 B1–B8，PLAN §10「提醒」）：用户在 系统设置 › 专注模式 › 某个模式 › 专注模式滤镜 里加上
// 「Kitty Tools」的「提醒」滤镜、选到点的提醒怎么出；那个模式开着时系统调 perform()，关掉时再调一次、参数是声明的默认值
// （WWDC22「Meet Focus filters」）——所以默认值必须是「照常」。加滤镜时系统列的推荐配置是「只在刘海上挂图标」
// （suggestedFocusFilters，B2）。公开接口（AppIntents，macOS 13 起），不要授权；不知道是哪个模式、叫什么，也用不着（B1）。
// 没做 App Intents 扩展：App 没开着时系统会不会把它叫起来送 perform() 没实测，所以启动、醒来时都问一次 current（问不到 = 照常）；
// current 回来之前先按偏好里记的上一次（Prefs.remindersFocus，这台电脑自己的：不注册默认值、不导出不同步），免得刚启动那一下
// 把专注期间错过的弹出来。
// ponytail: App 退出期间开关过的只靠启动时那次 current 补；要更准就加一个 App Intents 扩展（多一个 target）。

import AppIntents
import Observation

/// 专注模式开着时，到点的提醒怎么出（滤镜里的选项）
nonisolated enum ReminderFocusStyle: String, AppEnum {
  /// 照常（专注模式关掉时系统送来的也是它）
  case normal
  /// 只在刘海上挂一个图标：不弹出、不出声、不全屏、不催（B2 推荐）
  case light
  /// 什么都不显示，专注模式结束后再响
  case hold

  static let typeDisplayRepresentation: TypeDisplayRepresentation = "到点的提醒"
  static let caseDisplayRepresentations: [ReminderFocusStyle: DisplayRepresentation] = [
    .normal: "照常提醒",
    .light: "只在刘海上挂图标",
    .hold: "先不提醒，结束后再响",
  ]
}

/// 「提醒」这个专注模式滤镜
struct ReminderFocusFilter: SetFocusFilterIntent {
  static let title: LocalizedStringResource = "提醒"
  static let description: IntentDescription? = "这个专注模式开着时，Kitty Tools 到点的提醒怎么出"

  @Parameter(title: "到点的提醒", default: .normal)
  var style: ReminderFocusStyle

  var displayRepresentation: DisplayRepresentation {
    ReminderFocusStyle.caseDisplayRepresentations[style] ?? "照常提醒"
  }

  static func suggestedFocusFilters(for context: FocusFilterSuggestionContext) async -> [Self] {
    let filter = Self()
    filter.style = .light
    return [filter]
  }

  func perform() async throws -> some IntentResult {
    await ReminderFocus.shared.set(style)
    return .result()
  }
}

/// 专注模式滤镜现在说的是哪种：设置 › 提醒 读它写「现在：…」，ReminderCenter 接 onChange
@Observable final class ReminderFocus {
  static let shared = ReminderFocus()
  private(set) var style: ReminderFocusStyle
  @ObservationIgnored var onChange: ((ReminderFocusStyle) -> Void)?

  private init() {
    style =
      UserDefaults.standard.string(forKey: Prefs.remindersFocus).flatMap(
        ReminderFocusStyle.init(rawValue:)) ?? .normal
  }

  /// 系统送来的（perform、启动时的 current）：变了才记、才通知
  func set(_ next: ReminderFocusStyle) {
    guard next != style else { return }
    style = next
    UserDefaults.standard.set(next == .normal ? nil : next.rawValue, forKey: Prefs.remindersFocus)
    onChange?(next)
  }

  /// 问一次系统现在的滤镜（启动、醒来时）。问不到的当照常：记着的「安静」不能一直卡着（评审：滤镜在 App 退出期间被删了、
  /// 专注模式结束了，current 抛错时原来就一直压着、设置里还写着「开着」）
  func refresh() async {
    set((try? await ReminderFocusFilter.current)?.style ?? .normal)
  }
}
