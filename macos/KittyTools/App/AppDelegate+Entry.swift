// AppDelegate 的入口（第五轮体检 H1 从 AppDelegate.swift 拆出）：剪贴板面板、启动器、主界面的开关，全局动作 / 菜单栏 / 启动器内置动作的分发（run），
// 选状态的面板、暂停记录、钉图、文件夹授权，打开设置 / 提醒 / 插件介绍页，收起全部浮层。

import AppKit
import SwiftUI

extension AppDelegate {
  // MARK: 入口

  /// 启动器和剪贴板面板在同一位置，只开一个：呼出一个就收起另一个，固定着的剪贴板面板也收
  /// （两块叠在同一处没法用，固定只管点外不关；mac-overlay-panel §2）。选状态的面板和它们也互斥（pickStatus）
  func toggleClipboard() {
    // 已开着但不是 key 时 toggle 是「聚焦」而不是收起：同样要收起另一个
    if !(clipboardPanel.isVisible && clipboardPanel.isKeyWindow) {
      builtLauncherPanel?.hide()
      statusPicker.panel?.hide()
      noteCapture?.panel.hide()
    }
    if !clipboardPanel.isVisible { clipboardStore.enforceLimits() }
    // 设置 › 剪贴板「面板位置」：屏幕上方（默认）/ 跟随鼠标 / 上次位置（2026-11-04，同翻译浮窗）
    let place = OverlayPanel.placement(
      UserDefaults.standard.string(forKey: Prefs.clipboardPanelPosition),
      hasUserFrame: clipboardPanel.hasUserFrame, mouse: NSEvent.mouseLocation)
    clipboardPanel.toggle(anchor: place.anchor, atTop: place.atTop)
  }

  func toggleLauncher() {
    if !(launcherPanel.isVisible && launcherPanel.isKeyWindow) {
      builtClipboardPanel?.hide()
      statusPicker.panel?.hide()
      noteCapture?.panel.hide()
    }
    let appearing = !launcherPanel.isVisible
    if appearing {
      if Self.scriptsOn { scriptLibrary.refresh() }
      launcherModel.prepareForShow()
    }
    // 设置 › 启动器「面板位置」：同剪贴板面板（2026-11-04）
    let place = OverlayPanel.placement(
      UserDefaults.standard.string(forKey: Prefs.launcherPanelPosition),
      hasUserFrame: launcherPanel.hasUserFrame, mouse: NSEvent.mouseLocation)
    launcherPanel.toggle(anchor: place.anchor, atTop: place.atTop)
    // 接着上次的查询（没执行就收起、或执行的是文件结果，90 秒内，体检 A27、拍板 1A）：字全选，直接打字就替换，↩ 照样执行上次选中的
    if appearing, launcherModel.resumesQuery {
      (launcherPanel.firstResponder as? NSTextView)?.selectAll(nil)
    }
  }

  /// 快捷键「打开主界面」、启动器里那一项：开着、是 key 时再按一次 = 收起
  func toggleHome() {
    if homePanel.isVisible && homePanel.isKeyWindow { return homePanel.dismiss() }
    showHome()
  }

  /// 打开主界面（已经开着就把键盘拿回来）。icon：点菜单栏图标打开的，挂在图标下面；nil（快捷键、启动器、再打开一次 App、
  /// 图标藏着）在鼠标所在屏的上方正中，和启动器、剪贴板面板、快速记一条、选状态的面板同一个位置。只开一个——收起那几块
  /// （固定着的剪贴板面板也收，同 toggleLauncher）
  func showHome(under icon: NSRect? = nil) {
    builtClipboardPanel?.hide()
    builtLauncherPanel?.hide()
    statusPicker.panel?.hide()
    noteCapture?.panel.hide()
    refreshHome(appearing: !homePanel.isVisible)
    homePanel.present(atTop: icon == nil, below: icon)
  }

