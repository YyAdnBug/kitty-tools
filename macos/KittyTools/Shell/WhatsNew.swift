// 新功能标记（2026-11-05 拍板「全部按推荐」，拍板页 macos/build/research/new-badge-2026-11-05/decisions.html；PLAN §10
// 「新功能标记」；对标 Chrome 菜单里的「New」、iOS 主屏新装 App 名字前的小圆点）：从旧版本升上来后，这一版新加的功能挂一个「新」——
// 右键菜单是系统的菜单徽标（子菜单的父项、「设置…」跟着挂）、主界面是格子名字前的强调色小圆点（底栏「设置」前也是）、设置侧栏是
// 行尾的「新」（收起的组标题后一个小圆点）、设置页里新的那一节是标题后的「新」。菜单栏图标不挂（那个点是「有新版本」）。
// - 标什么：下面的 entries，每版最多 3 个（perVersion），只挑有入口的：新的一族、新动作、设置页里新的一节。修问题、改样子、
//   没有入口的（启动器的汇率这种）不标，交给刘海岛「已更新到 x」和更新日志。发版时挑好写进来；id 发布后别改（「碰过」按它记）。
// - 什么时候出：只有从旧版本升上来的（adopt：上次打开的版本之后、这一版及以前加的都算，跳着升级的中间几版一起标），新装不标；
//   功能关着不标，「已关闭」那组也不汇总（计时照走，过后再打开不补标）。
// - 什么时候没（2026-11-06 用户改：光点进设置页不算）：真用过一次就各处一起没——执行了它的动作（AppDelegate.run(action) 一个
//   口子：菜单、主界面、快捷键、启动器都走它）、拨过它那一行开关（touch(section:of:)；看着的时候不闪掉，换页才没：shown(visiting:)）；
//   升到下一版时上一版（和更早）的一起没（adopting）；一直没碰、也没升级，从这台 Mac 第一次打开那一版起最多挂 30 天（lifetime）。
// - 记账是这台 Mac 自己的（Prefs.whatsNewStarted / whatsNewTouched 不注册默认值：不导出、不同步、不进自动备份）。没有开关、
//   没有「全部标为已看」（拍板 B6）。
// 规则是纯函数（单测喂账本和条目）；读写偏好的几个薄包装给 AppDelegate 用，界面只拿算好的结果（截图自检不碰偏好）。

import AppKit
import SwiftUI

enum WhatsNew {
  /// 一个新功能：在哪几处标
  struct Entry: Equatable {
    /// 记在「碰过」里的名字：发布后别改
    let id: String
    /// 哪一版加的（MARKETING_VERSION）
    let version: String
    /// 归哪个功能：关着就不标；nil = 不归哪个功能（设置 › 通用 里的）
    let feature: Feature?
    /// 它的动作：菜单项、主界面的格子挂标记，执行了任意一个就算碰过
    var actions: [HotKeyAction] = []
    /// 它的设置页：侧栏那一行挂标记，打开过就算碰过
    var page: SettingsPage?
    /// 设置页里新的那一节（或那一行开关）的标题：标题后面挂「新」，进了页面知道新的是哪个；nil = 只标页
    var section: String?
  }

  /// 清单（新的版本往后加）
  static let entries: [Entry] = [
    // 0.7.2（GitHub 上来的）：截图翻译盖回截图上（设置 › 翻译 的开关，PR #5）、启动器不列常用（设置 › 启动器，issue #2）、
    // 钉住剪贴板内容能钉文字（issue #4）
    Entry(
      id: "screenshot-overlay", version: "0.7.2", feature: .translate, page: .translate,
      section: "截图翻译时把译文直接盖回截图上"),
    Entry(
      id: "launcher-frequent", version: "0.7.2", feature: .launcher, page: .launcher,
      section: "空搜索框里列出常用"),
    Entry(id: "pin-text", version: "0.7.2", feature: .screenshot, actions: [.pinClipboard]),
  ]

