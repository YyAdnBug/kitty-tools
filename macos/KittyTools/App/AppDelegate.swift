// 应用生命周期：单实例检查，按依赖顺序组装各模块（PLAN §4），热键与各翻译入口，首次安装 / 更新后打开设置窗，
// 退出 / 锁屏时的清理。

import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
  /// 只有真正跑起来的实例才做退出清理：让位退出的重复实例不能碰数据库
  private var isRunning = false
  /// 划词取词进行中：重复按热键直接忽略
  private var isReadingSelection = false
  /// 进行中的「划词翻译并替换」：再按一次热键取消
  private var replaceTask: Task<Void, Never>?
  /// 截图 / 截图翻译进行中（截屏 → 框选 → 识别或输出）：重复按热键直接忽略
  private var isCapturing = false
  let hotKeys = HotKeyCenter()

  // MARK: 数据与服务（按依赖顺序）

  private let dataDirectory = URL.applicationSupportDirectory.appending(
    path: Bundle.main.bundleIdentifier ?? "com.yy.kitty-tools.native")
  private lazy var database: Database = Self.openOrQuit { [dataDirectory] in
    try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
    return try Database(path: dataDirectory.appending(path: "kitty.sqlite3").path)
  }
  private lazy var clipboardStore: ClipboardStore = Self.openOrQuit { [database, dataDirectory] in
    let images = dataDirectory.appending(path: "images")
    try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
    return try ClipboardStore(db: database, images: ImageStore(directory: images))
  }
  private lazy var launcherUsage: LauncherUsage = Self.openOrQuit { [database] in
    try LauncherUsage(db: database)
  }
  private lazy var historyStore: HistoryStore = Self.openOrQuit { [database] in
    try HistoryStore(db: database)
  }
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
    // 钉图不变、不飞卡片：复制、存好了都用刘海说
    board.copy = { [unowned self] image, scale in
      Task {
        guard await copyImage(image, scale: scale) != nil else { return }
        island.show("已复制钉图", leading: Island.thumbnail(of: image))
      }
    }
    board.saveAs = { [unowned self] image, scale in
      Task { await saveImageAs(image, scale: scale) }
    }
    return board
  }()

  // MARK: 窗口

  private lazy var clipboardModel = ClipboardPanelModel(store: clipboardStore)
  private lazy var launcherModel = LauncherModel(usage: launcherUsage)

  private lazy var launcherPanel: OverlayPanel = {
    let model = launcherModel
    let panel = OverlayPanel(
      size: NSSize(width: 720, height: LauncherPanelView.searchHeight), topAnchored: true,
      // 启动器没有固定（N8）：点外面就收起
      autoHide: .clickOutside, isPinned: { false }, content: LauncherPanelView(model: model))
    panel.keyEquivalentHandler = { [unowned model] in model.handleKeyEquivalent($0) }
    panel.onHide = { [unowned model] in model.didHide() }
    panel.squeezesIn = { UserDefaults.standard.bool(forKey: Prefs.launcherSqueezeEntrance) }
    model.hidePanel = { [unowned panel] in panel.hide() }
    // ⌘K 菜单开着时瞬间长高：菜单锚在底栏上方，面板边长边插进来会越过搜索栏被裁，得先长好再从右下角放大
    model.resize = { [unowned panel, unowned model] in
      panel.setContentHeight($0, animated: !model.showsActions)
    }
    model.runAction = { [unowned self] in runLauncherAction($0) }
    model.openClipboard = { [unowned self] in searchClipboard($0) }
    model.boundHotKey = { [unowned self] in hotKeys.bindings[$0] }
    model.requestFolderAccess = { [unowned self] in requestFolderAccess() }
    model.island = island
    return panel
  }()

  private lazy var clipboardPanel: OverlayPanel = {
    let model = clipboardModel
    // 透镜指令条：和启动器同位置同宽（顶边在可见区 20%），高度按条数伸缩、顶边不动
    let panel = OverlayPanel(
      size: NSSize(
        width: ClipboardPanelView.width, height: ClipboardPanelView.height(for: model)),
      topAnchored: true, autoHide: .clickOutside,
      isPinned: { !UserDefaults.standard.bool(forKey: Prefs.clipboardHideOnUnfocus) },
      content: ClipboardPanelView(model: model))
    panel.keyEquivalentHandler = { [unowned model] in model.handleKeyEquivalent($0) }
    panel.onHide = { [unowned model] in model.reset() }
    model.hidePanel = { [unowned panel] in panel.hide() }
    model.resize = { [unowned panel] in panel.setContentHeight($0, animated: true) }
    // 剪贴板面板保持打开（兄弟浮层），翻译浮窗出现在旁边
    model.openTranslate = { [unowned self] text in
      coordinator.translate(text)
      translatePanel.present()
    }
    model.openSettings = { [unowned self] in showSettings() }
    model.openQuickLook = { [unowned self] in showQuickLook() }
    model.island = island
    model.closeQuickLook = { [unowned self] animated in
      guard animated else { return quickLookPanel.hide() }
      // 缩回动画期间它还在屏幕上：点过里面的文字（它是 key）就先把 key 还给剪贴板，别让这 0.24 s 里按的键落空
      if quickLookPanel.isKeyWindow, clipboardPanel.isVisible { clipboardPanel.makeKey() }
      quickLookPanel.unzoom(to: cardScreenFrame)
    }
    return panel
  }()

  /// ⌘Y 放大预览：剪贴板选中条目的大卡片。不抢键盘（点它里面的文字才当 key），点外面就关
  private lazy var quickLookPanel: OverlayPanel = {
    weak var created: OverlayPanel?
    let panel = OverlayPanel(
      size: NSSize(width: 820, height: 640), autoHide: .clickOutside, isPinned: { false },
      content: QuickLookView(model: clipboardModel) { [unowned self] size in
        // 连按方向键时直接换尺寸（先瞬时，再动画）
        created?.move(to: quickLookFrame(size), animated: !Style.isKeyRepeat)
      })
    created = panel
    panel.becomesKeyOnlyIfNeeded = true
    panel.keyEquivalentHandler = { [unowned self] in clipboardModel.handleKeyEquivalent($0) }
    panel.onHide = { [unowned self] in
      clipboardModel.quickLookDidHide()
      // 键盘关掉的（它是 key 时按 Esc）把 key 还给剪贴板；点别处关掉的不抢（鼠标还按着：用户正要去别处打字）
      if NSApp.keyWindow == nil, NSEvent.pressedMouseButtons == 0, clipboardPanel.isVisible {
        clipboardPanel.makeKey()
      }
    }
    return panel
  }()

  private lazy var translatePanel: OverlayPanel = {
    // 视图在面板建好之前就可能要求改高度：用弱引用接，别在 lazy 初始化里回头访问 translatePanel
    weak var created: OverlayPanel?
    let panel = OverlayPanel(
      size: NSSize(width: 420, height: 560), minSize: NSSize(width: 360, height: 200),
      autosaveName: "TranslatePanel", autoHide: .resignKey,
      isPinned: { UserDefaults.standard.bool(forKey: Prefs.floatingPinned) },
      content: TranslatePanelView(
        coordinator: coordinator, speaker: speaker,
        resize: { height in
          // 高度随内容（Bob 的做法）：最矮 220，最高到屏幕可见区的 85%，再多就在卡片区里滚。
          // 最小 / 最大高度都钉在这个值上：用户只能拖宽度，拖高度会和自动高度打架
          guard let panel = created else { return }
          let visible = (panel.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
          let height = min(max(height, 220), visible * 0.85)
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
    coordinator.hidePanel = { [unowned panel] in panel.dismiss() }
    // ⌘,、「⋯」菜单、错误卡片和空状态都直接到设置 › 翻译
    coordinator.openSettings = { [unowned self] in showSettings(page: .translate) }
    coordinator.focusSource = { [unowned panel] in
      panel.makeFirstResponder(panel.initialFirstResponder)
    }
    panel.onHide = { [unowned self, unowned panel] in
      // 收起即作废进行中的请求（省额度）；把 key 还给之前处于 key 的浮层（剪贴板面板 / 启动器）。
      // 已有别的窗口成了 key（因失焦而收起）就不抢
      coordinator.cancel()
      if NSApp.keyWindow == nil, let previous = panel.previousKeyPanel, previous.isVisible {
        previous.makeKey()
      }
    }
    return panel
  }()

  private func showQuickLook() {
    guard let item = clipboardModel.selectedItem else { return }
    // 右键菜单 / 无障碍的「放大预览」同一拍里先换选中再打开：先让面板把布局做完，新选中的透镜才报上位置
    if clipboardModel.cardFrame?.id != item.id {
      clipboardPanel.contentView?.layoutSubtreeIfNeeded()
    }
    clipboardModel.showsQuickLookContent = true
    let size = QuickLookView.idealSize(for: item, form: clipboardModel.contentForm(of: item))
    quickLookPanel.zoom(from: cardScreenFrame ?? clipboardPanel.frame, to: quickLookFrame(size))
  }

  /// 透镜（选中行）的屏幕坐标：剪贴板面板不在、透镜滚出可见区、报上来的不是当前选中项时为 nil（放大卡退回从面板长出）
  private var cardScreenFrame: NSRect? {
    guard clipboardPanel.isVisible, let card = clipboardModel.cardFrame,
      card.id == clipboardModel.selectedItem?.id
    else { return nil }
    let window = clipboardPanel.frame
    return NSRect(
      x: window.minX + card.rect.minX, y: window.maxY - card.rect.maxY, width: card.rect.width,
      height: card.rect.height)
  }

  /// 放大预览的位置：以剪贴板面板为中心，最大到屏幕可见区的 90%，再整个挪进可见区
  private func quickLookFrame(_ size: NSSize) -> NSRect {
    let visible = (clipboardPanel.screen ?? NSScreen.main)?.visibleFrame ?? .zero
    let width = min(size.width, visible.width * 0.9)
    let height = min(size.height, visible.height * 0.9)
    let center = CGPoint(x: clipboardPanel.frame.midX, y: clipboardPanel.frame.midY)
    return NSRect(
      x: min(max(center.x - width / 2, visible.minX), visible.maxX - width),
      y: min(max(center.y - height / 2, visible.minY), visible.maxY - height), width: width,
      height: height)
  }

  private lazy var settingsWindow: SettingsWindow = {
    weak var created: SettingsWindow?
    let window = SettingsWindow { [unowned self] page in
      switch page {
      case .general: AnyView(GeneralTab())
      case .clipboard: AnyView(ClipboardTab(store: clipboardStore).environment(island))
      case .launcher:
        AnyView(
          LauncherTab { [unowned self] in
            launcherUsage.clearAll()
            // 设置页上不显示条数，清完看不出变化
            island.show(
              "已清空启动器使用记录", detail: "「最近使用」和排序会从头开始学", symbol: "clock.arrow.circlepath")
          })
      case .screenshot: AnyView(ScreenshotTab())
      case .translate:
        AnyView(
          TranslateTab(services: serviceStore, history: historyStore, speaker: speaker)
            .environment(island))
      case .hotkeys: AnyView(HotkeysTab(center: hotKeys))
      case .about:
        // 开发版（bundle id 不同）不更新，不显示更新那一行
        AnyView(
          AboutTab(updater: updater.isSupported ? updater : nil) {
            created?.navigation.showsOnboarding = true
          })
      }
    } onboarding: { [unowned self] in
      AnyView(OnboardingView(center: hotKeys))
    }
    created = window
    return window
  }()

  // MARK: 生命周期

  func applicationDidFinishLaunching(_ notification: Notification) {
    // 单测以本 App 为宿主运行：不碰真实数据、不起热键
    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
    if yieldToOlderInstance() { return }
    isRunning = true
    Prefs.registerDefaults()
    AppAppearance.apply()  // 在任何浮层、设置窗、菜单出现之前

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
      }
    }

    hotKeys.setHandler(for: .clipboard) { [unowned self] in toggleClipboard() }
    hotKeys.setHandler(for: .selectionTranslate) { [unowned self] in selectionTranslate() }
    hotKeys.setHandler(for: .inputTranslate) { [unowned self] in showInputTranslate() }
    hotKeys.setHandler(for: .screenshotTranslate) { [unowned self] in screenshotTranslate() }
    hotKeys.setHandler(for: .launcher) { [unowned self] in toggleLauncher() }
    hotKeys.setHandler(for: .screenshot) { [unowned self] in screenshot() }
    hotKeys.setHandler(for: .screenshotLastRegion) { [unowned self] in
      screenshot(repeatingLastRegion: true)
    }
    hotKeys.setHandler(for: .recognizeText) { [unowned self] in recognizeText() }
    hotKeys.setHandler(for: .translateReplace) { [unowned self] in translateAndReplace() }
    hotKeys.reload()
    // 有快捷键没注册上（15.0 / 15.1 上只带 ⌥ 的组合）：按了没反应又不知道为什么，启动时说一次
    if let failed = hotKeys.failures.keys.first {
      let count = hotKeys.failures.count
      island.show(
        count == 1 ? "「\(failed.title)」快捷键没注册上" : "有 \(count) 个快捷键没注册上",
        detail: "到 设置 › 快捷键 里看原因、换一个组合",
        tone: .warning, symbol: "keyboard")
    }
    try? FileManager.default.removeItem(at: ShotShelf.dragDirectory)
    shelf.copy = { [unowned self] png in
      await copyPNG(png)
      return true
    }
    shelf.island = island
    shelf.save = { [unowned self] in await savePNG($0, asking: false) }
    shelf.pin = { [unowned self] in pins.pin($0, frame: $1) }
    let statusItem = StatusItem()
    statusItem.buildMenu = { [unowned self] in buildStatusMenu($0) }
    island.onToneChange = { [weak statusItem] in statusItem?.reflect($0) }
    self.statusItem = statusItem
    updater.island = island
    updater.start()
    launcherModel.rescanApps()  // 约 65ms，放在启动时，第一次呼出就不用等
    showWelcomeIfNeeded()
  }

  func applicationWillTerminate(_ notification: Notification) {
    if isRunning, UserDefaults.standard.bool(forKey: Prefs.clipboardClearOnQuit) {
      clipboardStore.clearOrdinary()
    }
  }

  /// 程序坞图标被点（设置窗打开期间才有程序坞图标）
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
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
    if !launcherPanel.isVisible { launcherModel.prepareForShow() }
    launcherPanel.toggle()
  }

  /// 启动器「cb 关键词」↩（启动器已收起，N9）：呼出剪贴板面板，再把关键词填进它的搜索框
  private func searchClipboard(_ keyword: String) {
    if !(clipboardPanel.isVisible && clipboardPanel.isKeyWindow) { toggleClipboard() }
    clipboardModel.query = keyword
  }

  private func hideUnpinned(_ panel: OverlayPanel, _ hideOnUnfocusKey: String) {
    if UserDefaults.standard.bool(forKey: hideOnUnfocusKey) { panel.hide() }
  }

  /// 启动器里的内置动作（id 见 LauncherItem.actions）；启动器已收起
  private func runLauncherAction(_ id: String) {
    switch id {
    case "clipboard": toggleClipboard()
    case "translate-input": showInputTranslate()
    case "screenshot": screenshot()
    case "ocr": recognizeText()
    case "translate-screenshot": screenshotTranslate()
    default: showSettings()
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

  func showInputTranslate() {
    coordinator.beginInput()
    translatePanel.present()
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
        coordinator.beginInput()  // 没有选中文字：当输入翻译用
      }
      translatePanel.present()
    }
  }

  /// 浮窗「替换原文」（划词来的会话）：收起浮窗 → 写剪贴板 → ⌘V。浮窗从不激活本 App，前台一直是原 App，
  /// 选区还在，粘贴就替换掉它。前台已经换了（浮窗固定着、用户点了别的 App）或没有辅助功能授权时只复制
  private func replaceOriginal() {
    guard let source = coordinator.replaceSource, let result = coordinator.primaryResult?.text
    else { return NSSound.beep() }
    let text = TranslateCoordinator.rewrap(result, like: source.text)
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == source.pid else {
      Paster.write(string: text)
      return island.show(
        "已复制译文", detail: "前台已不是取词的 App，没有替换", tone: .info, symbol: "doc.on.doc")
    }
    guard Permissions.isAccessibilityTrusted else {
      Paster.write(string: text)
      island.show("已复制译文", detail: "授权辅助功能后才能直接替换", tone: .warning)
      return Permissions.requestAccessibility()
    }
    translatePanel.hide()
    Paster.write(string: text)
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
    replaceTask = Task {
      defer {
        replaceTask = nil
        if restoresPanel { translatePanel.present(makingKey: false) }
      }
      let text = await SelectionReader.read(pausing: watcher)
      isReadingSelection = false  // 取完词就放开，等网络时不挡别的热键
      guard let text else { return island.show("没有选中文字", tone: .warning) }
      island.show("翻译中…", detail: "再按一次快捷键取消", tone: .progress, symbol: "character.bubble.fill")
      do {
        let result = TranslateCoordinator.rewrap(
          try await coordinator.translateOnce(text), like: text)
        guard !Task.isCancelled else { return }
        Paster.write(string: result)
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
              $0, lastRegion: lastRegion, preselect: repeatingLastRegion)
          })
      else { return }
      switch outcome {
      case .color(let hex):
        Paster.write(string: hex)
        recordInHistory(hex)
        island.show(
          "已复制色值", detail: hex, leading: Self.color(hex).map(Island.Leading.color) ?? .tone)
      case .scroll(let region):
        UserDefaults.standard.set(NSStringFromRect(region), forKey: Prefs.screenshotLastRegion)
        // 长截图在实时画面上截、滤掉本 App：没固定的浮层留着只会盖住选区，挡住滚轮和自动滚动
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

  /// 长截图（截图框选后按 S）：遮罩已收起，在实时画面上边滚边拼，结束后按选的方式输出。整个过程都算在这次截图里
  /// （isCapturing），期间别的截图热键不响应
  private func scrollCapture(_ region: CGRect) async {
    do {
      guard let result = try await ScrollCapture.run(region: region) else { return }
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
    hideUnpinned(clipboardPanel, Prefs.clipboardHideOnUnfocus)
    launcherPanel.hide()  // 启动器没有固定
    if !UserDefaults.standard.bool(forKey: Prefs.floatingPinned) { translatePanel.hide() }
  }

  /// 查屏幕录制授权 → 冻结各屏（本 App 开着的窗口留在画面里）→ 暂停全局热键框选 → 遮罩收起后把 key 还给截图前的
  /// key 窗口（还开着的话；只 makeKey，不激活本 App）。没授权 / 截屏失败时用刘海提示，返回 nil。
  /// 框选期间别的热键会弹出浮层抢走 key（遮罩就收不到 Esc）；设置里正在录快捷键时热键本来就停着，结束后不能替它恢复
  private func frozenSelection<T>(
    _ feature: String, _ select: ([ScreenCapture.Shot]) async -> T?
  ) async -> T? {
    guard Permissions.isScreenRecordingAllowed else {
      // 同设置 › 通用、引导里的授权按钮：系统框只弹一次，所以同时打开系统设置的「屏幕录制」
      Permissions.requestScreenRecording()
      Permissions.Kind.screenRecording.openSettings()
      island.show(
        "需要「屏幕录制」授权", detail: "\(feature)要用，授权后可能要重新打开本 App", tone: .warning)
      return nil
    }
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

  /// 截图 / 截图翻译 / 取色得到的文字记进剪贴板历史（和复制进来的一样过敏感文本过滤；来源 App 为空）。
  /// 已有同样正文的只挪到最前：走 record 会把那条的格式和来源冲掉，而这次并不是一次复制
  private func recordInHistory(_ text: String) {
    clipboardStore.recordOwnText(text)
  }

  /// 本机识别文字 → 原文记进剪贴板历史 → 翻译浮窗走现有的多服务翻译（截图翻译、截图工具栏的翻译共用）
  private func translateImage(_ image: CGImage) async {
    // ponytail: 识别期间不显示「识别中」：常见选区 0.04–0.13s，整屏密集文字约 0.9s；大选区嫌慢再加
    // 同识字：失败不为一句话开浮窗
    guard let text = await OCR.recognizeText(in: image) else {
      return island.show("文字识别失败", detail: "请重试", tone: .error)
    }
    guard !text.isEmpty else {
      return island.show("没有识别到文字", detail: "可以把选区框大一些再试", tone: .warning)
    }
    recordInHistory(text)
    coordinator.translate(text)
    translatePanel.present()
  }

  /// 有二维码 / 条码就复制它的内容，否则复制识别出的文字（设置里开了就把换行合成一段）；记进剪贴板历史
  private func copyRecognizedText(in image: CGImage) async {
    let codes = await OCR.barcodes(in: image)
    var text = codes.joined(separator: "\n")
    if text.isEmpty {
      guard let recognized = await OCR.recognizeText(in: image) else {
        return island.show("文字识别失败", detail: "请重试", tone: .error)
      }
      text =
        UserDefaults.standard.bool(forKey: Prefs.ocrJoinLines)
        ? OCR.joiningLines(recognized) : recognized
    }
    guard !text.isEmpty else {
      return island.show("没有识别到文字", tone: .warning)
    }
    Paster.write(string: text)
    recordInHistory(text)
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
    guard Style.reduceMotion else {
      let landing = FlyCard.fly(image, from: frame, linger: linger)
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
      guard let rect = FlyCard.landingRect(for: frame) else { return }
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

  /// 复制即译：只露出浮窗、不抢键盘（用户可能正在别的 App 里继续打字）
  private func copyToTranslate(_ text: String) {
    guard UserDefaults.standard.bool(forKey: Prefs.translateCopyToTranslate) else { return }
    coordinator.translate(text)
    translatePanel.present(makingKey: false)
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
  /// 右边是当前生效的快捷键，没设 / 注册失败的留空；复制即译接在翻译节末尾，有钉图时截图节末尾多钉图两项；
  /// 有新版本时最上面是「更新到 x…」；最后是设置、关于、检查更新（正式版）、退出
  private func buildStatusMenu(_ menu: NSMenu) {
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
          action.title, symbol: action.symbol, color: NSColor(action.color),
          key: binding?.menuKeyEquivalent ?? "", modifiers: binding?.modifierFlags ?? []
        ) { [unowned self] in
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
          }
        }
      }
      let color = NSColor(section.actions[0].color)
      if section.actions.contains(.selectionTranslate) {
        let copyToTranslate = UserDefaults.standard.bool(forKey: Prefs.translateCopyToTranslate)
        menu.addAction("复制即译", symbol: "doc.on.doc", color: color) { [unowned self] in
          UserDefaults.standard.set(!copyToTranslate, forKey: Prefs.translateCopyToTranslate)
          // 菜单一关就看不出开没开，这个后台模式会影响之后的每次复制
          island.show(
            copyToTranslate ? "已关闭复制即译" : "已开启复制即译",
            detail: copyToTranslate ? nil : "复制文字后会弹出翻译", tone: .info,
            symbol: copyToTranslate ? "character.bubble" : "character.bubble.fill")
        }
        .state = copyToTranslate ? .on : .off
      }
      if section.actions.contains(.screenshot), !pins.panels.isEmpty {
        menu.addAction(pins.isHidden ? "显示全部钉图" : "隐藏全部钉图", symbol: "pin", color: color) {
          [unowned self] in pins.toggleHidden()
        }
        menu.addAction("关闭全部钉图", symbol: "pin.slash", color: color) { [unowned self] in
          // 关了就回不来；隐藏着时屏幕上什么也看不到
          let count = pins.panels.count
          pins.closeAll()
          island.show("已关闭全部钉图", detail: "\(count) 张", tone: .info, symbol: "pin.slash")
        }
      }
    }
    let gray = NSColor.systemGray
    menu.addItem(.separator())
    menu.addAction("设置…", symbol: "gearshape", color: gray, key: ",") { [unowned self] in
      showSettings()
    }
    menu.addAction("关于 Kitty Tools", symbol: "info.circle", color: gray) {
      [unowned self] in showSettings(page: .about)
    }
    if updater.isSupported {
      menu.addAction("检查更新…", symbol: "arrow.triangle.2.circlepath", color: gray) {
        [unowned self] in Task { await updater.check(.menu) }
      }
    }
    menu.addAction("退出", symbol: "power", color: gray, key: "q") { NSApp.terminate(nil) }
  }

  // MARK: 启动辅助

  /// 首次安装打开欢迎引导（授权、快捷键；引导下面是通用页）；更新后第一次启动打开关于页看本版更新内容
  private func showWelcomeIfNeeded() {
    let last = UserDefaults.standard.string(forKey: Prefs.lastSeenVersion)
    UserDefaults.standard.set(AboutTab.version, forKey: Prefs.lastSeenVersion)
    if last == nil {
      showSettings(page: .general, onboarding: true)
    } else if last != AboutTab.version {
      showSettings(page: .about)
    }
  }

  /// LaunchServices 不保证同一 bundle id 只跑一份（例如 DMG 里一份、/Applications 里又一份）：
  /// 发现更早启动的实例就把它激活，自己退出。只让「更晚的」退出：两份同时启动时
  /// 若都见到对方就退，会一起退光（实测过）；启动时间相同再比 pid
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
    older.activate()
    NSApp.terminate(nil)
    return true
  }

  /// 数据库打不开就没法工作：弹窗说明后退出。数据目录 ~/Library/Application Support/<bundle id>/
  /// （Debug 与 Release 的 bundle id 不同，数据天然隔离）
  private static func openOrQuit<T>(_ open: () throws -> T) -> T {
    do {
      return try open()
    } catch {
      let alert = NSAlert()
      alert.alertStyle = .critical
      alert.messageText = "无法打开数据库"
      alert.informativeText = String(describing: error)
      NSApp.activate()
      alert.runModal()
      exit(1)
    }
  }
}