  /// 按现在的状态重排主界面（关着的功能、添加的插件、在不在录、钉图、当前生效的快捷键）。appearing：新呼出，直接定大小；
  /// 开着时再呼出一次，高度变了带动画
  private func refreshHome(appearing: Bool) {
    let fresh = WhatsNew.current()
    // 底栏「设置」的橙点直接读同步的状态（被观察的：主界面开着时也跟着变，U1）
    homeModel.syncer = noteSyncer
    homeModel.update(
      Home.sections(
        state: menuState, keys: hotKeys.bindings.mapValues(\.display),
        fresh: Set(fresh.flatMap(\.actions))),
      offCount: Home.offCount(
        enabled: Feature.enabled, available: Set(Feature.listed)),
      // 快捷键没反应时人多半先点图标：这时看一眼安全输入（issue #27）
      secureInput: hotKeys.secureInputBlock(),
      settingsIsNew: WhatsNew.inSettingsOnly(fresh), appearing: appearing)
    if appearing {
      homePanel.setContentSize(homeModel.size)
    } else {
      homePanel.setContentHeight(homeModel.size.height, animated: true)
    }
  }

  /// 启动器「cb 关键词」↩（启动器已收起，N9）：呼出剪贴板面板，再把关键词填进它的搜索框
  func searchClipboard(_ keyword: String) {
    if !(clipboardPanel.isVisible && clipboardPanel.isKeyWindow) { toggleClipboard() }
    clipboardModel.query = keyword
  }

  /// 启动器里的内置动作（id 见 LauncherItem.actions，体检 A26）；启动器已收起。和菜单栏走同一个 run
  func runLauncherAction(_ id: String) {
    // 脚本命令的两条（第二轮 D2）
    // 新建脚本：打开 设置 › 启动器 › 脚本命令，盖上新建的小表单（第三轮 D2，和设置里的按钮同一张）
    if id == LauncherItem.newScriptID {
      showSettings(page: .launcher, path: [SettingsSubpage.launcherScripts.route])
      // 速查表、欢迎引导盖着时不再叠一张（关了它也不会冒出来）
      guard settingsNavigation.page == .launcher, !settingsNavigation.showsShortcuts,
        !settingsNavigation.showsOnboarding
      else { return }
      settingsNavigation.showsNewScript = true
      return
    }
    if id == LauncherItem.scriptGuideID {
      Paster.write(string: ScriptAIGuide.text, record: true)
      island.show(
        "已复制脚本写法说明",
        detail: "贴给你常用的 AI、写上想做什么；它给的脚本到 设置 › 启动器 › 脚本命令「从剪贴板新建」",
        actions: [
          Island.Action("打开设置", opens: true) { [unowned self] in showSettings(.launcherScriptsAI) }
        ])
      return
    }
    if id.hasPrefix(LauncherItem.statusPresetPrefix) {
      // 状态屏的某个状态：按 id 现找（列表可能刚在设置里改过），没了就不做
      let presets = StatusPreset.load()
      if Feature.statusScreen.isOn,
        let preset = presets.first(where: { LauncherItem.statusPresetPrefix + $0.id == id })
      {
        statusScreen.enter(preset)
      }
      return
    }
    if let action = HotKeyAction.allCases.first(where: { LauncherItem.actionID($0) == id }) {
      return run(action)
    }
    run(MenuExtra(rawValue: id) ?? .settings)
  }

  /// 菜单栏里不对应全局热键的项：菜单栏、启动器、主界面（钉图两项、设置、退出）、主菜单（设置…、快捷键速查表）同一个分发
  func run(_ extra: MenuExtra) {
    // 归关着的功能的那几项（暂停记录、复制即译、钉图）：同 run(action) 的兜底
    if let feature = extra.section?.feature, !feature.isOn { return }
    switch extra {
    case .pauseClipboard: togglePauseRecording()
    case .copyToTranslate: toggleCopyToTranslate()
    case .pinsToggle: pins.toggleHidden()
    case .pinsClose: closeAllPins()
    case .settings: showSettings()
    case .shortcuts:
      showSettings()
      settingsNavigation.showsShortcuts = true
    case .about: showSettings(page: .about)
    case .updates: Task { await updater.check(.menu) }
    // 不确认，同菜单栏「退出」（第 9 批 M1：菜单栏图标隐藏时只剩启动器能退出）
    case .quit: NSApp.terminate(nil)
    }
  }