  /// 一版最多标几个（拍板 B1：标多了到处都是「新」，等于没标）
  static let perVersion = 3
  /// 一直没碰最多挂多久（拍板 B2）
  static let lifetime: TimeInterval = 30 * 24 * 60 * 60
  /// 写出来的那个字
  static let label = "新"
  /// 读屏念的
  static let spoken = "新功能"

  /// 系统菜单的徽标（macOS 14 起；样子、颜色系统定，拍板 C1）
  static var menuBadge: NSMenuItemBadge { NSMenuItemBadge(string: label) }

  /// 这台 Mac 的账：各版本第一次打开的时刻（从这一刻起算 30 天）、碰过哪几个
  struct Ledger: Equatable {
    var started: [String: Date] = [:]
    var touched: Set<String> = []
  }

  // MARK: 规则（纯函数）

  /// 升级上来：上次打开的是 last、这次是 current，(last, current] 里有条目的版本记下从 now 起算；记过的不动（退回旧版本再升回来
  /// 不重新算）。last 是 nil（新装）什么都不记——新装的人每样都是新的，不标（拍板 B3）
  static func adopting(
    _ ledger: Ledger, from last: String?, to current: String, now: Date,
    entries: [Entry] = entries
  ) -> Ledger {
    guard let last else { return ledger }
    var ledger = ledger
    // 真升了一版：上次打开的那一版和更早的不再标（「新」只留到下一版，2026-11-06 用户要的）。记成很久以前开始的（过了 30 天），
    // 不删：删了的话退回旧版本再升上来，中间那版会重新挂一遍。同一版重开、退回旧版本都不动
    if Updater.isNewer(current, than: last) {
      for version in ledger.started.keys where !Updater.isNewer(version, than: last) {
        ledger.started[version] = .distantPast
      }
    }
    for version in Set(entries.map(\.version))
    where Updater.isNewer(version, than: last) && !Updater.isNewer(version, than: current)
      && ledger.started[version] == nil
    {
      ledger.started[version] = now
    }
    return ledger
  }

  /// 此刻要标的：那一版开始标了、没过 30 天、没碰过、功能开着（钟往回拨了的照标）
  static func fresh(
    _ ledger: Ledger, enabled: Set<Feature>, now: Date, entries: [Entry] = entries
  ) -> [Entry] {
    entries.filter { entry in
      guard let start = ledger.started[entry.version], now.timeIntervalSince(start) < lifetime,
        !ledger.touched.contains(entry.id)
      else { return false }
      return entry.feature.map(enabled.contains) ?? true
    }
  }

  /// 碰过对得上的那几个。只记已经开始标的（还没升上来的、新装没标的不记），记过的不重复：没变化就是原样，调用方据此不写偏好
  static func touching(
    _ ledger: Ledger, entries: [Entry] = entries, _ matches: (Entry) -> Bool
  ) -> Ledger {
    var ledger = ledger
    for entry in entries where matches(entry) && ledger.started[entry.version] != nil {
      ledger.touched.insert(entry.id)
    }
    return ledger
  }

  /// 要标的里有没有只在设置里才有入口的（菜单的「设置…」、主界面底栏的「设置」前面挂标记，拍板 A4）
  static func inSettingsOnly(_ fresh: [Entry]) -> Bool {
    fresh.contains { $0.actions.isEmpty && $0.page != nil }
  }

  /// 换到设置的一页时，设置窗里该标哪几个（id）：此刻要标的（碰这一页之前算的），加上这一页原来就标着的——看着的时候不闪掉，
  /// 换到别的页才没（上一页的那几个已经碰过，不在 fresh 里、也不是这一页的）
  static func shown(
    visiting page: SettingsPage, fresh: [Entry], showing: Set<String>, entries: [Entry] = entries
  ) -> Set<String> {
    let mine = Set(entries.filter { $0.page == page }.map(\.id))
    return Set(fresh.map(\.id)).union(showing.intersection(mine))
  }

