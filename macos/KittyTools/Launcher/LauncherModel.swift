// 启动器状态与操作：查询 → 结果。空查询先列「收藏」（⌘D 加，按加入顺序、⌥⌘↑↓ 调），再用「常用」（全局使用分）补足到
// 8 行（体检 A22 D13；设置 › 启动器可以不列常用，issue #2）。结果顺序：这个查询选过的本地结果（第四轮体检 E8）、直达网址 / 路径、计算结果（含单位换算、
// 进制，体检 D11；汇率换算 2026-11-04，汇率表要联网取，取到了只换那一行）、关键词搜索，然后 App 目录
// （含系统设置面板，体检 D9）+ 内置动作 + 快捷链接 / 搜索提示 + 书签 + 用过的网址 / 文件按匹配分排序（同分系统命令最后，
// 体检 B36），再是浏览历史（各家开了「也搜浏览历史」才有，排在书签后、不和书签 / 用过的重复，最多 5 行，体检 D8），网页搜索兜底；
// 「cb 关键词」只有一行，↩ 收起启动器、呼出剪贴板面板并把关键词填进它的搜索框（N9；单输 cb 时它排第一、后面照常接本地结果）；
// 「fy 文本」只有一行，↩ 收起启动器、翻译浮窗直接翻译（体检 D10）；「ip」排在最前列本机和外网地址（IPAddresses，
// 外网的异步到，到了只换那几行），↩ 粘贴、⌘↩ 只复制；「open / find 词」、空格开头搜文件（FileSearch，
// 结果异步到，先留着上一次的结果，后面仍接整句匹配到的 App）。
// 系统命令（SystemCommands，对标 Alfred）：锁定屏幕、清倒废纸篓这类固定命令一行一个，按中文名 / 拼音 / Alfred 关键词
// 搜到；「quit / hide / forcequit / eject 空格」列正在运行的 App / 可推出的宗卷，「kill 空格」列后台进程（异步，
// 体检 D12：↩ 结束、⌘↩ 强制结束），「port 空格」是同一份进程的端口视图（一个在监听的端口一行；程序坞里的 App 也列，
// 它们 ↩ 走正常退出，rowVerb）；清倒废纸篓、全部退出、强制退出 / 强制结束不可撤销，第一下只上膛（选中行的副标题
// 换成确认提示），同一个键再按一次才执行（SystemControl，面板先收起）。
// 键盘（对标 Alfred / Raycast）：↑↓ 循环、↩ 执行（计算结果是粘贴，find 的文件是在访达中显示）、⌘↩ 在访达中显示
// （计算结果只复制，find 的文件是打开，网址用第二个浏览器打开）、⌥↩ 在访达里搜索、⌃↩ 网页搜索（按住修饰键时选中行的
// 副标题换成替代动作）、Tab 补全、⌘C 复制路径 / 网址、⇧⌘C 网址复制为 Markdown 链接、⌘D 收藏、⌘Y 快速查看文件、
// ⌘1–9 执行看得见的第 N 项（shortcutBase）、「常用」里 ⌘⌫ 移除一项（⌘Z 撤销，体检 B38）、Esc 先关预览 / 动作菜单再清空再关闭；
// ⌘K / →（光标在末尾时）动作菜单（N8，共用 ActionMenu）：列出选中项的全部动作连同键位，开着时搜索框用来过滤动作，
// ↑↓ ↩ 选择执行、Esc 关掉，菜单里标着的其余键位（⇥ ⌥↩ ⌃↩ ⌘ 键）照常可用、先关菜单。行上右键是同一份动作（体检 C8）。
// 单击选中、双击执行（和剪贴板面板一致）。打开 App / 文件 / 网址 / 搜索页：↩ 当下就收起，系统在后台打开，不等 App
// 启动完（2026-09-27 用户要求）；打开成功才记使用，打不开用刘海岛说。其余先执行、成功才收起（失败在面板里显示，§11 #33）。
// 启动器没有固定：点外面就收起（N8）；没执行就收起的，90 秒内再呼出保留查询和选中项（体检 A27）；文件结果（文件搜索、
// 路径模式里的行）执行过也留着（2026-11-24 拍板 1A 2B：同一次搜索常要连开几个）。
// 脚本命令（2026-11-07，ScriptCommand / ScriptLibrary / ScriptRunner）：一个脚本一行，和系统命令一样搜、排、记使用、收藏，
// 别名一字不差时排第一；↩ 跑它（写了 confirm 的先上膛），从网上下载的第一次先在面板里给用户看一眼全文（review，↩ 运行、
// Esc 回去）；超过 1 秒没跑完岛上出「正在运行」带「停止」；输出按它的 mode：岛上一行 / 粘贴 / 复制 / 不显示 /
// 全文（面板里原地换成输出那一页：↩ 粘贴、⌘C 复制、Esc 返回）/ 列表（每行一条结果，停手 0.15 s 重跑、撤掉上一次）。
// 要参数的（声明了参数、或者是列表的）：「别名 空格 文字」/「标题 空格 文字」把后面的字交给它，只打了关键词时 ↩ / Tab 先补「关键词 空格」。
// 这个文件留状态和存储属性；命令的快捷键、搜索、执行、脚本命令、收藏、快速查看、键盘、动作菜单拆在同目录的 LauncherModel+*.swift（第五轮体检 H1）。

