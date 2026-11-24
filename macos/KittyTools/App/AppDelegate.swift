// 应用生命周期：单实例检查，按依赖顺序组装各模块（PLAN §4），热键与各翻译入口，首次安装打开欢迎引导、
// 更新后第一次启动用刘海岛说一声，退出 / 锁屏时的清理；数据打不开时问用户怎么办、每天备份的时机（Storage/Backup.swift）；
// 便签的数据（Notes/：单独的库，启动的最后才开，打不开时单独问、不退出，退出 / 锁屏 / 睡眠前落盘，每天备份、
// 清「最近删除」里到期的）和三个入口（快速记一条的面板、新建便签、全部便签窗口；退出前落不下去先问），
// 还有屏幕边缘的便签（Notes/NoteEdge.swift：便签开好后建；截图框选、长截图、录屏选区和倒数、状态屏开始时叫停它；
// 浮动便签 Notes/NoteFloat.swift 也由它拿着，长截图时压在选区上的让开）；
// 录屏（框选、开录、结果、飞入和视频卡、退出前收尾、上次闪退留下的文件）；
// 录音（录音第 5 批：开录、和录屏互斥、结果、飞入和录音卡，收尾和闪退恢复同录屏）；
// 状态屏的三个入口（快捷键先出选状态的面板——设置里可改成直接进第一个状态，菜单栏子菜单、启动器每个状态一条；
// 会话在 StatusScreen/StatusScreen.swift，选状态的面板在 StatusScreen/StatusPicker.swift）；
// 功能开关（Shell/Feature.swift，2026-10-21）：启动时只起开着的功能，偏好一变就按开关起停（applyFeatures）。
// 这个文件留存储属性和建它们的那几段（数据与服务、窗口）；别的按概念拆在同目录的 AppDelegate+*.swift（第五轮体检 H1）。