  /// 设置窗里这一页要不要标（侧栏那一行、收起的组）：ids 是 shown 算出来的那一份
  static func marks(_ page: SettingsPage, in ids: Set<String>) -> Bool {
    entries.contains { ids.contains($0.id) && $0.page == page }
  }

  /// 设置页里这一节要不要标
  static func marks(section: String, of page: SettingsPage, in ids: Set<String>) -> Bool {
    entries.contains { ids.contains($0.id) && $0.page == page && $0.section == section }
  }

  // MARK: 这台 Mac 的账（偏好；AppDelegate 用）

  static func ledger(_ defaults: UserDefaults = .standard) -> Ledger {
    Ledger(
      started: defaults.dictionary(forKey: Prefs.whatsNewStarted)?.compactMapValues { $0 as? Date }
        ?? [:],
      touched: Set(defaults.stringArray(forKey: Prefs.whatsNewTouched) ?? []))
  }

  /// 改账：没变化不写（每执行一次动作都会来问一遍）
  private static func update(_ defaults: UserDefaults, _ change: (Ledger) -> Ledger) {
    let old = ledger(defaults)
    let new = change(old)
    guard new != old else { return }
    if new.started != old.started { defaults.set(new.started, forKey: Prefs.whatsNewStarted) }
    if new.touched != old.touched {
      defaults.set(new.touched.sorted(), forKey: Prefs.whatsNewTouched)
    }
  }

  /// 启动时（记「看过这一版」之前）：从 last 升到 current
  static func adopt(
    upgradingFrom last: String?, to current: String, defaults: UserDefaults = .standard,
    now: Date = .now
  ) {
    update(defaults) { adopting($0, from: last, to: current, now: now) }
  }

  /// 此刻要标的（功能开没开现读）
  static func current(_ defaults: UserDefaults = .standard, now: Date = .now) -> [Entry] {
    fresh(ledger(defaults), enabled: Feature.enabled, now: now)
  }

  /// 执行了一个动作
  static func touch(action: HotKeyAction, defaults: UserDefaults = .standard) {
    update(defaults) { touching($0) { $0.actions.contains(action) } }
  }

  /// 拨了设置页里新的那一行开关（Entry.section 是它的标题）。光打开那一页不算（2026-11-06）
  static func touch(section: String, of page: SettingsPage, defaults: UserDefaults = .standard) {
    update(defaults) { touching($0) { $0.page == page && $0.section == section } }
  }
}

/// 自己画的界面里的小圆点（主界面格子的名字前、底栏「设置」前、设置侧栏收起的组标题后；iOS 主屏新装 App 的那种）：6 pt 强调色
struct NewDot: View {
  var body: some View {
    Circle()
      .fill(Style.brand)
      .frame(width: 6, height: 6)
      .accessibilityLabel(WhatsNew.spoken)
  }
}

/// 设置页里一行开关的标题，这一版新加、还没换过页时后面跟一个「新」（WhatsNew.Entry.section 写的就是这个标题）
struct NewTitle: View {
  let title: String
  let page: SettingsPage
  let fresh: Set<String>

  init(_ title: String, page: SettingsPage, fresh: Set<String>) {
    self.title = title
    self.page = page
    self.fresh = fresh
  }

  var body: some View {
    HStack(spacing: 6) {
      Text(title)
      if WhatsNew.marks(section: title, of: page, in: fresh) { NewTag() }
    }
  }
}

/// 设置页里新的那一节，标题后面的「新」：强调色描边的小胶囊（菜单、侧栏行尾的是系统画的徽标）
struct NewTag: View {
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    Text(WhatsNew.label)
      .font(.system(size: 10, weight: .semibold))
      .foregroundStyle(Style.brandInk)
      .padding(.horizontal, 5)
      .frame(height: 15)
      .overlay(Capsule().strokeBorder(Style.brand, lineWidth: contrast == .increased ? 1.5 : 1))
      .fixedSize()
      .accessibilityLabel(WhatsNew.spoken)
  }
}