import AppKit
import Carbon.HIToolbox
import OSLog
import Observation
import SwiftUI
import UniformTypeIdentifiers

@Observable final class LauncherModel {
  var query = "" {
    didSet {
      typedAt = (ProcessInfo.processInfo.systemUptime, typedAt.last)
      forgotten = nil  // 打字就不能再撤销移除
      // 打了字就不是「回到原来的搜索」了：新结果照常换上、选中照常从第一行起
      lastRun = nil
      resumingFiles = false
      resumedSelection = nil
      review = nil
      if output != nil { closeOutput() }
      search()
    }
  }
  /// 最近两次改 query 的时刻（开机以来的秒数）
  @ObservationIgnored private var typedAt: (last: TimeInterval, previous: TimeInterval) = (0, 0)
  /// 两下之间不到这么久算连着打字
  static let typingGap: TimeInterval = 0.2
  /// 正在连着打字（这一下离上一下、离现在都不到 typingGap）：面板高度直接到位、不做动画（Whisker §1「每次按键后的结果刷新
  /// 0 ms」；2026-11-23 美化与提速 P4 量的：连着打字时每个字都起一段窗口帧动画，动画的每一帧 SwiftUI 都重排一遍）。
  /// 停下来之后的改动（后到的菜单项、外网地址、汇率）和停了一会儿再打的第一个字照常动画
  var isTyping: Bool { Self.isTyping(typedAt, now: ProcessInfo.processInfo.systemUptime) }

  /// isTyping 的纯函数（单测）
  static func isTyping(_ typed: (last: TimeInterval, previous: TimeInterval), now: TimeInterval)
    -> Bool
  {
    typed.last - typed.previous < typingGap && now - typed.last < typingGap
  }
  var results: [LauncherItem] = [] {
    // 结果换了（打字、重查、删掉一行）：看不见的勾去掉（多选，拍板 3A；同剪贴板「操作对象只算看得见的」）
    didSet {
      if !checked.isEmpty {
        let shown = Set(results.lazy.map(\.id))
        checked.removeAll { !shown.contains($0) }
      }
    }
  }
  /// 多选勾着的行（id，按勾的先后；只有文件、文件夹的行能勾，LauncherModel+MultiSelect）。空 = 不在多选
  var checked: [String] = []
  /// ⇧↑↓、⇧ 点按扩选的起点
  @ObservationIgnored var checkAnchor: String?
  var selection = 0
  /// 列表滚到哪了：可见部分的顶在内容里的位置（视图滚动时写进来；列表被空状态换掉时回 0）。只有按住 ⌘ 时界面才读它
  var listTop: CGFloat = 0
  /// ⌘1 对的是第几行：列表里第一条看得见的行。按住 ⌘ 显示的数字和 ⌘1–9 执行的行都从它起编（第五轮体检 U9：往下翻过之后
  /// ⌘1 对的是滚出去看不见的第一行）。每次现算，结果换了也对得上
  var shortcutBase: Int { LauncherPanelView.firstVisibleRow(top: listTop, in: self) }
  /// 选中高亮这次怎么移动（Whisker §4）：键盘单按 snap，连发和结果刷新不动画，鼠标点选 glide
  var selectionMotion = Style.Motion.instant
  /// 执行失败的提示（面板不收起）
  var error: String?
  /// 按住的修饰键：选中行的副标题换成它对应的替代动作（面板的 onModifierKeysChanged 推过来）
  var alternate = Alternate.none
  /// 文件搜索模式（open / find / 空格开头）；nil = 普通搜索
  var fileRequest: FileSearch.Request?
  /// 系统命令的带对象模式（quit / hide / forcequit / eject / kill / port 空格）；nil = 不在这个模式
  var commandRequest: SystemCommands.Request?
  /// 上膛的那一行：不可撤销的命令第一下按下后，等同一个键再按一次（打字、移动选中、Esc、收起都撤掉）
  var armed: Armed?
  /// 没有结果时显示的话。和结果一起换：文件搜索还在查时留着上一句，不闪「没有匹配」
  var emptyText = String(localized: "没有匹配的结果")
  /// 空查询时前几行是收藏（其余是常用）
  var favoriteCount = 0
  /// 底栏左边的就地提示（换掉种类色块和种类名）：收藏、移除常用（带撤销「已从常用中移除 · 撤销 ⌘Z」）
  var notice: BarNotice?
  /// ⌘Y 快速查看开着（体检 C7）：预览浮层跟着选中项走
  var isQuickLooking = false
  /// 预览浮层上画不画预览：打开前设上，浮层真正收走（缩回动画放完）才清掉。收走的浮层里别再画：SwiftUI 在看不见的
  /// 窗口里照样跟着选中项重建 Quick Look 视图（大 PDF、视频也会生成预览），同剪贴板 ⌘Y
  var showsQuickLookContent = false
  /// ⌘K 动作菜单开着：搜索框改成过滤动作
  var showsActions = false {
    didSet {
      actionQuery = ""
      actionSelection = 0
    }
  }
  var actionQuery = "" { didSet { actionSelection = 0 } }
  var actionSelection = 0
  /// 正在看的脚本（拍板 B5：从网上下载的，第一次跑之前先给用户看一眼全文）：列表换成脚本全文，↩ 运行、Esc 回去
  var review: ScriptReview?

