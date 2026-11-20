// AppDelegate 里菜单栏图标的菜单（第五轮体检 H1 从 AppDelegate.swift 拆出）：每次打开前按快捷键页的分节重建，保持唤醒、提醒的子菜单，停用快捷键那一项。

import AppKit
import SwiftUI

extension AppDelegate {
  /// 菜单栏「保持唤醒」一项带子菜单（第一个插件，拍板 B2）：开着时项名后面写还剩多久，子菜单第一项「停止保持唤醒」；
  /// 没开时「开始（无限期）」（带全局快捷键）和几档时长；定时的时段里另有一行灰字写到几点；最后「保持唤醒设置…」
  private func addKeepAwakeMenu(to menu: NSMenu, isNew: Bool) {
    let family = HotKeyAction.keepAwake
    let color = NSColor(family.color)
    let title: LocalizedStringResource =
      keepAwake.isActive ? "\(family.title) · \(keepAwake.status())" : family.titleResource
    let item = menu.addAction(title, symbol: family.symbol, color: color) {}
    if isNew { item.badge = WhatsNew.menuBadge }
    let submenu = NSMenu()
    // 定时那一行要灰着（只是告诉你到几点）：自动启用会把它点亮
    submenu.autoenablesItems = false
    let hotKey = hotKeys.bindings[family]
    if keepAwake.sessionEnd != nil {
      submenu.addAction(
        "停止保持唤醒", symbol: "stop.circle", color: color, key: hotKey?.menuKeyEquivalent ?? "",
        modifiers: hotKey?.modifierFlags ?? []
      ) { [unowned self] in keepAwake.end() }
    } else {
      if keepAwake.inSchedule {
        let line = submenu.addAction("\(keepAwake.status())", symbol: "clock", color: color) {}
        line.isEnabled = false
        submenu.addItem(.separator())
      }
      for preset in KeepAwakePlan.presets {
        let key = preset.minutes == nil ? hotKey : nil
        let title: LocalizedStringResource =
          preset.minutes == nil ? "开始（无限期）" : "\(preset.title)"
        submenu.addAction(
          title, symbol: "timer", color: color,
          key: key?.menuKeyEquivalent ?? "", modifiers: key?.modifierFlags ?? []
        ) { [unowned self] in
          keepAwake.begin(
            until: preset.minutes.map { Date.now.addingTimeInterval(Double($0 * 60)) },
            label: preset.title)
        }
      }
    }
    submenu.addItem(.separator())
    submenu.addAction(
      "保持唤醒设置…", symbol: MenuExtra.settings.symbol, color: NSColor(MenuExtra.settings.color)
    ) { [unowned self] in showSettings(page: .keepAwake) }
    item.submenu = submenu
  }

