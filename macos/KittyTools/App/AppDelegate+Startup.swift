// AppDelegate 的启动辅助（第五轮体检 H1 从 AppDelegate.swift 拆出）：欢迎引导、单实例让位、每日备份的时机、打开数据库和便签库（打不开时问用户）。

import AppKit
import FinderSync
import OSLog
import SwiftUI

extension AppDelegate {
  // MARK: 启动辅助

  /// 首次安装打开欢迎引导（授权、快捷键；引导下面是通用页）。更新后第一次启动不开设置窗、不抢前台：
  /// 刘海岛说「已更新到 x」+ 本版摘要（菜单栏图标照常弹一下），全文在菜单「关于 Kitty Tools」。
  /// 首次安装时「看过这一版」等引导走完才记（E1，settingsNavigation.onboardingClosed）：没走完就退出（授权屏幕录制后系统
  /// 要求重开）的，下次启动接着开引导、从做到的那一屏起；「登录时自动打开」按默认（开）注册，引导走完之前每次启动都补一次
  func showWelcomeIfNeeded() {
    let defaults = UserDefaults.standard
    let last = defaults.string(forKey: Prefs.lastSeenVersion)
    if last == nil {
      let reached = (defaults.object(forKey: Prefs.onboardingScreen) as? Int)
        .flatMap(OnboardingView.Screen.init(rawValue:))
      if reached == nil {
        defaults.set(OnboardingView.Screen.welcome.rawValue, forKey: Prefs.onboardingScreen)
      }
      // 登录项按默认（开）注册：引导还没走完时每次启动都看一眼，还没注册的才注册（上次没注册成、引导中途退出的补上；
      // 用户的选择在引导「开始使用」时才作数，之后在通用页里关掉照旧取消注册）；从磁盘映像里打开的不注册
      if LaunchAtLogin.isInstalled, LaunchAtLogin.isNotRegistered { try? LaunchAtLogin.set(true) }
      settingsNavigation.onboardingClosed = { [unowned self] in finishOnboarding() }
      firstInstall = true
      onboardingStart = OnboardingView.resume(
        reached: reached,
        granted: OnboardingView.granted(OnboardingView.permissions(for: Feature.enabled)))
      showSettings(page: .general, onboarding: true)
      return
    }
    // 从有「请求过」标记之前的版本升上来的：系统的授权框多半早弹过，标记补成请求过（U10）
    if let last { Permissions.adoptRequestFlags(upgradingFrom: last, defaults: defaults) }
    // 新功能标记：上次打开的版本之后加的那几样从现在起标（新装走不到这里，不标）
    WhatsNew.adopt(upgradingFrom: last, to: AboutTab.version, defaults: defaults)
    defaults.set(AboutTab.version, forKey: Prefs.lastSeenVersion)
    if last != AboutTab.version {
      let summary = AboutTab.releases.first { $0.version == AboutTab.version }?.localizedSummary
      var actions = [
        Island.Action("看更新了什么", opens: true) { [unowned self] in showSettings(page: .about) }
      ]
      // 从只同步便签的版本升上来、开着同步：新加的几类先没勾（NoteSyncer.isUpgrade；便签库开好后才真正存下），并进这座岛
      // 说——便签库开好后单独弹的话会把这座岛原地换掉
      var detail = summary.map(Island.excerpt)
      if NoteSyncer.isUpgrade(.standard) {
        toldSyncUpgrade = true
        detail = [detail, String(localized: "现在也能同步设置、片段和收藏这些了，到 设置 › 通用 › 同步 里勾上")]
          .compactMap { $0 }.joined(separator: Self.semicolon)
        actions.append(openSyncSettings)
      }
      // 升级时替用户保持了中文（InterfaceLanguage.keepChineseOnUpgrade）：说一声能换成英文
      if InterfaceLanguage.keptChinese {
        detail = [detail, String(localized: "现在也有英文界面了，在 设置 › 通用「语言」里换")]
          .compactMap { $0 }.joined(separator: Self.semicolon)
      }
      island.show(
        "已更新到 \(AboutTab.version)", detail: detail.map { "\($0)" }, tone: .success,
        symbol: "sparkles",
        actions: actions)
    }
  }

  /// 一串加了引号的名字（「A」「B」）里两个名字之间的那一段：中文「」「」、英文「”, “」。外面再包一层「%@」。
  /// 默认值不能是空串：查不到译文、默认值又是空的时候系统显示 key 本身（实测）
  static var quotedSeparator: String {
    String(localized: "list.quoted", defaultValue: "」「", comment: "「A」「B」这样一串名字里两个名字之间的那一段")
  }

  /// 「已更新到」那座岛上几句话之间的分隔：中文「；」、英文「; 」
  private static var semicolon: String {
    String(localized: "list.semicolon", defaultValue: "；", comment: "两句话并成一句时中间的分号")
  }