  struct ScriptReview: Equatable {
    let script: ScriptCommand
    /// 读到之前是 nil
    var reading: ScriptReading?
    /// 全文显示出来的那一刻：之后 reviewDwell 之内的 ↩ 不算（第三轮评审：照习惯连按两下 ↩ 不能直接放行）
    var shownAt: ContinuousClock.Instant?
    /// 过了 reviewDwell：底栏的「运行」这时才画成能点的（复查：那 1 秒里看着能点、点了只响提示音）
    var isSettled = false
    /// 看过之后要交给它的参数（「关键词 空格 文字」那一行按的 ↩）；nil = 普通那一行
    var arguments: [String]?

    var text: String? { reading?.text }
    /// 脚本比能显示的长（ScriptRunner.reviewLimit）：没看全，不在这里运行
    var isTruncated: Bool { reading?.isTruncated ?? false }
    /// 现在能不能放行：读到了、没有不能放行的原因（没看全、藏着字符、读不出来）
    var isRunnable: Bool { reading != nil && reading?.problem == nil }
  }

  /// 看全文 / 输出那一页的键盘滚动（第三轮评审：焦点一直在搜索框里，长脚本只能拿鼠标滚）：step ±1 一小段、±2 一屏，
  /// tick 让连按同一个方向也算变了
  struct PageScroll: Equatable {
    var step = 0
    var tick = 0
  }
  var pageScroll = PageScroll()

  /// 全文输出的脚本（B1 full）：列表换成它的输出，↩ 粘贴、⌘C 复制、⌘R 重跑、Esc 返回（还在跑时 Esc 停掉）
  var output: ScriptOutput?

  struct ScriptOutput: Equatable {
    let script: ScriptCommand
    /// 跑它时给的参数：⌘R 照这些再跑一次（第三轮 A3）
    var arguments: [String] = []
    /// 粘贴、复制的：去掉颜色码的纯文字
    var text = ""
    /// 显示的：认颜色（ScriptTerminal，第三轮 A2）。跑完是开头最多 outputDisplayLimit 字，跑着是最后 liveDisplayLimit 字
    var styled = AttributedString()
    /// 跑完的那一页只显示了开头一截（正文上面写一句）
    var isCut = false
    var isRunning = true
    /// 开始跑的时刻：跑着时副标题写「已 12 秒」（第三轮 A1）
    var startedAt = Date.now
    /// 出错 / 超时 / 停了：那一句（红字）
    var failure: String?

    /// 跑完：换上脚本写出来的（没收拾过的）输出——粘贴、复制的纯文字，显示开头一截（先按回车收好再数字数，数的是看得见的行）
    mutating func show(_ raw: String) {
      text = ScriptCommand.payload(raw)
      let lines = ScriptCommand.carriageReturns(raw)
      let head = lines.prefix(LauncherModel.outputDisplayLimit)
      isCut = head.endIndex != lines.endIndex
      styled = ScriptTerminal.styled(Self.trimmed(head))
    }

    /// 跑着（一秒四次）：只排最后一截，从一行的开头起（第 1 批评审：每次把 1 MB 全收拾一遍、排 10 万字，主线程跟不上）；
    /// 纯文字跑完再算
    mutating func showLive(_ raw: String) {
      var tail = raw.suffix(LauncherModel.liveDisplayLimit)
      if tail.startIndex != raw.startIndex, let newline = tail.firstIndex(where: \.isNewline) {
        tail = tail[tail.index(after: newline)...]
      }
      styled = ScriptTerminal.styled(Self.trimmed(tail))
    }

    private static func trimmed(_ text: Substring) -> String {
      var text = text
      while text.last?.isNewline == true { text = text.dropLast() }
      return String(text)
    }
  }

  /// 全文输出那一页跑完最多显示这么多字（再多 Text 排不动、卡主线程）；↩ 粘贴、⌘C 复制的照旧是全部
  static let outputDisplayLimit = 100_000
  /// 跑着时只显示最后这么多字（一秒排四次）
  static let liveDisplayLimit = 20_000

  enum Alternate {
    case none, command, option, control
  }

  struct Armed: Equatable {
    let id: String
    /// 是 ⌘↩ 上的膛（quit / hide 里的强制退出），要再按 ⌘↩
    let commandKey: Bool
    /// 选中行副标题换成的确认提示
    let text: String
  }

  /// 列表里的一个分组标题：排在第 row 行前面
  struct Group: Equatable {
    let row: Int
    let title: String
  }

  @ObservationIgnored let usage: LauncherUsage
  @ObservationIgnored var apps: [LauncherItem] = [] {
    didSet { appAliasCache = nil }
  }
  /// 单测 / 截图自检不读真实偏好；搜索时检查原文，改名、清空、导入或同步后下次搜索就生效。
  @ObservationIgnored var appAliasesText: () -> String = {
    UserDefaults.standard.string(forKey: Prefs.launcherAppAliases) ?? ""
  }
  @ObservationIgnored private var appAliasCache:
    (text: String, aliases: AppAliases, items: [LauncherItem])?