  /// 菜单栏「提醒」一项带子菜单（提醒 D6）：新建提醒…（带全局快捷键）、下一个是什么、几分钟后提醒我、
  /// 暂停全部 / 恢复、管理提醒…
  /// isNew：提醒是这一版新加的、还没碰过（新功能标记）：「提醒」和「新建提醒…」都挂「新」（子菜单的父项跟着挂，拍板 A4）
  private func addReminderMenu(to menu: NSMenu, isNew: Bool) {
    let family = HotKeyAction.reminderNew
    let color = NSColor(family.color)
    let item = menu.addAction(
      SettingsPage.reminders.titleResource, symbol: family.symbol, color: color
    ) {}
    let submenu = NSMenu()
    let hotKey = hotKeys.bindings[family]
    let create = submenu.addAction(
      "\(family.title)…", symbol: "plus", color: color, key: hotKey?.menuKeyEquivalent ?? "",
      modifiers: hotKey?.modifierFlags ?? []
    ) { [unowned self] in run(family) }
    if isNew {
      item.badge = WhatsNew.menuBadge
      create.badge = WhatsNew.menuBadge
    }
    if let next = reminders.nextUp() {
      let when = Reminder.Schedule(kind: .once, date: next.at).summary(
        now: .now, calendar: .current)
      submenu.addAction("下一个：\(next.reminder.displayTitle)（\(when)）", symbol: "clock", color: color)
      {
        [unowned self] in openReminder(next.reminder.id)
      }
    }
    submenu.addItem(.separator())
    for minutes in [5, 10, 25, 60] {
      submenu.addAction(
        minutes == 60 ? "1 小时后提醒我" : "\(minutes) 分钟后提醒我",
        symbol: "timer", color: color
      ) { [unowned self] in
        // 子菜单里的快捷提醒也算用过提醒（新功能标记）
        WhatsNew.touch(action: family)
        addReminder(
          Reminder(
            id: UUID().uuidString, title: ReminderPhrase.defaultTitle,
            schedule: .init(kind: .once, date: .now.addingTimeInterval(Double(minutes * 60)))))
      }
    }
    submenu.addItem(.separator())
    if let until = reminders.pausedUntil {
      // 今天之内只写钟点；到明天的带上哪天（「暂停到明天 8:00」，第五轮体检 E6）
      let title: LocalizedStringResource =
        Calendar.current.isDateInToday(until)
        ? "恢复提醒（暂停到 \(until.formatted(date: .omitted, time: .shortened))）"
        : "恢复提醒（暂停到\(Self.pauseDay(until))）"
      submenu.addAction(title, symbol: "play.circle", color: color) { [unowned self] in
        reminders.pause(until: nil)
        island.show("提醒恢复了", tone: .success, symbol: "checkmark.circle.fill")
      }
    } else {
      // 「暂停到明天」= 明天第一个时段开始，没设时段的到 8:00；半夜之后、今天的还没到时是今天的（E6：原来到 0:00 就结束，
      // 周六零点弹出工作日的提醒）。菜单上直接写到几点：今天的只写钟点。菜单每次打开时重建，时刻是打开那一刻算的
      func pauseItem(_ title: LocalizedStringResource, until: Date) {
        submenu.addAction(title, symbol: "pause.circle", color: color) { [unowned self] in
          reminders.pause(until: until)
          let time = until.formatted(date: .omitted, time: .shortened)
          // 英文句中的 tomorrow 小写：明天的单独一句，不拼摘要里的「Tomorrow at」
          let notice: LocalizedStringResource =
            if Calendar.current.isDateInToday(until) {
              "提醒暂停到 \(time)"
            } else if Calendar.current.isDateInTomorrow(until) {
              "提醒暂停到明天 \(time)"
            } else {
              "提醒暂停到\(Self.pauseDay(until))"
            }
          island.show(notice, detail: "这期间到点的，之后合成一条告诉你", tone: .info)
        }
      }
      pauseItem("暂停全部提醒 1 小时", until: .now.addingTimeInterval(3600))
      let morning = reminders.pauseUntilTomorrow()
      let title: LocalizedStringResource =
        Calendar.current.isDateInToday(morning)
        ? "暂停到 \(morning.formatted(date: .omitted, time: .shortened))"
        : "暂停到\(Self.pauseDay(morning))"
      pauseItem(title, until: morning)
    }
    submenu.addItem(.separator())
    submenu.addAction(
      "管理提醒…", symbol: MenuExtra.settings.symbol, color: NSColor(MenuExtra.settings.color)
    ) { [unowned self] in showSettings(page: .reminders) }
    item.submenu = submenu
  }

  /// 暂停到哪天几点的说法：「今天 15:30」「明天 8:00」「11月3日 8:00」（同提醒摘要里一次性的时间）
  private static func pauseDay(_ until: Date) -> String {
    Reminder.Schedule(kind: .once, date: until).summary(now: .now, calendar: .current)
  }

  // MARK: 菜单栏菜单