  /// 菜单栏和启动器内置动作此刻的状态：暂停记录了没有、复制即译开没开、钉图（nil = 没有）、能不能检查更新、在录屏还是录音
  /// （录音待录时不算在录：那一项仍叫「录音」，点它是开始）、状态屏有哪些状态、它的全局快捷键是不是直接进第一个。
  /// ponytail: 状态列表每次现读偏好（启动器每敲一个字读一遍；改过列表的要解一次 JSON，最多 20 个、几十微秒），
  /// 量出来慢了再缓存
  var menuState: LauncherItem.ActionState {
    LauncherItem.ActionState(
      recordingPaused: watcher.isUserPaused,
      copyToTranslate: UserDefaults.standard.bool(forKey: Prefs.translateCopyToTranslate),
      pinsHidden: pins.panels.isEmpty ? nil : pins.isHidden, checksUpdates: updater.isSupported,
      recording: recorder != nil
        ? .screenRecord : audioRecorder?.isStarted == true ? .audioRecord : nil,
      recordPaused: recorder?.isPaused ?? audioRecorder?.isPaused ?? false,
      awake: Feature.keepAwake.isOn && keepAwake.sessionEnd != nil,
      statusPresets: StatusPreset.load(),
      statusEntersFirst: UserDefaults.standard.bool(forKey: Prefs.statusScreenHotKeyEntersFirst),
      features: Feature.enabled)
  }

  /// 全局热键动作：热键、菜单栏、启动器同一个分发。byKey：全局快捷键按出来的
  func run(_ action: HotKeyAction, byKey: Bool = false) {
    // 关着的功能（Feature）：入口都藏了，这里兜底一道（漏网的路——别处直接调过来的——也挡住）
    guard action.isActive else { return }
    // 新功能标记：用过一次就各处一起没（菜单、主界面、快捷键、启动器都走这里）
    WhatsNew.touch(action: action)
    // 启动台是全屏面板：按别的功能键时先收掉（它自己的键走 toggle）
    if action != .launchpad, launchpad.isOpen { launchpad.close(animated: false) }
    // 主界面开着时按了别的功能（快捷键）：先收起它（从主界面点的，它已经收了）
    if action != .home { builtHomePanel?.hide() }
    switch action {
    case .clipboard: toggleClipboard()
    case .launcher: toggleLauncher()
    case .selectionTranslate: selectionTranslate()
    case .inputTranslate: showInputTranslate()
    case .translateReplace: translateAndReplace()
    case .screenshotTranslate: screenshotTranslate()
    case .screenshot: screenshot()
    case .screenshotLastRegion: screenshot(repeatingLastRegion: true)
    case .delayedScreenshot: delayedScreenshot()
    case .recognizeText: recognizeText()
    case .screenRecord: screenRecord()
    case .audioRecord: audioRecord()
    case .recordPause: toggleRecordingPause()
    case .pinClipboard: pinClipboard()
    case .shotHistory: showShotHistory()
    case .clothesline: toggleClothesline()
    case .statusScreen: pickStatus()
    case .noteCapture: toggleNoteCapture()
    case .noteNew: newNote()
    case .noteAll: showNotes()
    case .noteDeck: summonNoteDeck()
    case .launchpad: launchpad.toggle()
    // 按键叫出的（全局快捷键；启动器、主界面里按 ↩——这一刻的事件是按键）：临时当 key，Esc / ←→ / ↩ 能用（U9）。
    // 用鼠标从菜单栏菜单、主界面点的，和点刘海叫出的一样不抢键盘
    case .island:
      island.toggleBoard(byKeyboard: byKey || NSApp.currentEvent?.type == .keyDown)
    case .home: toggleHome()
    case .reminderNew: newReminder()
    case .keepAwake: keepAwake.toggle()
    case .appShortcuts: appShortcuts.toggle()
    }
  }