  var searchableApps: (aliases: AppAliases, items: [LauncherItem]) {
    let text = appAliasesText()
    if let cache = appAliasCache, cache.text == text { return (cache.aliases, cache.items) }
    let aliases = AppAliases(text: text)
    let items = apps.map { aliases.applying(to: $0) }
    appAliasCache = (text, aliases, items)
    return (aliases, items)
  }
  @ObservationIgnored var appsScannedAt: Date?
  /// 上次扫描时各应用程序目录的修改时间：呼出时变了就重扫（体检 B31）
  @ObservationIgnored var appsSignature: [Date?] = []
  /// 正在后台扫 App 目录（P3）：扫完换上；扫的时候再要不重复起
  @ObservationIgnored var scanTask: Task<Void, Never>?
  /// 面板开着（prepareForShow 到 didHide）：后台扫完时开着才按新目录重搜
  @ObservationIgnored var isShown = false
  /// 单测 / 截图自检：传入固定的 App 列表，不扫本机、不查 Spotlight、不读书签（文件结果由 showFiles 直接给）
  @ObservationIgnored let isFixture: Bool
  @ObservationIgnored let files = FileSearch()
  /// 这次文件搜索已经显示过一批：后面的批次到了保持选中项，不跳回第一行
  @ObservationIgnored var shownFileRequest: FileSearch.Request?
  // 以下由 AppDelegate 接上
  @ObservationIgnored var hidePanel: () -> Void = {}
  /// 第 8 批：呼出启动器前焦点在自家哪个能编辑的文本视图里（便签正文、标题框的字段编辑器）。有就直接粘进去，
  /// 不发合成按键、不要辅助功能授权；nil = 照旧 Paster.pasteToFrontmost
  @ObservationIgnored var pasteTargetView: () -> NSTextView? = { nil }
  @ObservationIgnored var runAction: (String) -> Void = { _ in }
  /// 内置动作此刻的状态（复制即译开没开、有没有钉图、能不能检查更新）
  @ObservationIgnored var actionState: () -> LauncherItem.ActionState = { .init() }
  /// 空查询在收藏后面列不列「常用」（设置 › 启动器，issue #2）；单测 / 截图自检固定是 true，不读宿主 App 的偏好
  @ObservationIgnored var showsFrequent: () -> Bool = {
    UserDefaults.standard.bool(forKey: Prefs.launcherShowsFrequent)
  }
  /// ⌘,：直达 设置 › 启动器（启动器已收起）。搜「设置」那个内置动作仍走 runAction，打开上次看的页
  @ObservationIgnored var openSettings: () -> Void = {}
  /// 面板按内容伸缩高度（顶边不动）
  @ObservationIgnored var resize: (CGFloat) -> Void = { _ in }
  /// cb 那一行 ↩（启动器已收起）：呼出剪贴板面板，把关键词填进它的搜索框
  @ObservationIgnored var openClipboard: (String) -> Void = { _ in }
  /// fy 那一行 ↩（启动器已收起）：翻译浮窗直接翻译这段
  @ObservationIgnored var translate: (String) -> Void = { _ in }
  /// 「提醒 …」：现在的提醒列表、建一条、打开 / 暂停一条、到设置里编辑一条（AppDelegate 给；提醒关着时列表是空的）
  @ObservationIgnored var reminders: () -> [Reminder] = { [] }
  @ObservationIgnored var createReminder: (Reminder) -> Void = { _ in }
  @ObservationIgnored var toggleReminder: (String) -> Void = { _ in }
  @ObservationIgnored var openReminder: (String) -> Void = { _ in }
  /// 「添加…插件」（2026-11-12 拍板 A4）：打开 设置 › 全部插件 里它的介绍页（2026-11-17 插件页改版 G1；原来是 设置 › 通用 › 功能 那张卡）（AppDelegate 给）
  @ObservationIgnored var offerPlugin: (Feature) -> Void = { _ in }
  /// 「awake …」（保持唤醒插件 B2）：手动开着时还剩多久（没开 nil）、开一段（结束时刻，nil = 无限期；行上的说法）、停掉
  @ObservationIgnored var keepAwakeStatus: () -> String? = { nil }
  @ObservationIgnored var keepAwakeBegin: (Date?, String) -> Void = { _, _ in }
  @ObservationIgnored var keepAwakeEnd: () -> Void = {}
  /// 搜菜单项的那个 App（第五轮体检 N3，MenuSearch）：呼出时的前台 App；App 快捷键插件没添加、没辅助功能授权、前台是本 App
  /// 时 nil（AppDelegate 给；单测、截图自检是 nil，不读真的菜单）
  @ObservationIgnored var menuApp: () -> NSRunningApplication? = { nil }
  /// 读那个 App 的菜单、建好行（pid、App 名、包路径；主线程外、整次 1 秒；单测、截图自检换成假的）
  @ObservationIgnored var readMenu: (pid_t, String, String?) async -> [LauncherItem] = {
    await MenuSearch.read(pid: $0, appName: $1, appPath: $2)
  }
  /// 菜单项的 ↩（启动器已收起）：切回那个 App、按位置找回去按它（AppDelegate 接 AppShortcuts.press）
  @ObservationIgnored var pressMenu: (MenuSearch.Entry) -> Void = { _ in }
  /// 这次呼出时的前台 App（prepareForShow 记下，收起时清掉）
  @ObservationIgnored var menuTarget: NSRunningApplication?
  /// 读到的菜单（哪个 App、什么时候读的、建好的行；收起后留着，staleAfter 以内再呼出同一个 App 不重读）和正在读的那一次
  @ObservationIgnored var menuRows: (pid: pid_t, readAt: Date, items: [LauncherItem])?
  @ObservationIgnored var menuTask: Task<Void, Never>?
  /// 收起后过 MenuSearch.staleAfter 丢掉读到的菜单（再呼出时取消）
  @ObservationIgnored var menuExpiry: Task<Void, Never>?
  /// 全局热键动作当前生效的组合（选中的内置动作右侧显示键帽）；AppDelegate 接 HotKeyCenter 注册上的那份
  @ObservationIgnored var boundHotKey: (HotKeyAction) -> HotKey? = { $0.hotKey }
  /// 文件搜索的授权提示 ↩：没问过就逐个弹系统框，问过就打开系统设置
  @ObservationIgnored var requestFolderAccess: () -> Void = {}
  /// 刘海岛（单测里是 nil）：只复制不粘贴时面板同时收起，结果看不见，用它说
  @ObservationIgnored var island: Island?
  /// 脚本命令（ScriptLibrary 读到的；启动器的「脚本命令」关着时是空的）
  @ObservationIgnored var scripts: () -> [ScriptCommand] = { [] }
  /// 设置 › 启动器「脚本命令」开着：「新建脚本」「复制脚本写法说明」两条内置动作跟着它
  @ObservationIgnored var scriptsOn: () -> Bool = { true }
  /// 跑一条脚本（单测换成假的）；第三个是边跑边交输出的（全文输出，别的模式是 nil）
  @ObservationIgnored var runScript:
    @MainActor (ScriptCommand, [String], ((String) -> Void)?) async -> ScriptRunner.Outcome = {
      await ScriptRunner.run($0, arguments: $1, live: $2)
    }
  /// 读脚本全文（review 那一页；单测换成假的）
  @ObservationIgnored var readScript: @MainActor (ScriptCommand) async -> ScriptReading = {
    await ScriptRunner.read($0.path)
  }
  /// 「命令」表里改过的别名和关掉的（拍板 C3 C4）；单测 / 截图自检是空的，不读宿主 App 的偏好
  @ObservationIgnored var commandSettings: () -> LauncherCommands.Settings = {
    LauncherModel.savedCommandSettings()
  }
  @ObservationIgnored private static var settingsCache:
    (aliases: String, off: String, settings: LauncherCommands.Settings)?