  /// 首次安装的引导走完了（「开始使用」、Esc、关掉设置窗）：这时才记「看过这一版」，做到第几屏的记录删掉（E1）
  private func finishOnboarding() {
    settingsNavigation.onboardingClosed = {}
    UserDefaults.standard.set(AboutTab.version, forKey: Prefs.lastSeenVersion)
    UserDefaults.standard.removeObject(forKey: Prefs.onboardingScreen)
    // 引导里勾上了访达右键：引导的授权屏不管系统里的扩展（applyFeatures 那时也不弹），走完了说一声、带「去打开」
    if Feature.finderMenu.isOn, !FIFinderSyncController.isExtensionEnabled {
      island.show(
        "访达右键还要在系统设置里打开一次", detail: "打开后在访达里右键就能看到", tone: .warning,
        actions: [.init("去打开", opens: true) { FinderMenuTab.openExtensionSettings() }])
    }
  }

  /// LaunchServices 不保证同一 bundle id 只跑一份（例如 DMG 里一份、/Applications 里又一份）：
  /// 发现更早启动的实例就再打开一次它的包（LaunchServices 给它发 reopen → 主界面，菜单栏图标隐藏时也回得去；
  /// 只 activate 的话没窗口的菜单栏 App 什么也不显示），自己退出。更新后的重启是等旧进程退了才 open，走不到这里。
  /// 只让「更晚的」退出：两份同时启动时若都见到对方就退，会一起退光（实测过）；启动时间相同再比 pid
  func yieldToOlderInstance() -> Bool {
    guard let bundleID = Bundle.main.bundleIdentifier else { return false }
    let me = NSRunningApplication.current
    let rank = { (app: NSRunningApplication) in
      (app.launchDate ?? .distantPast, app.processIdentifier)
    }
    let older = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
      $0.processIdentifier != me.processIdentifier && rank($0) < rank(me)
    }
    guard let older else { return false }
    if let url = older.bundleURL { NSWorkspace.shared.open(url) } else { older.activate() }
    NSApp.terminate(nil)
    return true
  }

  /// 今天还没备份过就备一份（Storage/Backup.swift：只备用户留下的收藏 / 片段 / 生词本等，另开只读连接在主线程外做，
  /// 1.7 MB 的库约 10 ms）。备好了、库有问题、没备成都只记日志，不打扰用户
  func backupIfDue() {
    // 便签还没开（启动到一半、便签的弹框还开着时来了锁屏 / 换日的通知）：先不做，开好之后启动流程会调
    guard hasOpenedNotes, !isBackingUp else { return }
    isBackingUp = true
    Task {
      let outcome = await Backup.run(in: dataDirectory)
      switch outcome {
      case .made(let url): Log.storage.notice("已备份数据库：\(url.lastPathComponent, privacy: .public)")
      case .damaged: Log.storage.error("数据库有问题，今天没有备份；已有的备份没动")
      case .failed(let reason): Log.storage.error("备份数据库失败：\(reason)")
      case .notDue: break
      }
      isDatabaseDamaged = outcome == .damaged
      await backupNotesIfDue()
      isBackingUp = false
      await backupSettingsIfDue()
    }
  }

  /// 便签库今天还没备份过就备一份（Notes/NotesBackup.swift：整库加图片目录，另开只读连接在主线程外做）。跟着上面数据库的
  /// 备份做，各备各的、一个不成不影响另一个；便签这次运行里不可用时不做。先把攒着没落盘的改动落下去。结果只记日志
  private func backupNotesIfDue() async {
    guard let noteStore else { return }
    noteStore.flush()
    let outcome = await NotesBackup.run(in: dataDirectory)
    switch outcome {
    case .made(let url): Log.storage.notice("已备份便签：\(url.lastPathComponent, privacy: .public)")
    case .damaged: Log.storage.error("便签库有问题，今天没有备份；已有的备份没动")
    case .failed(let reason): Log.storage.error("备份便签失败：\(reason)")
    case .notDue, .empty: break
    }
    isNotesDamaged = outcome == .damaged
  }

  /// 现在的设置与数据（导出文件的内容，不带密钥）：每天的自动备份和导入前那一份都写它。便签这次运行里不可用、
  /// 或者便签库刚查出有问题时不带便签这一类（不写一份空的、不全的把好的顶掉）
  private func currentArchive() -> SettingsArchive {
    .capture(
      services: serviceStore.services, clips: clipboardStore.items, groups: clipboardStore.groups,
      words: historyStore.search("", favoritesOnly: true, limit: 0),
      notes: isNotesDamaged ? nil : noteStore?.exportable)
  }

  /// 设置与数据的每日自动备份（Storage/SettingsBackup.swift）：开着的话，本机 backups/ 和用户另选的文件夹里今天还没有的
  /// 各存一份。跟着数据库的备份做（backupIfDue；库有问题时不做）；设置 › 通用里刚打开开关、刚选了文件夹时也调一次
  /// （今天已有的不重写）。该不该写、写、把结果记进偏好（设置页那两行的橙字）都在 SettingsBackup，这里只管别叠着调：
  /// 两份各走各的，另选的文件夹可能在卡住的网络盘上、很久不回来，本机那份不等它。读设置、编成 JSON 在主线程，
  /// 两份共用一次（ponytail: 上限是导出文件的 32 MB，实测约 0.6 s，常见的几十 KB 是毫秒级；真有人卡到了再挪出去）
  func backupSettingsIfDue() async {
    let defaults = UserDefaults.standard
    guard SettingsBackup.isEnabled(defaults), !isDatabaseDamaged else { return }
    var cached: SettingsBackup.Payload?
    let payload = { [unowned self] () -> SettingsBackup.Payload? in
      cached = cached ?? SettingsBackup.payload(of: currentArchive())
      return cached
    }
    if !isBackingUpSettings {
      isBackingUpSettings = true
      await SettingsBackup.backUpLocal(
        in: Backup.folder(in: dataDirectory), defaults: defaults, payload: payload)
      isBackingUpSettings = false
    }
    // ponytail: 上一次另存还卡着时换了文件夹，新文件夹要等下一次（启动、换日、锁屏）才有今天那份；真有人碰到再在这里补一次
    guard !isMirroringSettings, let extra = SettingsBackup.extraFolder(defaults) else { return }
    isMirroringSettings = true
    await SettingsBackup.mirror(to: extra, defaults: defaults, payload: payload)
    isMirroringSettings = false
  }

  /// 导入（和从备份恢复）动手之前先把现在的设置与数据存一份（SettingsBackup.snapshot；存不成就抛原因，导入不做）
  func snapshotBeforeImport() throws {
    try SettingsBackup.snapshot(in: Backup.folder(in: dataDirectory)) { [unowned self] in
      SettingsBackup.payload(of: currentArchive())
    }
  }

  /// 打开数据库和读它的三个仓库。打不开不直接退出（第二轮体检 S2，Storage/Backup.swift）：弹框让用户选用最近的备份、
  /// 重新开始还是退出；前两种把出问题的文件挪开留着、再开一次，还打不开才说明后退出（不循环）
  static func openOrQuit(in directory: URL) -> Stores {
    do {
      return try Recovery.open(
        in: directory, open: { try Stores(in: directory) },
        ask: { problem in
          let wording = Recovery.wording(for: problem, directory: directory)
          let alert = NSAlert()
          alert.alertStyle = .critical
          alert.messageText = wording.title
          alert.informativeText = wording.text
          for title in wording.buttons { alert.addButton(withTitle: title) }
          // Esc = 退出（什么都不动）；第一个按钮是默认（↩）
          alert.buttons.last?.keyEquivalent = "\u{1b}"
          NSApp.activate()
          let index =
            alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
          return wording.choices.indices.contains(index) ? wording.choices[index] : .quit
        })
    } catch Recovery.Failure.quit {
      exit(0)
    } catch {
      let alert = NSAlert()
      alert.alertStyle = .critical
      alert.messageText = String(localized: "无法打开数据库")
      let folder = (directory.path as NSString).abbreviatingWithTildeInPath
      alert.informativeText = String(localized: "\(String(describing: error))\n\n数据目录：\(folder)")
      NSApp.activate()
      alert.runModal()
      exit(1)
    }
  }

  /// 打开便签库（Notes/NotesBackup.swift 的 NotesRecovery）。打不开时问用户：用最近的备份 / 重新开始 / 这次先不用便签。
  /// **不退出 App**：问过之后还开不了就再说一声（弹框）；库是更新版本的 Kitty Tools 写的不弹框，刘海岛出一条警告。
  /// 这两种和用户选了「这次先不用」都返回 nil：便签这次用不了，别的功能照常
  func openNotes() -> NoteStore? {
    let directory = dataDirectory
    let show = { (title: String, text: String, buttons: [String]) -> Int in
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = title
      alert.informativeText = text
      for button in buttons { alert.addButton(withTitle: button) }
      // Esc = 最后一个按钮（这次先不用便签：什么都不动）；第一个按钮是默认（↩）
      if buttons.count > 1 { alert.buttons.last?.keyEquivalent = "\u{1b}" }
      NSApp.activate()
      return alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }
    do {
      return try NotesRecovery.open(
        in: directory,
        open: {
          try NoteStore(
            db: Database(path: directory.appending(path: NotesBackup.databaseName).path))
        },
        ask: { problem in
          let wording = NotesRecovery.wording(for: problem, directory: directory)
          let index = show(wording.title, wording.text, wording.buttons)
          return wording.choices.indices.contains(index) ? wording.choices[index] : .skip
        })
    } catch {
      Log.storage.error("便签这次用不了：\(error)")
      guard let notice = NotesRecovery.notice(for: error, directory: directory) else { return nil }
      if case .newer = error {
        island.show("\(notice.title)", detail: "\(notice.text)", tone: .warning)
      } else {
        _ = show(notice.title, notice.text, [String(localized: "好")])
      }
      return nil
    }
  }
}