  /// 「新建提醒」（提醒 D5）：打开启动器、填好「提醒 」（英文界面「remind 」），接着写时间和内容（解析和预览都在启动器里，不另做面板）；
  /// 启动器这个功能关着时打开 设置 › 提醒
  private func newReminder() {
    guard Feature.launcher.isOn else { return showSettings(page: .reminders) }
    if !(launcherPanel.isVisible && launcherPanel.isKeyWindow) { toggleLauncher() }
    // 英文界面填英文关键词（ReminderPhrase.keywords 里两个都认；第 1 批留下的，第 8 批让英文的一句话也认得出）
    launcherModel.query = InterfaceLanguage.running == .english ? "remind " : "提醒 "
    (launcherPanel.firstResponder as? NSTextView)?.moveToEndOfDocument(nil)
  }

  /// 加一条提醒（启动器一句话建的、菜单栏「几分钟后提醒我」）：写进偏好（执行层看着偏好跟上），岛上说一声、带「编辑」
  func addReminder(_ reminder: Reminder) {
    guard Feature.reminders.isOn else { return }
    let list = Reminder.load()
    guard list.count < Reminder.maxCount else {
      return island.show(
        "提醒已经满了", detail: "最多 \(Reminder.maxCount) 条，先到 设置 › 提醒 里删掉几条", tone: .warning)
    }
    Reminder.save(Reminder.adding(reminder, to: list))
    island.show(
      "提醒建好了", detail: "\(reminder.summary()) · \(reminder.displayTitle)", tone: .success,
      symbol: "checkmark.circle.fill",
      actions: [Island.Action("编辑", opens: true) { [unowned self] in openReminder(reminder.id) }])
  }

  /// 状态屏的全局快捷键（快捷键、菜单栏子菜单的「选择状态…」）：先出选状态的面板，选一个再进（Z13a）；设置 › 状态屏
  /// 打开「按快捷键直接进入排在最前面的状态」时不出面板、直接进第一个（Z10 原来的样子）。面板开着（是 key）时再按一次 =
  /// 选中下一张；开着但键盘不在它身上（比如刚点了翻译浮窗）就把键盘拿回来、选中的不动。
  /// 和剪贴板面板、启动器互斥：打开它时收起那两块（固定着的剪贴板面板也收，同 toggleLauncher）
  private func pickStatus() {
    let presets = StatusPreset.load()
    let defaults = UserDefaults.standard
    if defaults.bool(forKey: Prefs.statusScreenHotKeyEntersFirst) {
      if let first = presets.first { statusScreen.enter(first) }
      return
    }
    if let panel = statusPicker.panel, panel.isVisible {
      return panel.isKeyWindow ? statusPickerModel.move(.right) : panel.present()
    }
    builtClipboardPanel?.hide()
    builtLauncherPanel?.hide()
    noteCapture?.panel.hide()
    let screen = NSScreen.underMouse
    statusPickerModel.prepare(
      presets, last: defaults.string(forKey: Prefs.statusScreenLastPreset),
      maxHeight: (screen?.visibleFrame.height ?? 800) * 0.9)
    let panel = statusPicker.open()
    panel.setContentSize(statusPickerModel.layout.size)
    panel.present()
  }

  /// 岛上的「打开设置」：跳到 设置 › 快捷键（快捷键没注册上、同步来的撞上了）
  var openHotKeySettings: Island.Action {
    .init("打开设置", opens: true) { [unowned self] in showSettings(page: .hotkeys) }
  }

  /// 岛上的「勾选同步」：跳到 设置 › 通用（同步那一节在里面；从只同步便签的版本升上来时）
  var openSyncSettings: Island.Action {
    .init("勾选同步", opens: true) { [unowned self] in showSyncSettings() }
  }