  /// 偏好里的那份（按原文缓存：每敲一个字都要读）
  static func savedCommandSettings() -> LauncherCommands.Settings {
    let defaults = UserDefaults.standard
    let aliases = defaults.string(forKey: Prefs.launcherCommandAliases) ?? ""
    let off = defaults.string(forKey: Prefs.launcherCommandsOff) ?? ""
    if let cached = settingsCache, cached.aliases == aliases, cached.off == off {
      return cached.settings
    }
    let settings = LauncherCommands.Settings(aliasesText: aliases, offText: off)
    settingsCache = (aliases, off, settings)
    return settings
  }

  /// 开着的脚本（「命令」表里关掉的不算）
  var activeScripts: [ScriptCommand] {
    let settings = commandSettings()
    return scripts().filter { settings.isOn(LauncherCommands.scriptID($0)) }
  }

  /// 系统命令（锁定屏幕…）：「命令」表里关掉的不列，改了别名的把原来的英文关键词换成别名（副标题也写别名）
  var systemItems: [LauncherItem] {
    systemCommandItems + (shortcutsOn ? shortcutItems : [])
  }

  /// 搜索、运行快捷指令（X10）开着没有（单测、截图自检是关的：不起 shortcuts 进程）
  private var shortcutsOn: Bool {
    !isFixture && UserDefaults.standard.bool(forKey: Prefs.launcherShortcuts)
  }
  /// 缓存的快捷指令名字（呼出时过期就在后台重列，SystemShortcuts）
  @ObservationIgnored private(set) var shortcutNames: [String] = []
  /// 建好的那几行（拼音转换不便宜，别每打一个字都重建；名字变了才换）
  @ObservationIgnored private var shortcutItems: [LauncherItem] = []
  @ObservationIgnored private var shortcutsListedAt: Date?
  @ObservationIgnored private var shortcutsTask: Task<Void, Never>?