  /// 每次打开菜单前重建（N15）：按 HotKeyAction.sections 分节，和快捷键页同名同序，标题、符号、家族色也取自那里；
  /// 右边是当前生效的快捷键，没设 / 注册失败的留空；每节末尾接上那一节的 MenuExtra（暂停记录剪贴板、复制即译、
  /// 有钉图时的两项）；有新版本时最上面是「更新到 x…」；最后是设置、关于、检查更新（正式版）、退出。
  /// 状态屏那一节不画节标题，只有一项「状态屏」带子菜单：最上面「选择状态…」带全局快捷键（按它就是打开选状态的面板），
  /// 分隔线下面每个状态一行、点了直接进入；设置里打开「按快捷键直接进入排在最前面的状态」时没有「选择状态…」，
  /// 键位写在第一个状态右边（它进的就是那个）。各状态行的图标是它的表情（静止画面），没选的用家族色的符号垫。
  /// 最下面「管理状态…」打开 设置 › 状态屏
  func buildStatusMenu(_ menu: NSMenu) {
    let state = menuState
    let extras = MenuExtra.allCases.filter { $0.isAvailable(state) }
    // 新功能标记（WhatsNew）：这一版新加、还没碰过的动作挂系统的菜单徽标「新」；只在设置里才有入口的，挂在「设置…」上
    let fresh = WhatsNew.current()
    let freshActions = Set(fresh.flatMap(\.actions))
    func addExtra(_ extra: MenuExtra) {
      let item = menu.addAction(
        extra.titleResource(pinsHidden: state.pinsHidden == true), symbol: extra.symbol,
        color: NSColor(extra.color), key: extra == .settings ? "," : extra == .quit ? "q" : ""
      ) { [unowned self] in run(extra) }
      if let on = extra.isOn(state) { item.state = on ? .on : .off }
      if extra == .settings, WhatsNew.inSettingsOnly(fresh) { item.badge = WhatsNew.menuBadge }
    }
    // 别的 App 开着安全输入、挡着只带 ⌥ 的快捷键（issue #27）：最上面一行说是谁开着、小字说怎么关。只是说明，点不了
    // （没有动作的菜单项系统自动画成灰的）；和菜单栏图标的小锁、主界面那行橙字同一份字
    if let block = hotKeys.secureInputBlock() {
      let item = NSMenuItem(title: block.summary, action: nil, keyEquivalent: "")
      item.subtitle = block.advice
      item.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(hierarchicalColor: .systemOrange))
      menu.addItem(item)
      menu.addItem(.separator())
    }
    // 有新版本时最上面一项就是更新（强调色：现在该操作的东西）；跳过了的版本不挂（X11）
    if let release = updater.nudge {
      if let obstacle = updater.obstacle {
        // 这份 App 原地换不了（第五轮体检 E10）：改成去发布页，下面一行小字写原因
        let item = menu.addAction(
          "到发布页下载 \(release.version)", symbol: "arrow.down.circle.fill",
          color: NSColor(Style.brand)
        ) { [unowned self] in updater.openPage(release) }
        item.subtitle = obstacle.summary
        item.toolTip = obstacle.reason
      } else {
        menu.addAction(
          "更新到 \(release.version)…", symbol: "arrow.down.circle.fill", color: NSColor(Style.brand)
        ) { [unowned self] in Task { await updater.install() } }
      }
      menu.addItem(.separator())
    }
    // 「打开主界面」不进菜单：菜单和主界面是同一个图标的两半（右键 / 左键）
    for (index, section) in HotKeyAction.sections.filter({ $0.actions != [.home] }).enumerated() {
      if index > 0 { menu.addItem(.separator()) }
      if section.actions == [.reminderNew] {
        addReminderMenu(to: menu, isNew: freshActions.contains(.reminderNew))
        continue
      }
      if section.actions == [.keepAwake] {
        addKeepAwakeMenu(to: menu, isNew: freshActions.contains(.keepAwake))
        continue
      }
      if section.actions == [.statusScreen] {
        let family = HotKeyAction.statusScreen
        let color = NSColor(family.color)
        let item = menu.addAction(family.titleResource, symbol: family.symbol, color: color) {}
        if freshActions.contains(family) { item.badge = WhatsNew.menuBadge }
        let submenu = NSMenu()
        let hotKey = hotKeys.bindings[family]
        if !state.statusEntersFirst {
          submenu.addAction(
            "选择状态…", symbol: "square.grid.2x2.fill", color: color,
            key: hotKey?.menuKeyEquivalent ?? "", modifiers: hotKey?.modifierFlags ?? []
          ) { [unowned self] in run(family) }
          submenu.addItem(.separator())
        }
        for (row, preset) in state.statusPresets.enumerated() {
          let binding = state.statusEntersFirst && row == 0 ? hotKey : nil
          let entry = submenu.addAction(
            "\(preset.displayTitle)", symbol: StatusPreset.plainSymbol,
            color: color, key: binding?.menuKeyEquivalent ?? "",
            modifiers: binding?.modifierFlags ?? []
          ) { [unowned self] in statusScreen.enter(preset) }
          if let emoji = StatusEmoji.menuImage(preset.symbol) { entry.image = emoji }
        }
        submenu.addItem(.separator())
        submenu.addAction(
          "管理状态…", symbol: MenuExtra.settings.symbol, color: NSColor(MenuExtra.settings.color)
        ) { [unowned self] in showSettings(page: .statusScreen) }
        item.submenu = submenu
        continue
      }
      // 只有一项、节标题和它同名的不画节标题（F40：启动台那一节；关掉剪贴板后只剩「启动器」的那一节同理；
      // 状态屏那一节在上面单独处理）
      // 按目录的 key 比（不比显示的字）：节标题是「启动台」、唯一那一项也是「启动台」
      if !(section.actions.count == 1 && section.key == section.actions[0].titleResource.key) {
        menu.addItem(.sectionHeader(title: section.title))
      }
      for action in section.actions {
        let binding = hotKeys.bindings[action]
        let item = menu.addAction(
          "\(action.title(recording: state.isRunning(action)))", symbol: action.symbol,
          color: NSColor(action.color),
          key: binding?.menuKeyEquivalent ?? "", modifiers: binding?.modifierFlags ?? []
        ) { [unowned self] in run(action) }
        if freshActions.contains(action) { item.badge = WhatsNew.menuBadge }
      }
      for extra in extras where section.actions.contains(where: { $0 == extra.section }) {
        addExtra(extra)
      }
    }
    // 功能全关了时上面没有节：别让菜单以一条分隔线开头
    if menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
    addHotKeyBlockItem(to: menu)
    // 速查表只在启动器里（菜单里在 设置 › 快捷键）；退出排在最后
    for extra in extras where extra.section == nil && extra != .shortcuts { addExtra(extra) }
  }

  /// 「在「某 App」中停用 / 恢复快捷键」（HotKeyBlock，2026-11-10）：点菜单栏图标不激活本 App，前台还是撞键的那个 App。
  /// 前台是本 App、访达（含桌面）或不是普通 App 时没有这一项。停用加的是「全部快捷键」，恢复把那一条整个删掉
  private func addHotKeyBlockItem(to menu: NSMenu) {
    guard let front = NSWorkspace.shared.frontmostApplication, front != .current,
      front.activationPolicy == .regular, let id = front.bundleIdentifier, id != "com.apple.finder"
    else { return }
    let name = front.localizedName ?? id
    let blocked = HotKeyBlock.list(HotKeyBlock.stored).contains { $0.bundleID == id }
    menu.addAction(
      blocked ? "在「\(name)」中恢复快捷键" : "在「\(name)」中停用快捷键",
      symbol: "keyboard",
      color: NSColor(Style.Family.general)
    ) { [unowned self] in
      HotKeyBlock.change { list in
        if blocked {
          list.removeAll { $0.bundleID == id }
        } else if !list.contains(where: { $0.bundleID == id }) {
          list.append(HotKeyBlock(bundleID: id))
        }
      }
      hotKeys.blocksChanged()
      island.show(
        blocked ? "「\(name)」里恢复了快捷键" : "「\(name)」里不再响应快捷键",
        detail: blocked ? nil : "按键交给它；设置 › 快捷键 里可以改", symbol: "keyboard")
    }
  }
}