  /// 设置 › 通用 › 同步（刘海岛上「打开同步设置」「勾选同步」，第五轮体检 U1；设置改版起同步在通用页的子页里）。
  /// 设置窗挂着别的表单时 show 不换页也不推（同 SettingsWindow.show 的口径）
  func showSyncSettings() {
    showSettings(page: .general, path: [SettingsSubpage.generalSync.route])
  }

  /// 暂停记录剪贴板的三处一起设：采集、面板底栏、菜单栏图标的暂停角标（X13）
  func setRecordingPaused(_ paused: Bool) {
    watcher.isUserPaused = paused
    clipboardModel.isRecordingPaused = paused
    statusItem?.clipboardPaused = paused
  }

  /// 暂停 / 恢复记录剪贴板（菜单栏、启动器，D4；主界面 2026-11-13 起不放开关）：不存盘，重启 App 自动恢复记录（免得忘了关）；
  /// 菜单一关就看不出开没开，用刘海说（剪贴板面板底栏也写着「已暂停记录」）
  private func togglePauseRecording() {
    let paused = watcher.isUserPaused
    setRecordingPaused(!paused)
    island.show(
      paused ? "已恢复记录剪贴板" : "已暂停记录剪贴板",
      detail: paused ? nil : "复制的内容不进历史，再点一次恢复", tone: .info,
      symbol: paused ? "play.circle.fill" : "pause.circle.fill",
      actions: [.init("撤销") { [unowned self] in togglePauseRecording() }])
  }

  /// 复制即译开关（菜单栏、启动器；另在 设置 › 翻译 和翻译浮窗上）：开关一关就看不出开没开，这个后台模式会影响之后的每次复制，用刘海说
  private func toggleCopyToTranslate() {
    let wasOn = UserDefaults.standard.bool(forKey: Prefs.translateCopyToTranslate)
    UserDefaults.standard.set(!wasOn, forKey: Prefs.translateCopyToTranslate)
    island.show(
      wasOn ? "已关闭复制即译" : "已开启复制即译",
      detail: wasOn ? nil : "复制文字后会弹出翻译", tone: .info,
      symbol: wasOn ? "character.bubble" : "character.bubble.fill",
      actions: [.init("撤销") { [unowned self] in toggleCopyToTranslate() }])
  }

  /// 关闭全部钉图（菜单栏、启动器）：关了就回不来，隐藏着时屏幕上什么也看不到，用刘海说
  private func closeAllPins() {
    let count = pins.panels.count
    pins.closeAll()
    island.show("已关闭全部钉图", detail: "\(count) 张", tone: .info, symbol: "pin.slash")
  }

  /// 钉住剪贴板里的图（第二轮体检 F1；快捷键默认不设、菜单栏、启动器）：剪贴板面板「钉到屏幕」的一步版，钉在鼠标所在屏
  /// 可见区中央、连按依次错开（PinBoard.clipboardFrame）。没有图片、是文字时把文字排成卡片钉上去（issue #4）。
  /// 只读剪贴板，不写、不记历史（不是新内容）；图片、文字都没有时提示音 + 岛
  private func pinClipboard() {
    guard let screen = NSScreen.underMouse else { return }
    let (scale, visible) = (screen.backingScaleFactor, screen.visibleFrame)
    func place(_ image: CGImage) {
      let pixels = CGSize(width: image.width, height: image.height)
      pins.pin(
        image,
        frame: PinBoard.clipboardFrame(
          pixels: pixels, scale: scale, visible: visible, pinned: pins.panels.map(\.frame)))
    }
    guard let source = PinBoard.clipboardImage() else {
      if let text = PinBoard.clipboardText(),
        let card = PinBoard.textCard(
          text, scale: scale, limit: PinBoard.textCardLimit(visible: visible),
          appearance: NSApp.effectiveAppearance)
      {
        return place(card)
      }
      NSSound.beep()
      return island.show("剪贴板里没有图片或文字", tone: .warning)
    }
    Task {
      guard let image = await PinBoard.decode(source) else {
        let name =
          if case .file(let url) = source {
            String(localized: "「\(url.lastPathComponent)」")
          } else {
            String(localized: "这张图片")
          }
        return island.show("没能钉到屏幕", detail: "读不出\(name)", tone: .error)
      }
      // 解码完才找空位：连按几下时，前一张这时已经钉上了
      place(image)
    }
  }

