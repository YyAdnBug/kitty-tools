// 提醒和专注模式（2026-11-17 拍板 B1–B8，2026-11-17 晚改成认任何专注模式：拍板 B2，PLAN §10「提醒」）。
// 两样合起来算「现在到点的提醒怎么出」：
// ① 系统现在开着哪个专注模式（Shell/SystemFocus.swift 读系统日志，不要授权）：开着任何一个就按设置 › 提醒「专注模式开着时」
//    （Prefs.remindersDuringFocus，默认只在刘海上挂图标）；
// ② 专注模式滤镜：用户在 系统设置 › 专注模式 › 某个模式 › 专注模式滤镜 里加了 Kitty Tools 的「提醒」、另选了的，那个模式
//    开着时以滤镜为准（想「只让某几个模式静音」：设置里选照常，给那几个模式加滤镜）。系统在模式开着时调 perform()，关掉时
//    再调一次、参数是声明的默认值（WWDC22「Meet Focus filters」）——所以默认值必须是「跟着 Kitty 的设置」（follow），它也就是
//    「这个模式没有另选」。加滤镜时系统列的推荐配置是「只在刘海上挂图标」（suggestedFocusFilters）。公开接口（AppIntents），
//    不要授权。
// 系统日志读不到时只剩 ②（SystemFocus.isReadable）。单条提醒的「专注模式时也照常提醒」（Reminder.duringFocus）照旧最优先，
// 在 ReminderCenter 里算。
// 没做 App Intents 扩展：App 没开着时系统会不会把它叫起来送 perform() 没实测，所以启动、醒来时都问一次 current（问不到 = 没另选）；
// current 回来之前先按偏好里记的上一次（Prefs.remindersFocus，这台电脑自己的：不注册默认值、不导出不同步），免得刚启动那一下
// 把专注期间错过的弹出来。
// ponytail: App 退出期间开关过的只靠启动时那次 current 补；要更准就加一个 App Intents 扩展（多一个 target）。

import AppIntents
import Observation

/// 专注模式开着时，到点的提醒怎么出（滤镜里的选项；设置 › 提醒只有后三种）
nonisolated enum ReminderFocusStyle: String, AppEnum {
  /// 跟着 Kitty 的设置：滤镜的默认值（= 这个模式没另选；专注模式关掉时系统送来的也是它）
  case follow
  /// 照常
  case normal
  /// 只在刘海上挂一个图标：不弹出、不出声、不全屏、不催（B2 推荐）
  case light
  /// 什么都不显示，专注模式结束后再响
  case hold

  static let typeDisplayRepresentation: TypeDisplayRepresentation = "到点的提醒"
  static let caseDisplayRepresentations: [ReminderFocusStyle: DisplayRepresentation] = [
    .follow: "跟着 Kitty 的设置",
    .normal: "照常提醒",
    .light: "只在刘海上挂图标",
    .hold: "先不提醒，结束后再响",
  ]
}

/// 「提醒」这个专注模式滤镜
struct ReminderFocusFilter: SetFocusFilterIntent {
  static let title: LocalizedStringResource = "提醒"
  static let description: IntentDescription? = "这个专注模式开着时，Kitty Tools 到点的提醒怎么出"

  @Parameter(title: "到点的提醒", default: .follow)
  var style: ReminderFocusStyle

  var displayRepresentation: DisplayRepresentation {
    ReminderFocusStyle.caseDisplayRepresentations[style] ?? "跟着 Kitty 的设置"
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

/// 现在到点的提醒怎么出（滤镜 + 系统现在的专注模式 + 设置合起来，effective）：设置 › 提醒 读它写「现在：…」，
/// ReminderCenter 接 onChange
@Observable final class ReminderFocus {
  static let shared = ReminderFocus()
  /// 合起来的：照常 / 挂图标 / 先不提醒（不会是 follow）
  private(set) var style = ReminderFocusStyle.normal
  /// 滤镜现在说的（follow = 现在开着的模式没另选、或者没开专注模式）
  private(set) var filter: ReminderFocusStyle
  /// 系统现在开着的专注模式（SystemFocus 给；读不到日志时是 nil）
  private(set) var mode: SystemFocus.Mode?
  @ObservationIgnored var onChange: ((ReminderFocusStyle) -> Void)?

  private init() {
    filter =
      UserDefaults.standard.string(forKey: Prefs.remindersFocus).flatMap(
        ReminderFocusStyle.init(rawValue:)) ?? .follow
    style = Self.effective(filter: filter, focused: false, setting: Self.setting)
  }

  /// 合起来怎么出（纯函数）：滤镜另选了的以滤镜为准；不然开着专注模式时按设置，没开时照常
  nonisolated static func effective(
    filter: ReminderFocusStyle, focused: Bool, setting: ReminderFocusStyle
  ) -> ReminderFocusStyle {
    if filter != .follow { return filter }
    guard focused else { return .normal }
    return setting == .follow ? .light : setting
  }

  /// 设置 › 提醒「专注模式开着时」（读不出来是默认的挂图标）
  static var setting: ReminderFocusStyle {
    UserDefaults.standard.string(forKey: Prefs.remindersDuringFocus).flatMap(
      ReminderFocusStyle.init(rawValue:)) ?? .light
  }

  /// 滤镜送来的（perform、启动时的 current）
  func set(_ next: ReminderFocusStyle) {
    guard next != filter else { return }
    filter = next
    UserDefaults.standard.set(next == .follow ? nil : next.rawValue, forKey: Prefs.remindersFocus)
    update()
  }

  /// 系统的专注模式变了（SystemFocus.onChange）
  func set(mode next: SystemFocus.Mode?) {
    guard next != mode else { return }
    mode = next
    update()
  }

  /// 偏好变了（AppDelegate）：设置里换了「专注模式开着时」
  func settingChanged() { update() }

  private func update() {
    let next = Self.effective(filter: filter, focused: mode != nil, setting: Self.setting)
    guard next != style else { return }
    style = next
    onChange?(next)
  }

  /// 问一次系统现在的滤镜（启动、醒来时）。问不到的当没另选：记着的「安静」不能一直卡着（评审：滤镜在 App 退出期间被删了、
  /// 专注模式结束了，current 抛错时原来就一直压着、设置里还写着「开着」）
  func refresh() async {
    set((try? await ReminderFocusFilter.current)?.style ?? .follow)
  }
}