import AppKit
import FinderSync
import OSLog
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
  /// 数据打开之后才算跑起来，才做退出清理、才响应「再打开一次」：让位退出的重复实例、还停在「数据打不开」弹框上的
  /// 都不能碰数据库（弹框开着时去读 stores 会把打开流程再跑一遍）
  var isRunning = false
  /// 网址把 App 冷启动时，系统可能在 applicationDidFinishLaunching 之前就把网址交过来：先存着，起来了再做（访达右键）
  var pendingLinks: [URL] = []
  /// 划词取词进行中：重复按热键直接忽略
  var isReadingSelection = false
  /// 进行中的「划词翻译并替换」：再按一次热键取消
  var replaceTask: Task<Void, Never>?
  /// 这次替换的标记：旧任务收尾时只清自己的引用，别把紧接着启动的新任务清掉
  var replaceID: UUID?
  /// 截图家族的框选进行中（截屏 → 框选遮罩 → 长截图面板）：这时再按截图家族、划词翻译的热键只响一声。出图（编码、另存为、
  /// 识字、快速保存）不算（第五轮体检 E3，beginCapture）；录屏只占框选阶段（C9）
  var isCapturing = false
  /// 延时截图正在倒数（第五轮体检 N2）：再按一次延时截图 = 取消。倒数不算 isCapturing（这几秒里别的浮层照常弹，才截得到）
  var shotCountdown: ShotCountdown?
  /// 录屏会话（框选之后、开录到文件挪好）：在录时录屏的入口都是停止；录制中照样能截图、识字、截图翻译（C9）
  var recorder: ScreenRecorder?
  /// 录音会话（录音第 5 批，开录到文件挪好）：在录时录音的入口都是停止；和录屏互斥（C9-a）。手测反馈第 3 批起它可能还在
  /// 待录（控制条出来了、没开始，isStarted 为 false）：这时录音的入口是开始，不算在录（菜单标题、互斥、更新、退出都不看它）
  var audioRecorder: AudioRecorder?
  /// 退出时在等录屏 / 录音收尾（applicationShouldTerminate 返回了 .terminateLater）
  var quitsAfterRecording = false
  /// 退出时在等装后台下好的新版本（replyQuit）：装完、到点两条路只回一次话
  var quitReplyPending = false
  /// 上次按功能开关（Feature）起停过的样子和那时复制即译开没开（剪贴板的轮询看它）：applyFeatures 只对变了的做事；
  /// nil = 还没起过（启动时）
  var appliedFeatures: Set<Feature>?
  var appliedCopyToTranslate = false
  var ocrMarkerWatcher: OCRPreparationMarkerWatcher?
  /// 上一次应用的「截完图放哪」：换了就重新起停晾衣绳（2026-10-27 用户手测）
  var appliedPlacement: Prefs.ShotPlacement?
  /// 屏幕边缘的便签起过没有：便签开着才起（start 会把固定着的浮动便签放回屏幕上），启动时关着的打开时再起
  var startedNoteEdge = false
  let hotKeys = HotKeyCenter()

  // MARK: 数据与服务（按依赖顺序）

  /// ~/Library/Application Support/<bundle id>/（Debug 与 Release 的 bundle id 不同，数据天然隔离）：两个库、图片、
  /// 每日备份都在这里；设置 › 通用「数据目录」在访达里打开它
  nonisolated static let supportDirectory = URL.applicationSupportDirectory.appending(
    path: Bundle.main.bundleIdentifier ?? "com.yy.kitty-tools.native")
  let dataDirectory = AppDelegate.supportDirectory
  /// 库和读它的三个仓库：一起打开，哪一步（开库、建表、读表）抛错都算打不开，不留开到一半的连接
  /// （不是 private：BackupTests 在临时目录里拿它走真的打开流程）
  struct Stores {
    let clipboard: ClipboardStore
    let launcher: LauncherUsage
    let history: HistoryStore
    /// 截图历史（2026-10-26 拍板）：图在 <数据目录>/shots/，记录在同一个库的 shots 表
    let shots: ShotHistory

    init(in directory: URL) throws {
      let images = directory.appending(path: "images")
      try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
      let database = try Database(path: directory.appending(path: Backup.databaseName).path)
      clipboard = try ClipboardStore(db: database, images: ImageStore(directory: images))
      launcher = try LauncherUsage(db: database)
      history = try HistoryStore(db: database)
      shots = try ShotHistory(db: database, directory: directory.appending(path: "shots"))
    }
  }
  lazy var stores = Self.openOrQuit(in: dataDirectory)
  var clipboardStore: ClipboardStore { stores.clipboard }
  var launcherUsage: LauncherUsage { stores.launcher }
  var historyStore: HistoryStore { stores.history }
  var shotHistory: ShotHistory { stores.shots }
  /// 备份正在做（backupIfDue）：换日和锁屏的通知挨着来时不做两遍
  var isBackingUp = false
  /// 设置与数据的自动备份正在做（backupSettingsIfDue）：本机那份、另存到用户选的文件夹的那份各一个标记——
  /// 另选的文件夹在卡住的网络盘上时，那一份可能很久不回来，不能拦着本机那份
  var isBackingUpSettings = false
  var isMirroringSettings = false
  /// 上一次备份数据库时发现库有问题（Backup.run 给了 .damaged）：这时内存里读到的片段、收藏可能不全，设置与数据的
  /// 自动备份先不做——写出去会把好的那几份顶掉（数据库的备份同样的规矩：坏了不备、已有的不动）
  var isDatabaseDamaged = false
  /// 便签（PLAN §10「便签」，Notes/NoteStore.swift）：单独的库 notes.sqlite3，启动的最后才开（finishLaunchingNotes）。
  /// 打不开时单独问（openNotes），不让 App 退出；这次运行里不可用时是 nil——导出和每日备份不带便签这一类，导入跳过便签
  var noteStore: NoteStore?
  /// 便签同步（便签未来计划 A，NoteSyncer）：便签库开成了才有；开没开同步看它自己记的偏好
  var noteSyncer: NoteSyncer?
  /// 便签开过了（开成了、用户选了先不用都算）。之前不做每日备份（backupIfDue）：便签还没开时写出去的当天那份 JSON
  /// 里没有便签，而当天那份只写一次
  var hasOpenedNotes = false
  /// 上一次备份便签库时发现库有问题（NotesBackup.run 给了 .damaged）：内存里读到的便签可能不全，设置与数据的自动备份里
  /// 先不带便签这一类（同 isDatabaseDamaged 的道理：写出去会把带着好便签的那几份顶掉）
  var isNotesDamaged = false
  /// 快速记一条的面板和它的状态（Notes/NoteCapture.swift）：第一次用时建——便签要能用才有（noteStore 启动的最后才开，
  /// 可能是 nil）——建了就留着，草稿在它的 model 里
  var noteCapture: (panel: OverlayPanel, model: NoteCaptureModel)?
  /// 全部便签窗口（Notes/NotesWindow.swift，普通窗口）：同样第一次用时建；关着的在空闲回收时整个放掉（下次打开重建）
  var notesWindow: NotesWindow?
  /// 全部便签窗口的模型：窗口放掉了它还留着——下次打开选中的那条、看的是哪个视图、搜索词都还在
  var notesModel: NotesWindowModel?
  /// 屏幕边缘的便签（Notes/NoteEdge.swift，第 3 批）：便签开好之后建（finishLaunchingNotes），它自己看总开关和有没有
  /// 便签决定建不建窗口；便签这次用不了时是 nil
  var noteEdge: NoteEdge?
  lazy var watcher = ClipboardWatcher(store: clipboardStore)
  let serviceStore = TranslateServiceStore()
  lazy var coordinator = TranslateCoordinator(services: serviceStore, history: historyStore)
  let speaker = Speaker()
  /// 刘海岛（全局轻提示）
  let island = Island()
  /// 刘海岛上的系统一瞬提示（电源、电量、耳机、网络；设置 › 刘海岛「系统提示」，开着的才监听）
  lazy var systemNotices = SystemNotices(island: island)
  /// 整点报时（设置 › 刘海岛「日程」，默认关；Shell/Chime.swift）
  let hourlyChime = HourlyChime()
  /// 刘海岛的正在播放（刘海岛扩展第 2 期）：开着才连包里的正在播放服务
  lazy var nowPlaying = NowPlaying(island: island)
  /// 刘海岛上的「下一个日程」（设置 › 刘海岛，默认关）
  lazy var nextEvent = NextEvent(island: island)
  /// 音量 / 亮度键换成刘海岛上的提示（设置 › 刘海岛，默认关）。状态屏开着时不重建它的拦截（新建的会排到状态屏那一处
  /// 前面，音量键穿过状态屏），退出时补（第五轮体检 E11）
  private(set) lazy var mediaKeys: MediaKeys = {
    let keys = MediaKeys(island: island)
    keys.isHeldBack = { [unowned self] in statusScreen.isActive }
    return keys
  }()
  /// 访达里的 ⌘X 剪切、⌘V 移动（访达右键插件里的开关，issue #33）
  lazy var finderKeys = FinderKeys(island: island)
  /// 平滑滚动（插件，SmoothScroll/）：起停跟着插件添没添加和辅助功能授权（apply），滚动那条线程由它管
  private(set) lazy var smoothScroll = SmoothScroll()
  lazy var keyRemapping = KeyRemapping(rulesKey: Prefs.keyRemappingRules)
  /// 片段展开（剪贴板的一项，2026-11-22）：起停在 apply（启动、偏好变了、剪贴板条目变了）
  private(set) lazy var snippetExpander = SnippetExpander(store: clipboardStore)
  /// 应用内更新（读本仓库的 GitHub release）
  let updater = Updater()
  /// CleanShot 式常驻缩略图（截图飞入右下角后留在那里）
  let shelf = ShotShelf()
  /// 晾衣绳（第十族，2026-10-26 拍板）：屏幕顶上一根绳子，挂着截图历史里的几条；和常驻缩略图二选一
  /// （设置 › 截图「截完图放哪」）。截图这个功能开着才起，鼠标停到菜单栏那一条上才滑下来
  lazy var clothesline: Clothesline = {
    let line = Clothesline(history: shotHistory)
    // 看框选遮罩 / 长截图面板 / 长图标注遮罩在不在屏幕上，不看 isCapturing（第三轮体检 R4：框选收起后这次截图
    // 还在出图、记历史，看标记的话绳子不先下来、挂上了也不出来）
    line.isSuppressed = { [unowned self] in
      statusScreen.isActive || Clothesline.isCovered(by: NSApp.windows)
        || (Feature.launchpad.isOn && launchpad.isOpen)
    }
    line.onHide = { [unowned self] in idleReclaim.schedule() }
    line.actions = shotActions
    return line
  }()
  /// 状态屏（PLAN §10）：进入时收起三块浮层、停用全局热键，退出时恢复。正在录屏 / 录音时不让进（控制条和停止项
  /// 会被盖住、热键停着，退出前停不了）；截图框选、读选中文字这类一会儿就完的事进行中也不进
  lazy var statusScreen: StatusScreen = {
    let screen = StatusScreen()
    screen.island = island
    screen.hotKeys = hotKeys
    screen.hidePanels = { [unowned self] in
      hidePanels()
      // 进去之后键盘鼠标都被拦着：便签攒着没落盘的先落下去，屏幕边缘那叠连打开着的便签一起收（suspend 里落盘）
      noteStore?.flush()
      noteEdge?.suspend(.all)
    }
    screen.blocker = { [unowned self] in
      let busy = String(localized: "先停止这一段再进入状态屏")
      if recorder != nil { return (String(localized: "正在录屏"), busy) }
      if audioRecorder?.isStarted == true { return (String(localized: "正在录音"), busy) }
      return nil
    }
    screen.isBusy = { [unowned self] in isCapturing || isReadingSelection }
    // 在状态屏里时到点的提醒等退出后再响（提醒 C11）；音量键那个拦截在里面时欠下的重建补上（E11）
    screen.onExit = { [unowned self] in
      if Feature.reminders.isOn { reminders.recheck() }
      mediaKeys.resume()
    }
    return screen
  }()
  /// 保持唤醒（第一个插件，PLAN §10「保持唤醒」）：起停跟着插件添没添加（applyFeatures），开始 / 结束在岛上说一声
  private(set) lazy var keepAwake: KeepAwake = {
    let keepAwake = KeepAwake()
    keepAwake.announce = { [unowned self] title, detail in
      island.show(
        "\(title)", detail: detail.map { "\($0)" }, tone: .info,
        symbol: SettingsPage.keepAwake.symbol)
    }
    keepAwake.island = island
    return keepAwake
  }()
  /// 提醒（PLAN §10「提醒」）：到点挂在刘海岛上。起停跟着功能开关（applyFeatures），列表变了看着偏好跟上
  lazy var reminders: ReminderCenter = {
    let center = ReminderCenter()
    center.island = island
    // 录屏 / 录音时边框、全屏、状态屏都降成轻提醒，也不出声（C11）
    center.isRecording = { [unowned self] in recorder != nil || audioRecorder?.isStarted == true }
    center.isStatusActive = { [unowned self] in statusScreen.isActive }
    center.enterStatus = { [unowned self] in enterStatus(forReminder: $0) }
    center.speak = { [unowned self] text in
      speaker.stop()
      speaker.toggle(text, language: nil)
    }
    center.grantAccessibility = { Permissions.requestAccessibility() }
    return center
  }()
  /// 选状态的面板（Z13a，按状态屏的全局快捷键时先出它；StatusScreen/StatusPicker.swift）：选了就立刻收起面板，
  /// 再进入——进不去（没授权、正在录屏…）也照常收起，原因由 StatusScreen.enter 说。那张卡片在屏幕上的位置一起给过去，
  /// 画面从它长到整屏（Z14a）
  lazy var statusPickerModel: StatusPickerModel = {
    let model = StatusPickerModel()
    model.onEnter = { [unowned self] preset, card in
      let panel = statusPicker.panel
      let origin = card.flatMap { panel?.screenRect(of: $0) }
      panel?.hide()
      statusScreen.enter(preset, from: origin)
    }
    return model
  }()
  /// 启动台（第八族，2026-10-18，SPEC）：全屏图标网格，和现有的「启动器」（⌥Space 搜索框）是两个东西。
  /// 打开时先收起别的浮层；截图、录屏、状态屏、正在录快捷键时不能打开。设置 › 启动台。
  lazy var launchpad: Launchpad = {
    let board = Launchpad()
    board.island = island
    board.usage = launcherUsage
    board.canOpen = { [unowned self] in
      !isCapturing && !isReadingSelection && recorder == nil && audioRecorder == nil
        && !statusScreen.isActive && !OverlayPanel.isSelectingRegion(in: NSApp.windows)
        && hotKeys.recording == nil
    }
    board.openTrackpadSettings = { [unowned self] in openTrackpadSettings() }
    board.willOpen = { [unowned self] in
      builtHomePanel?.hide()
      builtClipboardPanel?.hide()
      builtLauncherPanel?.hide()
      statusPicker.panel?.hide()
      noteCapture?.panel.hide()
      builtTranslatePanel?.hide()
    }
    return board
  }()
  /// 程序坞预览（第九族，2026-10-22，PLAN §10「程序坞预览」）：鼠标停在程序坞的 App 图标上弹出它所有窗口的缩略图。
  /// 功能开关开着才起（默认关）；启动台开着、状态屏、截图框选时不弹。设置 › 程序坞预览。
  /// 睡眠关蓝牙（插件，2026-11-17）：只有添加了才建
  /// App 快捷键（插件，2026-11-17，PLAN §10「App 快捷键」）：单独按住 ⌘ 弹出前台 App 菜单里的快捷键。添加了才起；
  /// 截图框选、状态屏、启动台开着时不弹（同程序坞预览）。面板用时建、收起后放掉（AppShortcuts 里的 TransientPanel）
  lazy var appShortcuts: AppShortcuts = {
    let shortcuts = AppShortcuts()
    shortcuts.isSuppressed = { [unowned self] in
      isCapturing || statusScreen.isActive || OverlayPanel.isSelectingRegion(in: NSApp.windows)
        || (Feature.launchpad.isOn && launchpad.isOpen) || hotKeys.recording != nil
    }
    shortcuts.onHide = { [unowned self] in idleReclaim.schedule() }
    shortcuts.announce = { [unowned self] text in
      island.show(text, tone: .warning, symbol: SettingsPage.appShortcuts.symbol)
    }
    return shortcuts
  }()
  lazy var bluetoothSnooze: BluetoothSnooze = {
    let snooze = BluetoothSnooze()
    snooze.announce = { [unowned self] text in
      island.show(text, tone: .warning, symbol: SettingsPage.bluetoothSnooze.symbol)
    }
    return snooze
  }()

  lazy var dockPreview: DockPreview = {
    let preview = DockPreview()
    preview.isSuppressed = { [unowned self] in
      isCapturing || statusScreen.isActive || OverlayPanel.isSelectingRegion(in: NSApp.windows)
        || (Feature.launchpad.isOn && launchpad.isOpen)
    }
    preview.onHide = { [unowned self] in idleReclaim.schedule() }
    builtDockPreview = preview
    return preview
  }()
  /// 程序坞预览建过没有（空闲回收看它，别为了回收把关着的功能建出来，同 builtLauncherPanel）
  private weak var builtDockPreview: DockPreview?

  /// 用时再建、收起后放掉（TransientPanel）：不像三块主面板那样天天呼出，里面最多 20 张缩小的状态屏，不常驻。
  /// 没有固定，点外面就收起；出现在鼠标所在屏的中央（OverlayPanel 不带 frameName、不 topAnchored 时就是居中）
  lazy var statusPicker = TransientPanel { [unowned self] in
    OverlayPanel(
      size: statusPickerModel.layout.size, autoHide: .clickOutside, isPinned: { false },
      content: StatusPickerView(model: statusPickerModel))
  }
  /// 主界面（2026-10-29，Shell/HomePanel.swift）：快捷键「打开主界面」、启动器、再打开一次 App 时出来。第一次用时才建、
  /// 建了留着（同启动器：小、天天用）；没有固定，点外面就收起
  lazy var homeModel = HomeModel()
  weak var builtHomePanel: OverlayPanel?
  lazy var homePanel: OverlayPanel = {
    let model = homeModel
    let panel = OverlayPanel(
      size: model.size, autoHide: .clickOutside, isPinned: { false },
      // 包 AnyView：同启动器（带了 environment 的不透明类型 Swift 6.4 不让直接传进这个泛型 init）
      content: AnyView(HomeView(model: model).environment(updater)))
    // ⌘, 设置、⌘Q 退出（主界面不激活本 App，主菜单收不到）
    panel.keyEquivalentHandler = { [unowned model] event in
      guard let extra = Home.command(code: event.typedKeyCode, modifiers: event.modifierFlags)
      else { return false }
      model.run(extra)
      return true
    }
    panel.onHide = { [unowned self] in
      statusItem?.homeDidClose()
      idleReclaim.schedule()
    }
    // 15–26 上再点菜单栏图标由图标自己收起：不当成点了外面（不然先收、松手时又开）
    panel.ignoresClick = { [unowned self] in statusItem?.ownsClick(at: $0) == true }
    model.hidePanel = { [unowned panel] in panel.hide() }
    // 直接推进到「功能」那一页（第五轮体检 U12，原来停在通用页顶上、还要再点「功能 ›」）
    model.openFeatures = { [unowned self] in
      showSettings(page: .general, path: [FeaturesPage.route])
    }
    // 打字转到启动器（X12）：启动器这个功能关着就响一声。按键原样交给启动器输入框的字段编辑器（经输入法：开着拼音时
    // 这一下进组字，第一个字母不拆出去，同 issue #30）；框里原有的字先全选、被这一下替换。输入框没拿到焦点时
    // （toggleLauncher 之后照理已经是它，同那里的 selectAll）退回直接填这个字
    model.typeToLauncher = { [unowned self, unowned panel] event in
      guard Feature.launcher.isOn else { return NSSound.beep() }
      panel.hide()
      if !(launcherPanel.isVisible && launcherPanel.isKeyWindow) { toggleLauncher() }
      if let editor = launcherPanel.firstResponder as? NSTextView {
        editor.selectAll(nil)
        editor.keyDown(with: event)
      } else {
        launcherModel.query = event.characters ?? ""
      }
    }
    model.perform = { [unowned self] target in
      switch target {
      case .action(let action): run(action)
      case .extra(let extra): run(extra)
      }
    }
    builtHomePanel = panel
    return panel
  }()
  /// 菜单栏图标与菜单（启动后才建：单测以本 App 为宿主时不往菜单栏加东西）
  var statusItem: StatusItem?
  /// 标注遮罩（长截图按 A、历史里双击打开，收起就放掉）
  var annotateOverlay: AnnotateOverlay?
  /// 截图历史窗口（菜单栏 / 启动器打开，关掉就放掉）
  var shotHistoryWindow: ShotHistoryWindow?
  /// 钉图（菜单栏显示「隐藏 / 关闭全部钉图」）
  lazy var pins: PinBoard = {
    let board = PinBoard()
    // 钉图不变、不飞卡片：拷贝、存好了都用刘海说（体检 C9：⌘S 快速保存，同截图；识字 / 翻译同截图工具栏，D17）

    board.output = { [unowned self] action, image, scale in
      Task {
        switch action {
        case .copy:
          guard let copied = await copyImage(image, scale: scale) else { return }
          island.show(
            "已复制钉图", detail: copied.detail.map { "\($0)" as LocalizedStringResource },
            leading: Island.thumbnail(of: image))
        case .save:
          guard let saved = await saveImage(image, scale: scale, asking: false) else { return }
          island.show(
            "\(FlyCard.Badge.saved(saved.url).title)", detail: "\(saved.url.lastPathComponent)",
            leading: Island.thumbnail(of: image), actions: .file(saved.url))
        case .saveAs: await saveImageAs(image, scale: scale)
        case .recognize: await copyRecognizedText(in: image)
        case .translate: await translateInPanel(image)
        case .pin: break
        }
      }
    }
    // 钉图上选中的字（2026-11-17）：拷贝同识字（记进剪贴板历史）；翻译同钉图的翻译（开翻译浮窗）；搜索同启动器的 ⌃↩
    board.textOutput = { [unowned self] action, text in
      switch action {
      case .copy:
        Paster.write(string: text, record: true)
        island.show("已复制", detail: "\(Island.excerpt(text))")
      case .translate:
        guard Feature.translate.isOn else { return }
        coordinator.translate(text)
        presentTranslate()
      case .search:
        let query = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard Feature.launcher.isOn, let engine = WebSearch.primary(),
          let url = URL(string: WebSearch.url(engine, query))
        else { return }
        // 交给系统在后台打开（同启动器：同步的 open 要等浏览器启动完才返回），打不开时岛说一声
        NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) {
          [weak self] _, error in
          guard let error else { return }
          let message = error.localizedDescription
          Task { @MainActor in
            self?.island.show(
              "打不开「\(url.absoluteString)」", detail: "\(message)", tone: .error)
          }
        }
      }
    }
    return board
  }()

  // MARK: 窗口

  lazy var clipboardModel = ClipboardPanelModel(store: clipboardStore)
  lazy var launcherModel = LauncherModel(usage: launcherUsage)
  /// 启动器的脚本命令（2026-11-07）：每次呼出启动器在主线程外重读一遍，换上了新的就让启动器重搜
  lazy var scriptLibrary: ScriptLibrary = {
    let library = ScriptLibrary()
    library.onChange = { [unowned self] in
      launcherModel.scriptsChanged()
      // 脚本加了 / 删了：给它们设的快捷键跟着注册 / 注销（第三轮 D1）
      hotKeys.reloadCommandsIfChanged()
    }
    return library
  }()

  /// 设置 › 启动器「脚本命令」开着（关着时自带的和自己的脚本都不出现）
  static var scriptsOn: Bool { UserDefaults.standard.bool(forKey: Prefs.launcherScripts) }

  /// 「命令和别名」里开 / 关一条（启动器 ⌘K「关掉这条命令」和它的「撤销」、复制自带的之后关掉自带的）：写偏好，
  /// 启动器和设置页都现读
  private static func setLauncherCommand(_ id: String, on: Bool) {
    var settings = LauncherModel.savedCommandSettings()
    settings.set(on, for: id)
    UserDefaults.standard.set(settings.offText, forKey: Prefs.launcherCommandsOff)
  }

  /// 启动器 ⌘K「改别名…」（第二轮 D1）：打开 设置 › 启动器 › 命令和别名，只列这一条、别名框拿着焦点
  private func openCommandSettings(_ id: String) {
    showSettings(page: .launcher)
    // 设置窗开着速查表 / 确认框时不换页（SettingsWindow.show）：没到启动器页就不推
    guard settingsNavigation.page == .launcher else { return }
    settingsNavigation.focusedCommand = id
    settingsNavigation.path = [LauncherCommandsPage.route]
  }

  /// 启动器 ⌘K「复制一份到我的脚本」：复制出来的和自带的同一个关键词，自带的关掉（同设置里右键的那一项，拍板 D2「用你的」）
  private func copyBundledScript(_ script: ScriptCommand) {
    guard let url = ScriptLibrary.copyBundled(script) else {
      return island.show("没复制成「\(script.title)」", detail: "脚本文件夹写不进去", tone: .error)
    }
    Self.setLauncherCommand(LauncherCommands.scriptID(script), on: false)
    scriptLibrary.refresh()
    island.show(
      "已复制到我的脚本：\(url.lastPathComponent)", detail: "自带的那条关掉了，改这一份就行",
      actions: [.reveal(url)])
  }

  /// 看过、确认要跑的下载来的脚本：去掉隔离标记，重读脚本库
  private func approveDownloadedScript(_ script: ScriptCommand) async {
    _ = await ScriptRunner.clearDownloaded(script.path)
    scriptLibrary.refresh()
  }

  /// 空闲回收（常驻内存，2026-10-07，PLAN §10）：三块主面板哪块收起、进程内识完一次字、全部便签窗口关掉、屏幕边缘
  /// 那叠收起、浮动便签收回（2026-10-18）都重新计时，过了 Memory.idleDelay 还闲着（isIdle），就把闲着白占的还回去——
  /// 透镜缓存（装满约 50 MB，再看到时重做）、链接预览的头图（12 条都看过约 70 MB；字节留着，再看到时重解，不联网）、
  /// 关着的全部便签窗口（约 12 MB）、便签图片的缩略图（便签墙上看过 50 张图约 65 MB）、程序坞预览的缩略图缓存（最多
  /// 20 张、最坏约 11 MB）和收着的预览面板（约 6 MB；预览收起时也重新计时）、识字模型（macOS 15 上约 50 MB，下次识字
  /// 重新加载，慢 0.2–0.4 s；放它要 18–200 ms，在主线程外做；设置里关掉「空闲时释放识字模型」的不放，PR #39）、
  /// 分配器手里的空页（跑了三天的正式版估 20–34 MB；放在最后，前几样腾出来的页一起还）。到点时还忙着（面板固定着、
  /// 正在用）就再等一轮
  lazy var idleReclaim = Memory.IdleTimer(
    after: Memory.idleDelay,
    isIdle: { [unowned self] in Self.isIdle(windows: NSApp.windows, isCapturing: isCapturing) },
    work: { [unowned self] in reclaimIdleMemory() })

  /// 开机后闲下来（3 秒，没在框选、没有面板开着、没在走欢迎引导；忙着就再等一轮）在屏外预排启动器和剪贴板面板
  /// （2026-11-23 美化与提速 P7：第一次呼出要当场建 SwiftUI 树、排第一遍版，启动器约 155 ms、剪贴板 5000 条 100–155 ms；
  /// 预排过 40–55 ms）。只做一次，启动时排上（applicationDidFinishLaunching）
  lazy var panelPrewarm = Memory.IdleTimer(
    after: .seconds(3),
    isIdle: { [unowned self] in
      Self.isIdle(windows: NSApp.windows, isCapturing: isCapturing)
        && !settingsNavigation.showsOnboarding
    },
    work: { [unowned self] in prewarmPanels() })

  /// 功能关着的不建（关着时本来就不会被建出来）；已经呼出过的不用。启动器先按空搜索框搜一遍（收藏、常用），第一次呼出时
  /// prepareForShow 搜出来的还是这几行，SwiftUI 只比一遍；面板建好之后再搜（搜索要读面板接上的功能开关）
  private func prewarmPanels() {
    if Feature.launcher.isOn, builtLauncherPanel == nil {
      let panel = launcherPanel
      launcherModel.search()
      panel.prewarm()
    }
    if Feature.clipboard.isOn, builtClipboardPanel == nil { clipboardPanel.prewarm() }
  }

  /// 上一次看到的「空闲时释放识字模型」。AppDelegate 建出来时默认值还没注册（bool(forKey:) 读到 false），先按注册的
  /// 默认值（开）记；偏好里是关的，第一次偏好通知时预热一次，和启动时那次是同一个（OCR.foreground 只做一次）
  private var lastOCRReleaseWhenIdle = true

  /// 「空闲时释放识字模型」变了（设置里拨、导入、同步）：打开时上一轮空闲回收可能已经做完，重新排一次；关掉时预热上
  func applyIdleOCRPreference() {
    let enabled = UserDefaults.standard.bool(forKey: Prefs.ocrReleaseWhenIdle)
    guard enabled != lastOCRReleaseWhenIdle else { return }
    lastOCRReleaseWhenIdle = enabled
    if enabled { idleReclaim.schedule() } else { warmRecognitionIfKept() }
  }

  /// 关掉了「空闲时释放识字模型」、开着截图或翻译、模型编好了：在后台把进程内的识字模型加载上（OCR.foreground：本次
  /// 运行最多一次，真实请求先到就不做）。默认开着释放时不预热——预热完两分钟又会被空闲回收放掉，白做一回（PR #39）。
  /// 实测（macOS 27.0.1，2026-11-20）：预热 0.2 s、CPU 0.1 s，之后第一次识 1200 × 600 的选区快 0.1–0.3 s
  func warmRecognitionIfKept() {
    guard !UserDefaults.standard.bool(forKey: Prefs.ocrReleaseWhenIdle),
      !Feature.enabled.isDisjoint(with: [.screenshot, .translate]), OCR.isPrepared()
    else { return }
    OCR.foreground.warmIfUnused { [self] in
      if !(await OCR.warmForegroundModels()) { Log.clipboard.error("前台识字预热没成") }
      idleReclaim.schedule()
    }
  }

  /// 现在算不算闲（纯函数）：没在框选，看得见的窗口里没有浮层（三块主面板等）、没有全部便签窗口、没有展开着的那叠
  /// （扇着、打开着便签；一直展开时静置的那一列常驻屏幕上，不算）。**浮动便签不拦**：它可以一直浮在屏幕上，拦了就
  /// 永远不回收（清缓存时留下它的图，见 reclaimIdleMemory）。设置窗也不拦：回收的东西它都不用（开着的设置窗不放，
  /// releaseClosedSettingsWindow 只放关着的）
  static func isIdle(windows: [NSWindow], isCapturing: Bool) -> Bool {
    !isCapturing
      && !windows.contains { window in
        guard window.isVisible else { return false }
        if let deck = window as? NoteDeckPanel { return deck.isExpanded }
        return window is OverlayPanel || window.identifier == NotesWindow.identifier
      }
  }

  private func reclaimIdleMemory() {
    ThumbnailView.dropPreviews()
    // 程序坞预览关着也放（R10：原来只在开着时放，关掉之后弹过的面板一直留着）；没建过就不建
    builtDockPreview?.reclaim()
    // 截图关着也放（R10：原来只在开着时放，关掉截图之后那块面板一直留着）；历史的缩略图只留挂在绳子上的那几张
    clothesline.reclaim()
    ShotThumbnails.shared.keep(only: clothesline.model.pegged)
    LinkPreview.shared.dropHeroes()
    Annotation.releaseCaches()  // 打码的缩小图和模糊用的 Core Image 上下文（约 45 MB，2026-11-12）
    releaseClosedNotesWindow()
    releaseClosedSettingsWindow()
    // 便签正文里解好的图片缩略图（第 7 批：按像素数算 cost，闲下来整块放掉）；浮在屏幕上的那张便签里的图留着
    // （清了它下一次重画先闪一块纸色）
    let floating = (noteEdge?.floats.floatingIDs ?? []).compactMap { noteStore?.note($0) }
    NoteImageThumbnails.discard(keeping: Set(floating.flatMap { NoteImages.ids(in: $0.body) }))
    Task {
      if UserDefaults.standard.bool(forKey: Prefs.ocrReleaseWhenIdle) {
        await OCR.releaseModel()
      }
      Memory.relieve()
    }
  }

  /// 关着的全部便签窗口整个放掉（2026-10-18 量：300 条、50 张图的便签墙关掉、清了缩略图缓存之后，放掉窗口还能再回落
  /// 约 12 MB——窗口的图层、SwiftUI 视图树、墙上卡片自己拿着的缩略图；重开到第一屏约 0.2 s，卡片缓存在仓库里不用重建）。
  /// 模型留着（notesModel）。最小化着的不放（它在程序坞里，放了就点不回来）。
  /// 照 NoteDeck.releasePanel 的写法：先拿到局部变量、属性置空，再拆视图树（拆的时候有回调进来，属性已经是 nil）
  private func releaseClosedNotesWindow() {
    guard let old = notesWindow, !old.isVisible, !old.window.isMiniaturized else { return }
    notesWindow = nil
    old.window.contentViewController = nil
    // 搜索的折叠缓存只有这扇窗口的搜索框用：一起放掉
    noteStore?.dropSearchCache()
  }

  /// 关着的设置窗整个放掉（2026-11-24 量，内存探针第 7 节：17 页各看两遍后关窗，留着的窗口和停着的那一页约 15 MB 堆、
  /// 3 MB 属性图；放掉后 footprint 第一次回落 8–39 MB（7 次中位 33），之后每次 3–8 MB。关窗后不回落的大头不在这里：
  /// 第一次打开时系统框架一次性的类型、符号缓存约 20 MB，和分配器留着的空闲页约 30 MB（macOS 27 的 xzone，调回收接口还不出）。
  /// 代价是再打开要重建，-O 的测试宿主里约 0.5 s（留着时 1–3 ms），所以等闲下来再放：刚关又开的不用重建。
  /// 最小化着的不放（它在程序坞里）。同 releaseClosedNotesWindow：先置空属性，再拆视图树
  private func releaseClosedSettingsWindow() {
    guard let old = builtSettingsWindow, !old.window.isVisible, !old.window.isMiniaturized else {
      return
    }
    builtSettingsWindow = nil
    // 记位置的名字让出来（万一旧窗口对象还被谁捏着，新建的那扇就占不到这个名字、不再记位置）
    old.window.setFrameAutosaveName("")
    old.window.contentViewController = nil
  }

  /// 三块主面板建过没有（lazy：一碰就建）。只是要收起时看它们：没建过就不用收，别为了收起把关着的功能（Feature）的面板
  /// 建出来、一直留在内存里（打开设置窗、呼出别的面板、划词时都会收一遍）
  weak var builtLauncherPanel: OverlayPanel?
  weak var builtClipboardPanel: OverlayPanel?
  weak var builtTranslatePanel: OverlayPanel?

  lazy var launcherPanel: OverlayPanel = {
    let model = launcherModel
    let panel = OverlayPanel(
      size: NSSize(width: Style.listPanelWidth, height: LauncherPanelView.searchHeight),
      minSize: NSSize(
        width: Style.listPanelWidths.lowerBound, height: LauncherPanelView.searchHeight),
      frameName: "LauncherPanel", topAnchored: true,
      // 启动器没有固定（N8）：点外面就收起
      autoHide: .clickOutside, isPinned: { false },
      // 包 AnyView：带了 environment 的是不透明类型，Swift 6.4 认为它的 View 遵循可能是隔离的、不让直接传进这个泛型 init
      // （编译警告）；根视图的类型不变，包一层没有重建的开销。剪贴板、翻译浮窗同
      content: AnyView(LauncherPanelView(model: model).environment(updater)))
    panel.keyEquivalentHandler = { [unowned model] in model.handleKeyEquivalent($0) }
    // 拖左右边改宽度、拖下边改最多几行（2026-11-05 W1 W2）
    panel.maxSize = NSSize(
      width: Style.listPanelWidths.upperBound, height: .greatestFiniteMagnitude)
    panel.widthKey = Prefs.launcherPanelWidth
    panel.heightRange = { [unowned model] in LauncherPanelView.heightRange(for: model) }
    panel.heightDragged = { [unowned model] height in
      UserDefaults.standard.set(
        LauncherPanelView.rows(forHeight: height, model: model), forKey: Prefs.launcherPanelRows)
    }
    panel.onHide = { [unowned self, unowned model] in
      model.didHide()
      idleReclaim.schedule()
    }
    panel.squeezesIn = { Self.squeezesIn() }
    model.hidePanel = { [unowned panel] in panel.hide() }
    model.pasteTargetView = { [unowned panel] in panel.pasteTarget() }
    // ⌘K 菜单开着时瞬间长高：菜单锚在底栏上方，面板边长边插进来会越过搜索栏被裁，得先长好再从右下角放大。
    // 连着打字时也直接到位（isTyping，P4）
    model.resize = { [unowned panel, unowned model] in
      panel.setContentHeight($0, animated: !model.showsActions && !model.isTyping)
    }
    model.runAction = { [unowned self] in runLauncherAction($0) }
    model.actionState = { [unowned self] in menuState }
    // ⌘, 和内置「设置」：设置 › 启动器，停在「空搜索框里列出常用」（设置改版 S8）
    model.openSettings = { [unowned self] in showSettings(.launcherFrequent) }
    // cb、fy 两行只在剪贴板 / 翻译开着（Feature）时列出来，这里再挡一道
    model.openClipboard = { [unowned self] in
      if Feature.clipboard.isOn { searchClipboard($0) }
    }
    // fy 那一行（体检 D10）：翻译浮窗直接翻译，位置照「浮窗位置」设置（跟随鼠标 / 上次位置）
    model.translate = { [unowned self] text in
      guard Feature.translate.isOn else { return }
      coordinator.translate(text)
      presentTranslate()
    }
    // 「提醒 …」（提醒 D2 D4）：列表现读偏好；建一条、打开 / 暂停都写回偏好，执行层看着偏好变化跟上
    model.reminders = { Feature.reminders.isOn ? Reminder.load() : [] }
    model.createReminder = { [unowned self] in addReminder($0) }
    model.toggleReminder = { id in
      var list = Reminder.load()
      guard let index = list.firstIndex(where: { $0.id == id }) else { return }
      list[index].isOn.toggle()
      Reminder.save(list)
    }
    model.openReminder = { [unowned self] in openReminder($0) }
    model.offerPlugin = { [unowned self] in showPlugin($0) }
    model.keepAwakeStatus = { [unowned self] in
      keepAwake.sessionEnd == nil ? nil : keepAwake.status()
    }
    model.keepAwakeBegin = { [unowned self] in keepAwake.begin(until: $0, label: $1) }
    model.keepAwakeEnd = { [unowned self] in keepAwake.end() }
    model.openQuickLook = { [unowned self] in
      launcherQuickLook.open().zoom(
        from: launcherRowFrame ?? launcherPanel.frame, to: launcherQuickLookFrame)
    }
    model.closeQuickLook = { [unowned self] animated in
      Self.closeQuickLook(
        launcherQuickLook.panel, owner: launcherPanel, animated: animated, to: launcherRowFrame)
    }
    // 搜前台 App 的菜单项（第五轮体检 N3）：归 App 快捷键插件、要辅助功能授权；前台是本 App 时不读（主线程问自己会卡到超时）
    model.menuApp = {
      guard Feature.appShortcuts.isOn, Permissions.isAccessibilityTrusted,
        let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid()
      else { return nil }
      return app
    }
    model.pressMenu = { [unowned self] entry in
      guard Feature.appShortcuts.isOn,
        let app = NSRunningApplication(processIdentifier: entry.pid), !app.isTerminated
      else { return }
      // 启动器不激活本 App，前台一般还是它；万一换了（比如中间点过别处）先切回去，菜单项按下去的窗口在前面
      if !app.isActive { app.activate() }
      AppShortcuts.press(entry.item, in: app) { [unowned self] text in
        island.show(text, tone: .warning, symbol: SettingsPage.appShortcuts.symbol)
      }
    }
    model.boundHotKey = { [unowned self] in hotKeys.bindings[$0] }
    model.requestFolderAccess = { [unowned self] in requestFolderAccess() }
    model.perform = { [unowned self] in SystemControl.perform($0, island: island) }
    model.island = island
    model.scripts = { [unowned self] in Self.scriptsOn ? scriptLibrary.scripts : [] }
    model.scriptsOn = { Self.scriptsOn }
    model.approveScript = { [unowned self] in await approveDownloadedScript($0) }
    model.editScript = { ScriptLibrary.edit($0.path) }
    model.openCommandSettings = { [unowned self] in openCommandSettings($0) }
    model.setCommandOn = { Self.setLauncherCommand($0, on: $1) }
    model.copyBundledScript = { [unowned self] in copyBundledScript($0) }
    model.showPanel = { [unowned self] in
      // 那一张里留着的「看输出」：启动器关掉了就不叫（关掉 = 入口全藏）
      guard Feature.launcher.isOn else { return false }
      if !(launcherPanel.isVisible && launcherPanel.isKeyWindow) { toggleLauncher() }
      return true
    }
    builtLauncherPanel = panel
    return panel
  }()

  /// 启动器 ⌘Y 快速查看（体检 C7）：选中文件的 Quick Look 卡，从选中行长出来；同剪贴板 ⌘Y 大卡，不抢键盘
  /// （点它里面才当 key），点外面就关，↑↓ 仍在启动器里换选中、预览跟着换。用时再建、收起后放掉（TransientPanel）
  lazy var launcherQuickLook = TransientPanel { [unowned self] in
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
  static func squeezesIn() -> Bool {
    UserDefaults.standard.bool(forKey: Prefs.panelSqueezeEntrance)
  }

  /// ⌘Y 大卡收走后：键盘关掉的（它是 key 时按 Esc）把 key 还给主面板；点别处关掉的不抢（鼠标还按着：用户正要去别处打字）
  private static func returnKey(to owner: OverlayPanel) {
    if NSApp.keyWindow == nil, NSEvent.pressedMouseButtons == 0, owner.isVisible {
      owner.makeKey()
    }
  }

  lazy var clipboardPanel: OverlayPanel = {
    let model = clipboardModel
    // 透镜指令条：和启动器同位置同宽（顶边在可见区 20%），高度按条数伸缩、顶边不动
    let panel = OverlayPanel(
      size: NSSize(
        width: ClipboardPanelView.width, height: ClipboardPanelView.height(for: model)),
      minSize: NSSize(
        width: Style.listPanelWidths.lowerBound, height: ClipboardPanelView.searchHeight),
      frameName: "ClipboardPanel", topAnchored: true, autoHide: .clickOutside,
      isPinned: { !UserDefaults.standard.bool(forKey: Prefs.clipboardHideOnUnfocus) },
      content: AnyView(ClipboardPanelView(model: model).environment(updater)))
    panel.keyEquivalentHandler = { [unowned model] in model.handleKeyEquivalent($0) }
    panel.onHide = { [unowned self, unowned model] in
      model.reset()
      idleReclaim.schedule()
    }
    panel.squeezesIn = { Self.squeezesIn() }
    model.hidePanel = { [unowned panel] in panel.hide() }
    model.pasteTargetView = { [unowned panel] in panel.pasteTarget() }
    // 打字带来的高度变化直接到位（isTyping，美化与提速 P3）
    model.resize = { [unowned panel, unowned model] in
      panel.setContentHeight($0, animated: !model.isTyping)
    }
    panel.maxSize = NSSize(
      width: Style.listPanelWidths.upperBound, height: .greatestFiniteMagnitude)
    panel.widthKey = Prefs.clipboardPanelWidth
    panel.heightRange = {
      ClipboardPanelView.heightRange(banner: !Permissions.isAccessibilityTrusted)
    }
    panel.heightDragged = { height in
      UserDefaults.standard.set(
        ClipboardPanelView.rows(forHeight: height, banner: !Permissions.isAccessibilityTrusted),
        forKey: Prefs.clipboardPanelRows)
    }
    // 剪贴板面板保持打开（兄弟浮层），翻译浮窗出现在旁边。翻译关着（Feature）时面板里没有这一项，这里再挡一道
    model.openTranslate = { [unowned self] text in
      guard Feature.translate.isOn else { return }
      coordinator.translate(text)
      presentTranslate()
    }
    // ⌘, 和底栏齿轮直达 设置 › 剪贴板（同翻译浮窗直达 设置 › 翻译）
    model.openSettings = { [unowned self] in showSettings(.clipboardPasteOnClick) }
    model.openQuickLook = { [unowned self] in showQuickLook() }
    // 图片条目「钉到屏幕」（体检 D1）：和截图的钉图同一块板
    model.pinImage = { [unowned self] in pins.pin($0, frame: $1) }
    model.pinnedFrames = { [unowned self] in pins.panels.map(\.frame) }
    model.island = island
    model.closeQuickLook = { [unowned self] animated in
      Self.closeQuickLook(
        quickLookPanel.panel, owner: clipboardPanel, animated: animated, to: cardScreenFrame)
    }
    builtClipboardPanel = panel
    return panel
  }()

  /// ⌘Y 放大预览：剪贴板选中条目的大卡片。不抢键盘（点它里面的文字才当 key），点外面就关。
  /// 用时再建、收起后放掉（TransientPanel）；放掉时把大卡那一档的缩略图也丢掉，再让分配器把空页还给系统（体检 M1 M4）
  lazy var quickLookPanel = TransientPanel(
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

  lazy var translatePanel: OverlayPanel = {
    // 视图在面板建好之前就可能要求改高度：用弱引用接，别在 lazy 初始化里回头访问 translatePanel
    weak var created: OverlayPanel?
    let panel = OverlayPanel(
      size: NSSize(width: TranslatePanelView.defaultWidth, height: 560),
      minSize: NSSize(width: 360, height: 200),
      frameName: "TranslatePanel", autoHide: .resignKey,
      isPinned: { UserDefaults.standard.bool(forKey: Prefs.floatingPinned) },
      content: AnyView(
        TranslatePanelView(
          coordinator: coordinator, speaker: speaker,
          resize: { [unowned self] height, mustFit in
            // 高度随内容（Bob 的做法），前三张结果卡总放得下（TranslatePanelView.panelHeight）。
            // 最小 / 最大高度都钉在这个值上：用户只能拖宽度，拖高度会和自动高度打架
            guard let panel = created else { return }
            let visible = (panel.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
            let height = TranslatePanelView.panelHeight(
              height, mustFit: mustFit, visible: visible,
              cap: UserDefaults.standard.double(forKey: Prefs.translatePanelMaxHeight))
            panel.minSize = NSSize(width: 360, height: height)
            panel.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: height)
            // 出字时一行一行直接长到位，别的时候变化 8 pt 以上才带动画（TranslatePanelView.animatesResize）
            panel.setContentHeight(
              height,
              animated: TranslatePanelView.animatesResize(
                from: panel.frame.height, to: height, streaming: coordinator.isStreamingText))
          },
          replaceOriginal: { [unowned self] in replaceOriginal() },
          isShown: { created?.isVisible ?? false }
        ).environment(island)))
    created = panel
    // 宽度记进偏好（W1；以前拖过的宽度在 frameName 里，没写过偏好时照旧用那份）、拖下边定最高多高（W2）
    panel.widthKey = Prefs.translatePanelWidth
    panel.heightRange = { [weak panel] in
      let visible = (panel?.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
      return TranslatePanelView.minHeight...max(visible - 24, TranslatePanelView.minHeight)
    }
    panel.heightDragged = { height in
      UserDefaults.standard.set(Double(height), forKey: Prefs.translatePanelMaxHeight)
    }
    coordinator.historyList.island = island
    panel.keyEquivalentHandler = { [unowned self] in coordinator.handleKeyEquivalent($0) }
    // ⌘,、「⋯」菜单和空状态到设置 › 翻译；错误卡带服务 id，直达那个服务的详情页（体检 C5）
    coordinator.openSettings = { [unowned self] service in
      // 没带服务的落到「翻译服务」那一组（设置改版 S8）
      guard let service else { return showSettings(.translateServices) }
      showSettings(page: .translate)
      // 设置窗开着速查表 / 确认框时不换页（SettingsWindow.show）：没到翻译页就不推，别把服务 id 推进别的页的 NavigationStack
      if settingsNavigation.page == .translate { settingsNavigation.path = [service] }
    }
    coordinator.focusSource = { [unowned panel] in
      panel.makeFirstResponder(panel.initialFirstResponder)
    }
    coordinator.isPanelKey = { [unowned panel] in panel.isKeyWindow }
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
    builtTranslatePanel = panel
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
  var firstInstall = false
  /// 欢迎引导从哪一屏起：首次安装没走完、下次接着开的从做到的那屏起（E1）；关于页重看从头
  var onboardingStart = OnboardingView.Screen.welcome
  /// 「已更新到」那座岛已经顺带说了同步新加的几类先没勾（NoteSyncer.isUpgrade）：便签库开好后不再单独弹
  var toldSyncUpgrade = false

  /// 设置窗的导航状态：窗口懒建，主菜单的「显示 › 返回」（KittyToolsApp 的 SettingsCommands）一启动就要读它
  let settingsNavigation = SettingsNavigation()

  /// 设置窗：用时再建；关掉后闲下来整个放掉（releaseClosedSettingsWindow），再打开时重建，还停在原来那页（导航状态在
  /// settingsNavigation 里）
  private var builtSettingsWindow: SettingsWindow?

  var settingsWindow: SettingsWindow {
    if let built = builtSettingsWindow { return built }
    let window = makeSettingsWindow()
    builtSettingsWindow = window
    return window
  }

  private func makeSettingsWindow() -> SettingsWindow {
    settingsNavigation.newScriptCreated = { [unowned self] url in
      scriptLibrary.refresh()
      island.show(
        "已新建「\(url.lastPathComponent)」", detail: "改好保存，下次呼出启动器就能用",
        actions: [.reveal(url)])
    }
    // 新功能标记：换到一页（打开设置窗也算）时重算设置窗里该标哪几个。光打开不算碰过（拨了那一节 / 那一行开关才算，2026-11-06），
    // 这一页上刚拨过的看着的时候不闪掉（WhatsNew.shown）
    settingsNavigation.visit = { [unowned self] page in
      let fresh = WhatsNew.current()
      let shown = WhatsNew.shown(visiting: page, fresh: fresh, showing: settingsNavigation.fresh)
      if shown != settingsNavigation.fresh { settingsNavigation.fresh = shown }
    }
    // 每一页都给刘海岛（子页、「高级…」里的「恢复默认」要在岛上给「撤销」）
    let pages: (SettingsPage) -> AnyView = { [unowned self] page in
      switch page {
      case .general:
        AnyView(
          GeneralTab(
            transfer: SettingsTransfer(
              services: serviceStore, clipboard: clipboardStore, history: historyStore,
              notes: { [unowned self] in noteStore },
              applied: { [unowned self] in settingsImported() },
              backupFolder: Backup.folder(in: dataDirectory),
              snapshot: { [unowned self] in try snapshotBeforeImport() },
              backupNow: { [unowned self] in await backupSettingsIfDue() }),
            sync: noteSyncer
          )
          .environment(island))
      case .island: AnyView(IslandTab(mediaKeys: mediaKeys))
      case .plugins: AnyView(PluginsPage())
      case .clipboard:
        AnyView(
          ClipboardTab(store: clipboardStore, expander: snippetExpander).environment(island))
      case .launcher:
        AnyView(
          LauncherTab(scripts: scriptLibrary) { [unowned self] in
            launcherUsage.clearAll()
            // 设置页上不显示条数，清完看不出变化
            island.show(
              "已清空启动器使用记录", detail: "「常用」和排序会从头开始学，收藏不动",
              symbol: "clock.arrow.circlepath")
          }
          .environment(island)
          // 「命令和别名」里每条命令的快捷键录制框（第三轮 D1）
          .environment(hotKeys))
      case .launchpad:
        AnyView(
          LaunchpadTab(
            resetDefault: { [unowned self] in launchpad.resetToDefault() },
            undo: { [unowned self] in launchpad.undoLastLayoutChange() },
            canUndo: { [unowned self] in launchpad.canUndoLayout },
            reflow: { [unowned self] in launchpad.reflow(from: $0) },
            importSystem: { [unowned self] in launchpad.importFromSystem() },
            pinchChanged: { [unowned self] in launchpad.applySettings() },
            cornerChanged: { [unowned self] in launchpad.applySettings() },
            pinchAvailable: { [unowned self] in launchpad.pinchAvailable },
            systemPinchOn: { [unowned self] in launchpad.systemPinchIsOn },
            openTrackpadSettings: { [unowned self] in openTrackpadSettings() },
            copyPinchCommand: { [unowned self] in launchpad.copyPinchCommand() }))
      case .screenshot:
        AnyView(
          ScreenshotTab(shots: shotHistory, openHistory: { [unowned self] in showShotHistory() }))
      case .record: AnyView(RecordTab())
      case .notes:
        AnyView(
          NotesTab(
            openNotes: { [unowned self] in showNotes() },
            notes: { [unowned self] in noteStore },
            images: { [unowned self] in noteStore?.images },
            island: island))
      case .statusScreen: AnyView(StatusScreenTab())
      case .reminders: AnyView(RemindersTab())
      case .dockPreview: AnyView(DockPreviewTab())
      case .finderMenu: AnyView(FinderMenuTab())
      case .keepAwake: AnyView(KeepAwakeTab(keepAwake: keepAwake))
      case .bluetoothSnooze:
        AnyView(BluetoothSnoozeTab { [unowned self] in bluetoothSnooze.requestAccess() })
      case .smoothScroll: AnyView(SmoothScrollTab(smoothScroll: smoothScroll))
      case .appShortcuts: AnyView(AppShortcutsTab())
      case .keyRemapping: AnyView(KeyRemappingTab(remapping: keyRemapping))
      case .translate:
        AnyView(
          TranslateTab(services: serviceStore, history: historyStore, speaker: speaker)
            .environment(island))
      // 「全部恢复默认」的撤销在刘海岛上（第五轮体检 U5）
      case .hotkeys: AnyView(HotkeysTab(center: hotKeys).environment(island))
      case .about:
        // 开发版（bundle id 不同）不更新，不显示更新那一行
        AnyView(
          AboutTab(updater: updater.isSupported ? updater : nil) {
            self.firstInstall = false
            self.onboardingStart = .welcome
            self.settingsNavigation.showsOnboarding = true
          })
      }
    }
    let window = SettingsWindow(navigation: settingsNavigation) { [unowned self] in
      AnyView(pages($0).environment(island))
    } onboarding: { [unowned self] in
      AnyView(
        OnboardingView(center: hotKeys, firstRun: firstInstall, screen: onboardingStart) {
          [unowned self] screen in
          // 首次安装：记做到了第几屏（引导只往前翻），没走完就退出、下次接着开（E1）
          if firstInstall {
            UserDefaults.standard.set(screen.rawValue, forKey: Prefs.onboardingScreen)
          }
        }
        .environment(island))
    }
    window.onClose = { [unowned self] in idleReclaim.schedule() }
    return window
  }

  /// 到点的提醒要进入状态屏（提醒 C1 / C12）：先把进不去的情况挑出来（进不去时提醒退成全屏，原因写在全屏上——状态屏自己的
  /// 警告岛会被全屏盖住），再真的进。进去了返回 nil
  private func enterStatus(forReminder id: String) -> (reason: String, grants: Bool)? {
    guard Feature.statusScreen.isOn else { return (String(localized: "状态屏插件没添加"), false) }
    guard Permissions.isAccessibilityTrusted else {
      return (String(localized: "还没给辅助功能授权，进不了状态屏"), true)
    }
    if let blocked = statusScreen.blocker() {
      return (String(localized: "\(blocked.title)，没进状态屏"), false)
    }
    guard !statusScreen.isBusy(), !statusScreen.isActive else {
      return (String(localized: "现在进不了状态屏"), false)
    }
    let presets = StatusPreset.load()
    guard let preset = presets.first(where: { $0.id == id }) ?? presets.first else {
      return (String(localized: "没有可进入的状态"), false)
    }
    statusScreen.enter(preset)
    return statusScreen.isActive ? nil : (String(localized: "没进入状态屏"), false)
  }

  /// 导入设置（设置 › 通用）整批写完偏好之后，让运行中的东西跟上：各页自己改的时候有各自的 onChange，这里没人通知。
  /// 别的设置都是用到时现读偏好，菜单栏图标自己看着偏好。返回按新上限清掉了几条剪贴板历史（导入的结果里说）
  func settingsImported() -> Int {
    AppAppearance.apply()
    Accent.shared.select(
      AccentChoice(rawValue: UserDefaults.standard.string(forKey: Prefs.accent) ?? "") ?? .system,
      persists: false)
    // 正在录快捷键时热键停着，录完它自己会重新注册
    if hotKeys.recording == nil { hotKeys.reload() }
    launchpad.applySettings()
    if Feature.clipboard.isOn { clipboardStore.recognizePendingImages() }
    // 功能开关变了的，偏好的变化通知到了 applyFeatures 自己跟上
    return clipboardStore.enforceLimits()
  }

  // MARK: 截图要的存储属性（截图的方法在 AppDelegate+Screenshot.swift）

  /// 历史里一条的那几样操作：历史窗口和晾衣绳共用一份（只接一次）。
  /// 读原图、缩略图都在主线程外（R6：原来点一下「改标注」、单击晾衣绳上带标注的那张，主线程上整张解码）
  lazy var shotActions: ShotActions = {
    var actions = ShotActions()
    actions.copy = { [unowned self] item in
      Task {
        // 录制的那几条拷的是文件（同常驻缩略图的视频卡，C8-a：点了才进剪贴板历史）
        if let path = item.filePath {
          let url = URL(filePath: path)
          guard ShotHistory.fileExists(item) else { return missingShotFile() }
          Paster.write(files: [url])
          if recordsClipboard { clipboardStore.recordFiles([url]) }
          let poster = await shotHistory.thumbnail(for: item.id)
          island.show(
            "已复制\(item.kind.title)", detail: "\(url.lastPathComponent)",
            leading: poster.map { Island.thumbnail(of: $0) } ?? .tone)
          return
        }
        guard let image = await shotHistory.composed(item) else { return missingShot() }
        // 拷成文件时借存过的文件名（同拖出去的那份）
        let name = shotHistory.dragName(for: item)
        guard let copied = await copyImage(image, scale: item.scale, name: name) else { return }
        island.show(
          "已复制截图", detail: copied.detail.map { "\($0)" as LocalizedStringResource },
          leading: Island.thumbnail(of: image))
      }
    }
    actions.save = { [unowned self] item in
      Task {
        guard let image = await shotHistory.composed(item) else { return missingShot() }
        guard let saved = await saveImage(image, scale: item.scale, asking: false) else { return }
        shotHistory.markSaved(item.id, to: saved.url)
        island.show(
          "\(FlyCard.Badge.saved(saved.url).title)", detail: "\(saved.url.lastPathComponent)",
          leading: Island.thumbnail(of: image), actions: .file(saved.url))
      }
    }
    // 多选（2026-10-27）：拷贝写成几个文件放进剪贴板——剪贴板只装得下一张图，装文件才能一次给好几张
    // （和拖出去的是同一份：存过的 / 录制的就是那个文件，别的现合成一份成品 PNG）
    actions.copyMany = { [unowned self] items in
      Task {
        var urls: [URL] = []
        for item in items {
          if let url = await shotHistory.dragFile(for: item) { urls.append(url) }
        }
        guard !urls.isEmpty else { return missingShot() }
        Paster.write(files: urls)
        if recordsClipboard { clipboardStore.recordFiles(urls) }
        island.show(
          "已复制 \(urls.count) 项", detail: urls.first.map { "\($0.lastPathComponent)" })
      }
    }
    // 多选存储：一条条存到快速保存目录，最后只说一句（一张张弹提示会刷屏）
    actions.saveMany = { [unowned self] items in
      Task {
        var saved: [URL] = []
        for item in items {
          guard let image = await shotHistory.composed(item),
            let out = await saveImage(image, scale: item.scale, asking: false)
          else { continue }
          shotHistory.markSaved(item.id, to: out.url)
          saved.append(out.url)
        }
        guard let first = saved.first else { return missingShot() }
        let folder = ScreenshotOutput.folderName(of: first.deletingLastPathComponent())
        island.show("已存 \(saved.count) 张", detail: "\(folder)", actions: .file(first))
      }
    }
    actions.saveAs = { [unowned self] item in
      Task {
        guard let image = await shotHistory.composed(item) else { return missingShot() }
        if let saved = await saveImageAs(image, scale: item.scale) {
          shotHistory.markSaved(item.id, to: saved)
        }
      }
    }
    actions.pin = { [unowned self] item in
      Task {
        guard let image = await shotHistory.composed(item) else { return missingShot() }
        // 钉回当初那一块（拍板 B2），大小按图的比例重算（长截图记的是选区，E3）；没记位置的（老条目）、那块屏已经拔掉的
        // 钉在可见区中央，同「钉住剪贴板里的图」
        let frame = PinBoard.historyFrame(
          pixels: CGSize(width: image.width, height: image.height), scale: item.scale,
          source: item.frame, screens: NSScreen.screens.map { ($0.frame, $0.visibleFrame) },
          fallback: (NSScreen.main ?? NSScreen.screens[0]).visibleFrame,
          pinned: pins.panels.map(\.frame))
        pins.pin(image, frame: frame, window: item.isWindow)
        shotHistory.markPinned(item.id)
      }
    }
    actions.recognize = { [unowned self] item in
      Task {
        guard let image = await shotHistory.composed(item) else { return missingShot() }
        await copyRecognizedText(in: image)
      }
    }
    actions.notice = { [unowned self] text, warning in
      island.show("\(text)", tone: warning ? .warning : .info)
    }
    actions.edit = { [unowned self] item in
      Task {
        guard let original = await shotHistory.image(for: item.id) else { return missingShot() }
        openAnnotate(
          original, scale: item.scale, history: { item.id }, annotations: item.annotations,
          fromHistory: true)
      }
    }
    // 录屏转成 GIF / 压缩（U1）：进度岛、取消、结果岛同常驻缩略图的视频卡（VideoJob）；做好的进历史
    // （GIF 存进快速保存目录，压缩版在原文件旁边），封面用这一条的缩略图
    actions.convert = { [unowned self] item, job in
      guard let path = item.filePath, ShotHistory.fileExists(item) else { return missingShotFile() }
      Task {
        let poster = job == .compress ? await shotHistory.thumbnail(for: item.id) : nil
        job.start(URL(filePath: path), poster: poster, island: island) { [unowned self] output in
          Task {
            await shotHistory.record(file: output.file, poster: output.poster, kind: job.kind)
          }
        }
      }
    }
    actions.forget = { [unowned self] item in showShotHistory(deleting: item) }
    actions.openHistory = { [unowned self] in showShotHistory() }
    return actions
  }()

  /// 截图拷贝的号（第五轮体检 E3 评审 4）：出图在「正在截图」的标记外面做以后，两次截图会叠在一起——前一张编码慢、后一张
  /// 先拷好了，前一张编完再写剪贴板就把后一张顶回去。按下拷贝时取号，写剪贴板那一刻已经有更新的号就不写（历史照记）
  var copies = 0
}