  /// 呼出时：快捷指令的列表过期了就在后台重列（不等它；列好了开着的面板按新的重搜）
  func refreshShortcuts(now: Date) {
    guard shortcutsOn, shortcutsTask == nil,
      shortcutsListedAt.map({ now.timeIntervalSince($0) > SystemShortcuts.staleAfter }) ?? true
    else { return }
    shortcutsTask = Task { [weak self] in
      let names = await SystemShortcuts.list()
      guard let self else { return }
      shortcutsTask = nil
      shortcutsListedAt = .now
      guard let names, names != shortcutNames else { return }
      shortcutNames = names
      shortcutItems = names.map(SystemShortcuts.item)
      if isShown, !query.isEmpty { search() }
    }
  }

  private var systemCommandItems: [LauncherItem] {
    let settings = commandSettings()
    guard !settings.aliases.isEmpty || !settings.off.isEmpty else { return SystemCommands.items }
    return SystemCommands.items.compactMap { item in
      let id = LauncherCommands.systemID(item.target)
      guard settings.isOn(id) else { return nil }
      let alias = settings.alias(id, default: item.target)
      guard alias != item.target else { return item }
      var item = item
      item.names = item.names.filter { $0 != item.target } + [alias].compactMap { $0 }
      item.subtitle = alias ?? ""
      return item
    }
  }
  /// 列表脚本打字时重跑（停手 listDelay 再跑；新的一跑就撤掉上一次）
  @ObservationIgnored var listTask: Task<Void, Never>?
  /// 只跑一次、自己过滤的列表脚本（第三轮 B3，@kitty.filter）：这次呼出里跑出来的结果（按脚本路径；failed = 没跑成，那一行不过滤），
  /// 收起时清掉；正在跑的那一次不跟着打字撤掉（打字只是过滤）
  @ObservationIgnored var filterRows: [String: (rows: [LauncherItem], failed: Bool)] = [:]
  @ObservationIgnored var filterTask: (path: String, task: Task<Void, Never>)?
  /// 正在跑的那条普通列表脚本（listTask 的）
  @ObservationIgnored var listPath: String?

