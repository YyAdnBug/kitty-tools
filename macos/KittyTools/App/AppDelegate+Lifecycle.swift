// AppDelegate 的生命周期（第五轮体检 H1 从 AppDelegate.swift 拆出）：启动时按依赖顺序接线、刘海岛的手感、按功能开关起停（applyFeatures）、
// 便签开好之后的那一段、退出前的收尾（录制、便签落盘）、打开网址 / 重新打开。

import AppKit
import FinderSync
import OSLog
import SwiftUI

extension AppDelegate {
  // MARK: 生命周期

  func applicationDidFinishLaunching(_ notification: Notification) {
    // 单测以本 App 为宿主运行：不碰真实数据、不起热键
    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
    if yieldToOlderInstance() { return }
    // 新装把功能开关明写进偏好（只开四个；升级上来的不碰），在注册默认值之前（功能管理拍板 M4 M5）
    Feature.seedNewInstall()
    // 新装：会吞掉这台的布局、系统语言要用的字母的默认 ⌥ 键先不注册（第五轮体检 E9）
    HotKeyAction.seedNewInstall()
    // 新装、系统英文在前：第一 / 第二语言明写成英语 / 简体中文（注册的默认值不动，多语言第 4 批）
    Lang.seedNewInstall()
    Prefs.registerDefaults()
    Task { await EmojiPack.trim() }  // 动画表情的缓存收到上限以内（主线程外）
    Prefs.migrate()
    FinderLink.ensureKey()  // 访达右键的凭证（扩展从偏好里读）：功能开没开都先备好
    FileMoves.forgetCut()  // 上次的剪切作废（清单只在内存里，偏好里那两个数留着会在几天后「复活」）
    FileMoves.ledger = .standard  // 访达右键的临时名记进偏好；上次退出时没收尾的删掉（单测里不接）
    FileMoves.cleanLeftovers()
    AppAppearance.apply()  // 在任何浮层、设置窗、菜单出现之前
    // 打开数据：打不开时就在这里问用户（用备份 / 重新开始 / 退出），这时还没有热键和菜单栏图标
    _ = stores
    isRunning = true

    // 访达右键「拷贝图中文字」交给这里：识字要等模型、做完排空闲回收（recognizing）
    FinderLink.copyImageText = { [unowned self] urls in copyRecognizedText(inFiles: urls) }
    // 本 App 生成的新文字写剪贴板时同时记进历史（Paster.write(string:record:)，mac-native §5）；暂停记录、剪贴板关着时不记
    Paster.recordText = { [unowned self] in
      if recordsClipboard { clipboardStore.recordOwnText($0) }
    }
    // 剪贴板关着（Feature）也照做：保留天数到期照删、孤儿图片照清（数据层不跟着开关走）。轮询和识字在 applyFeatures 里按开关起
    let launchedAt = Date.now
    // 开着「退出时清空」：上次闪退、强退、断电没走到退出那一步，启动时补清一次，不把普通历史带回来（第四轮体检 E5）
    if UserDefaults.standard.bool(forKey: Prefs.clipboardClearOnQuit) {
      clipboardStore.clearOrdinary()
    }
    clipboardStore.enforceLimits()
    clipboardStore.images.removeOrphans(
      keeping: Set(clipboardStore.items.map(\.id)), createdBefore: launchedAt)
    watcher.onText = { [unowned self] text in copyToTranslate(text) }
    DistributedNotificationCenter.default().addObserver(
      forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main
    ) { [weak self] _ in
      // weak + 里面再 guard（同 Launchpad 的换屏通知）：Swift 6.4（Xcode 27.1）起 unowned self 在 assumeIsolated 里用会报
      // 「sending 'self' risks causing data races」。AppDelegate 和 App 同寿命，行为不变
      MainActor.assumeIsolated {
        guard let self else { return }
        if UserDefaults.standard.bool(forKey: Prefs.clipboardClearOnLock) {
          self.clipboardStore.clearOrdinary()
        }
        self.noteStore?.flush()
        self.backupIfDue()
      }
    }
    // 睡眠前把便签攒着没落盘的改动落下去（锁屏、退出同）
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { _ = self?.noteStore?.flush() }
    }
    // 醒来时同步马上合一轮（睡着的这段时间别的电脑可能改过；没开同步时它自己不做事）
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.noteSyncer?.syncNow()
        if Feature.keyRemapping.isOn { self.keyRemapping.refresh(recheck: true) }
      }
    }
    // 每天一份备份：启动时一次（在最后，等便签开好：finishLaunchingNotes），一直开着不退的靠系统的换日通知
    // （午夜发；睡过了午夜的醒来时补发，不保证准点），锁屏时再看一眼（换日那次没备成的补上）。都是现成的事件，
    // 不为它加定时器
    NotificationCenter.default.addObserver(
      forName: .NSCalendarDayChanged, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        // 「最近删除」里放满 30 天的便签、图片目录里没人引用满 30 天的文件：启动时清一次，换日时再清
        self.purgeNotes()
        // 截图历史过了保留期的同样换日时清（原来只在记新的一条时清，一直不截图就一直留着，第四轮体检 E24）
        self.shotHistory.prune()
        // 拷贝成文件、拖出去的那些临时文件：启动时整个清空，一直开着不退的换日时删一天以前的
        ShotShelf.purgeStaleDragFiles()
        self.backupIfDue()
      }
    }

    for action in HotKeyAction.allCases {
      hotKeys.setHandler(for: action) { [unowned self] in
        // 录屏开着「显示按键」：本 App 的全局快捷键被 Carbon 热键吃掉、InputOverlay 的键盘监听收不到，在这里补给它
        // （没开显示按键时 showKey 不做事；停止录屏的那一下不显示，免得留在最后一帧里）
        if action != .screenRecord, let key = hotKeys.bindings[action] {
          recorder?.inputOverlay?.showKey(key.display)
        }
        // 状态屏里热键本来停着；万一被别处重新注册了（安全输入开着时拦截也吞不掉它们）：不响应
        guard !statusScreen.isActive else { return }
        run(action, byKey: true)
      }
    }
    // 启动器「命令和别名」里每条命令的快捷键（脚本命令第三轮 D1）：只注册此刻能做事的（启动器开着、那条开着、脚本这台 Mac
    // 上有）。启动器的模型在建面板时接好，设了命令快捷键才提前建；脚本还没读过的先读一遍，读完 onChange 再注册
    hotKeys.commandHotKeys = { [unowned self] in
      let saved = LauncherModel.savedCommandHotKeys()
      guard Feature.launcher.isOn, !saved.isEmpty else { return [] }
      _ = launcherPanel
      if Self.scriptsOn, !scriptLibrary.isLoaded { scriptLibrary.refresh() }
      return saved.filter { launcherModel.canRunHotKey($0.key) }.sorted { $0.key < $1.key }
        .map { ($0.key, $0.value) }
    }
    hotKeys.onCommand = { [unowned self] id in
      guard Feature.launcher.isOn, !statusScreen.isActive else { return }
      // 录屏「显示按键」：同各动作的快捷键，补给按键提示
      if let key = hotKeys.commandBindings[id] { recorder?.inputOverlay?.showKey(key.display) }
      launcherModel.runHotKey(id)
    }
    hotKeys.knowsCommand = { [unowned self] id in
      _ = launcherPanel
      return launcherModel.hasCommand(id)
    }
    hotKeys.reload()
    try? FileManager.default.removeItem(at: ShotShelf.dragDirectory)
    shelf.copy = { [unowned self] png in await copyPNG(png) }
    // 角落缩略图的「改标注」（X7）：历史里记好了这一条就同截图历史的「改标注」（原图 + 标注接着改、回写那一条），
    // 没记成（历史关着）就对着这张图标、不回写
    shelf.annotate = { [unowned self] image, scale, remembered in
      Task {
        if let id = await remembered?.value, let item = shotHistory.item(id),
          let original = await shotHistory.image(for: id)
        {
          return openAnnotate(
            original, scale: item.scale, history: { id }, annotations: item.annotations,
            fromHistory: true)
        }
        openAnnotate(image, scale: scale)
      }
    }
    shelf.island = island
    shelf.save = { [unowned self] in await savePNG($0, asking: false) }
    shelf.pin = { [unowned self] in pins.pin($0, frame: $1, window: $2) }
    // 录屏 / 录音卡的「拷贝」：拷的是文件，同截图的图片自己记进剪贴板历史（C8-a：点了才进；暂停记录、剪贴板关着时不记）
    // 转出来的 GIF、压缩版也进历史；右键「在历史里看」打开历史窗口（2026-10-26 拍板 B1、D1）
    shelf.remember = { [unowned self] file, poster, kind in
      Task { await shotHistory.record(file: file, poster: poster, kind: kind) }
    }
    shelf.openHistory = { [unowned self] in showShotHistory() }
    shelf.historyIsOn = { [unowned self] in shotHistory.isOn }
    // 改完标注、缩略图重做好了（2026-10-26 用户手测：历史里看着像没改过）：清掉那张的缓存，
    // 开着的历史窗口重画网格、晾衣绳重画那张卡并重做拖出去的那份
    shotHistory.onThumbnailChanged = { [unowned self] id in
      ShotThumbnails.shared.forget(id)
      shotHistoryWindow?.model.touch()
      if Feature.screenshot.isOn { clothesline.thumbnailChanged(id) }
    }
    // 历史里删掉的（历史窗口、清理、「现在清空」）：晾衣绳上挂着的跟着取下（R10）
    shotHistory.onRemoved = { [unowned self] ids in clothesline.forget(ids) }
    shelf.copyFile = { [unowned self] url in
      Paster.write(files: [url])
      if recordsClipboard { clipboardStore.recordFiles([url]) }
    }
    let statusItem = StatusItem()
    statusItem.buildMenu = { [unowned self] in buildStatusMenu($0) }
    // 左键：主界面（右键、⌃点是菜单）
    statusItem.openHome = { [unowned self] in showHome(under: $0) }
    statusItem.closeHome = { [unowned self] in builtHomePanel?.dismiss(byKeyboard: false) }
    statusItem.homeIsOpen = { [unowned self] in builtHomePanel?.isVisible == true }
    island.onToneChange = { [weak statusItem] in statusItem?.reflect($0) }
    self.statusItem = statusItem
    updater.island = island
    // 有新版本：菜单栏图标右上角出小圆点，常驻到更新为止
    updater.onAvailableChange = { [weak statusItem] in statusItem?.updateVersion = $0?.version }
    // 别的 App 开着安全输入、挡着只带 ⌥ 的快捷键：菜单栏图标右下角出橙色小锁，没了就撤（issue #27）
    hotKeys.onSecureInputChange = { [weak statusItem] in statusItem?.secureInput = $0 }
    updater.start()
    // 刘海岛：点刘海、快捷键「打开刘海岛」叫出那一张。快捷动作每次打开时现取（照 设置 › 刘海岛 的先后和开关，
    // 关着的功能不出，录着时写「停止录屏」）
    island.boardActions = { [unowned self] in
      let recording: HotKeyAction? =
        recorder != nil ? .screenRecord : audioRecorder?.isStarted == true ? .audioRecord : nil
      let defaults = UserDefaults.standard
      let off = HotKeyAction.islandOff(defaults.string(forKey: Prefs.islandActionsOff) ?? "")
      return HotKeyAction.islandOrder(defaults.string(forKey: Prefs.islandActionOrder) ?? "")
        .filter { $0.isActive && !off.contains($0) }
        .map { action in
          Island.Action("\(action.title(recording: recording == action))", symbol: action.symbol) {
            [unowned self] in run(action)
          }
        }
    }
    // 框选截图 / 录屏、启动台、状态屏盖着刘海时，点它、停在它上面都不算
    island.isSuppressed = { [unowned self] in
      isCapturing || launchpad.isOpen || statusScreen.isActive || island.hiddenForFullScreen
    }
    island.hasExtras = Feature.island.isOn
    island.respondsToNotch = respondsToNotch
    // 那一张上的月历旁边列今天的日程（没有「日历」授权是 nil；岛自己不碰 EventKit）
    island.agendaProvider = { [unowned self] in nextEvent.agenda() }
    applyIslandFeel()
    island.start()
    systemNotices.apply()
    hourlyChime.apply()
    // 系统专注模式（读系统日志，SystemFocus）：刘海上提示由它自己出；提醒那边跟着它算（ReminderFocus）。要在提醒起来
    // （applyFeatures）之前接好：刚启动时按偏好里记着的那个模式算，别把专注期间压着的弹出来
    SystemFocus.shared.island = island
    Chime.isRecording = { [unowned self] in recorder != nil || audioRecorder?.isStarted == true }
    SystemFocus.shared.onChange = { _, mode in ReminderFocus.shared.set(mode: mode) }
    SystemFocus.shared.apply()
    ReminderFocus.shared.set(mode: SystemFocus.shared.current)
    nowPlaying.apply()
    nextEvent.apply()
    mediaKeys.apply()
    smoothScroll.apply()
    finderKeys.apply()
    // 状态屏里键盘被拦着、录快捷键时按的是要录的组合：都不展开
    snippetExpander.isBusy = { [unowned self] in statusScreen.isActive || hotKeys.recording != nil }
    // 带 {input} 的片段：关键词删掉了，叫出剪贴板面板问（面板不激活本 App，填完粘回原来那个 App / 那条便签）
    snippetExpander.fill = { [unowned self] item in
      if !(clipboardPanel.isVisible && clipboardPanel.isKeyWindow) { toggleClipboard() }
      clipboardModel.fillSnippet(item)
    }
    snippetExpander.apply()
    showWelcomeIfNeeded()
    // 有快捷键没注册上（15.0 / 15.1 上只带 ⌥ 的组合）：按了没反应又不知道为什么，启动时说一次
    // （放在「已更新」之后：同一座岛原地换内容，警告不能被盖掉）
    if let failed = hotKeys.failures.keys.first {
      let count = hotKeys.failures.count
      island.show(
        count == 1 ? "「\(failed.title)」快捷键没注册上" : "有 \(count) 个快捷键没注册上",
        detail: "到 设置 › 快捷键 里看原因、换一个组合",
        tone: .warning, symbol: "keyboard", actions: [openHotKeySettings])
    }
    // 上次录屏 / 录音没正常收尾（闪退）：能播的挪进快速保存目录，说一声（C7）。
    // 压缩到一半退出留下的隐藏临时文件也删掉（E24：只删记下的那几个路径，不列保存目录）
    Task { await VideoExport.removePartials() }
    // 选过快速保存的文件夹却没存名字（0.10.0 及以前）：主线程外补上（第五轮体检 P2）
    ScreenshotOutput.rememberSaveFolderName()
    Task {
      for medium in [ScreenRecorder.Medium.screen, .audio] {
        guard
          let found = await ScreenRecorder.recover(
            into: ScreenshotOutput.saveDirectory, medium: medium)
        else { continue }
        island.show("\(found.title)", detail: "\(found.detail)", tone: found.tone)
      }
    }
    finishLaunchingNotes()
    // 按功能开关起各功能的后台活（剪贴板轮询、启动器 / 启动台扫目录、捏合和触发角、便签屏幕边缘），之后偏好一变就跟上：
    // 通用 › 功能、各页的「启用」、导入设置三条路都走这里，不另外接线
    applyFeatures()
    NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.applyFeatures()
        self.applyIdleOCRPreference()
        self.island.respondsToNotch = self.respondsToNotch
        self.applyIslandFeel()
        self.systemNotices.apply()
        self.hourlyChime.apply()
        SystemFocus.shared.apply()
        ReminderFocus.shared.settingChanged()
        self.nowPlaying.apply()
        self.nextEvent.apply()
        self.mediaKeys.apply()
        self.smoothScroll.apply()
        if Feature.keyRemapping.isOn { self.keyRemapping.defaultsChanged() }
        self.finderKeys.apply()
        self.snippetExpander.apply()
        // 命令的快捷键跟着「命令和别名」的开关和别名、脚本命令总开关、⌘K「关掉这条命令」走（第 4 批评审：只在那一页的
        // onChange 里跟，别处改的不注销）；没变不动
        self.hotKeys.reloadCommandsIfChanged()
        // 提醒列表在偏好里：设置页改了、导入了、它自己删掉响过的一次性提醒，都从这里跟上（只比列表那一个键）
        if Feature.reminders.isOn { self.reminders.defaultsChanged() }
      }
    }
    // 访达右键把 App 冷启动时交过来的动作：剪贴板历史、偏好都起来了再做（拷贝的路径才记得进历史）
    for url in pendingLinks { FinderLink.perform(url, island: island) }
    pendingLinks = []
  }

  /// 设置 › 刘海岛的「停在刘海上自动展开」「触感反馈」跟上（启动时、偏好变了时）
  private func applyIslandFeel() {
    island.hoverExpands = UserDefaults.standard.bool(forKey: Prefs.islandHoverExpands)
    island.haptics = UserDefaults.standard.bool(forKey: Prefs.islandHaptics)
    island.blurs = UserDefaults.standard.bool(forKey: Prefs.islandBlur)
    // 这两样归刘海岛插件：移除插件后不再藏起基本的提示（评审）
    island.hidesFromCapture =
      Feature.island.isOn && UserDefaults.standard.bool(forKey: Prefs.islandHidesFromCapture)
    island.hidesInFullScreen =
      Feature.island.isOn && UserDefaults.standard.bool(forKey: Prefs.islandHidesInFullScreen)
    let defaults = UserDefaults.standard
    island.dwellScale =
      (defaults.string(forKey: Prefs.islandNoticeLength).flatMap(Island.DwellLength.init)
      ?? .standard).scale
    island.hoverDelay = .milliseconds(
      Int(min(max(defaults.double(forKey: Prefs.islandHoverDelay), 0.1), 3) * 1000))
    island.levelStay = .milliseconds(
      Int(min(max(defaults.double(forKey: Prefs.islandLevelStay), 0.5), 10) * 1000))
    if island.levelAccent != defaults.bool(forKey: Prefs.islandLevelAccent) {
      island.levelAccent.toggle()
    }
    if island.levelPercent != defaults.bool(forKey: Prefs.islandLevelPercent) {
      island.levelPercent.toggle()
    }
    if island.outlined != defaults.bool(forKey: Prefs.islandOutlined) {
      island.outlined.toggle()
    }
  }

  /// 点刘海、停在刘海上、往下滑打开（有活动是它的卡片，没有是那一张）：刘海岛插件添加着，设置 › 刘海岛「点刘海打开」也开着
  private var respondsToNotch: Bool {
    Feature.island.isOn && UserDefaults.standard.bool(forKey: Prefs.islandNotchClicks)
  }

  /// 剪贴板历史现在记不记（剪贴板这个功能开着、没在菜单栏暂停）：本 App 自己写剪贴板的几处（Paster.recordText、截图、
  /// 录屏卡的拷贝）都看它，不各写各的
  var recordsClipboard: Bool { Feature.clipboard.isOn && !watcher.isUserPaused }

  private static let ocrFeatures: Set<Feature> = [.clipboard, .translate, .screenshot]

  /// 按功能开关（Feature，设置 › 通用 › 功能）起停各功能：后台活起 / 停、关掉的那些开着的界面收起、热键重新注册。
  /// 启动时调一次（只起开着的，不碰关着的功能），之后偏好一变就调，只对变了的功能做事；数据层（库、备份、到期清理）不动
  private func applyFeatures() {
    let now = Feature.enabled
    let copyToTranslate = UserDefaults.standard.bool(forKey: Prefs.translateCopyToTranslate)
    let before = appliedFeatures
    let placement = Prefs.ShotPlacement.current()
    guard
      now != before || copyToTranslate != appliedCopyToTranslate
        || placement != appliedPlacement
    else { return }
    appliedFeatures = now
    appliedCopyToTranslate = copyToTranslate
    appliedPlacement = placement
    let turnedOn = now.subtracting(before ?? [])
    let turnedOff = (before ?? []).subtracting(now)
    let launching = before == nil

    // 识字模型在启动 / 刚启用时提前准备；运行中缓存被清理，也走同一个 OCR.prepare，不等下一次截图。
    if now.isDisjoint(with: Self.ocrFeatures) {
      ocrMarkerWatcher?.stop()
      ocrMarkerWatcher = nil
    } else if !turnedOn.isDisjoint(with: Self.ocrFeatures), let marker = OCR.preparationMarker {
      if ocrMarkerWatcher == nil {
        ocrMarkerWatcher = OCRPreparationMarkerWatcher(marker: marker) { [weak self] in
          let prepared = await OCR.prepare(marker: marker)
          if prepared, !Task.isCancelled { self?.warmRecognitionIfKept() }
          return prepared
        }
      }
      ocrMarkerWatcher?.start(preparing: true)
    }

    // 新插件的「新」：添加了就算碰过（插件页改版 E1；启动时开着的也记——同步来的、旧版本里加过的）
    for plugin in turnedOn where plugin.isPlugin { WhatsNew.touch(plugin: plugin) }
    // 刘海岛插件（2026-11-13）：没添加时活动、常驻的刘海监听都停（Island.hasExtras），提示照常
    island.hasExtras = now.contains(.island)
    // 刚添加时提醒的倒数、专注模式里压着的那一个重新挂上（2026-11-17 评审）
    if turnedOn.contains(.island), !launching, now.contains(.reminders) { reminders.recheck() }
    // 剪贴板的轮询：记历史要它，复制即译也要它（剪贴板关着时只为复制即译跑、不入库）
    watcher.records = now.contains(.clipboard)
    if now.contains(.clipboard) || (now.contains(.translate) && copyToTranslate) {
      watcher.start()
    } else {
      watcher.stop()
    }
    if turnedOn.contains(.clipboard) { clipboardStore.recognizePendingImages() }
    // 启动器：约 65ms，放在启动时，第一次呼出就不用等；运行中打开的，第一次呼出时 prepareForShow 自己扫
    if launching, turnedOn.contains(.launcher) { launcherModel.rescanApps() }
    // 启动台的本机 App 目录也在启动时扫一遍（约 130ms Debug，见 PLAN §10「启动台」的量）：扫在启动时、不在打开时，
    // 打开到第一帧才稳在 100ms 以内（R11）；捏合、触发角按偏好起停（系统的捏合还开着时不注册回调）
    if turnedOn.contains(.launchpad) {
      launchpad.prepare()
      launchpad.applySettings()
    }
    if turnedOn.contains(.notes) {
      if !launching, let noteStore {
        NoteSample.addIfFirst(
          to: noteStore, defaults: .standard, hotKey: HotKeyAction.noteCapture.hotKey?.display)
      }
      if let noteEdge, !startedNoteEdge {
        startedNoteEdge = true
        noteEdge.start()
      } else {
        noteEdge?.floats.resume()  // 关掉时藏起来的浮动便签放回来（那叠看着偏好自己摆回来）
      }
    }

    // 晾衣绳（第十族）：截图开着、而且「截完图放哪」选的就是它才听鼠标（start 自己再查一次落点，
    // 选了别的就当场取下、收起）；截图关掉时也取下全部（挂着的标记本来就不跨重启）
    if Feature.screenshot.isOn { clothesline.start() }

    if turnedOn.contains(.reminders) { reminders.start() }
    if turnedOn.contains(.keepAwake) { keepAwake.start() }
    // 刘海岛插件刚添加：没添加时岛不收活动，开着的那段保持唤醒补挂上去
    if turnedOn.contains(.island), now.contains(.keepAwake) { keepAwake.syncIsland(force: true) }

    // 访达右键（拍板 D3）：运行中打开、系统里扩展还没打开时直接带去 系统设置 › 登录项与扩展；启动时、欢迎引导里勾上的不当场弹
    // （同程序坞预览要授权）。扩展自己读开关，这边没有后台活要起停
    if turnedOn.contains(.finderMenu), !launching, !settingsNavigation.showsOnboarding,
      !FIFinderSyncController.isExtensionEnabled
    {
      FinderMenuTab.openExtensionSettings()
    }

    // App 快捷键：运行中添加、还没有辅助功能授权时当场带去授权（同程序坞预览；没有它按住 ⌘ 听不到、菜单也读不了）
    if turnedOn.contains(.appShortcuts) {
      appShortcuts.start()
      if !launching, !settingsNavigation.showsOnboarding, !Permissions.isAccessibilityTrusted {
        Permissions.requestAccessibility()
      }
    }

    if turnedOn.contains(.keyRemapping) { keyRemapping.start() }

    // 睡眠关蓝牙：运行中添加、还没问过蓝牙授权时当场问（同程序坞预览：启动时、欢迎引导里勾上的不当场弹）
    if turnedOn.contains(.bluetoothSnooze) {
      bluetoothSnooze.start()
      if !launching, !settingsNavigation.showsOnboarding, !BluetoothSnooze.isAuthorized {
        bluetoothSnooze.requestAccess()
      }
    }

    if turnedOn.contains(.dockPreview) {
      dockPreview.start()
      // 运行中打开时缺授权就带去授权（拍板 A3）：先要辅助功能（没有它用不了），有了再要屏幕录制（没有只列标题）；
      // 启动时不问（关着的人、早就给过的人都不打扰）；在欢迎引导第一屏勾上的也不当场问，交给引导的授权那一屏（功能管理 M6：
      // 当场弹会盖住引导，还把「请求过」用掉，授权屏的「去授权」就只能开系统设置了）
      if !launching, !settingsNavigation.showsOnboarding {
        if !Permissions.isAccessibilityTrusted {
          Permissions.requestAccessibility()
        } else if !Permissions.isScreenRecordingAllowed {
          Permissions.requestScreenRecording()
        }
      }
    }

    // 插件移除：停掉、不再听（手动开着的那一段也停）
    if turnedOff.contains(.keepAwake) { keepAwake.stop() }

    // 平滑滚动：起停在 smoothScroll.apply（偏好监听里调）。运行中添加时缺授权就当场要（同程序坞预览；启动时、欢迎引导里不问）；
    // 别的改滚轮的工具开着时说一声（两层平滑会叠在一起、两层反向会反回去）
    if turnedOn.contains(.smoothScroll), !launching, !settingsNavigation.showsOnboarding {
      if !Permissions.isAccessibilityTrusted { Permissions.requestAccessibility() }
      if let other = SmoothScroll.runningOtherTools().first {
        island.show(
          "「\(other)」也在处理鼠标滚轮", detail: "两边一起开会平滑两次、反向两次：留一边就好", tone: .warning,
          symbol: "computermouse")
      }
    }

    // 片段展开：起停在 snippetExpander.apply（偏好监听里调）。运行中添加时缺授权就当场要（同平滑滚动；启动时、欢迎引导里不问）
    if turnedOn.contains(.snippetExpand), !launching, !settingsNavigation.showsOnboarding,
      !Permissions.isAccessibilityTrusted
    {
      Permissions.requestAccessibility()
    }

    guard !launching else { return }
    // 正在录快捷键时热键停着，录完它自己会重新注册；只是复制即译开关变了不用重新注册
    if now != before, hotKeys.recording == nil { hotKeys.reload() }
    guard !turnedOff.isEmpty else { return }
    if turnedOff.contains(.clipboard) {
      builtClipboardPanel?.hide()
      quickLookPanel.panel?.hide()
      // 菜单栏的「暂停记录」跟着剪贴板藏起来了：恢复，免得复制即译也一直被它挡着
      setRecordingPaused(false)
    }
    if turnedOff.contains(.launcher) {
      builtLauncherPanel?.hide()
      launcherQuickLook.panel?.hide()
    }
    if turnedOff.contains(.translate) {
      builtTranslatePanel?.hide()
      // 浮窗没开着时 onHide 不会来：进行中的请求、朗读直接停
      coordinator.cancel()
      speaker.stop()
      replaceTask?.cancel()
      replaceTask = nil
    }
    if turnedOff.contains(.screenshot) {
      shotCountdown?.cancel()  // 延时截图的倒数（N2）
      if !pins.panels.isEmpty { pins.closeAll() }
      clothesline.stop()
      // 截图历史窗口、长图标注也收（R10：原来关掉截图它们还开着、还能出图）；历史窗口走自己的 onClose 清缓存
      shotHistoryWindow?.window.close()
      annotateOverlay?.close()
    }
    if turnedOff.contains(.record) {
      // 正在录：照常停止并收尾（文件存好、飞出卡片，同退出时）；待录的控制条直接收掉
      closeReadyAudio()
      recorder?.stop()
      audioRecorder?.stop()
    }
    if turnedOff.contains(.notes) {
      noteStore?.flush()
      noteCapture?.panel.hide()
      // 最小化在程序坞里的也关（不然点回来照样能用）
      if let window = notesWindow?.window, window.isVisible || window.isMiniaturized {
        window.close()
      }
      // 浮动便签先藏起来（固定着的位置记录不清，打开后放回原处）；那叠看着偏好自己收起
      noteEdge?.floats.suspend(covering: .infinite)
    }
    // 同步不跟着功能开关起停（设置那部分一直在合）：关着的功能那部分一轮里跳过（featureOn）；打开的那一刻合一轮
    if !launching, !turnedOn.isDisjoint(with: Self.syncFeatures.values) { noteSyncer?.syncNow() }
    if turnedOff.contains(.launchpad) { launchpad.turnOff() }
    if turnedOff.contains(.statusScreen) { statusPicker.panel?.hide() }
    if turnedOff.contains(.dockPreview) { dockPreview.stop() }
    if turnedOff.contains(.bluetoothSnooze) { bluetoothSnooze.stop() }
    if turnedOff.contains(.appShortcuts) { appShortcuts.stop() }
    if turnedOff.contains(.keyRemapping) { keyRemapping.stop() }
    if turnedOff.contains(.reminders) { reminders.stop() }
    idleReclaim.schedule()  // 关掉的功能占着的缓存跟着还
  }

  /// 启动的最后一步，几样连着做：开便签库、清「最近删除」里到期的、从没有过便签的人放一条示例（NoteSample，
  /// 在备份和屏幕边缘开始之前：当天那份备份里带着它，边缘一开始就有药丸）、今天的第一次备份。
  /// 放在最后：便签库打不开时要弹框问，弹框里说「剪贴板、翻译和别的功能不受影响」——这时剪贴板监听、热键、菜单栏图标
  /// 都已经起来了，这句话才是真的。备份跟在后面：便签还没开就备，当天那份 JSON 里就没有便签（backupIfDue 也因此等着）
  private func finishLaunchingNotes() {
    noteStore = openNotes()
    hasOpenedNotes = true
    // 图片目录（第 7 批行内图片）：和库一起开；库这次不可用时不给（图都画占位框、粘进来的存不了）
    noteStore?.images = NoteImageStore(
      directory: dataDirectory.appending(path: NotesBackup.imagesName))
    purgeNotes()
    // 便签关着（Feature）时库照开、到期照清、照常备份；示例便签和屏幕边缘等打开时再说（applyFeatures）
    if let noteStore, Feature.notes.isOn {
      NoteSample.addIfFirst(
        to: noteStore, defaults: .standard, hotKey: HotKeyAction.noteCapture.hotKey?.display)
    }
    backupIfDue()
    noteEdge = noteStore.map(makeNoteEdge)
    // 开着的空白便签不删（NoteStore.left，第四轮体检 E11）：那叠里开着的、浮着的、全部便签窗口里选着的
    noteStore?.isOpen = { [unowned self] id in
      noteEdge?.isOpen(id) == true
        || (notesWindow?.isVisible == true && notesModel?.selection == id)
    }
    if let noteStore {
      let syncer = NoteSyncer(store: noteStore)
      syncer.island = island
      syncer.openSettings = { [unowned self] in showSyncSettings() }
      // 上次停止同步、换服务器时没删完就退了的镜像（第五轮体检 E14）
      syncer.removeStaleMirrors()
      // 从只同步便签的版本升上来：新加的几类先没勾（NoteSyncer.isUpgrade），说一声去哪里勾。「已更新到」那座岛已经并进去
      // 说了的不再说；岛上正挂着警告（快捷键没注册上）时也不弹——同一座岛原地换内容，警告不能被盖掉，只靠设置页那句
      if syncer.upgraded, !toldSyncUpgrade, island.content?.tone != .warning {
        island.show(
          "现在也能同步设置、片段和收藏这些了", detail: "要同步哪几类，到 设置 › 通用 › 同步 里勾上", tone: .info,
          symbol: "arrow.triangle.2.circlepath.circle.fill", actions: [openSyncSettings])
      }
      let settings = SettingsSync(applied: { [unowned self] in
        // 换了保留天数、图片上限这些，清掉了历史的说一声（不然无声少了东西）
        let pruned = settingsImported()
        if pruned > 0 {
          island.show(
            "同步换了剪贴板的保留设置", detail: "按新的设置清掉了 \(pruned) 条历史", tone: .info,
            symbol: "arrow.triangle.2.circlepath.circle.fill")
        }
      })
      // 正在录屏 / 录音、录快捷键、状态屏开着：这一轮先不合设置（对面关掉录制功能会把这台正在录的停掉）
      settings.isBusy = { [unowned self] in
        recorder != nil || audioRecorder != nil || hotKeys.recording != nil
          || statusScreen.isActive
      }
      settings.conflicted = { [unowned self] pair in
        island.show(
          "同步来的快捷键撞上了", detail: "\(pair)用的是同一个组合，到 设置 › 快捷键 里改一个",
          tone: .warning, actions: [openHotKeySettings])
      }
      syncer.sources = [
        clipboardStore, historyStore, WebSearchSync(), TranslateServiceSync(store: serviceStore),
        launcherUsage, StatusPresetSync(), ReminderSync(), settings,
      ]
      syncer.featureOn = { Self.syncFeatures[$0]?.isOn ?? true }
      noteSyncer = syncer
      syncer.start()
    }
  }

  /// 同步的每一部分跟着哪个功能（NoteSyncer.featureOn：关着的那部分不合；设置不跟任何功能，一直合）
  private static let syncFeatures: [String: Feature] = [
    NoteSyncer.notesPart: .notes, SyncRecords.Kind.clips.rawValue: .clipboard,
    SyncRecords.Kind.vocabulary.rawValue: .translate, SyncRecords.Kind.engines.rawValue: .launcher,
    SyncRecords.Kind.services.rawValue: .translate, SyncRecords.Kind.launcher.rawValue: .launcher,
    SyncRecords.Kind.statuses.rawValue: .statusScreen,
    SyncRecords.Kind.reminders.rawValue: .reminders,
  ]

  /// 便签的定期清理：「最近删除」里放满 30 天的真删；图片目录里没人引用满 30 天的文件删掉
  /// （账记在目录里的 .orphans.plist，从**第一次发现**没人引用算起）。便签这次用不了时不清（noteStore 是 nil）
  private func purgeNotes() {
    guard let noteStore else { return }
    noteStore.purgeExpired()
    // 快速记一条的草稿里贴的图也算有人引用（X5）：开着的面板看内存里的，没建过面板看草稿文件
    let draft =
      noteCapture.map { Set($0.model.images.map(\.id)) }
      ?? NoteCaptureModel.draftImages(
        at: dataDirectory.appending(path: NoteCaptureModel.draftName))
    noteStore.images?.purge(referenced: noteStore.referencedImages.union(draft))
  }

  /// 屏幕边缘的便签：右键菜单里的「全部便签」「设置…」、「在全部便签里打开」接到这里的入口；什么时候不许扇出也由这里说
  private func makeNoteEdge(_ store: NoteStore) -> NoteEdge {
    let edge = NoteEdge(store: store, island: island)
    edge.canFan = { [unowned self] in canFanNotes }
    edge.showNotes = { [unowned self] in showNotes() }
    edge.showSettings = { [unowned self] in showSettings(.notesDeck) }
    edge.showInWindow = { [unowned self] in showNotes(revealing: $0) }
    // 那叠收起、浮动便签收回：也排空闲回收（只用便签的人，看过的图也要还回去）
    edge.onHide = { [unowned self] in idleReclaim.schedule() }
    return edge
  }

  /// 便签屏幕边缘的药丸现在响不响应鼠标：截图 / 截图翻译 / 识字 / 录屏的框选和长截图进行中（isCapturing；另看一眼遮罩在
  /// 不在）、录屏倒数的那几秒、状态屏里都不响应。这些会话开始的地方另外显式叫停已经展开的那叠（NoteEdge.suspend）——
  /// 不靠「被别的窗口盖住就收不到鼠标」（追踪区不看遮挡），也不为它加轮询（mac-overlay-panel §12）
  private var canFanNotes: Bool {
    !isCapturing && recorder?.isCountingDown != true && !statusScreen.isActive
      && !OverlayPanel.isSelectingRegion(in: NSApp.windows)
  }

  /// 在录屏 / 录音时先停止并收尾再退（13 条默认细节：最多等 5 s；没写完也照样退，录屏由 replayd 自己收尾，下次启动 recover 接手）
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    // 便签攒着的改动先落下去；落不下去、用户选了取消就不退（这时录屏 / 录音什么都还没动）
    guard flushNotesBeforeQuit() else { return .terminateCancel }
    // 快速记一条停手不到 1 秒的草稿（E2）
    noteCapture?.model.saveDraft()
    closeReadyAudio()  // 待录的录音控制条没有东西要收尾：直接收掉，不等它回调
    guard recorder != nil || audioRecorder != nil else {
      guard updater.hasPrepared else { return .terminateNow }
      replyQuit()
      return .terminateLater
    }
    quitsAfterRecording = true
    recorder?.stop()
    audioRecorder?.stop()
    Task {
      try? await Task.sleep(for: .seconds(5))
      guard quitsAfterRecording else { return }
      quitsAfterRecording = false
      replyQuit()
    }
    return .terminateLater
  }

  /// .terminateLater 之后回话「可以退了」：先装上后台下好的新版本（第四轮体检 X11；装不成照常退）。最多等 30 秒
  /// （解包、验签各自的上限加起来要几分钟）：到点直接退，装到一半的不换上（换上那一下是原子的），下次打开再查再下
  func replyQuit() {
    quitReplyPending = true
    let finish = { [unowned self] in
      guard quitReplyPending else { return }
      quitReplyPending = false
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    Task {
      await updater.installPrepared()
      finish()
    }
    Task {
      try? await Task.sleep(for: .seconds(30))
      finish()
    }
  }

  /// 退出前把便签攒着没落盘的改动落下去（应用内更新的重启也走这里：Updater.install 调的是 NSApp.terminate）。
  /// 落不下去不悄悄丢：弹框说原因，「再试一次」「仍要退出」「取消」。返回能不能接着退
  private func flushNotesBeforeQuit() -> Bool {
    guard isRunning, let noteStore else { return true }
    return noteStore.flushBeforeQuit { problem in
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = String(localized: "便签没存上")
      alert.informativeText = String(
        localized: "最近改的便签没能写进磁盘（\(problem)）。\n现在退出，这些改动就丢了；可以先把正在写的那条拷贝到别处，再试一次。")
      alert.addButton(withTitle: String(localized: "再试一次"))
      alert.addButton(withTitle: String(localized: "仍要退出")).hasDestructiveAction = true
      // Esc = 取消
      alert.addButton(withTitle: String(localized: "取消")).keyEquivalent = "\u{1b}"
      NSApp.activate()
      switch alert.runModal() {
      case .alertFirstButtonReturn: return .retry
      case .alertSecondButtonReturn: return .quitAnyway
      default: return .cancel
      }
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    guard isRunning else { return }
    ocrMarkerWatcher?.stop()
    ocrMarkerWatcher = nil
    if Feature.keyRemapping.isOn { keyRemapping.stop() }
    FileMoves.forgetCut()  // 访达右键剪切的清单只在内存里：退出后扩展别再列「粘贴」
    statusScreen.exit(.quit)  // 在状态屏里被要求退出（远程、脚本）：拦截当场撤掉
    SystemFocus.shared.terminate()  // 读专注模式的 log stream 当场停掉，不留给 launchd（评审）
    // 便签：applicationShouldTerminate 已经落过、落不下去也问过了；这里再落一次兜着之后才有的改动（等录屏收尾的那几秒）
    noteStore?.flush()
    // 面板固定着删了再退出：删掉的也要落库（撤销栈平时在面板收起时提交，体检 A2），⌘C 复制过的挪到最前
    clipboardModel.reset()
    if UserDefaults.standard.bool(forKey: Prefs.clipboardClearOnQuit) {
      clipboardStore.clearOrdinary()
    }
  }

  /// 访达右键的扩展把动作交过来（App 自己的网址，Info.plist 的 CFBundleURLTypes）。先看发送方是不是自家的访达扩展
  /// （本团队签名；这一刻的苹果事件里带着发送方，冷启动时存起来的也是在这里核对过的）；别的网址、对不上凭证的都不做
  func application(_ application: NSApplication, open urls: [URL]) {
    guard FinderLink.fromOwnExtension(NSAppleEventManager.shared().currentAppleEvent) else {
      Log.finder.notice("网址不是自家访达扩展发来的，没理")
      return
    }
    guard isRunning else {
      pendingLinks += urls
      return
    }
    for url in urls { FinderLink.perform(url, island: island) }
  }

  /// 再打开一次本 App：点程序坞图标（设置窗等普通窗口开着时才有）、在访达或启动器里打开已经在运行的它。
  /// 打开主界面（2026-10-29 拍板 C2；原来是进设置，设置从主界面一键过去）；菜单栏图标隐藏时（设置 › 通用，第 9 批 M1）
  /// 就靠这条回来
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    // 启动时「数据打不开」的弹框还开着（没有程序坞图标，容易被别的窗口盖住再点一次）：把它带到前面，不建设置窗
    guard isRunning else {
      NSApp.activate()
      return false
    }
    // 普通窗口（设置窗、全部便签窗口、截图历史）开着时点程序坞图标——图标就是它们带出来的：把开着的带到前面就行，
    // 不另开主界面
    if NSApp.windows.contains(where: { $0.isVisible && !($0 is NSPanel) && $0.canBecomeMain }) {
      NSApp.activate()
      return true
    }
    // 从访达 / 程序坞再打开一次时本 App 被激活了：主界面是不激活的面板，先把前台还给原来的 App（deactivate 交还给
    // 上一个在前台的），不然从主界面打开的剪贴板、片段 ⌘V 落到本 App 自己身上（第四轮体检 E22②）。
    // 失活不一定当场落定：等真退到后面了再出主界面（最多 0.5 s），不然它刚当上 key 就跟着本 App 一起被撤掉
    guard NSApp.isActive else {
      showHome()
      return false
    }
    NSApp.deactivate()
    Task { [weak self] in
      for _ in 0..<25 where NSApp.isActive { try? await Task.sleep(for: .milliseconds(20)) }
      self?.showHome()
    }
    return false
  }
}
