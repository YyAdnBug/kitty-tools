// 新功能标记（2026-11-05 拍板「全部按推荐」，拍板页 macos/build/research/new-badge-2026-11-05/decisions.html；PLAN §10
// 「新功能标记」；对标 Chrome 菜单里的「New」、iOS 主屏新装 App 名字前的小圆点）：从旧版本升上来后，这一版新加的功能挂一个「新」——
// 右键菜单是系统的菜单徽标（子菜单的父项、「设置…」跟着挂）、主界面是格子名字前的强调色小圆点（底栏「设置」前也是）、设置侧栏是
// 行尾的「新」（收起的组标题后一个小圆点）、设置页里新的那一节是标题后的「新」。菜单栏图标不挂（那个点是「有新版本」）。
// - 标什么：下面的 entries，每版最多 3 个（perVersion），只挑有入口的：新的一族、新动作、设置页里新的一节。修问题、改样子、
//   没有入口的（启动器的汇率这种）不标，交给刘海岛「已更新到 x」和更新日志。发版时挑好写进来；id 发布后别改（「碰过」按它记）。
// - 什么时候出：只有从旧版本升上来的（adopt：上次打开的版本之后、这一版及以前加的都算，跳着升级的中间几版一起标），新装不标；
//   功能关着不标，「已关闭」那组也不汇总（计时照走，过后再打开不补标）。
// - 什么时候没（2026-11-06 用户改：光点进设置页不算）：真用过一次就各处一起没——执行了它的动作（AppDelegate.run(action) 一个
//   口子：菜单、主界面、快捷键、启动器都走它）、拨过它那一节 / 那一行的开关（touch(section:of:)；看着的时候不闪掉，换页才没：
//   shown(visiting:)）；升到下一版时上一版（和更早）的一起没（adopting）；一直没碰、也没升级，从这台 Mac 第一次打开那一版起最多挂
//   30 天（lifetime）。
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
    /// 设置页里新的那一节（或那一行开关）的标题：标题后面挂「新」，进了页面知道新的是哪个；nil = 只标页。
    /// 按目录的 key 认那一节（多语言：不拿显示出来的字比，换了语言也对得上；页里写的是同一句中文就是同一个 key）
    var section: LocalizedStringResource?
    /// 新插件（插件页改版 E1）：插件默认不添加，按 feature 就永远标不上——这种条目没添加时标（「全部插件」那一行、
    /// 侧栏「全部插件」，page 写 .plugins），添加着不标，添加的那一刻算碰过（之后移除也不再标）。feature 写 nil
    var plugin: Feature?
  }

  /// 清单（新的版本往后加）
  static let entries: [Entry] = [
    // 0.7.2（GitHub 上来的，release-0.7.2 发布分支上同一份）：截图翻译盖回截图上（设置 › 翻译 的开关，PR #5）、
    // 启动器不列常用（设置 › 启动器，issue #2）、钉住剪贴板内容能钉文字（issue #4）。从 0.7.1 直接跳到 0.8.0 的也标
    Entry(
      id: "screenshot-overlay", version: "0.7.2", feature: .translate, page: .translate,
      section: "截图翻译时把译文直接盖回截图上"),
    Entry(
      id: "launcher-frequent", version: "0.7.2", feature: .launcher, page: .launcher,
      section: "空搜索框里列出常用"),
    Entry(id: "pin-text", version: "0.7.2", feature: .screenshot, actions: [.pinClipboard]),
    // 0.7.3（release-0.7.3 发布分支上同一份）：截图拷贝为 PNG 文件、框选时保持屏幕原色（都在 设置 › 截图）
    Entry(
      id: "screenshot-copy-as-file", version: "0.7.3", feature: .screenshot, page: .screenshot,
      section: "截图拷贝为"),
    Entry(
      id: "screenshot-keeps-colors", version: "0.7.3", feature: .screenshot, page: .screenshot,
      section: "框选时保持屏幕原色"),
    Entry(
      id: "reminders", version: "0.8.0", feature: .reminders, actions: [.reminderNew],
      page: .reminders),
    Entry(id: "features", version: "0.8.0", feature: nil, page: .general, section: "功能"),
    Entry(
      id: "launcher-scripts", version: "0.8.0", feature: .launcher, page: .launcher,
      section: "脚本命令"),
    // 0.8.1：应用别名（设置 › 启动器，PR #13）、按 App 停用快捷键（设置 › 快捷键 最下面一节）。按使用习惯排 App、
    // iPad App 的中文名、几处修问题没有入口，不标
    Entry(
      id: "app-aliases", version: "0.8.1", feature: .launcher, page: .launcher,
      section: "应用别名"),
    Entry(
      id: "hotkey-block", version: "0.8.1", feature: nil, page: .hotkeys,
      section: "在这些 App 里停用"),
    // 0.9.0（拍板 D9）：插件（设置 › 通用「功能」那一行：便签这些挪进了插件；添加 / 移除一个就算看过）、
    // 设置 › 刘海岛 里新的「正在播放」（刘海岛插件的页，拨过那个开关算看过；原来挑的是「系统提示」，正在播放进 0.9.0 后换成它，
    // 一版最多 3 个）、设置 › 通用「同步」能连 WebDAV 服务器
    // （issue #18，点过「连接服务器…」算看过）。截图标注的新东西在框选后的工具栏里、刘海两边的活动和两指下滑没有入口，不标
    // 2026-11-17 插件页改版：插件挪进「全部插件」，这一条改标通用页「插件 ›」那一行（id 不变），添加 / 移除过一个插件算看过
    Entry(id: "plugins", version: "0.9.0", feature: nil, page: .general, section: "插件"),
    Entry(
      id: "island-now-playing", version: "0.9.0", feature: .island, page: .island,
      section: "正在播放"),
    Entry(id: "sync-server", version: "0.9.0", feature: nil, page: .general, section: "同步"),
    // 0.10.0（多语言）：设置 › 通用「语言」那一行（拨过算看过；只有升级上来的标，升级的保持了中文，这一行告诉他能换）。
    // 英文界面本身、搜索中英都认、自带脚本说英文没有单独的入口，不标
    Entry(
      id: "interface-language", version: "0.10.0", feature: nil, page: .general,
      section: GeneralTab.languageLabel),
    // 0.10.0 另有 设置 › 截图「也认网页里的元素」（截图识别元素第三轮，拨过算看过；0.10.1 设置改版并进高级里的「悬停时识别」）
    Entry(
      id: "screenshot-web-elements", version: "0.10.0", feature: .screenshot, page: .screenshot,
      section: "悬停时识别"),
    // 0.10.0 的四个新插件（插件页改版 E1）：没添加时在「全部插件」那一行、侧栏「全部插件」上标，添加了算碰过；四个算一个
    Entry(
      id: "plugin-keep-awake", version: "0.10.0", feature: nil, page: .plugins, plugin: .keepAwake),
    Entry(
      id: "plugin-bluetooth-snooze", version: "0.10.0", feature: nil, page: .plugins,
      plugin: .bluetoothSnooze),
    Entry(
      id: "plugin-smooth-scroll", version: "0.10.0", feature: nil, page: .plugins,
      plugin: .smoothScroll),
    Entry(
      id: "plugin-app-shortcuts", version: "0.10.0", feature: nil, page: .plugins,
      plugin: .appShortcuts),
    // 0.10.1：延时截图（新动作：菜单、主界面、快捷键，用过一次算看过）、设置 › 访达右键「在访达里用 ⌘X 剪切、⌘V 移动」
    // （拨过算看过）、设置 › 翻译 › 查词与朗读「朗读速度」（选过一档算看过；推进行跟着挂，SettingsItem.subpageIsNew）。
    // 设置改版和搜索落到行（整个设置窗都变了，挂哪都不对）、讲解外文句子和附加要求（在每个大模型服务的详情里，列表上没有一处能挂）、
    // 启动器路径模式和搜菜单项（打字就出来，没有入口）、窗口截图的阴影（截图 › 高级里的一行，改样子）不标，交给更新日志
    Entry(
      id: "delayed-screenshot", version: "0.10.1", feature: .screenshot,
      actions: [.delayedScreenshot]),
    Entry(
      id: "finder-keys", version: "0.10.1", feature: .finderMenu, page: .finderMenu,
      section: "在访达里用 ⌘X 剪切、⌘V 移动"),
    Entry(
      id: "speech-speed", version: "0.10.1", feature: .translate, page: .translate,
      section: "朗读速度"),
    // 0.10.2：设置 › 截图「截图圆角」（拖过算看过）——升上来以后截出来的图默认就是圆角、四角透明，标出来让人知道在哪调。
    // 剪贴板图片行、空格放大预览、空闲释放识字模型（都在面板里或「高级…」里，默认样子就看得到 / 没变）、App 快捷键面板改版、
    // 安全输入的小锁和录键提醒（改样子、修问题）不标，交给更新日志
    Entry(
      id: "screenshot-corner-radius", version: "0.10.2", feature: .screenshot, page: .screenshot,
      section: "截图圆角"),
    // 0.10.3：新插件「键位映射」（没添加时在侧栏「插件」那一行标，添加了算碰过）、剪贴板的片段展开和新的全局动作
    // 「暂停 / 继续录制」（不设默认快捷键，录制时菜单、主界面、快捷键页标，用过一次算看过）。启动台「隐藏的 App」
    // （推进行没接「新」）、录屏暂停本身（HUD 上的按钮）、美化与提速（改样子、提速）不标，交给更新日志
    // 片段展开（11-24 起是剪贴板的一项，不是插件）：设置 › 剪贴板「打关键词展开片段」那一行标，拨过、存过一个关键词算看过
    Entry(
      id: "snippet-expand", version: "0.10.3", feature: .clipboard, page: .clipboard,
      section: "打关键词展开片段"),
    Entry(
      id: "plugin-key-remapping", version: "0.10.3", feature: nil, page: .plugins,
      plugin: .keyRemapping),
    Entry(id: "record-pause", version: "0.10.3", feature: .record, actions: [.recordPause]),
  ]

  /// 一版最多标几个（拍板 B1：标多了到处都是「新」，等于没标）。同一版的几个新插件算一个：都只标在「全部插件」一处
  static let perVersion = 3
  /// 一直没碰最多挂多久（拍板 B2）
  static let lifetime: TimeInterval = 30 * 24 * 60 * 60
  /// 写出来的那个字
  static var label: String { String(localized: "新", comment: "新功能标记：菜单徽标、设置页标题后的小胶囊") }
  /// 读屏念的
  static var spoken: String { String(localized: "新功能") }

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
      // 这台用不了的插件（台式机上的睡眠关蓝牙、15 上的启动台）不标：「全部插件」里没有它，碰不掉（评审 1）
      if let plugin = entry.plugin { return plugin.isAvailable && !enabled.contains(plugin) }
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

  /// 插件页里这个插件的那一行要不要标：新插件本身，或者它自己那一页里有新东西（2026-11-23 插件侧栏改版 N3：插件的页不在侧栏、
  /// 从这一行推进，标在页里的新功能从外面也要看得到）
  static func marks(plugin: Feature, in ids: Set<String>) -> Bool {
    entries.contains { ids.contains($0.id) && ($0.plugin == plugin || $0.page == plugin.page) }
  }

  /// 侧栏「插件」那一行要不要标（N3）：插件页自己的（新插件），加上各插件页里的
  static func marksPlugins(in ids: Set<String>) -> Bool {
    entries.contains { ids.contains($0.id) && $0.page?.sidebarPage == .plugins }
  }

  /// 设置页里这一节要不要标（按 key 比）
  static func marks(
    section: LocalizedStringResource, of page: SettingsPage, in ids: Set<String>
  ) -> Bool {
    entries.contains { ids.contains($0.id) && $0.page == page && $0.section?.key == section.key }
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

  /// 添加了一个插件（AppDelegate.applyFeatures：从哪儿添加的都算，同步来的也算）
  static func touch(plugin: Feature, defaults: UserDefaults = .standard) {
    update(defaults) { touching($0) { $0.plugin == plugin } }
  }

  /// 拨了设置页里新的那一节 / 那一行的开关（Entry.section 是它的标题）。光打开那一页不算（2026-11-06）
  static func touch(
    section: LocalizedStringResource, of page: SettingsPage, defaults: UserDefaults = .standard
  ) {
    update(defaults) { touching($0) { $0.page == page && $0.section?.key == section.key } }
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
  let title: LocalizedStringResource
  let page: SettingsPage
  let fresh: Set<String>

  init(_ title: LocalizedStringResource, page: SettingsPage, fresh: Set<String>) {
    self.title = title
    self.page = page
    self.fresh = fresh
  }

  var body: some View {
    HStack(spacing: 6) {
      Text(plain: title)
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