  /// 这一行是不是还在等结果的那条列表脚本的（看得见的是上一次的、或者「正在运行…」）。按脚本分：一条在跑不挡别的脚本的行
  /// （第 2 批评审）
  func isPending(_ item: LauncherItem) -> Bool {
    guard item.kind == .scriptResult else { return false }
    return [listTask == nil ? nil : listPath, filterTask?.path].contains {
      $0.map { item.target.hasPrefix($0 + "\n") } ?? false
    }
  }
  /// 列表结果到之前按了 ↩：到了就执行第一条（打字、收起就作罢）
  @ObservationIgnored var runsWhenListed = false
  static let listDelay = Duration.milliseconds(150)
  /// 列表脚本每跑一次最多等这么久（打字时一直在重跑，慢的不能挂着）
  static let listTimeout = 10
  /// 看过、确认要跑的下载来的脚本：去掉隔离标记、重读脚本库
  @ObservationIgnored var approveScript: @MainActor (ScriptCommand) async -> Void = { _ in }
  /// 看全文那一页显示出来之后多久的 ↩ 才算放行（单测设成 0）
  @ObservationIgnored var reviewDwell = Duration.seconds(1)
  /// 脚本行的 ⌘K（第二轮 D1）：编辑、到设置里改别名（命令表那一行的 id）、开关一条命令、把自带的复制一份到我的脚本。
  /// AppDelegate 接上；单测 / 截图自检是空的——不开编辑器、不写偏好、不写文件
  @ObservationIgnored var editScript: (ScriptCommand) -> Void = { _ in }
  @ObservationIgnored var openCommandSettings: (_ id: String) -> Void = { _ in }
  @ObservationIgnored var setCommandOn: (_ id: String, _ isOn: Bool) -> Void = { _, _ in }
  @ObservationIgnored var copyBundledScript: (ScriptCommand) -> Void = { _ in }
  /// 岛上「看输出」（第二轮 D3）：把启动器叫出来（已经开着、在前就不动）；false = 没叫出来（启动器功能关着）
  @ObservationIgnored var showPanel: () -> Bool = { true }
  /// 最近一次要「看输出」的全部输出（出错的、收起后接着跑完的全文脚本；只留这一次，不记日志）；id 给岛上「看输出」认
  @ObservationIgnored var lastOutput: (id: UUID, page: ScriptOutput)?
  /// 全文脚本还在跑时启动器收起了：接着跑，跑完在岛上说（第三轮评审：原来悄悄停掉、输出也丢了）
  @ObservationIgnored var detachedOutputs: Set<String> = []
  /// 这次运行里确认过的（去不掉隔离标记的文件夹：只读的、别人的）
  @ObservationIgnored var approvedScripts: Set<String> = []
  /// 正在跑的脚本（按路径）：「停止」按钮取消它；同一个还在跑时再按 ↩ 不重复起
  @ObservationIgnored var runningScripts: [String: Task<Void, Never>] = [:]
  /// 脚本行的缓存：每敲一个字都要列一遍，拼音转写不便宜（同内置动作）
  @ObservationIgnored var scriptCache:
    (scripts: [ScriptCommand], settings: LauncherCommands.Settings, items: [LauncherItem])?
  /// 文件结果最后一行的授权提示：每次呼出后第一次进文件搜索时算一次（要读受保护目录，问过之前不读）。
  /// ponytail: 授权被重置（tccutil reset、撤掉完全磁盘访问）后，第一次进文件搜索时系统会弹框
  @ObservationIgnored var folderHint: LauncherItem?
  /// 路径模式（以 / 或 ~/ 开头，PathBrowser）：这次的输入怎么拆；nil = 不在路径模式
  @ObservationIgnored var pathRequest: PathBrowser.Request?
  /// 读过的目录（收起时清掉）、正在读的（同一个目录同时只读一次）、读得慢时过 0.15 秒出「正在读取…」
  @ObservationIgnored var pathListings: [String: PathBrowser.Listing] = [:]
  @ObservationIgnored var pathReads: [String: Task<Void, Never>] = [:]
  @ObservationIgnored var pathWait: Task<Void, Never>?
  /// 要的目录还没读到、看得见的还是上一次的结果：↩、⌘1–9 只响提示音（不然会打开上一次的某一行）
  @ObservationIgnored var pathPending = false
  /// 收藏、常用里的文件和应用程序目录以外的 App 不在了的（呼出时在主线程外查，PathBrowser.missing）；没查完时照常列
  @ObservationIgnored var missingPaths: Set<String> = []
  @ObservationIgnored var presenceTask: Task<Void, Never>?
  @ObservationIgnored var checksFolderAccess = false
  /// 用户按过 ↑↓ / 点选过：文件结果后续批次到了才按 id 保持选中项，否则回到第一行（最佳匹配）
  @ObservationIgnored var userMovedSelection = false
  /// 执行系统命令（启动器已收起）：AppDelegate 接 SystemControl；单测、截图自检里什么都不做，不会真锁屏、关机
  @ObservationIgnored var perform: (SystemControl.Action) -> Void = { _ in }
  /// 带对象模式列哪些（正在运行的 App / 可推出的宗卷）；单测、截图自检换成固定的
  @ObservationIgnored var commandTargets: @MainActor (SystemCommands.Verb) -> [LauncherItem] =
    SystemCommands.targets(for:)
  /// 这次带对象模式列出来的：进模式时列一次，之后打字只过滤，列表不跟着重排
  @ObservationIgnored var commandItems: (verb: SystemCommands.Verb, items: [LauncherItem])?
  /// kill / port 空格列哪些进程（ps、lsof 在进程外跑，异步到）；单测、截图自检换成固定的，不跑命令
  @ObservationIgnored var processTargets: (SystemCommands.Verb) async -> [LauncherItem] = {
    await $0 == .port ? Processes.portTargets() : Processes.targets()
  }
  /// 正在列的那一次，记着是给哪个关键词列的（kill 改成 port 时上一次的不要了）
  @ObservationIgnored var processTask: (verb: SystemCommands.Verb, task: Task<Void, Never>)?
  /// 浏览历史的行（开着「也搜浏览历史」的各家合起来；开关一关 refresh 就扔掉）；单测、截图自检换成固定的
  @ObservationIgnored var historyItems: () -> [LauncherItem] = { BrowserHistory.shared.items }
  /// 浏览器书签的行（开着书签开关、装着的各家合起来，按文件修改时间缓存）；单测、截图自检换成固定的
  @ObservationIgnored var bookmarkItems: () -> [LauncherItem] = { Bookmarks.items() }
  /// 呼出时读 / 重读浏览历史和 Firefox 书签（进程外，读完才返回；返回换没换上新的）；单测、截图自检里什么都不做
  @ObservationIgnored var refreshHistory: () async -> Bool = {
    await BrowserHistory.shared.refresh()
  }
  @ObservationIgnored var historyTask: Task<Void, Never>?
  /// 网页搜索与快捷链接的列表（偏好里的）；单测、截图自检用预置的
  @ObservationIgnored var engines: () -> [SearchEngine] = { WebSearch.engines }
  /// 默认浏览器以外能开网页的 App（「用 X 打开」、⌘↩）；单测、截图自检换成固定的
  @ObservationIgnored var browsers: () -> [URL] = { LauncherModel.otherBrowsers() }
  /// 能打开这种类型文件的 App（默认的排第一，最多 5 个）；单测、截图自检换成固定的
  @ObservationIgnored var applications: (UTType) -> [(url: URL, isDefault: Bool)] = {
    LauncherModel.applications(toOpen: $0)
  }
  /// 移到废纸篓（能从废纸篓放回，不二次确认），给出它在废纸篓里的位置（岛上的「撤销」挪回来用）；单测里换成记一笔，不真删
  @ObservationIgnored var recycle: (URL) async throws -> URL? = {
    // 只移一样：按原网址查不到（文件夹的网址补了结尾的「/」这类）就取唯一那一项
    let moved = try await NSWorkspace.shared.recycle([$0])
    return moved[$0] ?? moved.values.first
  }
  /// 「fy 单词」副标题的释义（系统词典第一条）；单测、截图自检换成固定的
  @ObservationIgnored var lookUp: (String) async -> String? = { word in
    await WordLookup.systemDictionary(word)?.groups.first?.senses.first?.definition
  }
  @ObservationIgnored var definitionTask: Task<Void, Never>?
  /// 「ip」的本机地址（这次呼出里第一次输 ip 时读一次）；单测、截图自检换成固定的
  @ObservationIgnored var localAddresses: () -> [LauncherItem] = { IPAddresses.localItems() }
  /// 「ip」的外网地址：问一家查询服务；单测、截图自检换成固定的，不联网
  @ObservationIgnored var publicAddress: (IPAddresses.Service) async -> String? = {
    await IPAddresses.lookUp($0)
  }
  /// 这次呼出里 ip 的结果：本机那几行、两家查询服务各自查到没有、还在查的（收起时全清）
  @ObservationIgnored var ipLocal: [LauncherItem]?
  @ObservationIgnored var ipLookups: [IPAddresses.Service: IPAddresses.Lookup] = [:]
  @ObservationIgnored var ipTasks: [IPAddresses.Service: Task<Void, Never>] = [:]
  /// 计算器汇率换算的汇率表：取一份新的；单测、截图自检换成固定的，不联网
  @ObservationIgnored var fetchRates: () async -> ExchangeRates.Table? = {
    await ExchangeRates.fetch()
  }
  /// 手上的那份（正式运行时启动就从偏好读，取到新的写回去；单测、截图自检里不读不写偏好）
  @ObservationIgnored var rates: ExchangeRates.Table?
  @ObservationIgnored var ratesTask: Task<Void, Never>?
  /// 上一次取没取到（占位行写「没取到」；再打字、再呼出时重取）
  @ObservationIgnored var ratesFailed = false
  /// 汇率换算用过的货币（货币候选排前面）；正式运行时启动就从偏好读，单测、截图自检里不读不写偏好
  @ObservationIgnored var recentCurrencies: [String] = []
  /// 这次呼出里查过的浏览器 / 打开方式（⌘K 每打一个字都要重算动作表，LaunchServices 别每次都问）
  @ObservationIgnored var browserCache: [URL]?
  @ObservationIgnored var applicationCache: [String: [(url: URL, isDefault: Bool)]] = [:]
  /// ⌘Y 预览浮层（AppDelegate 接）：从选中行长出来 / 缩回去（animated = false 时直接收起）
  @ObservationIgnored var openQuickLook: () -> Void = {}
  @ObservationIgnored var closeQuickLook: (_ animated: Bool) -> Void = { _ in }
  /// 选中行在窗口里的位置（视图报上来，⌘Y 从它长出来）；滚出可见区时是 nil
  @ObservationIgnored var rowFrame: (id: String, rect: CGRect)?
  /// 刚从常用里移除的一项和它的使用记录：⌘Z 放回（只留最近一次；打字、移动、Esc、收起都清掉）
  @ObservationIgnored var forgotten: (item: LauncherItem, entries: [LauncherUsage.Entry])? {
    didSet {
      if forgotten == nil, notice?.kind == .undo { notice = nil }
    }
  }
  @ObservationIgnored var noticeTask: Task<Void, Never>?
  /// 这次呼出里执行过会收起面板的动作（↩、⌘1–9、双击、⌘C 这些）：收起时不留查询
  @ObservationIgnored var executed = false
  /// 留着查询收起的时间：90 秒内再呼出保留查询和选中项
  @ObservationIgnored var keptAt: Date?
  /// 收起之前最后对着哪一行做了打开、在访达中显示、在终端中打开、复制、拷贝这类事（在做的那一处记，不看入口：
  /// ⌘K、右键、快捷键都走同一批函数）。收起时看它是不是文件 / 文件夹（拍板 1A）；打字、收起时清掉
  @ObservationIgnored var lastRun: LauncherItem?
  /// 正在回到原来的文件搜索：重查到的文件都在现在的列表里就不换（不然刚开过的那个被使用加成顶到第一行、选中跟着跳），
  /// 多出新文件才换。打字、收起时清掉
  @ObservationIgnored var resumingFiles = false
  /// 回到原来的路径模式时选中的那一行：目录重读到了、重排之后选回它。打字、移动选中、收起时清掉
  @ObservationIgnored var resumedSelection: String?
  /// 这次呼出接着上次的查询（AppDelegate 据此把搜索框的字全选：直接打字就替换）
  @ObservationIgnored var resumesQuery = false

  static let recentLimit = 8
  /// 浏览历史最多列几行：排在书签后面，别把兜底搜索、补全提示挤出可见区
  static let historyLimit = 5
  static let rescanInterval: TimeInterval = 300
  /// 留着查询收起后，多久内再呼出接着用（拍板 2B：60 → 90 秒）
  static let keepQueryInterval: TimeInterval = 90

  init(usage: LauncherUsage, apps: [LauncherItem]? = nil) {
    self.usage = usage
    isFixture = apps != nil
    if let apps {
      self.apps = apps
      appsScannedAt = .now
      engines = { WebSearch.defaults }
      processTargets = { _ in [] }
      historyItems = { [] }
      bookmarkItems = { [] }
      refreshHistory = { false }
      fetchRates = { nil }
      showsFrequent = { true }
      commandSettings = { .init() }
      appAliasesText = { "" }
    } else {
      rates = ExchangeRates.load()
      recentCurrencies = ExchangeRates.loadRecents()
    }
  }
}