  /// 启动器文件搜索的授权提示（启动器已收起）：第一次逐个弹系统授权框（桌面、文稿、下载、iCloud 云盘），
  /// 结果用刘海岛说；问过了就打开系统设置的「文件和文件夹」
  func requestFolderAccess() {
    guard Permissions.deniedFolders() == nil else {
      return Permissions.Kind.filesAndFolders.openSettings()
    }
    // 启动器刚 orderOut，下面读目录会停住主线程直到用户点完系统框：先把窗口变化提交给 WindowServer，
    // 否则冻住的启动器在授权框期间一直挂在屏幕上（审查时实测）
    CATransaction.flush()
    let denied = Permissions.requestFolderAccess()
    if denied.isEmpty {
      island.show("已允许访问", detail: "文件搜索现在能搜到桌面、文稿、下载里的文件")
    } else {
      island.show(
        "没有权限搜\(String(localized: "「\(denied.joined(separator: Self.quotedSeparator))」"))",
        detail: "可在系统设置 › \(Permissions.privacyPane) › 文件和文件夹里打开",
        tone: .warning, actions: [.settings(for: .filesAndFolders)])
    }
  }

  /// 打开系统设置 › 触控板 › 更多手势（设置 › 启动台里系统捏合还开着时的那一行；只读、不改系统设置）
  func openTrackpadSettings() {
    guard
      let url = URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension")
    else { return }
    NSWorkspace.shared.open(url)
  }

  /// 打开 设置 › 提醒 并推进到这一条（启动器 ⌘↩、建好之后岛上的「编辑」、菜单栏）
  func openReminder(_ id: String) {
    showSettings(page: .reminders)
    settingsNavigation.path = [id]
  }

  /// 打开这个插件的介绍页（启动器「添加…插件」，插件拍板 A4、插件页改版 G1）：不直接添加，先看清能做什么、要什么授权
  func showPlugin(_ plugin: Feature) {
    showSettings(page: .plugins)
    // 设置窗挂着表单（速查表、确认框）时 show 不换页：别把介绍页推进别的页的栈里
    guard settingsNavigation.page == .plugins else { return }
    settingsNavigation.path = [PluginsPage.route(plugin)]
  }

  /// 打开设置窗（page 为 nil 保持上次的页；onboarding 盖上欢迎引导）：先按正常隐藏路径收起浮层
  /// （固定的浮层会盖在设置窗上）
  func showSettings(page: SettingsPage? = nil, path: [String] = [], onboarding: Bool = false) {
    hidePanels()
    settingsWindow.show(page: page, path: path, onboarding: onboarding)
  }

  /// 打开设置窗、落到那一行（设置改版 S8：面板里的「设置…」、岛上的「打开设置」）：滚过去描一圈
  func showSettings(_ item: SettingsItem) {
    // 设置窗挂着表单（速查表、确认框）时不动：show 不换页，同一页上也别退掉推进着的详情页、把确认框一起拆掉
    // （同 showSyncSettings）。挂着的是「高级…」表单照样落过去。先看再 show：换页时 advanced 已经清了，表单还没收走
    let free = settingsWindow.window.attachedSheet == nil || settingsNavigation.advanced != nil
    showSettings(page: item.page)
    guard free, settingsNavigation.page == item.page else { return }
    settingsNavigation.open(item)
  }

  /// 三块浮层、选状态的面板、快速记一条、主界面都收起，固定着的也收（打开设置、打开全部便签、进入状态屏）
  func hidePanels() {
    launchpad.close(animated: false)
    builtHomePanel?.hide()
    builtClipboardPanel?.hide()
    builtLauncherPanel?.hide()
    statusPicker.panel?.hide()
    noteCapture?.panel.hide()
    builtTranslatePanel?.hide()
  }
}
