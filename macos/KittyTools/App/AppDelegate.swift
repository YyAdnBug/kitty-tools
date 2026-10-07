// 应用生命周期：单实例检查，按依赖顺序组装各模块（PLAN §4），热键与各翻译入口，首次安装打开欢迎引导、
// 更新后第一次启动用刘海岛说一声，退出 / 锁屏时的清理；数据打不开时问用户怎么办、每天备份的时机（Storage/Backup.swift）；
// 录屏（框选、开录、结果、飞入和视频卡、退出前收尾、上次闪退留下的文件）；
// 录音（录音第 5 批：开录、和录屏互斥、结果、飞入和录音卡，收尾和闪退恢复同录屏）。

import AppKit
import OSLog
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
  /// 数据打开之后才算跑起来，才做退出清理、才响应「再打开一次」：让位退出的重复实例、还停在「数据打不开」弹框上的
  /// 都不能碰数据库（弹框开着时去读 stores 会把打开流程再跑一遍）
  private var isRunning = false
  /// 划词取词进行中：重复按热键直接忽略
  private var isReadingSelection = false
  /// 进行中的「划词翻译并替换」：再按一次热键取消
  private var replaceTask: Task<Void, Never>?
  /// 这次替换的标记：旧任务收尾时只清自己的引用，别把紧接着启动的新任务清掉
  private var replaceID: UUID?
  /// 截图 / 截图翻译进行中（截屏 → 框选 → 识别或输出）：重复按热键直接忽略。录屏只占框选阶段（C9）
  private var isCapturing = false
  /// 录屏会话（框选之后、开录到文件挪好）：在录时录屏的入口都是停止；录制中照样能截图、识字、截图翻译（C9）
  private var recorder: ScreenRecorder?
  /// 录音会话（录音第 5 批，开录到文件挪好）：在录时录音的入口都是停止；和录屏互斥（C9-a）。手测反馈第 3 批起它可能还在
  /// 待录（控制条出来了、没开始，isStarted 为 false）：这时录音的入口是开始，不算在录（菜单标题、互斥、更新、退出都不看它）
  private var audioRecorder: AudioRecorder?
  /// 退出时在等录屏 / 录音收尾（applicationShouldTerminate 返回了 .terminateLater）
  private var quitsAfterRecording = false
  let hotKeys = HotKeyCenter()

  // MARK: 数据与服务（按依赖顺序）

  /// ~/Library/Application Support/<bundle id>/（Debug 与 Release 的 bundle id 不同，数据天然隔离）
  private let dataDirectory = URL.applicationSupportDirectory.appending(
    path: Bundle.main.bundleIdentifier ?? "com.yy.kitty-tools.native")
  /// 库和读它的三个仓库：一起打开，哪一步（开库、建表、读表）抛错都算打不开，不留开到一半的连接
  /// （不是 private：BackupTests 在临时目录里拿它走真的打开流程）
  struct Stores {
    let clipboard: ClipboardStore
    let launcher: LauncherUsage
    let history: HistoryStore

    init(in directory: URL) throws {
      let images = directory.appending(path: "images")
      try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
      let database = try Database(path: directory.appending(path: Backup.databaseName).path)
      clipboard = try ClipboardStore(db: database, images: ImageStore(directory: images))
      launcher = try LauncherUsage(db: database)
      history = try HistoryStore(db: database)
    }
  }
  private lazy var stores = Self.openOrQuit(in: dataDirectory)
  private var clipboardStore: ClipboardStore { stores.clipboard }
  private var launcherUsage: LauncherUsage { stores.launcher }
  private var historyStore: HistoryStore { stores.history }
  /// 备份正在做（backupIfDue）：换日和锁屏的通知挨着来时不做两遍
  private var isBackingUp = false
  private lazy var watcher = ClipboardWatcher(store: clipboardStore)
  private let serviceStore = TranslateServiceStore()
  private lazy var coordinator = TranslateCoordinator(services: serviceStore, history: historyStore)
  private let speaker = Speaker()
  /// 刘海岛（全局轻提示）
  private let island = Island()
  /// 应用内更新（读本仓库的 GitHub release）
  private let updater = Updater()
  /// CleanShot 式常驻缩略图（截图飞入右下角后留在那里）
  private let shelf = ShotShelf()
  /// 菜单栏图标与菜单（启动后才建：单测以本 App 为宿主时不往菜单栏加东西）
  private var statusItem: StatusItem?
  /// 钉图（菜单栏显示「隐藏 / 关闭全部钉图」）
  lazy var pins: PinBoard = {
    let board = PinBoard()
    // 钉图不变、不飞卡片：拷贝、存好了都用刘海说（体检 C9：⌘S 快速保存，同截图；识字 / 翻译同截图工具栏，D17）
    board.output = { [unowned self] action, image, scale in
      Task {
        switch action {
        case .copy:
          guard await copyImage(image, scale: scale) != nil else { return }
          island.show("已复制钉图", leading: Island.thumbnail(of: image))
        case .save:
          guard let saved = await saveImage(image, scale: scale, asking: false) else { return }
          island.show(
            FlyCard.Badge.saved(saved.url).title, detail: saved.url.lastPathComponent,
            leading: Island.thumbnail(of: image))
        case .saveAs: await saveImageAs(image, scale: scale)
        case .recognize: await copyRecognizedText(in: image)
        case .translate: await translateImage(image)
        case .pin: break
        }
      }
    }
    return board
  }()

  // MARK: 窗口

  private lazy var clipboardModel = ClipboardPanelModel(store: clipboardStore)
  private lazy var launcherModel = LauncherModel(usage: launcherUsage)

  /// 空闲回收（常驻内存，2026-10-07，PLAN §10）：三块主面板哪块收起、进程内识完一次字都重新计时，过了
  /// Memory.idleDelay 还没有面板开着，就把闲着白占的还回去——透镜缓存（装满约 50 MB，再看到时重做）、识字模型
  /// （约 50 MB，下次识字重新加载，慢 0.2–0.4 s；放它要 18–200 ms，在主线程外做）、分配器手里的空页（跑了三天的
  /// 正式版估 20–34 MB；放在最后，前两样腾出来的页一起还）。到点时还有面板开着（固定着、正在用）或正在框选就再等一轮
  private lazy var idleReclaim = Memory.IdleTimer(
    after: Memory.idleDelay,
    isIdle: { [unowned self] in
      !isCapturing && !NSApp.windows.contains { $0 is OverlayPanel && $0.isVisible }
    },
    work: { [unowned self] in reclaimIdleMemory() })

  private func reclaimIdleMemory() {
    ThumbnailView.dropPreviews()
    Task {
      await OCR.releaseModel()
      Memory.relieve()
    }
  }

  private lazy var launcherPanel: OverlayPanel = {
    let model = launcherModel
    let panel = OverlayPanel(
      size: NSSize(width: 720, height: LauncherPanelView.searchHeight), topAnchored: true,
      // 启动器没有固定（N8）：点外面就收起
      autoHide: .clickOutside, isPinned: { false },
      content: LauncherPanelView(model: model).environment(updater))
    panel.keyEquivalentHandler = { [unowned model] in model.handleKeyEquivalent($0) }
    panel.onHide = { [unowned self, unowned model] in
      model.didHide()
      idleReclaim.schedule()
    }
    panel.squeezesIn = { Self.squeezesIn() }
    model.hidePanel = { [unowned panel] in panel.hide() }
    // ⌘K 菜单开着时瞬间长高：菜单锚在底栏上方，面板边长边插进来会越过搜索栏被裁，得先长好再从右下角放大
    model.resize = { [unowned panel, unowned model] in
      panel.setContentHeight($0, animated: !model.showsActions)
    }
    model.runAction = { [unowned self] in runLauncherAction($0) }
    model.actionState = { [unowned self] in menuState }
    model.openSettings = { [unowned self] in showSettings(page: .launcher) }
    model.openClipboard = { [unowned self] in searchClipboard($0) }
    // fy 那一行（体检 D10）：翻译浮窗直接翻译，位置照「浮窗位置」设置（跟随鼠标 / 上次位置）
    model.translate = { [unowned self] text in
      coordinator.translate(text)
      presentTranslate()
    }
    model.openQuickLook = { [unowned self] in
      launcherQuickLook.open().zoom(
        from: launcherRowFrame ?? launcherPanel.frame, to: launcherQuickLookFrame)
    }
    model.closeQuickLook = { [unowned self] animated in
      Self.closeQuickLook(
        launcherQuickLook.panel, owner: launcherPanel, animated: animated, to: launcherRowFrame)
    }
    model.boundHotKey = { [unowned self] in hotKeys.bindings[$0] }
    model.requestFolderAccess = { [unowned self] in requestFolderAccess() }
    model.perform = { [unowned self] in SystemControl.perform($0, island: island) }
    model.island = island
    return panel
  }()

  /// 启动器 ⌘Y 快速查看（体检 C7）：选中文件的 Quick Look 卡，从选中行长出来；同剪贴板 ⌘Y 大卡，不抢键盘
  /// （点它里面才当 key），点外面就关，↑↓ 仍在启动器里换选中、预览跟着换。用时再建、收起后放掉（TransientPanel）
  private lazy var launcherQuickLook = TransientPanel { [unowned self] in
    let panel = OverlayPanel(
      size: NSSize(width: 900, height: 680), autoHide: .clickOutside, isPinned: { false },
      content: LauncherQuickLookView(model: launcherModel))
    panel.becomesKeyOnlyIfNeeded = true
    panel.keyEquivalentHandler = { [unowned self] in launcherModel.handleKeyEquivalent($0) }
    panel.onHide = { [unowned self] in
      launcherModel.quickLookDidHide()
      Self.returnKey(to: launcherPanel)
    }
    return panel
  }

  /// 启动器选中行的屏幕坐标：滚出可见区、报上来的不是当前选中项时为 nil（预览退回从面板长出 / 原地淡出）
  private var launcherRowFrame: NSRect? {
    guard launcherPanel.isVisible, let row = launcherModel.rowFrame,
      row.id == launcherModel.selectedItem?.id
    else { return nil }
    return launcherPanel.screenRect(of: row.rect)
  }

  /// 预览卡的位置：以启动器为中心、900×680（同剪贴板单个文件的大卡）
  private var launcherQuickLookFrame: NSRect {
    launcherPanel.centeredFrame(NSSize(width: 900, height: 680))
  }

  /// ⌘Y 大卡缩回 / 收起（剪贴板、启动器共用）：缩回动画期间它还在屏幕上，点过里面（它是 key）就先把 key 还给主面板，
  /// 别让这 0.24 s 里按的键落空。card 是 nil = 没开着（没建过、或者收起后已经放掉）
  private static func closeQuickLook(
    _ card: OverlayPanel?, owner: OverlayPanel, animated: Bool, to frame: NSRect?
  ) {
    guard let card else { return }
    guard animated else { return card.hide() }
    if card.isKeyWindow, owner.isVisible { owner.makeKey() }
    card.unzoom(to: frame)
  }

  /// 剪贴板、启动器、翻译浮窗呼出时挤压弹开（设置 › 通用「动效」；三块面板统一，2026-09-29 用户要求）
  private static func squeezesIn() -> Bool {
    UserDefaults.standard.bool(forKey: Prefs.panelSqueezeEntrance)
  }

  /// ⌘Y 大卡收走后：键盘关掉的（它是 key 时按 Esc）把 key 还给主面板；点别处关掉的不抢（鼠标还按着：用户正要去别处打字）
  private static func returnKey(to owner: OverlayPanel) {
    if NSApp.keyWindow == nil, NSEvent.pressedMouseButtons == 0, owner.isVisible {
      owner.makeKey()
    }
  }

  private lazy var clipboardPanel: OverlayPanel = {
    let model = clipboardModel
    // 透镜指令条：和启动器同位置同宽（顶边在可见区 20%），高度按条数伸缩、顶边不动
    let panel = OverlayPanel(
      size: NSSize(
        width: ClipboardPanelView.width, height: ClipboardPanelView.height(for: model)),
      topAnchored: true, autoHide: .clickOutside,
      isPinned: { !UserDefaults.standard.bool(forKey: Prefs.clipboardHideOnUnfocus) },
      content: ClipboardPanelView(model: model).environment(updater))
    panel.keyEquivalentHandler = { [unowned model] in model.handleKeyEquivalent($0) }
    panel.onHide = { [unowned self, unowned model] in
      model.reset()
      idleReclaim.schedule()
    }
    panel.squeezesIn = { Self.squeezesIn() }
    model.hidePanel = { [unowned panel] in panel.hide() }
    model.resize = { [unowned panel] in panel.setContentHeight($0, animated: true) }
    // 剪贴板面板保持打开（兄弟浮层），翻译浮窗出现在旁边
    model.openTranslate = { [unowned self] text in
      coordinator.translate(text)
      presentTranslate()
    }
    // ⌘, 和底栏齿轮直达 设置 › 剪贴板（同翻译浮窗直达 设置 › 翻译）
    model.openSettings = { [unowned self] in showSettings(page: .clipboard) }
    model.openQuickLook = { [unowned self] in showQuickLook() }
    // 图片条目「钉到屏幕」（体检 D1）：和截图的钉图同一块板
    model.pinImage = { [unowned self] in pins.pin($0, frame: $1) }
    model.pinnedFrames = { [unowned self] in pins.panels.map(\.frame) }
    model.island = island
    model.closeQuickLook = { [unowned self] animated in
      Self.closeQuickLook(
        quickLookPanel.panel, owner: clipboardPanel, animated: animated, to: cardScreenFrame)
    }
    return panel
  }()

  /// ⌘Y 放大预览：剪贴板选中条目的大卡片。不抢键盘（点它里面的文字才当 key），点外面就关。
  /// 用时再建、收起后放掉（TransientPanel）；放掉时把大卡那一档的缩略图也丢掉，再让分配器把空页还给系统（体检 M1 M4）
  private lazy var quickLookPanel = TransientPanel(
    onRelease: {
      ThumbnailView.dropCards()
      Memory.relieve()
    },
    make: { [unowned self] in
      weak var created: OverlayPanel?
      let panel = OverlayPanel(
        size: NSSize(width: 820, height: 640), autoHide: .clickOutside, isPinned: { false },
        content: QuickLookView(model: clipboardModel) { [unowned self] item in
          // 连按方向键时直接换尺寸（先瞬时，再动画）
          created?.move(to: quickLookFrame(for: item), animated: !Style.isKeyRepeat)
        })
      created = panel
      panel.becomesKeyOnlyIfNeeded = true
      panel.keyEquivalentHandler = { [unowned self] in clipboardModel.handleKeyEquivalent($0) }
      panel.onHide = { [unowned self] in
        clipboardModel.quickLookDidHide()
        Self.returnKey(to: clipboardPanel)
      }
      return panel
    })

  private lazy var translatePanel: OverlayPanel = {
    // 视图在面板建好之前就可能要求改高度：用弱引用接，别在 lazy 初始化里回头访问 translatePanel
    weak var created: OverlayPanel?
    let panel = OverlayPanel(
      size: NSSize(width: 420, height: 560), minSize: NSSize(width: 360, height: 200),
      frameName: "TranslatePanel", autoHide: .resignKey,
      isPinned: { UserDefaults.standard.bool(forKey: Prefs.floatingPinned) },
      content: TranslatePanelView(
        coordinator: coordinator, speaker: speaker,
        resize: { height, mustFit in
          // 高度随内容（Bob 的做法），前三张结果卡总放得下（TranslatePanelView.panelHeight）。
          // 最小 / 最大高度都钉在这个值上：用户只能拖宽度，拖高度会和自动高度打架
          guard let panel = created else { return }
          let visible = (panel.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
          let height = TranslatePanelView.panelHeight(height, mustFit: mustFit, visible: visible)
          panel.minSize = NSSize(width: 360, height: height)
          panel.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: height)
          // 变化 8 pt 以上才带动画：流式输出时每来几个字都会长一点，小变化直接设
          panel.setContentHeight(height, animated: abs(panel.frame.height - height) >= 8)
        },
        replaceOriginal: { [unowned self] in replaceOriginal() }
      ).environment(island))
    created = panel
    coordinator.historyList.island = island
    panel.keyEquivalentHandler = { [unowned self] in coordinator.handleKeyEquivalent($0) }
    // ⌘,、「⋯」菜单和空状态到设置 › 翻译；错误卡带服务 id，直达那个服务的详情页（体检 C5）
    coordinator.openSettings = { [unowned self] service in
      showSettings(page: .translate)
      // 设置窗开着速查表 / 确认框时不换页（SettingsWindow.show）：没到翻译页就不推，别把服务 id 推进别的页的 NavigationStack
      if let service, settingsNavigation.page == .translate { settingsNavigation.path = [service] }
    }
    coordinator.focusSource = { [unowned panel] in
      panel.makeFirstResponder(panel.initialFirstResponder)
    }
    panel.onHide = { [unowned self, unowned panel] in
      // 收起即作废进行中的请求（省额度）、停下朗读（体检 B23）；把 key 还给之前处于 key 的浮层（剪贴板面板 / 启动器）。
      // 已有别的窗口成了 key（因失焦而收起）就不抢
      coordinator.cancel()
      speaker.stop()
      if NSApp.keyWindow == nil, let previous = panel.previousKeyPanel, previous.isVisible {
        previous.makeKey()
      }
      idleReclaim.schedule()
    }
    panel.squeezesIn = { Self.squeezesIn() }
    return panel
  }()

  private func showQuickLook() {
    guard let item = clipboardModel.selectedItem else { return }
    // 右键菜单 / 无障碍的「放大预览」同一拍里先换选中再打开：先让面板把布局做完，新选中的透镜才报上位置
    if clipboardModel.cardFrame?.id != item.id {
      clipboardPanel.contentView?.layoutSubtreeIfNeeded()
    }
    clipboardModel.showsQuickLookContent = true
    quickLookPanel.open().zoom(
      from: cardScreenFrame ?? clipboardPanel.frame, to: quickLookFrame(for: item))
  }

  /// ⌘Y 大卡摆在哪：按条目的理想尺寸（图片放不下时等比缩进所在屏可见区的 90%），以剪贴板面板为中心
  private func quickLookFrame(for item: ClipItem) -> NSRect {
    clipboardPanel.centeredFrame(
      QuickLookView.idealSize(
        for: item, form: clipboardModel.contentForm(of: item), within: clipboardPanel.cardLimit))
  }

  /// 透镜（选中行）的屏幕坐标：剪贴板面板不在、透镜滚出可见区、报上来的不是当前选中项时为 nil（放大卡退回从面板长出）
  private var cardScreenFrame: NSRect? {
    guard clipboardPanel.isVisible, let card = clipboardModel.cardFrame,
      card.id == clipboardModel.selectedItem?.id
    else { return nil }
    return clipboardPanel.screenRect(of: card.rect)
  }

  /// 这次的欢迎引导是首次安装（「登录时自动打开」默认勾）；关于页重看时清掉，勾选框跟随当前状态
  private var firstInstall = false

  /// 设置窗的导航状态：窗口懒建，主菜单的「显示 › 返回」（KittyToolsApp 的 SettingsCommands）一启动就要读它
  let settingsNavigation = SettingsNavigation()

  private lazy var settingsWindow: SettingsWindow = {
    weak var created: SettingsWindow?
    let window = SettingsWindow(navigation: settingsNavigation) { [unowned self] page in
      switch page {
      case .general:
        AnyView(
          GeneralTab(
            transfer: SettingsTransfer(services: serviceStore) { [unowned self] in
              settingsImported()
            }
          )
          .environment(island))
      case .clipboard: AnyView(ClipboardTab(store: clipboardStore).environment(island))
      case .launcher:
        AnyView(
          LauncherTab { [unowned self] in
            launcherUsage.clearAll()
            // 设置页上不显示条数，清完看不出变化
            island.show(
              "已清空启动器使用记录", detail: "「常用」和排序会从头开始学，收藏不动",
              symbol: "clock.arrow.circlepath")
          })
      case .screenshot: AnyView(ScreenshotTab())
      case .record: AnyView(RecordTab())
      case .translate:
        AnyView(
          TranslateTab(services: serviceStore, history: historyStore, speaker: speaker)
            .environment(island))
      case .hotkeys: AnyView(HotkeysTab(center: hotKeys))
      case .about:
        // 开发版（bundle id 不同）不更新，不显示更新那一行
        AnyView(
          AboutTab(updater: updater.isSupported ? updater : nil) {
            self.firstInstall = false
            created?.navigation.showsOnboarding = true
          })
      }
    } onboarding: { [unowned self] in
      AnyView(OnboardingView(center: hotKeys, firstRun: firstInstall).environment(island))
    }
    created = window
    return window
  }()

  /// 导入设置（设置 › 通用）整批写完偏好之后，让运行中的东西跟上：各页自己改的时候有各自的 onChange，这里没人通知。
  /// 别的设置都是用到时现读偏好，菜单栏图标自己看着偏好。返回按新上限清掉了几条剪贴板历史（导入的结果里说）
  private func settingsImported() -> Int {
    AppAppearance.apply()
    Accent.shared.select(
      AccentChoice(rawValue: UserDefaults.standard.string(forKey: Prefs.accent) ?? "") ?? .system,
      persists: false)
    // 正在录快捷键时热键停着，录完它自己会重新注册
    if hotKeys.recording == nil { hotKeys.reload() }
    clipboardStore.recognizePendingImages()
    return clipboardStore.enforceLimits()
  }

  // MARK: 生命周期

  func applicationDidFinishLaunching(_ notification: Notification) {
    // 单测以本 App 为宿主运行：不碰真实数据、不起热键
    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
    if yieldToOlderInstance() { return }
    Prefs.registerDefaults()
    Prefs.migrate()
    AppAppearance.apply()  // 在任何浮层、设置窗、菜单出现之前
    // 打开数据：打不开时就在这里问用户（用备份 / 重新开始 / 退出），这时还没有热键和菜单栏图标
    _ = stores
    isRunning = true

    // 本 App 生成的新文字写剪贴板时同时记进历史（Paster.write(string:record:)，mac-native §5）；暂停记录时不记
    Paster.recordText = { [unowned self] in
      if !watcher.isUserPaused { clipboardStore.recordOwnText($0) }
    }
    let launchedAt = Date.now
    clipboardStore.enforceLimits()
    clipboardStore.images.removeOrphans(
      keeping: Set(clipboardStore.items.map(\.id)), createdBefore: launchedAt)
    clipboardStore.recognizePendingImages()
    watcher.onText = { [unowned self] text in copyToTranslate(text) }
    watcher.start()
    DistributedNotificationCenter.default().addObserver(
      forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main
    ) { [unowned self] _ in
      MainActor.assumeIsolated {
        if UserDefaults.standard.bool(forKey: Prefs.clipboardClearOnLock) {
          clipboardStore.clearOrdinary()
        }
        backupIfDue()
      }
    }
    // 每天一份备份：启动时一次，一直开着不退的靠系统的换日通知（午夜发；睡过了午夜的醒来时补发，不保证准点），
    // 锁屏时再看一眼（换日那次没备成的补上）。都是现成的事件，不为它加定时器
    backupIfDue()
    NotificationCenter.default.addObserver(
      forName: .NSCalendarDayChanged, object: nil, queue: .main
    ) { [unowned self] _ in
      MainActor.assumeIsolated { backupIfDue() }
    }

    for action in HotKeyAction.allCases {
      hotKeys.setHandler(for: action) { [unowned self] in
        // 录屏开着「显示按键」：本 App 的全局快捷键被 Carbon 热键吃掉、InputOverlay 的键盘监听收不到，在这里补给它
        // （没开显示按键时 showKey 不做事；停止录屏的那一下不显示，免得留在最后一帧里）
        if action != .screenRecord, let key = hotKeys.bindings[action] {
          recorder?.inputOverlay?.showKey(key.display)
        }
        run(action)
      }
    }
    hotKeys.reload()
    try? FileManager.default.removeItem(at: ShotShelf.dragDirectory)
    shelf.copy = { [unowned self] png in
      await copyPNG(png)
      return true
    }
    shelf.island = island
    shelf.save = { [unowned self] in await savePNG($0, asking: false) }
    shelf.pin = { [unowned self] in pins.pin($0, frame: $1) }
    // 录屏 / 录音卡的「拷贝」：拷的是文件，同截图的图片自己记进剪贴板历史（C8-a：点了才进；暂停记录时不记）
    shelf.copyFile = { [unowned self] url in
      Paster.write(files: [url])
      if !watcher.isUserPaused { clipboardStore.recordFiles([url]) }
    }
    let statusItem = StatusItem()
    statusItem.buildMenu = { [unowned self] in buildStatusMenu($0) }
    island.onToneChange = { [weak statusItem] in statusItem?.reflect($0) }
    self.statusItem = statusItem
    updater.island = island
    // 有新版本：菜单栏图标右上角出小圆点，常驻到更新为止
    updater.onAvailableChange = { [weak statusItem] in statusItem?.updateVersion = $0?.version }
    updater.start()
    launcherModel.rescanApps()  // 约 65ms，放在启动时，第一次呼出就不用等
    showWelcomeIfNeeded()
    // 有快捷键没注册上（15.0 / 15.1 上只带 ⌥ 的组合）：按了没反应又不知道为什么，启动时说一次
    // （放在「已更新」之后：同一座岛原地换内容，警告不能被盖掉）
    if let failed = hotKeys.failures.keys.first {
      let count = hotKeys.failures.count
      island.show(
        count == 1 ? "「\(failed.title)」快捷键没注册上" : "有 \(count) 个快捷键没注册上",
        detail: "到 设置 › 快捷键 里看原因、换一个组合",
        tone: .warning, symbol: "keyboard")
    }
    // 上次录屏 / 录音没正常收尾（闪退）：能播的挪进快速保存目录，说一声（C7）
    Task {
      for medium in [ScreenRecorder.Medium.screen, .audio] {
        guard
          let found = await ScreenRecorder.recover(
            into: ScreenshotOutput.saveDirectory, medium: medium)
        else { continue }
        island.show(found.title, detail: found.detail, tone: found.tone)
      }
    }
  }

  /// 在录屏 / 录音时先停止并收尾再退（13 条默认细节：最多等 5 s；没写完也照样退，录屏由 replayd 自己收尾，下次启动 recover 接手）
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    closeReadyAudio()  // 待录的录音控制条没有东西要收尾：直接收掉，不等它回调
    guard recorder != nil || audioRecorder != nil else { return .terminateNow }
    quitsAfterRecording = true
    recorder?.stop()
    audioRecorder?.stop()
    Task {
      try? await Task.sleep(for: .seconds(5))
      guard quitsAfterRecording else { return }
      quitsAfterRecording = false
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  func applicationWillTerminate(_ notification: Notification) {
    guard isRunning else { return }
    // 面板固定着删了再退出：删掉的也要落库（撤销栈平时在面板收起时提交，体检 A2），⌘C 复制过的挪到最前
    clipboardModel.reset()
    if UserDefaults.standard.bool(forKey: Prefs.clipboardClearOnQuit) {
      clipboardStore.clearOrdinary()
    }
  }

  /// 再打开一次本 App：点程序坞图标（设置窗打开期间才有）、在访达或启动器里打开已经在运行的它。
  /// 菜单栏图标隐藏时（设置 › 通用，第 9 批 M1）就靠这条回到设置
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    // 启动时「数据打不开」的弹框还开着（没有程序坞图标，容易被别的窗口盖住再点一次）：把它带到前面，不建设置窗
    guard isRunning else {
      NSApp.activate()
      return false
    }
    showSettings()
    return false
  }

  // MARK: 入口

  /// 启动器和剪贴板面板在同一位置，只开一个：呼出一个就收起另一个，固定着的剪贴板面板也收
  /// （两块叠在同一处没法用，固定只管点外不关；mac-overlay-panel §2）
  func toggleClipboard() {
    // 已开着但不是 key 时 toggle 是「聚焦」而不是收起：同样要收起另一个
    if !(clipboardPanel.isVisible && clipboardPanel.isKeyWindow) { launcherPanel.hide() }
    if !clipboardPanel.isVisible { clipboardStore.enforceLimits() }
    clipboardPanel.toggle()
  }

  func toggleLauncher() {
    if !(launcherPanel.isVisible && launcherPanel.isKeyWindow) { clipboardPanel.hide() }
    let appearing = !launcherPanel.isVisible
    if appearing { launcherModel.prepareForShow() }
    launcherPanel.toggle()
    // 接着上次的查询（没执行就收起、60 秒内，体检 A27）：字全选，直接打字就替换，↩ 照样执行上次选中的
    if appearing, launcherModel.resumesQuery {
      (launcherPanel.firstResponder as? NSTextView)?.selectAll(nil)
    }
  }

  /// 启动器「cb 关键词」↩（启动器已收起，N9）：呼出剪贴板面板，再把关键词填进它的搜索框
  private func searchClipboard(_ keyword: String) {
    if !(clipboardPanel.isVisible && clipboardPanel.isKeyWindow) { toggleClipboard() }
    clipboardModel.query = keyword
  }

  /// 启动器里的内置动作（id 见 LauncherItem.actions，体检 A26）；启动器已收起。和菜单栏走同一个 run
  private func runLauncherAction(_ id: String) {
    if let action = HotKeyAction.allCases.first(where: { LauncherItem.actionID($0) == id }) {
      return run(action)
    }
    run(MenuExtra(rawValue: id) ?? .settings)
  }

  /// 菜单栏里不对应全局热键的项：菜单栏、启动器同一个分发
  private func run(_ extra: MenuExtra) {
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
  /// （录音待录时不算在录：那一项仍叫「录音」，点它是开始）
  private var menuState: LauncherItem.ActionState {
    LauncherItem.ActionState(
      recordingPaused: watcher.isUserPaused,
      copyToTranslate: UserDefaults.standard.bool(forKey: Prefs.translateCopyToTranslate),
      pinsHidden: pins.panels.isEmpty ? nil : pins.isHidden, checksUpdates: updater.isSupported,
      recording: recorder != nil
        ? .screenRecord : audioRecorder?.isStarted == true ? .audioRecord : nil)
  }

  /// 全局热键动作：热键、菜单栏、启动器同一个分发
  func run(_ action: HotKeyAction) {
    switch action {
    case .clipboard: toggleClipboard()
    case .launcher: toggleLauncher()
    case .selectionTranslate: selectionTranslate()
    case .inputTranslate: showInputTranslate()
    case .translateReplace: translateAndReplace()
    case .screenshotTranslate: screenshotTranslate()
    case .screenshot: screenshot()
    case .screenshotLastRegion: screenshot(repeatingLastRegion: true)
    case .recognizeText: recognizeText()
    case .screenRecord: screenRecord()
    case .audioRecord: audioRecord()
    case .pinClipboard: pinClipboard()
    }
  }

  /// 暂停 / 恢复记录剪贴板（菜单栏、启动器，D4）：不存盘，重启 App 自动恢复记录（免得忘了关）；
  /// 菜单一关就看不出开没开，用刘海说
  private func togglePauseRecording() {
    let paused = watcher.isUserPaused
    watcher.isUserPaused = !paused
    clipboardModel.isRecordingPaused = !paused
    island.show(
      paused ? "已恢复记录剪贴板" : "已暂停记录剪贴板",
      detail: paused ? nil : "复制的内容不进历史，再点一次恢复", tone: .info,
      symbol: paused ? "play.circle" : "pause.circle")
  }

  /// 复制即译开关（菜单栏、启动器）：开关一关就看不出开没开，这个后台模式会影响之后的每次复制，用刘海说
  private func toggleCopyToTranslate() {
    let wasOn = UserDefaults.standard.bool(forKey: Prefs.translateCopyToTranslate)
    UserDefaults.standard.set(!wasOn, forKey: Prefs.translateCopyToTranslate)
    island.show(
      wasOn ? "已关闭复制即译" : "已开启复制即译", detail: wasOn ? nil : "复制文字后会弹出翻译", tone: .info,
      symbol: wasOn ? "character.bubble" : "character.bubble.fill")
  }

  /// 关闭全部钉图（菜单栏、启动器）：关了就回不来，隐藏着时屏幕上什么也看不到，用刘海说
  private func closeAllPins() {
    let count = pins.panels.count
    pins.closeAll()
    island.show("已关闭全部钉图", detail: "\(count) 张", tone: .info, symbol: "pin.slash")
  }

  /// 钉住剪贴板里的图（第二轮体检 F1；快捷键默认不设、菜单栏、启动器）：剪贴板面板「钉到屏幕」的一步版，钉在鼠标所在屏
  /// 可见区中央、连按依次错开（PinBoard.clipboardFrame）。只读剪贴板，不写、不记历史（不是新内容）；没有图片时提示音 + 岛
  private func pinClipboard() {
    guard let source = PinBoard.clipboardImage() else {
      NSSound.beep()
      return island.show("剪贴板里没有图片", tone: .warning)
    }
    let mouse = NSEvent.mouseLocation
    guard
      let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
        ?? NSScreen.main
    else { return }
    let (scale, visible) = (screen.backingScaleFactor, screen.visibleFrame)
    Task {
      guard let image = await PinBoard.decode(source) else {
        let name = if case .file(let url) = source { "「\(url.lastPathComponent)」" } else { "这张图片" }
        return island.show("没能钉到屏幕", detail: "读不出\(name)", tone: .error)
      }
      // 解码完才找空位：连按几下时，前一张这时已经钉上了
      let pixels = CGSize(width: image.width, height: image.height)
      pins.pin(
        image,
        frame: PinBoard.clipboardFrame(
          pixels: pixels, scale: scale, visible: visible, pinned: pins.panels.map(\.frame)))
    }
  }

  /// 启动器文件搜索的授权提示（启动器已收起）：第一次逐个弹系统授权框（桌面、文稿、下载、iCloud 云盘），
  /// 结果用刘海岛说；问过了就打开系统设置的「文件和文件夹」
  private func requestFolderAccess() {
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
        "没有权限搜" + denied.map { "「\($0)」" }.joined(), detail: "可在系统设置 › 隐私与安全性 › 文件和文件夹里打开",
        tone: .warning)
    }
  }

  /// 输入翻译（体检 A14）：热键是开关——浮窗开着且是 key 就收起；否则打开，保留上次的原文和结果、原文全选
  /// （直接打字就替换，⌫ 清空），上次收起时中断的卡片重跑。总在上次的位置（不跟随鼠标）。菜单栏、启动器同一条路
  func showInputTranslate() {
    if translatePanel.isVisible, translatePanel.isKeyWindow { return translatePanel.dismiss() }
    coordinator.resumeInput()
    translatePanel.present()
    (translatePanel.firstResponder as? NSTextView)?.selectAll(nil)
  }

  /// 翻译浮窗出现：设置 › 翻译「浮窗位置」是跟随鼠标（默认）时放在光标右下，否则在上次的位置（体检 A13）
  private func presentTranslate(makingKey: Bool = true) {
    let followsMouse =
      UserDefaults.standard.string(forKey: Prefs.translatePanelPosition) != "last"
    translatePanel.present(
      makingKey: makingKey, anchor: followsMouse ? NSEvent.mouseLocation : nil)
  }

  /// 划词翻译：取词完成前绝不显示浮窗（先显示会取消原 App 的选区）。自家浮层是 key 时先收起，
  /// 否则 AX 读到的、⌘C 发到的都是自己
  func selectionTranslate() {
    // 截图框选中不划词：取词结束时显示的浮窗会被遮罩盖住、还抢走遮罩的 key
    guard !isReadingSelection, !isCapturing else { return }
    isReadingSelection = true
    // 本 App 从不激活：此刻的前台就是取词的 App（「替换原文」只粘回它）
    let sourceApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
    if clipboardPanel.isKeyWindow { clipboardPanel.hide() }
    if launcherPanel.isKeyWindow { launcherPanel.hide() }
    if translatePanel.isKeyWindow { translatePanel.orderOut(nil) }
    Task {
      defer { isReadingSelection = false }
      if let text = await SelectionReader.read(pausing: watcher) {
        coordinator.translate(text, selectedIn: sourceApp)
      } else if !Permissions.isAccessibilityTrusted {
        coordinator.showNotice("划词翻译需要「辅助功能」授权", permission: .accessibility)
        Permissions.requestAccessibility()
      } else {
        // 没有选中文字：当输入翻译用，占位说清楚是没取到（体检 A16），VoiceOver 同一句
        coordinator.beginInput(missedSelection: true)
        Island.announce("没取到选中的文字，可以直接输入或粘贴")
      }
      presentTranslate()
    }
  }

  /// 浮窗「替换原文」（划词来的会话）：收起浮窗 → 写剪贴板 → ⌘V。浮窗从不激活本 App，前台一直是原 App，
  /// 选区还在，粘贴就替换掉它。前台已经换了（浮窗固定着、用户点了别的 App）或没有辅助功能授权时只复制
  private func replaceOriginal() {
    guard let source = coordinator.replaceSource, let result = coordinator.primaryResult?.text
    else { return NSSound.beep() }
    let text = TranslateCoordinator.rewrap(result, like: source.text)
    // 写进去的译文是新内容，三条路都记进剪贴板历史（mac-native §5）
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == source.pid else {
      Paster.write(string: text, record: true)
      return island.show(
        "已复制译文", detail: "前台已不是取词的 App，没有替换", tone: .info, symbol: "doc.on.doc")
    }
    guard Permissions.isAccessibilityTrusted else {
      Paster.write(string: text, record: true)
      island.show("已复制译文", detail: "授权辅助功能后才能直接替换", tone: .warning)
      return Permissions.requestAccessibility()
    }
    translatePanel.hide()
    Paster.write(string: text, record: true)
    _ = Paster.pasteToFrontmost()
  }

  /// 划词翻译并替换（静默，对标 Bob 1.18）：取词 → 第一个服务翻译（等完整结果）→ 粘回替换选区；
  /// 不开浮窗，用轻提示报进度和结果；翻译期间再按一次热键取消。默认不设快捷键。
  /// 等结果的几秒里前台换了 App、或自家浮层成了 key，就只复制不粘（免得粘进别处）
  func translateAndReplace() {
    if let replaceTask {
      replaceTask.cancel()
      self.replaceTask = nil
      return island.show("已取消划词翻译并替换", tone: .info, symbol: "xmark.circle.fill")
    }
    guard !isReadingSelection, !isCapturing else { return }
    guard Permissions.isAccessibilityTrusted else {
      island.show("需要「辅助功能」授权", detail: "划词翻译并替换要用", tone: .warning)
      return Permissions.requestAccessibility()
    }
    let sourceApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
    isReadingSelection = true
    // 和划词翻译一样：自家浮层是 key 时先收起，否则读到的、粘贴进去的都是自己。翻译浮窗只 orderOut
    // （hide 的 onHide 会把 key 还给别的浮层）：没固定就顺手作废它的请求，固定着的替换完再露出来
    let pinned = UserDefaults.standard.bool(forKey: Prefs.floatingPinned)
    let restoresPanel = translatePanel.isKeyWindow && pinned
    if clipboardPanel.isKeyWindow { clipboardPanel.hide() }
    if launcherPanel.isKeyWindow { launcherPanel.hide() }
    if translatePanel.isKeyWindow {
      translatePanel.orderOut(nil)
      if !pinned { coordinator.cancel() }
    }
    let id = UUID()
    replaceID = id
    replaceTask = Task {
      defer {
        if replaceID == id { replaceTask = nil }
        if restoresPanel { translatePanel.present(makingKey: false, keepsPlace: true) }
      }
      let text = await SelectionReader.read(pausing: watcher)
      isReadingSelection = false  // 取完词就放开，等网络时不挡别的热键
      // 取词期间被再按一次取消了：岛上已是「已取消」，别再用「没有选中文字」「翻译中…」盖掉它
      // （后者会一直挂到 60 秒兜底）
      guard !Task.isCancelled else { return }
      guard let text else { return island.show("没有选中文字", tone: .warning) }
      island.show("翻译中…", detail: "再按一次快捷键取消", tone: .progress, symbol: "character.bubble.fill")
      do {
        let result = TranslateCoordinator.rewrap(
          try await coordinator.translateOnce(text), like: text)
        guard !Task.isCancelled else { return }
        Paster.write(string: result, record: true)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == sourceApp,
          NSApp.keyWindow == nil
        else {
          return island.show(
            "已复制译文", detail: "前台已不是取词的 App，没有替换", tone: .info, symbol: "doc.on.doc")
        }
        _ = Paster.pasteToFrontmost()
        island.show("已替换为译文", detail: Island.excerpt(result))
      } catch {
        guard !Task.isCancelled else { return }
        island.show("翻译失败", detail: error.localizedDescription, tone: .error)
      }
    }
  }

  /// 截图翻译：冻结各屏 → 框选 → 本机识别文字 → 原文记进剪贴板历史 → 翻译浮窗走现有的多服务翻译
  func screenshotTranslate() {
    beginCapture(hidingPanels: true) { [self] in
      guard
        let region = await frozenSelection(
          "截图翻译", { await RegionSelector.select($0, hint: "拖动框选要翻译的文字 · Esc 取消") })
      else { return }
      await translateImage(region)
    }
  }

  /// 识字：框选后静默复制识别出的文字（有二维码 / 条码时复制它的内容），轻提示结果，不弹窗
  func recognizeText() {
    beginCapture(hidingPanels: true) { [self] in
      guard
        let region = await frozenSelection(
          "识字", { await RegionSelector.select($0, hint: "拖动框选要识别的文字或二维码 · Esc 取消") })
      else { return }
      await copyRecognizedText(in: region)
    }
  }

  /// 截图：框选后可标注；↩ 复制（同时记进剪贴板历史）、⌘S 快速保存、另存为、T 钉图、S 长截图、识字、翻译，C 复制色值。
  /// repeatingLastRegion：一开始就选中上次的区域（「截取上次区域」热键，可以连按）
  func screenshot(repeatingLastRegion: Bool = false) {
    beginCapture(hidingPanels: false) { [self] in
      let lastRegion = UserDefaults.standard.string(forKey: Prefs.screenshotLastRegion).map(
        NSRectFromString)
      guard
        let outcome = await frozenSelection(
          "截图",
          {
            await RegionSelector.capture(
              $0, lastRegion: lastRegion, preselect: repeatingLastRegion,
              recordingBlocker: { [weak self] in self?.recordingBlocker(.screen) })
          })
      else { return }
      switch outcome {
      case .color(let hex): copyColor(hex)
      // 截图调整时按 R / 点「录屏」切过去的（录屏第 2 批）：和 ⌥R 框完一样开录
      case .record(let region): beginRecording(region)
      case .scroll(let region):
        UserDefaults.standard.set(NSStringFromRect(region), forKey: Prefs.screenshotLastRegion)
        // 长截图在实时画面上截、滤掉本 App：没固定的浮层留着只会盖住选区，挡住滚轮和自动滚动
        // （钉图、常驻缩略图同理，体检 B40，在 scrollCapture 里让开）
        hideUnpinnedPanels()
        await scrollCapture(region)
      case .capture(let capture):
        UserDefaults.standard.set(
          NSStringFromRect(capture.frame), forKey: Prefs.screenshotLastRegion)
        switch capture.action {
        case .copy:
          let land = captured(capture.image, scale: capture.scale, frame: capture.frame)
          if let png = await copyImage(capture.image, scale: capture.scale) { land(.copied, png) }
        case .pin:
          FlyCard.playShutter()
          pins.pin(capture.image, frame: capture.frame)
        case .save:
          let land = captured(capture.image, scale: capture.scale, frame: capture.frame)
          if let saved = await saveImage(capture.image, scale: capture.scale, asking: false) {
            land(.saved(saved.url), saved.png)
          }
        case .saveAs:
          FlyCard.playShutter()
          await saveImageAs(capture.image, scale: capture.scale)
        case .recognize: await copyRecognizedText(in: capture.image)
        case .translate: await translateImage(capture.image)
        }
      }
    }
  }

  /// 录屏：在录（含倒数）就停止 / 取消；否则冻结各屏、框选（同截图：窗口、整屏、拖框、D 上次区域，和截图共用上次区域），
  /// 交回选区后开录（按设置先倒数）。isCapturing 只占框选阶段：开录后录制状态在 recorder 里，截图、识字照常，
  /// 再按一次快捷键就停（C9）
  func screenRecord() {
    if let recorder { return recorder.stop() }
    guard !refusesRecording(.screen) else { return }
    beginCapture(hidingPanels: false) { [self] in
      let lastRegion = UserDefaults.standard.string(forKey: Prefs.screenshotLastRegion).map(
        NSRectFromString)
      guard
        let outcome = await frozenSelection(
          "录屏", { await RegionSelector.record($0, lastRegion: lastRegion) })
      else { return }
      switch outcome {
      case .color(let hex): copyColor(hex)
      case .record(let region): beginRecording(region)
      case .capture, .scroll: break
      }
    }
  }

  /// 现在开不了 medium 的原因（岛的标题、说明；nil = 能录）：录屏和录音互斥（C9-a，另一种在录，含倒数、等授权）、
  /// 同一种已经在录（录屏中截图再按 R）、正在装更新（装好会退出重新打开，录到一半会被截断；录制中的「不能更新」只防得住
  /// 先录后更新）。录音待录（控制条开着、没开始）不算在录：不拦录屏，真要录屏时 beginRecording 把控制条收掉
  private func recordingBlocker(_ medium: ScreenRecorder.Medium) -> (title: String, detail: String)?
  {
    let busy = "先停止这一段再录"
    if recorder != nil { return (medium == .screen ? "已经在录屏" : "正在录屏", busy) }
    if audioRecorder?.isStarted == true {
      return (medium == .audio ? "已经在录音" : "正在录音", busy)
    }
    if case .installing = updater.state {
      return ("正在更新", "装好会自动重新打开，之后再\(medium.noun)")
    }
    return nil
  }

  /// 开不了就出警告岛，返回 true
  private func refusesRecording(_ medium: ScreenRecorder.Medium) -> Bool {
    guard let blocker = recordingBlocker(medium) else { return false }
    island.show(blocker.title, detail: blocker.detail, tone: .warning)
    return true
  }

  /// 录音（录音第 5 批，拍板 A1-a；手测反馈第 3 批改成先出控制条）：没有会话时，默认先在屏幕底部出录音控制条（待录，不录），
  /// 设置 › 录制「按快捷键后立即开始录音」开着才直接开始；待录时再触发（快捷键 / 菜单栏 / 启动器，或点控制条的 ●）= 开始；
  /// 录着时 = 停止（菜单栏 / 启动器这时叫「停止录音」）。录什么看来源（设置 › 录制「录音」、待录的控制条上都能改，第 6 批）。
  /// 和录屏互斥（C9-a）：录屏在录（含倒数、等麦克风授权）时岛说先停止那一段；正在装更新时不开录（同录屏）
  func audioRecord() {
    if let audioRecorder {
      return audioRecorder.isStarted ? audioRecorder.stop() : audioRecorder.start()
    }
    guard !refusesRecording(.audio) else { return }
    let immediately = UserDefaults.standard.bool(forKey: Prefs.audioRecordStartsImmediately)
    // 立即开始：开不了（录系统声音没有屏幕录制授权）就不建会话，同以前
    if immediately, !allowsAudioRecording(AudioRecorder.Source(.standard)) { return }
    let recorder = AudioRecorder(directory: ScreenshotOutput.saveDirectory, island: island) {
      [weak self] in
      self?.recorded($0, .audio)
    }
    audioRecorder = recorder
    if immediately { return recorder.start() }
    // 先出控制条：来源可能在控制条上改，真正开始那一刻（点 ●、再触发一次）才查
    recorder.allowsStart = { [weak self] in self?.allowsAudioRecording($0) ?? false }
    recorder.open()
  }

  /// 真正开始录音那一刻能不能录（开不了已出警告岛）：互斥和正在装更新再看一次（待录期间状态可能变了）；录系统声音走录屏
  /// 管线，要「屏幕录制」授权（同截图，screenRecordingAllowed）。能录就从这时起挡更新（待录时不挡）
  private func allowsAudioRecording(_ source: AudioRecorder.Source) -> Bool {
    guard !refusesRecording(.audio),
      source == .microphone || screenRecordingAllowed(for: "录系统声音")
    else { return false }
    updater.blocker = "录制结束后再更新"
    return true
  }

  /// 待录的录音控制条当场收掉（还没开始，没有东西要收尾、不等回调）：要录屏了、退出 App。在录的不动
  private func closeReadyAudio() {
    guard let audioRecorder, !audioRecorder.isStarted else { return }
    audioRecorder.close()
    self.audioRecorder = nil
  }

  /// 框选交回录屏选区（⌥R 的框选、截图里按 R 切过去的）：记成上次区域（和截图共用）、收走压在选区上的常驻缩略图
  /// （同长截图；钉图照常录进去）、开录（先倒数）
  private func beginRecording(_ region: CGRect) {
    // 截图里按 R 时已经问过（SelectionSession.recordingBlocker，停在截图里）；框选期间状态还可能变（系统睡眠停了录音、
    // 更新开始装），这里兜底
    guard !refusesRecording(.screen) else { return }
    closeReadyAudio()  // 录音控制条开着、还没开始：收掉，照常录屏（录屏和录音只留一个）
    UserDefaults.standard.set(NSStringFromRect(region), forKey: Prefs.screenshotLastRegion)
    shelf.dismiss(covering: region)
    guard
      let recorder = ScreenRecorder(
        region: region, directory: ScreenshotOutput.saveDirectory, hotKeys: hotKeys,
        island: island, onFinish: { [weak self] in self?.recorded($0, .screen) })
    else {
      return island.show("没能开始录屏", detail: "找不到选区所在的屏幕", tone: .warning)
    }
    self.recorder = recorder
    updater.blocker = "录制结束后再更新"
    recorder.start()
  }

  /// 录屏 / 录音收尾：文件已挪进快速保存目录（挪不过去的留在原地、在访达里选中），刘海岛说结果（成功时岛让菜单栏图标弹一下）；
  /// 挪进去了还要飞卡片、留视频卡 / 录音卡（landRecording）。倒数中（录音：等授权框时、关掉待录的控制条）取消的不出岛，只播报。录制中麦克风断开的
  /// （第 4 批）summary 是警告：卡片照飞，岛也出来说「后半段没有麦克风声音」；开着麦克风（录音总是）但之前拒绝过授权的，这时打开
  /// 系统设置的麦克风页（录音被拒时岛说「需要麦克风授权」，第 5 批）；开着显示按键但没有辅助功能授权的同样这时打开辅助功能页
  private func recorded(_ result: ScreenRecorder.Result, _ medium: ScreenRecorder.Medium) {
    if medium == .screen { recorder = nil } else { audioRecorder = nil }
    // 关掉待录的录音控制条也走到这里（按取消收尾）：另一种在录时不替它放开更新
    if recorder == nil, audioRecorder?.isStarted != true { updater.blocker = nil }
    defer {
      if quitsAfterRecording {
        quitsAfterRecording = false
        NSApp.reply(toApplicationShouldTerminate: true)
      }
    }
    // 开录报屏幕录制授权问题（录屏、录系统声音）
    if result.reason == .denied { Permissions.Kind.screenRecording.openSettings() }
    // 开着麦克风但之前拒绝过：开录时只出了警告岛，这时才打开（开录前打开会盖住选区、录进画面）
    if result.microphoneDenied { Permissions.Kind.microphone.openSettings() }
    // 开着显示按键但没有辅助功能授权（手测反馈第 2 批）：同样到这时才打开；先请求一次——从没问过时系统设置的列表里
    // 还没有本 App（系统框只弹这一次，问过的不再弹）。麦克风页刚打开的就不再开辅助功能页（连开两个，前一个被盖掉，
    // 用户只看得到后一个）：开关已经弹回，下次打开显示按键再提示；从没问过的，上面的系统框自己带「打开系统设置」
    if result.keysDenied {
      Permissions.requestAccessibility()
      if !result.microphoneDenied { Permissions.openAccessibilitySettings() }
    }
    // 挪不进快速保存目录：在访达里选中留下的文件，马上能拖走
    if let file = result.file, !result.moved {
      NSWorkspace.shared.activateFileViewerSelecting([file])
    }
    let folder = FileManager.default.displayName(atPath: ScreenshotOutput.saveDirectory.path)
    guard let summary = ScreenRecorder.summary(result, folder: folder, medium: medium) else {
      return Island.announce("已取消")
    }
    var leading = Island.Leading.tone
    if result.moved, let file = result.file {
      // 飞过去了：落地的角标已写目录名，正常停的不再出岛（同截图快速保存），只给 VoiceOver 说一句
      if landRecording(file, result, medium), summary.tone == .success {
        return Island.announce(
          "\(medium.noun)已保存到「\(folder)」，"
            + ScreenRecorder.spoken(Int(result.duration.components.seconds)))
      }
      if summary.tone == .success, let poster = result.poster {
        leading = Island.thumbnail(of: poster)
      }
    }
    let symbol = medium == .screen ? "video.circle.fill" : "waveform.circle.fill"
    island.show(
      summary.title, detail: summary.detail, tone: summary.tone,
      symbol: summary.tone == .success ? symbol : nil, leading: leading)
  }

  /// 录屏存进快速保存目录后（拍板 R11-a）：最后一帧从选区（整屏录制就是那块屏）按 S1 飞到右下角，没有快门声，落地弹文件夹
  /// 角标，再交给常驻缩略图的视频卡（设置里关了常驻缩略图就停 0.9 s 自己滑走）。减弱动态效果、没取到最后一帧时不飞，
  /// 视频卡在角落淡入（关了常驻缩略图就只有岛）。录音（第 5 批，A5-a）同一套：波形图从 HUD 的位置（result.region，和图同比例的
  /// 小框）长到录音卡那么大（AudioRecorder.posterSize），交给录音卡。返回飞了没有（飞了的正常停不再出岛）
  private func landRecording(
    _ file: URL, _ result: ScreenRecorder.Result, _ medium: ScreenRecorder.Medium
  ) -> Bool {
    let seconds = Int(result.duration.components.seconds)
    let audio = medium == .audio
    let size = audio ? AudioRecorder.posterSize : nil
    let keepsThumbnail = UserDefaults.standard.bool(forKey: Prefs.screenshotShelf)
    let flies = result.poster != nil && !Style.reduceMotion
    let linger: (CGRect, FlyCard.Badge) -> Void = { [weak self] rect, _ in
      self?.shelf.add(
        recording: file, seconds: seconds, audio: audio, poster: result.poster,
        source: result.region, at: rect, fadesIn: !flies)
    }
    guard flies, let poster = result.poster else {
      if keepsThumbnail, let rect = FlyCard.landingRect(for: result.region, size: size) {
        linger(rect, .saved(file))
      }
      return false
    }
    let landing = FlyCard.fly(
      poster, from: result.region, size: size, linger: keepsThumbnail ? linger : nil,
      seconds: seconds, audio: audio)
    landing.onShow = { [weak self] in self?.statusItem?.pop() }
    // 文件已经存好了：直接给角标（落地时弹出来）；结果由调用方说（带时长，或中断的岛）
    landing.land(.saved(file), announces: false)
    return true
  }

  /// 框选时按 C：复制放大镜中心的色值（截图、录屏的框选）
  private func copyColor(_ hex: String) {
    Paster.write(string: hex, record: true)
    island.show(
      "已复制色值", detail: hex, leading: Self.color(hex).map(Island.Leading.color) ?? .tone)
  }

  /// 长截图（截图框选后按 S）：遮罩已收起，在实时画面上边滚边拼，结束后按选的方式输出。整个过程都算在这次截图里
  /// （isCapturing），期间别的截图热键不响应
  private func scrollCapture(_ region: CGRect) async {
    // 压在选区上的钉图会吞掉滚轮、把自动滚动的合成滚轮当缩放（体检 B40）：让开到长截图结束（拷贝、存储、取消、出错），
    // 另存为的存储面板弹出来之前就放回；常驻缩略图直接收走
    pins.suspend(covering: region)
    shelf.dismiss(covering: region)
    // 固定着的剪贴板面板留在屏幕上，它的 ⌘Y 大卡也还开着：压在选区上同样会吞掉滚轮，收走
    if clipboardModel.isQuickLooking, let card = quickLookPanel.panel,
      card.frame.intersects(region)
    {
      card.hide()
    }
    do {
      let finished = try await ScrollCapture.run(region: region)
      pins.resume()
      guard let result = finished else { return }
      switch result.action {
      case .copy:
        let land = captured(result.image, scale: result.scale, frame: region)
        if let png = await copyImage(result.image, scale: result.scale) { land(.copied, png) }
      case .save:
        let land = captured(result.image, scale: result.scale, frame: region)
        if let saved = await saveImage(result.image, scale: result.scale, asking: false) {
          land(.saved(saved.url), saved.png)
        }
      case .saveAs:
        FlyCard.playShutter()
        await saveImageAs(result.image, scale: result.scale)
      }
    } catch {
      pins.resume()
      island.show("长截图失败", detail: error.localizedDescription, tone: .error)
    }
  }

  /// 截图和截图翻译共用的开头：互斥；work 跑完才算这次截图结束。
  /// 截图（热键、⌥X、启动器、菜单栏）不收自家窗口：用户 2026-09-26 要能截到本 App，开着的浮层、设置窗、钉图留在
  /// 冻结帧里、能悬停和单击选中，截完还开着（遮罩当 key、被点时浮层不自动收起，OverlayPanel.isSelectingRegion）；
  /// 按 S 转长截图时才收起没固定的。截图翻译 / 识字（hidingPanels）照旧收起没固定的浮层；固定着的不收，照样截进去
  private func beginCapture(hidingPanels: Bool, _ work: @escaping () async -> Void) {
    guard !isCapturing, !isReadingSelection else { return }
    isCapturing = true
    if hidingPanels { hideUnpinnedPanels() }
    Task {
      defer { isCapturing = false }
      await work()
    }
  }

  /// 收起没固定的浮层。先收剪贴板面板再收翻译浮窗：反过来浮窗的 onHide 会把 key 还给剪贴板面板
  private func hideUnpinnedPanels() {
    clipboardPanel.hideUnlessPinned()
    launcherPanel.hide()  // 启动器没有固定
    translatePanel.hideUnlessPinned()
  }

  /// 有「屏幕录制」授权（截图家族、录系统声音开始前查）；没有就同设置 › 通用、引导里的授权按钮：请求一次（系统框只弹一次，
  /// 所以同时打开系统设置的「屏幕录制」）+ 警告岛说 feature 要用，返回 false
  private func screenRecordingAllowed(for feature: String) -> Bool {
    guard !Permissions.isScreenRecordingAllowed else { return true }
    Permissions.requestScreenRecording()
    Permissions.Kind.screenRecording.openSettings()
    island.show(
      "需要「屏幕录制」授权", detail: "\(feature)要用，授权后可能要重新打开本 App", tone: .warning)
    return false
  }

  /// 查屏幕录制授权 → 冻结各屏（本 App 开着的窗口留在画面里）→ 暂停全局热键框选 → 遮罩收起后把 key 还给截图前的
  /// key 窗口（还开着的话；只 makeKey，不激活本 App）。没授权 / 截屏失败时用刘海提示，返回 nil。
  /// 框选期间别的热键会弹出浮层抢走 key（遮罩就收不到 Esc）；设置里正在录快捷键时热键本来就停着，结束后不能替它恢复
  private func frozenSelection<T>(
    _ feature: String, _ select: ([ScreenCapture.Shot]) async -> T?
  ) async -> T? {
    guard screenRecordingAllowed(for: feature) else { return nil }
    let shots: [ScreenCapture.Shot]
    do {
      shots = try await ScreenCapture.freeze()
    } catch {
      island.show("截屏失败", detail: error.localizedDescription, tone: .error)
      return nil
    }
    let hotKeysWereActive = !hotKeys.bindings.isEmpty
    hotKeys.suspend()
    defer { if hotKeysWereActive { hotKeys.reload() } }
    let previousKey = NSApp.keyWindow
    let result = await select(shots)
    // 本 App 在前台时（设置窗是 key），遮罩 orderOut 后 AppKit 可能把 key 交给别的自家窗口（比如浮层），所以不只看 nil
    if let previousKey, previousKey.isVisible, NSApp.keyWindow !== previousKey {
      previousKey.makeKey()
    }
    return result
  }

  /// 本机识别文字 → 原文记进剪贴板历史 → 翻译浮窗走现有的多服务翻译（截图翻译、截图工具栏的翻译共用）。
  /// 总是按段送去翻（体检 A32：同一段的行接起来、段间空一行，不看「接起来」开关），记进历史的原文也是这一份
  private func translateImage(_ image: CGImage) async {
    // 同识字：失败不为一句话开浮窗
    guard let lines = await recognizing({ await OCR.recognizeLines(in: image) }) else {
      return island.show("文字识别失败", detail: "请重试", tone: .error)
    }
    guard !lines.isEmpty else {
      return island.show("没有识别到文字", detail: "可以把选区框大一些再试", tone: .warning)
    }
    // 没有结果岛（接着开浮窗）：「识别中」出过就收掉
    if island.content?.title == Self.recognizingTitle { island.dismiss() }
    let text = OCR.text(lines, joined: true, separator: "\n\n")
    // 原文不写剪贴板、只记进历史（同一个入口：过敏感文本过滤、已有同文只挪到最前）
    Paster.recordText?(text)
    coordinator.translate(text)
    presentTranslate()
  }

  /// 识字慢的时候先出「识别中」（第二轮体检 R3）：常见选区 0.04–0.13 s，不出；整屏密集文字约 0.9 s，过了 0.3 s 还没出结果
  /// 刘海岛先说一声，结果出来原地换掉（识字、截图翻译、钉图上的识字 / 翻译都走这里）
  private static let recognizingTitle = "识别中…"

  private func recognizing<T>(_ work: () async -> T) async -> T {
    // 进程内识过字，模型就留在内存里：这一路不一定开关面板（⌥O 识字、钉图上识字），自己记得回头放掉
    defer { idleReclaim.schedule() }
    return await island.showIfSlow(Self.recognizingTitle, work)
  }

  /// 有二维码 / 条码就复制它的内容，否则复制识别出的文字（设置里开了就把换行合成一段）；记进剪贴板历史
  private func copyRecognizedText(in image: CGImage) async {
    let (codes, lines) = await recognizing { () -> ([String], [OCR.Line]?) in
      let codes = await OCR.barcodes(in: image)
      // 有码就不用再识字
      return (codes, codes.isEmpty ? await OCR.recognizeLines(in: image) : [])
    }
    var text = codes.joined(separator: "\n")
    if text.isEmpty {
      guard let lines else {
        return island.show("文字识别失败", detail: "请重试", tone: .error)
      }
      // 设置 › 截图开着「接起来」：同一段的行接起来、段间换行（体检 A32）；关着一行一行原样
      text = OCR.text(lines, joined: UserDefaults.standard.bool(forKey: Prefs.ocrJoinLines))
    }
    guard !text.isEmpty else {
      return island.show("没有识别到文字", tone: .warning)
    }
    Paster.write(string: text, record: true)
    island.show(
      codes.isEmpty ? "已复制" : "已复制二维码", detail: Island.excerpt(text),
      symbol: codes.isEmpty ? nil : "qrcode")
  }

  /// 截图复制：PNG 写进剪贴板（经 Paster，watcher 会跳过），所以自己记进剪贴板历史。返回编码好的 PNG（常驻缩略图接着用，
  /// 不再编码一遍），失败 nil
  @discardableResult
  private func copyImage(_ image: CGImage, scale: CGFloat) async -> Data? {
    guard let png = await ScreenshotOutput.png(image, scale: scale) else {
      island.show("截图编码失败", detail: "请重试", tone: .error)
      return nil
    }
    await copyPNG(png)
    return png
  }

  private func copyPNG(_ png: Data) async {
    Paster.write([.png: png])
    guard !watcher.isUserPaused else { return }  // 菜单栏暂停了记录
    var item = ClipItem(kind: .image)
    guard let info = await clipboardStore.images.save(png, isPNG: true, id: item.id) else { return }
    item.image = info
    clipboardStore.record(item)
  }

  /// ⌘S 快速保存 / 另存为（asking）；返回存到的文件和编码好的 PNG（取消、失败为 nil）
  @discardableResult
  private func saveImage(_ image: CGImage, scale: CGFloat, asking: Bool) async -> (
    url: URL, png: Data
  )? {
    guard let png = await ScreenshotOutput.png(image, scale: scale) else {
      island.show("截图编码失败", detail: "请重试", tone: .error)
      return nil
    }
    return await savePNG(png, asking: asking).map { ($0, png) }
  }

  /// 另存为（截图、长截图、钉图）：不飞卡片、不进常驻缩略图，存好了用刘海说
  private func saveImageAs(_ image: CGImage, scale: CGFloat) async {
    guard let saved = await saveImage(image, scale: scale, asking: true) else { return }
    island.show("已保存", detail: saved.url.lastPathComponent, leading: Island.thumbnail(of: image))
  }

  /// 存编码好的 PNG；返回存到的文件（取消、失败为 nil）。失败时截图改放进剪贴板，别让这张图就这么丢了
  private func savePNG(_ png: Data, asking: Bool) async -> URL? {
    do {
      return asking ? try await ScreenshotOutput.saveAs(png) : try ScreenshotOutput.quickSave(png)
    } catch {
      await copyPNG(png)
      island.show("保存失败，截图已复制到剪贴板", detail: error.localizedDescription, tone: .warning)
      return nil
    }
  }

  /// 截图落地：快门声 + 飞行卡片（遮罩刚收起就飞，不等编码）。返回的 land 在复制 / 保存成功后调，给卡片角标和编码好的
  /// PNG，角标弹完后交给常驻缩略图（ShotShelf：拷贝、存储、拖出都用这份 PNG，不留整张解码的图）；减弱动态效果时不飞，
  /// land 时缩略图直接在角落淡入。失败不调（另有提示）
  private func captured(_ image: CGImage, scale: CGFloat, frame: CGRect) -> (
    FlyCard.Badge, Data
  ) -> Void {
    FlyCard.playShutter()
    var png = Data()
    let linger: (CGRect, FlyCard.Badge) -> Void = { [weak self] rect, badge in
      self?.shelf.add(image, png: png, scale: scale, source: frame, at: rect, badge: badge)
    }
    // 设置 › 截图关了常驻缩略图（体检 D18）：卡片落地弹完角标停 0.9 s 自己滑走（不给 linger）；减弱动态效果时只有岛
    let keepsThumbnail = UserDefaults.standard.bool(forKey: Prefs.screenshotShelf)
    guard Style.reduceMotion else {
      let landing = FlyCard.fly(image, from: frame, linger: keepsThumbnail ? linger : nil)
      landing.onShow = { [weak self] in self?.statusItem?.pop() }
      return { badge, data in
        png = data
        landing.land(badge)
      }
    }
    return { [weak self] badge, data in
      png = data
      // 不飞就没有落地的角标：结果用刘海说（Whisker：减弱动态效果时飞行卡片改成轻提示；岛自己会播报）
      self?.island.show(badge.title, leading: Island.thumbnail(of: image))
      guard keepsThumbnail, let rect = FlyCard.landingRect(for: frame) else { return }
      linger(rect, badge)
    }
  }

  /// "#RRGGBB" → 色块（取色的轻提示用）
  private static func color(_ hex: String) -> NSColor? {
    guard hex.count == 7, let value = Int(hex.dropFirst(), radix: 16) else { return nil }
    return NSColor(
      srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
      blue: CGFloat(value & 0xFF) / 255, alpha: 1)
  }

  /// 复制即译：只露出浮窗、不抢键盘（用户可能正在别的 App 里继续打字）。网址、路径、数字、超长的、本来就是第一语言的
  /// （目标自动时）和刚翻过的同一段静默跳过（体检 A12 B20）；这次的译文不自动复制（盖掉刚复制的原文，A19）
  private func copyToTranslate(_ text: String) {
    let defaults = UserDefaults.standard
    guard defaults.bool(forKey: Prefs.translateCopyToTranslate) else { return }
    let (first, second) = Lang.preferredPair
    guard
      TranslateCoordinator.worthTranslating(
        copied: text, translated: coordinator.translatedSource, first: first, second: second,
        autoTarget: defaults.string(forKey: Prefs.translateTarget) == nil)
    else { return }
    coordinator.translate(text, fromCopy: true)
    presentTranslate(makingKey: false)
  }

  /// 打开设置窗（page 为 nil 保持上次的页；onboarding 盖上欢迎引导）：先按正常隐藏路径收起浮层
  /// （固定的浮层会盖在设置窗上）
  func showSettings(page: SettingsPage? = nil, onboarding: Bool = false) {
    clipboardPanel.hide()
    launcherPanel.hide()
    translatePanel.hide()
    settingsWindow.show(page: page, onboarding: onboarding)
  }

  // MARK: 菜单栏菜单

  /// 每次打开菜单前重建（N15）：按 HotKeyAction.sections 分节，和快捷键页同名同序，标题、符号、家族色也取自那里；
  /// 右边是当前生效的快捷键，没设 / 注册失败的留空；每节末尾接上那一节的 MenuExtra（暂停记录剪贴板、复制即译、
  /// 有钉图时的两项）；有新版本时最上面是「更新到 x…」；最后是设置、关于、检查更新（正式版）、退出
  private func buildStatusMenu(_ menu: NSMenu) {
    let state = menuState
    let extras = MenuExtra.allCases.filter { $0.isAvailable(state) }
    func addExtra(_ extra: MenuExtra) {
      let item = menu.addAction(
        extra.title(pinsHidden: state.pinsHidden == true), symbol: extra.symbol,
        color: NSColor(extra.color), key: extra == .settings ? "," : extra == .quit ? "q" : ""
      ) { [unowned self] in run(extra) }
      if let on = extra.isOn(state) { item.state = on ? .on : .off }
    }
    // 有新版本时最上面一项就是更新（强调色：现在该操作的东西）
    if let release = updater.available {
      menu.addAction(
        "更新到 \(release.version)…", symbol: "arrow.down.circle.fill", color: NSColor(Style.brand)
      ) { [unowned self] in Task { await updater.install() } }
      menu.addItem(.separator())
    }
    for (index, section) in HotKeyAction.sections.enumerated() {
      if index > 0 { menu.addItem(.separator()) }
      menu.addItem(.sectionHeader(title: section.title))
      for action in section.actions {
        let binding = hotKeys.bindings[action]
        menu.addAction(
          action.title(recording: state.recording == action), symbol: action.symbol,
          color: NSColor(action.color),
          key: binding?.menuKeyEquivalent ?? "", modifiers: binding?.modifierFlags ?? []
        ) { [unowned self] in run(action) }
      }
      for extra in extras where section.actions.contains(where: { $0 == extra.section }) {
        addExtra(extra)
      }
    }
    menu.addItem(.separator())
    // 速查表只在启动器里（菜单里在 设置 › 快捷键）；退出排在最后
    for extra in extras where extra.section == nil && extra != .shortcuts { addExtra(extra) }
  }

  // MARK: 启动辅助

  /// 首次安装打开欢迎引导（授权、快捷键；引导下面是通用页）。更新后第一次启动不开设置窗、不抢前台：
  /// 刘海岛说「已更新到 x」+ 本版摘要（菜单栏图标照常弹一下），全文在菜单「关于 Kitty Tools」
  private func showWelcomeIfNeeded() {
    let last = UserDefaults.standard.string(forKey: Prefs.lastSeenVersion)
    UserDefaults.standard.set(AboutTab.version, forKey: Prefs.lastSeenVersion)
    if last == nil {
      firstInstall = true
      showSettings(page: .general, onboarding: true)
    } else if last != AboutTab.version {
      let summary = AboutTab.releases.first { $0.version == AboutTab.version }?.summary
      island.show(
        "已更新到 \(AboutTab.version)", detail: summary.map(Island.excerpt), tone: .success,
        symbol: "sparkles")
    }
  }

  /// LaunchServices 不保证同一 bundle id 只跑一份（例如 DMG 里一份、/Applications 里又一份）：
  /// 发现更早启动的实例就再打开一次它的包（LaunchServices 给它发 reopen → 进设置，菜单栏图标隐藏时也回得去；
  /// 只 activate 的话没窗口的菜单栏 App 什么也不显示），自己退出。更新后的重启是等旧进程退了才 open，走不到这里。
  /// 只让「更晚的」退出：两份同时启动时若都见到对方就退，会一起退光（实测过）；启动时间相同再比 pid
  private func yieldToOlderInstance() -> Bool {
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
  private func backupIfDue() {
    guard !isBackingUp else { return }
    isBackingUp = true
    Task {
      let outcome = await Backup.run(in: dataDirectory)
      isBackingUp = false
      switch outcome {
      case .made(let url): Log.storage.notice("已备份数据库：\(url.lastPathComponent, privacy: .public)")
      case .damaged: Log.storage.error("数据库有问题，今天没有备份；已有的备份没动")
      case .failed(let reason): Log.storage.error("备份数据库失败：\(reason)")
      case .notDue: break
      }
    }
  }

  /// 打开数据库和读它的三个仓库。打不开不直接退出（第二轮体检 S2，Storage/Backup.swift）：弹框让用户选用最近的备份、
  /// 重新开始还是退出；前两种把出问题的文件挪开留着、再开一次，还打不开才说明后退出（不循环）
  private static func openOrQuit(in directory: URL) -> Stores {
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
      alert.messageText = "无法打开数据库"
      alert.informativeText =
        "\(error)\n\n数据目录：\((directory.path as NSString).abbreviatingWithTildeInPath)"
      NSApp.activate()
      alert.runModal()
      exit(1)
    }
  }
}
