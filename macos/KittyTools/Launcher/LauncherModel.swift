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
// ⌘1–9 执行第 N 项、「常用」里 ⌘⌫ 移除一项（⌘Z 撤销，体检 B38）、Esc 先关预览 / 动作菜单再清空再关闭；
// ⌘K / →（光标在末尾时）动作菜单（N8，共用 ActionMenu）：列出选中项的全部动作连同键位，开着时搜索框用来过滤动作，
// ↑↓ ↩ 选择执行、Esc 关掉，菜单里标着的其余键位（⇥ ⌥↩ ⌃↩ ⌘ 键）照常可用、先关菜单。行上右键是同一份动作（体检 C8）。
// 单击选中、双击执行（和剪贴板面板一致）。打开 App / 文件 / 网址 / 搜索页：↩ 当下就收起，系统在后台打开，不等 App
// 启动完（2026-09-27 用户要求）；打开成功才记使用，打不开用刘海岛说。其余先执行、成功才收起（失败在面板里显示，§11 #33）。
// 启动器没有固定：点外面就收起（N8）；没执行就收起的，60 秒内再呼出保留查询和选中项（体检 A27）。
// 脚本命令（2026-11-07，ScriptCommand / ScriptLibrary / ScriptRunner）：一个脚本一行，和系统命令一样搜、排、记使用、收藏，
// 别名一字不差时排第一；↩ 跑它（写了 confirm 的先上膛），从网上下载的第一次先在面板里给用户看一眼全文（review，↩ 运行、
// Esc 回去）；超过 1 秒没跑完岛上出「正在运行」带「停止」；输出按它的 mode：岛上一行 / 粘贴 / 复制 / 不显示 /
// 全文（面板里原地换成输出那一页：↩ 粘贴、⌘C 复制、Esc 返回）/ 列表（每行一条结果，停手 0.15 s 重跑、撤掉上一次）。
// 要参数的（声明了参数、或者是列表的）：「别名 空格 文字」/「标题 空格 文字」把后面的字交给它，只打了关键词时 ↩ / Tab 先补「关键词 空格」。

import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI
import UniformTypeIdentifiers

@Observable final class LauncherModel {
  var query = "" {
    didSet {
      forgotten = nil  // 打字就不能再撤销移除
      review = nil
      if output != nil { closeOutput() }
      search()
    }
  }
  private(set) var results: [LauncherItem] = []
  var selection = 0
  /// 选中高亮这次怎么移动（Whisker §4）：键盘单按 snap，连发和结果刷新不动画，鼠标点选 glide
  private(set) var selectionMotion = Style.Motion.instant
  /// 执行失败的提示（面板不收起）
  private(set) var error: String?
  /// 按住的修饰键：选中行的副标题换成它对应的替代动作（面板的 onModifierKeysChanged 推过来）
  var alternate = Alternate.none
  /// 文件搜索模式（open / find / 空格开头）；nil = 普通搜索
  private(set) var fileRequest: FileSearch.Request?
  /// 系统命令的带对象模式（quit / hide / forcequit / eject / kill / port 空格）；nil = 不在这个模式
  private(set) var commandRequest: SystemCommands.Request?
  /// 上膛的那一行：不可撤销的命令第一下按下后，等同一个键再按一次（打字、移动选中、Esc、收起都撤掉）
  private(set) var armed: Armed?
  /// 没有结果时显示的话。和结果一起换：文件搜索还在查时留着上一句，不闪「没有匹配」
  private(set) var emptyText = "没有匹配的结果"
  /// 空查询时前几行是收藏（其余是常用）
  private(set) var favoriteCount = 0
  /// 底栏左边的就地提示（换掉种类色块和种类名）：收藏、移除常用（带撤销「已从常用中移除 · 撤销 ⌘Z」）
  private(set) var notice: BarNotice?
  /// ⌘Y 快速查看开着（体检 C7）：预览浮层跟着选中项走
  private(set) var isQuickLooking = false
  /// 预览浮层上画不画预览：打开前设上，浮层真正收走（缩回动画放完）才清掉。收走的浮层里别再画：SwiftUI 在看不见的
  /// 窗口里照样跟着选中项重建 Quick Look 视图（大 PDF、视频也会生成预览），同剪贴板 ⌘Y
  private(set) var showsQuickLookContent = false
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
  private(set) var review: ScriptReview?

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
  private(set) var pageScroll = PageScroll()

  /// 全文输出的脚本（B1 full）：列表换成它的输出，↩ 粘贴、⌘C 复制、⌘R 重跑、Esc 返回（还在跑时 Esc 停掉）
  private(set) var output: ScriptOutput?

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
  @ObservationIgnored private var apps: [LauncherItem] = []
  @ObservationIgnored private var appsScannedAt: Date?
  /// 上次扫描时各应用程序目录的修改时间：呼出时变了就重扫（体检 B31）
  @ObservationIgnored private var appsSignature: [Date?] = []
  /// 正在后台扫 App 目录（P3）：扫完换上；扫的时候再要不重复起
  @ObservationIgnored private var scanTask: Task<Void, Never>?
  /// 面板开着（prepareForShow 到 didHide）：后台扫完时开着才按新目录重搜
  @ObservationIgnored private var isShown = false
  /// 单测 / 截图自检：传入固定的 App 列表，不扫本机、不查 Spotlight、不读书签（文件结果由 showFiles 直接给）
  @ObservationIgnored private let isFixture: Bool
  @ObservationIgnored private let files = FileSearch()
  /// 这次文件搜索已经显示过一批：后面的批次到了保持选中项，不跳回第一行
  @ObservationIgnored private var shownFileRequest: FileSearch.Request?
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

  // MARK: 命令的快捷键（第三轮 D1）

  /// 最多这么多条（文件、同步来的再多也不读）
  static let maxCommandHotKeys = 200

  /// 偏好里那段 JSON → 编号 → 组合：读不出来的、过不了录制框规矩的（缺修饰键、通用编辑键）、连按两下的（命令的快捷键
  /// 只认组合）都丢掉。纯函数，配单测
  static func commandHotKeys(fromText text: String) -> [String: HotKey] {
    guard let data = text.data(using: .utf8),
      let decoded = try? JSONDecoder().decode([String: HotKey].self, from: data)
    else { return [:] }
    let usable = decoded.filter {
      !$0.key.isEmpty && $0.value.isUsable && $0.value.doubleTap == nil
    }
    return Dictionary(
      uniqueKeysWithValues: usable.sorted { $0.key < $1.key }.prefix(maxCommandHotKeys).map {
        ($0.key, $0.value)
      })
  }

  static func text(of hotKeys: [String: HotKey]) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard !hotKeys.isEmpty, let data = try? encoder.encode(hotKeys) else { return "" }
    return String(decoding: data, as: UTF8.self)
  }

  /// 一条命令给人看的名字（查重的提示里）：关键词命令、系统命令的名字，脚本的文件名
  static func commandTitle(_ id: String) -> String {
    if let builtIn = LauncherCommands.builtIns.first(where: { $0.id == id }) {
      return builtIn.title
    }
    let system = LauncherCommands.systemID("")
    if id.hasPrefix(system),
      let command = SystemCommand(rawValue: String(id.dropFirst(system.count)))
    {
      return command.title
    }
    return (id as NSString).lastPathComponent
  }

  /// 偏好里存着的（录制框、热键中心读）
  static func savedCommandHotKeys(_ defaults: UserDefaults = .standard) -> [String: HotKey] {
    commandHotKeys(fromText: defaults.string(forKey: Prefs.launcherCommandHotKeys) ?? "")
  }

  /// 改一条（nil = 清除）
  static func setCommandHotKey(
    _ hotKey: HotKey?, for id: String, _ defaults: UserDefaults = .standard
  ) {
    var all = savedCommandHotKeys(defaults)
    all[id] = hotKey
    defaults.set(text(of: all), forKey: Prefs.launcherCommandHotKeys)
  }

  /// 这条命令在这台 Mac 上有（关着的也算；录制框查重只算有的）
  func hasCommand(_ id: String) -> Bool {
    let system = LauncherCommands.systemID("")
    return LauncherCommands.builtIns.contains { $0.id == id }
      || (id.hasPrefix(system)
        && SystemCommand(rawValue: String(id.dropFirst(system.count))) != nil)
      || scripts().contains { LauncherCommands.scriptID($0) == id }
  }

  /// 这条命令此刻按快捷键能不能做事：开着；脚本在（这台 Mac 上有、脚本命令开着）；关键词命令的功能开着、还有别名（别名清空了
  /// 打不出它）；系统命令都在。热键中心只注册这些
  func canRunHotKey(_ id: String) -> Bool {
    let settings = commandSettings()
    guard settings.isOn(id) else { return false }
    if activeScripts.contains(where: { LauncherCommands.scriptID($0) == id }) { return true }
    if let builtIn = LauncherCommands.builtIns.first(where: { $0.id == id }) {
      let needs: Feature? =
        switch builtIn.keyword {
        case "cb": .clipboard
        case "fy": .translate
        case "remind": .reminders
        default: nil
        }
      return needs.map(features.contains) != false
        && settings.alias(id, default: builtIn.keyword) != nil
    }
    return id.hasPrefix(LauncherCommands.systemID(""))
      && SystemCommand(rawValue: String(id.dropFirst(LauncherCommands.systemID("").count))) != nil
  }

  /// 「命令和别名」里给一条命令设的快捷键按下了（第三轮 D1）。脚本：从网上下载没看过的、要参数的（含列表）、写了 confirm 的
  /// 打开启动器，做在启动器里按 ↩ 的那一步（先看全文 / 填好「关键词 空格」/ 选中并上膛）；全文输出的打开启动器看输出；
  /// 别的直接跑（粘贴的粘进眼前的 App）。关键词命令打开启动器、填好「关键词 空格」。系统命令要确认的同脚本，别的直接做。
  /// 使用只记总数，不记在当时搜索框里的字上
  func runHotKey(_ id: String) {
    guard canRunHotKey(id) else { return }
    let settings = commandSettings()
    if let script = activeScripts.first(where: { LauncherCommands.scriptID($0) == id }) {
      let item = LauncherItem.script(script, alias: scriptAlias(script))
      let unreviewed = script.isDownloaded && !approvedScripts.contains(script.path)
      if unreviewed || script.takesInput || script.confirmation != nil {
        return showAndExecute(item, word: scriptAlias(script) ?? script.title)
      }
      if script.mode == .full {
        guard showPanel() else { return }
        showsActions = false
        // 它自己还在跑：start 会在岛上说「还在运行」，不动眼前那一页（清空搜索框会停掉它）
        if runningScripts[script.path] == nil {
          // 别的全文脚本的那一页还在跑：交给岛（跑完说一声带「看输出」），不停掉它（第 4 批评审）
          if let current = output, current.isRunning {
            output = nil
            detach(current.script)
          }
          query = ""
        }
      }
      usage.record(item, query: "")
      runWithoutPanel { start(script, arguments: []) }
      return
    }
    if let builtIn = LauncherCommands.builtIns.first(where: { $0.id == id }),
      let alias = settings.alias(id, default: builtIn.keyword)
    {
      guard showPanel() else { return }
      showsActions = false
      query = alias + " "
      return
    }
    let keyword = String(id.dropFirst(LauncherCommands.systemID("").count))
    guard let command = SystemCommand(rawValue: keyword),
      let item = systemItems.first(where: { $0.target == keyword })
    else { return }
    if command.confirmation != nil {
      return showAndExecute(item, word: settings.alias(id, default: keyword) ?? command.title)
    }
    usage.record(item, query: "")
    runWithoutPanel {
      close()
      perform(.command(command))
    }
  }

  /// 打开启动器、打 word、选中那一行按一下 ↩（上膛、补关键词、先看全文都在 execute 里）
  private func showAndExecute(_ item: LauncherItem, word: String) {
    guard showPanel() else { return }
    // ⌘K 菜单开着时收起：不然上了膛的那句压在菜单下面，菜单第一项（执行）再按一下 ↩ 就跑了（第 4 批评审）
    showsActions = false
    query = word
    guard let index = results.firstIndex(where: { $0.id == item.id }) else { return }
    selection = index
    execute(results[index])
  }

  /// 启动器没开着时直接做：close() 会记「执行过」（下次收起清掉查询），没开着就不该记
  private func runWithoutPanel(_ work: () -> Void) {
    let wasShown = isShown
    work()
    if !wasShown { executed = false }
  }

  /// 一条脚本此刻的别名：「命令」表里改过的用改过的，没改过的是头部写的 keyword
  func scriptAlias(_ script: ScriptCommand) -> String? {
    commandSettings().alias(LauncherCommands.scriptID(script), default: script.keyword)
  }

  /// 开着的脚本（「命令」表里关掉的不算）
  private var activeScripts: [ScriptCommand] {
    let settings = commandSettings()
    return scripts().filter { settings.isOn(LauncherCommands.scriptID($0)) }
  }

  /// 系统命令（锁定屏幕…）：「命令」表里关掉的不列，改了别名的把原来的英文关键词换成别名（副标题也写别名）
  private var systemItems: [LauncherItem] {
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
  @ObservationIgnored private var listTask: Task<Void, Never>?
  /// 只跑一次、自己过滤的列表脚本（第三轮 B3，@kitty.filter）：这次呼出里跑出来的结果（按脚本路径；failed = 没跑成，那一行不过滤），
  /// 收起时清掉；正在跑的那一次不跟着打字撤掉（打字只是过滤）
  @ObservationIgnored private var filterRows: [String: (rows: [LauncherItem], failed: Bool)] = [:]
  @ObservationIgnored private var filterTask: (path: String, task: Task<Void, Never>)?
  /// 正在跑的那条普通列表脚本（listTask 的）
  @ObservationIgnored private var listPath: String?

  /// 这一行是不是还在等结果的那条列表脚本的（看得见的是上一次的、或者「正在运行…」）。按脚本分：一条在跑不挡别的脚本的行
  /// （第 2 批评审）
  private func isPending(_ item: LauncherItem) -> Bool {
    guard item.kind == .scriptResult else { return false }
    return [listTask == nil ? nil : listPath, filterTask?.path].contains {
      $0.map { item.target.hasPrefix($0 + "\n") } ?? false
    }
  }
  /// 列表结果到之前按了 ↩：到了就执行第一条（打字、收起就作罢）
  @ObservationIgnored private var runsWhenListed = false
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
  @ObservationIgnored private(set) var lastOutput: (id: UUID, page: ScriptOutput)?
  /// 全文脚本还在跑时启动器收起了：接着跑，跑完在岛上说（第三轮评审：原来悄悄停掉、输出也丢了）
  @ObservationIgnored private var detachedOutputs: Set<String> = []
  /// 这次运行里确认过的（去不掉隔离标记的文件夹：只读的、别人的）
  @ObservationIgnored private var approvedScripts: Set<String> = []
  /// 正在跑的脚本（按路径）：「停止」按钮取消它；同一个还在跑时再按 ↩ 不重复起
  @ObservationIgnored private var runningScripts: [String: Task<Void, Never>] = [:]
  /// 脚本行的缓存：每敲一个字都要列一遍，拼音转写不便宜（同内置动作）
  @ObservationIgnored private var scriptCache:
    (scripts: [ScriptCommand], settings: LauncherCommands.Settings, items: [LauncherItem])?
  /// 文件结果最后一行的授权提示：每次呼出后第一次进文件搜索时算一次（要读受保护目录，问过之前不读）。
  /// ponytail: 授权被重置（tccutil reset、撤掉完全磁盘访问）后，第一次进文件搜索时系统会弹框
  @ObservationIgnored var folderHint: LauncherItem?
  @ObservationIgnored private var checksFolderAccess = false
  /// 用户按过 ↑↓ / 点选过：文件结果后续批次到了才按 id 保持选中项，否则回到第一行（最佳匹配）
  @ObservationIgnored private var userMovedSelection = false
  /// 执行系统命令（启动器已收起）：AppDelegate 接 SystemControl；单测、截图自检里什么都不做，不会真锁屏、关机
  @ObservationIgnored var perform: (SystemControl.Action) -> Void = { _ in }
  /// 带对象模式列哪些（正在运行的 App / 可推出的宗卷）；单测、截图自检换成固定的
  @ObservationIgnored var commandTargets: @MainActor (SystemCommands.Verb) -> [LauncherItem] =
    SystemCommands.targets(for:)
  /// 这次带对象模式列出来的：进模式时列一次，之后打字只过滤，列表不跟着重排
  @ObservationIgnored private var commandItems: (verb: SystemCommands.Verb, items: [LauncherItem])?
  /// kill / port 空格列哪些进程（ps、lsof 在进程外跑，异步到）；单测、截图自检换成固定的，不跑命令
  @ObservationIgnored var processTargets: (SystemCommands.Verb) async -> [LauncherItem] = {
    await $0 == .port ? Processes.portTargets() : Processes.targets()
  }
  /// 正在列的那一次，记着是给哪个关键词列的（kill 改成 port 时上一次的不要了）
  @ObservationIgnored private var processTask: (verb: SystemCommands.Verb, task: Task<Void, Never>)?
  /// 浏览历史的行（开着「也搜浏览历史」的各家合起来；开关一关 refresh 就扔掉）；单测、截图自检换成固定的
  @ObservationIgnored var historyItems: () -> [LauncherItem] = { BrowserHistory.shared.items }
  /// 浏览器书签的行（开着书签开关、装着的各家合起来，按文件修改时间缓存）；单测、截图自检换成固定的
  @ObservationIgnored var bookmarkItems: () -> [LauncherItem] = { Bookmarks.items() }
  /// 呼出时读 / 重读浏览历史和 Firefox 书签（进程外，读完才返回；返回换没换上新的）；单测、截图自检里什么都不做
  @ObservationIgnored var refreshHistory: () async -> Bool = {
    await BrowserHistory.shared.refresh()
  }
  @ObservationIgnored private var historyTask: Task<Void, Never>?
  /// 网页搜索与快捷链接的列表（偏好里的）；单测、截图自检用预置的
  @ObservationIgnored var engines: () -> [SearchEngine] = { WebSearch.engines }
  /// 默认浏览器以外能开网页的 App（「用 X 打开」、⌘↩）；单测、截图自检换成固定的
  @ObservationIgnored var browsers: () -> [URL] = { LauncherModel.otherBrowsers() }
  /// 能打开这种类型文件的 App（默认的排第一，最多 5 个）；单测、截图自检换成固定的
  @ObservationIgnored var applications: (UTType) -> [(url: URL, isDefault: Bool)] = {
    LauncherModel.applications(toOpen: $0)
  }
  /// 移到废纸篓（能从废纸篓放回，不二次确认）；单测里换成记一笔，不真删
  @ObservationIgnored var recycle: (URL) async throws -> Void = {
    _ = try await NSWorkspace.shared.recycle([$0])
  }
  /// 「fy 单词」副标题的释义（系统词典第一条）；单测、截图自检换成固定的
  @ObservationIgnored var lookUp: (String) async -> String? = { word in
    await WordLookup.systemDictionary(word)?.groups.first?.senses.first?.definition
  }
  @ObservationIgnored private var definitionTask: Task<Void, Never>?
  /// 「ip」的本机地址（这次呼出里第一次输 ip 时读一次）；单测、截图自检换成固定的
  @ObservationIgnored var localAddresses: () -> [LauncherItem] = { IPAddresses.localItems() }
  /// 「ip」的外网地址：问一家查询服务；单测、截图自检换成固定的，不联网
  @ObservationIgnored var publicAddress: (IPAddresses.Service) async -> String? = {
    await IPAddresses.lookUp($0)
  }
  /// 这次呼出里 ip 的结果：本机那几行、两家查询服务各自查到没有、还在查的（收起时全清）
  @ObservationIgnored private var ipLocal: [LauncherItem]?
  @ObservationIgnored private var ipLookups: [IPAddresses.Service: IPAddresses.Lookup] = [:]
  @ObservationIgnored private var ipTasks: [IPAddresses.Service: Task<Void, Never>] = [:]
  /// 计算器汇率换算的汇率表：取一份新的；单测、截图自检换成固定的，不联网
  @ObservationIgnored var fetchRates: () async -> ExchangeRates.Table? = {
    await ExchangeRates.fetch()
  }
  /// 手上的那份（正式运行时启动就从偏好读，取到新的写回去；单测、截图自检里不读不写偏好）
  @ObservationIgnored var rates: ExchangeRates.Table?
  @ObservationIgnored private var ratesTask: Task<Void, Never>?
  /// 上一次取没取到（占位行写「没取到」；再打字、再呼出时重取）
  @ObservationIgnored private var ratesFailed = false
  /// 汇率换算用过的货币（货币候选排前面）；正式运行时启动就从偏好读，单测、截图自检里不读不写偏好
  @ObservationIgnored var recentCurrencies: [String] = []
  /// 这次呼出里查过的浏览器 / 打开方式（⌘K 每打一个字都要重算动作表，LaunchServices 别每次都问）
  @ObservationIgnored private var browserCache: [URL]?
  @ObservationIgnored private var applicationCache: [String: [(url: URL, isDefault: Bool)]] = [:]
  /// ⌘Y 预览浮层（AppDelegate 接）：从选中行长出来 / 缩回去（animated = false 时直接收起）
  @ObservationIgnored var openQuickLook: () -> Void = {}
  @ObservationIgnored var closeQuickLook: (_ animated: Bool) -> Void = { _ in }
  /// 选中行在窗口里的位置（视图报上来，⌘Y 从它长出来）；滚出可见区时是 nil
  @ObservationIgnored var rowFrame: (id: String, rect: CGRect)?
  /// 刚从常用里移除的一项和它的使用记录：⌘Z 放回（只留最近一次；打字、移动、Esc、收起都清掉）
  @ObservationIgnored private var forgotten: (item: LauncherItem, entries: [LauncherUsage.Entry])? {
    didSet {
      if forgotten == nil, case .undo = notice { notice = nil }
    }
  }
  @ObservationIgnored private var noticeTask: Task<Void, Never>?
  /// 这次呼出里执行过会收起面板的动作（↩、⌘1–9、双击、⌘C 这些）：收起时不留查询
  @ObservationIgnored private var executed = false
  /// 没执行就收起的时间：60 秒内再呼出保留查询和选中项
  @ObservationIgnored private var keptAt: Date?
  /// 这次呼出接着上次的查询（AppDelegate 据此把搜索框的字全选：直接打字就替换）
  @ObservationIgnored private(set) var resumesQuery = false

  static let recentLimit = 8
  /// 浏览历史最多列几行：排在书签后面，别把兜底搜索、补全提示挤出可见区
  static let historyLimit = 5
  static let rescanInterval: TimeInterval = 300
  /// 没执行就收起后，多久内再呼出保留查询
  static let keepQueryInterval: TimeInterval = 60

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
    } else {
      rates = ExchangeRates.load()
      recentCurrencies = ExchangeRates.loadRecents()
    }
  }

  /// 空查询：「收藏」+「常用」（一个空格是文件搜索，不算）
  var isShowingRecent: Bool {
    fileRequest == nil && query.trimmingCharacters(in: .whitespaces).isEmpty
  }

  /// 列表里的分组标题：空查询「收藏」「常用」，文件搜索只输了关键词时「最近打开和下载的文件」，
  /// 系统命令只输了关键词时「正在运行的 App」/「可推出的磁盘」
  var groups: [Group] {
    if isShowingRecent {
      var groups: [Group] = []
      if favoriteCount > 0 { groups.append(Group(row: 0, title: "收藏")) }
      if favoriteCount == 0 || results.count > favoriteCount {
        groups.append(Group(row: favoriteCount, title: "常用"))
      }
      return groups
    }
    if let commandRequest, commandRequest.terms.isEmpty {
      return [Group(row: 0, title: commandRequest.verb.groupTitle)]
    }
    return fileRequest?.terms.isEmpty == true ? [Group(row: 0, title: "最近打开和下载的文件")] : []
  }

  /// 第一个分组标题
  var groupTitle: String? { groups.first?.title }

  /// 内置动作（按此刻的状态）
  private var builtIns: [LauncherItem] { LauncherItem.actions(actionState()) }

  /// 脚本命令的行（按此刻的脚本库）
  private var scriptItems: [LauncherItem] {
    let scripts = activeScripts
    let settings = commandSettings()
    if let scriptCache, scriptCache.scripts == scripts, scriptCache.settings == settings {
      return scriptCache.items
    }
    let items = scripts.map { LauncherItem.script($0, alias: scriptAlias($0)) }
    scriptCache = (scripts, settings, items)
    return items
  }

  /// 脚本库重读完、换上了新的：开着、用户还没挑过选中项时按新的重搜（同后台扫完 App 目录）
  func scriptsChanged() {
    // 去掉了下载标记的不再记着：同一个位置以后又放进一个新下载的，照样先看一眼
    let downloaded = Set(scripts().filter(\.isDownloaded).map(\.path))
    approvedScripts.formIntersection(downloaded)
    if isShown, !userMovedSelection, armed == nil, review == nil, fileRequest == nil,
      commandRequest == nil
    {
      search()
    }
  }
  /// 开着的功能（Feature）：cb 那一行要剪贴板开着、fy 那一行要翻译开着
  private var features: Set<Feature> { actionState().features }

  /// 启动时、呼出时应用程序目录变了时扫 App 目录。在后台扫（约 65 ms，原来在主线程：装完 App 马上按 ⌥Space 要卡这么久，
  /// 第三轮体检 P3）：面板先用旧列表出来，扫完换上——开着、正在搜的按新目录重搜（用户还没挪过选中时）。
  /// App 路径的图标缓存跟着清掉：升级换了图标的下次按新的读（B3）
  func rescanApps() {
    guard !isFixture, scanTask == nil else { return }
    // 扫之前取：扫的时候又装了 App，下次呼出照样看得出目录变了
    let signature = AppCatalog.signature()
    scanTask = Task {
      let scanned = await AppCatalog.scanInBackground()
      scanTask = nil
      LauncherIcons.forget((apps + scanned).filter { $0.kind == .app }.map(\.target))
      apps = scanned
      appsSignature = signature
      appsScannedAt = .now
      if isShown, !userMovedSelection, armed == nil, fileRequest == nil, commandRequest == nil,
        !query.trimmingCharacters(in: .whitespaces).isEmpty
      {
        search()
      }
    }
  }

  /// 呼出前：应用程序目录变了就重扫（后台扫，扫完刚装的 App 就搜得到）；60 秒内没执行就收起的，接着上次的查询和选中项
  func prepareForShow(now: Date = .now) {
    isShown = true
    if !isFixture,
      Self.needsRescan(
        scannedAt: appsScannedAt, scanned: appsSignature, now: AppCatalog.signature())
    {
      rescanApps()
    }
    browserCache = nil
    applicationCache = [:]
    checksFolderAccess = !isFixture
    let keeps = keptAt.map { now.timeIntervalSince($0) <= Self.keepQueryInterval } ?? false
    keptAt = nil
    let kept = keeps ? selectedItem?.id : nil
    if keeps || query.isEmpty { search() } else { query = "" }
    if let kept { reselect(kept) }
    resumesQuery = keeps && !query.isEmpty
    loadHistory()
  }

  /// 浏览历史、Firefox 书签该重读就在进程外读（开关关着时清掉）；换上了新读的、正在搜、用户还没挑过选中项，就按新的历史重搜一次
  private func loadHistory() {
    guard historyTask == nil else { return }
    historyTask = Task {
      let reloaded = await refreshHistory()
      historyTask = nil
      if reloaded, !userMovedSelection, armed == nil, fileRequest == nil, commandRequest == nil,
        LauncherMatch.isLongEnough(query)
      {
        search()
      }
    }
  }

  /// 呼出前要不要重扫 App 目录：没扫过，或者各应用程序目录的修改时间（放进 / 删掉 .app 都会变）和上次扫描时不一样
  static func needsRescan(scannedAt: Date?, scanned: [Date?], now: [Date?]) -> Bool {
    scannedAt == nil || scanned != now
  }

  /// 收起：执行过、或者查询是空的，清空；没执行就收起的（点外面、再按热键、切到别的 App）留着查询和选中项，
  /// 60 秒内再呼出接着用（体检 A27）。App 目录超过 5 分钟就趁没人看时重扫（接住子文件夹里的升级、改名）
  func didHide(now: Date = .now) {
    isShown = false
    files.forgetItems()
    showsActions = false
    error = nil
    armed = nil
    review = nil
    if let output {
      self.output = nil
      if output.isRunning { detach(output.script) }
    }
    listTask?.cancel()
    listTask = nil
    filterTask?.task.cancel()
    filterTask = nil
    filterRows = [:]
    runsWhenListed = false
    forgotten = nil
    notice = nil
    definitionTask?.cancel()
    if isQuickLooking {
      closeQuickLook(false)
      quickLookDidHide()
    }
    // 还在列的进程不要了（再呼出重列）
    processTask?.task.cancel()
    processTask = nil
    // ip 再呼出时重读重查：这期间可能换了网络
    cancelIPLookups()
    ipLookups = [:]
    ipLocal = nil
    ratesTask?.cancel()
    ratesTask = nil
    ratesFailed = false
    // 打着密码参数没跑就收起的也不留（第三轮 C3：60 秒内再呼出时还看得见）
    if executed || query.isEmpty || holdsSecret {
      keptAt = nil
      if !query.isEmpty { query = "" }
    } else {
      keptAt = now
      files.stop()
      // 带对象模式（quit / eject / kill / port 空格）的列表再呼出时重列：这期间可能退出了 App、推出了磁盘、进程结束了
      commandItems = nil
    }
    executed = false
    if let scannedAt = appsScannedAt, now.timeIntervalSince(scannedAt) > Self.rescanInterval {
      rescanApps()
    }
  }

  private func search() {
    error = nil
    armed = nil
    listTask?.cancel()
    listTask = nil
    runsWhenListed = false
    selectionMotion = .instant
    selection = 0
    userMovedSelection = false
    shownFileRequest = nil
    favoriteCount = 0
    definitionTask?.cancel()
    // 「命令」表（拍板 C3 C4）：开头是改过的别名的换回原关键词交给原来那一套；原关键词改掉了 / 关掉的挡掉
    let settings = commandSettings()
    let (command, blocked) = LauncherCommands.canonical(query, settings: settings)
    func allowed(_ id: String) -> Bool { settings.isOn(id) && !blocked.contains(id) }
    // 打字路过 ip（「iphone」）时还没查完的不要了
    if !(allowed("builtin:ip") && IPAddresses.matches(command)) { cancelIPLookups() }
    // 汇率同样：还在等那 0.3 s 的撤掉（「命令」表里关掉了汇率换算也撤掉）
    let currencyOn = settings.isOn("builtin:currency")
    if !currencyOn || ExchangeRates.request(for: query) == nil {
      ratesTask?.cancel()
      ratesTask = nil
    }
    fileRequest = FileSearch.request(for: command).flatMap {
      allowed($0.mode == .open ? "builtin:open" : "builtin:find") ? $0 : nil
    }
    commandRequest =
      fileRequest == nil
      ? SystemCommands.request(for: command).flatMap {
        allowed("builtin:" + $0.verb.rawValue) ? $0 : nil
      } : nil
    if commandRequest == nil { commandItems = nil }
    if let fileRequest {
      searchFiles(fileRequest)
      return
    }
    files.stop()
    if let commandRequest {
      showTargets(commandRequest)
      return
    }
    emptyText = "没有匹配的结果"
    let features = features
    if features.contains(.translate), allowed("builtin:fy"), let text = Self.translateQuery(command)
    {
      results = [Self.translateItem(text)]
      lookUpDefinition(text)
      return
    }
    // 「cb 词」（带空格）只有这一行（N9）；单输 cb 时它排第一，后面照常接本地结果（体检 B33）
    if features.contains(.clipboard), allowed("builtin:cb"), let keyword = Self.clipQuery(command),
      command.count > 2
    {
      results = [Self.clipItem(keyword)]
      return
    }
    // 「提醒 …」（带空格）只列提醒：能认出时间的先是「建一条」，再是已有的提醒（D2 D4）；单输「提醒」出补全提示
    if features.contains(.reminders), allowed("builtin:reminder"),
      let rest = ReminderPhrase.query(command)
    {
      emptyText = "还没有提醒：在「提醒 」后面接着写时间和内容，如「10分钟 喝水」"
      results = Self.reminderItems(rest, list: reminders(), now: .now)
      return
    }
    // 「别名 空格 文字」：交给那条脚本（B2），它的那几行排在普通结果前面
    let invocation = ScriptCommand.invocation(for: query, in: activeScripts, alias: scriptAlias)
    let invocationRows = invocation.map(invocationRows) ?? []
    // 下载来、还没看过的：那一行（↩ 先看全文）不排在最前，接在普通结果后面（复查：同别名一字不差的那一处）
    let trusted = invocation.map {
      !$0.script.isDownloaded || approvedScripts.contains($0.script.path)
    }
    // 自己过滤的没跑成、下面又有别的结果：不留那行错误（同普通列表）；不再打这条脚本时忘掉没跑成的，再打到它重跑一次
    let filterFailed = invocation.map { filterRows[$0.script.path]?.failed == true } ?? false
    for (path, cached) in filterRows where cached.failed && path != invocation?.script.path {
      filterRows[path] = nil
    }
    var leading = trusted == false ? [] : invocationRows
    let trailing = trusted == false ? invocationRows : []
    let query = query.trimmingCharacters(in: .whitespaces)
    let typed = command.trimmingCharacters(in: .whitespaces)
    let ip = allowed("builtin:ip") && IPAddresses.matches(typed) ? ipItems() : []
    // 内置命令的提示行：关掉的、原关键词改掉了的不出，改了别名的把「kill 空格」换成别名
    func labeled(_ items: [LauncherItem]) -> [LauncherItem] {
      items.compactMap { item in
        if let id = LauncherCommands.builtIn(forPrompt: item.target)?.id, blocked.contains(id) {
          return nil
        }
        return LauncherCommands.relabel(item, settings: settings)
      }
    }
    if query.isEmpty {
      results = home()
      return
    }
    let engines = engines()
    let direct = DirectItems.items(for: query)
    let keyword = WebSearch.keywordItem(for: query, engines: engines)
    let prompts = WebSearch.promptItems(for: query, engines: engines)
    let filePrompts = FileSearch.promptItems(for: typed)
    let systemPrompts = SystemCommands.promptItems(for: typed)
    let clip =
      features.contains(.clipboard) && allowed("builtin:cb") && Self.clipQuery(typed) != nil
      ? [Self.clipItem("")] : []
    let fy = Self.translatePrompts(for: features.contains(.translate) ? typed : "")
    let currency = ExchangeRates.promptItems(for: typed)
    // 「新建提醒…」提示排在本地结果后面：输「提醒」想打开系统「提醒事项」的，↩ 照旧打开它
    let tx = features.contains(.reminders) ? labeled(Self.reminderPrompts(for: typed)) : []
    let exactPrompts: [LauncherItem] =
      prompts.exact + labeled(filePrompts.exact + systemPrompts.exact)
    let partialPrompts: [LauncherItem] =
      prompts.partial
      + labeled(filePrompts.partial + systemPrompts.partial + fy.partial + currency.partial)
    let calculation = calculationItem(query, currency: currencyOn)
    // 货币打到一半（「100 美元 转 英」）：紧跟在计算结果的位置列候选；有计算结果时不列（单位换算、打全了的汇率）
    let currencyHints =
      calculation == nil && currencyOn
      ? ExchangeRates.suggestions(for: query, recents: recentCurrencies) : []
    let top: [LauncherItem] =
      clip + labeled(fy.exact + currency.exact) + ip + direct + [calculation].compactMap { $0 }
      + currencyHints + [keyword].compactMap { $0 } + exactPrompts
    // 书签、浏览历史至少 2 个字才搜（1 个字母命中太多；含中文时 1 个字就搜，U8）
    let longEnough = LauncherMatch.isLongEnough(query)
    let bookmarks = longEnough ? bookmarkItems() : []
    let used = usedLocations(excluding: bookmarks)
    // 书签先粗筛（几千个每敲一个字都完整打分太慢，P3；同 visited）
    let tokens = LauncherMatch.tokens(query)
    let scriptItems = scriptItems
    let local = LauncherMatch.rank(
      apps + builtIns + (scriptsOn() ? LauncherItem.scriptActions : []) + systemItems + scriptItems
        + WebSearch.quicklinkItems(engines: engines)
        + bookmarks.filter { LauncherMatch.mayMatch(tokens, $0) } + used, query: query
    ) { usage.boost(for: $0, query: query) }
    // 脚本的别名一字不差：排第一（拍板 C1）。下载来、还没看过的不算（第三轮评审：头部写个 safari、ip 就能抢走第一行）
    let aliased = Self.aliased(
      scriptItems,
      scripts: activeScripts.filter { !$0.isDownloaded || approvedScripts.contains($0.path) },
      query: query, alias: scriptAlias)
    let history = longEnough ? visited(query, excluding: bookmarks + used) : []
    // 兜底默认只在没有本地结果时出现（和 Alfred 一样；以前带空格的查询把兜底排到匹配的 App 前面），
    // 设置里可改成总是附在最后。已经有网址 / 路径直达项、或明写了 http(s):// 的就不再兜底（体检 B35：
    // 以前只看开头是不是 http，「http 缓存」「https 证书」没有本地结果时什么都不剩）
    let explicit =
      direct.contains { $0.kind == .path || $0.kind == .url }
      || ["http://", "https://"].contains(where: query.lowercased().hasPrefix)
    let wantsFallback =
      local.isEmpty || UserDefaults.standard.bool(forKey: Prefs.launcherFallbackAlways)
    let fallback =
      keyword == nil && wantsFallback && !explicit
      ? WebSearch.fallbackItems(for: query, engines: engines) : []
    // 直达项和书签 / 用过的网址可能是同一项：按 id 去重，保留靠前的
    var seen = Set<String>()
    let ordered = Self.promoting(local, over: top) { usage.boost(for: $0, query: query).query > 0 }
    if filterFailed, (aliased + ordered).contains(where: { ![.search, .prompt].contains($0.kind) })
    {
      leading = []
    }
    results = (leading + aliased + ordered + trailing + tx + history + partialPrompts + fallback)
      .filter { seen.insert($0.id).inserted }
    if let invocation { startList(invocation) }
  }

  /// 别名（关键词）和输入一字不差的脚本行（不分大小写、去掉两头空白）。纯函数，配单测
  static func aliased(
    _ items: [LauncherItem], scripts: [ScriptCommand], query: String,
    alias: (ScriptCommand) -> String? = { $0.keyword }
  ) -> [LauncherItem] {
    let text = LauncherMatch.fold(query.trimmingCharacters(in: .whitespaces))
    guard !text.isEmpty else { return [] }
    let paths = Set(scripts.filter { alias($0) == text }.map(\.path))
    return items.filter { paths.contains($0.target) }
  }

  /// 本地结果里在完全相同的输入下选过的（使用记录里这个查询的分 > 0）排到固定行（剪贴板、翻译、ip、直达、计算、
  /// 关键词提示）前面，彼此顺序不变；其余本地结果照旧跟在固定行后面（第四轮体检 E8：输 gh 选过 Ghostty 的，
  /// 下次 gh 第一行还是「用 GitHub 搜索…」）。纯函数，配单测
  static func promoting(
    _ local: [LauncherItem], over top: [LauncherItem], chosen: (LauncherItem) -> Bool
  ) -> [LauncherItem] {
    let picked = local.filter(chosen)
    return picked + top + local.filter { !chosen($0) }
  }

  /// 浏览历史里匹配上的（体检 D8）：去掉已经是书签 / 用过的网址（不分大小写），只比标题和去协议的网址、不加使用分，
  /// 最多 5 行；副标题按这一刻拼上「3 天前」。不算「本地结果」：只有历史匹配上时照样出兜底搜索
  private func visited(_ query: String, excluding known: [LauncherItem]) -> [LauncherItem] {
    let pages = historyItems()
    guard !pages.isEmpty else { return [] }
    let seen = Set(known.map { $0.target.lowercased() })
    // 先粗筛（LauncherMatch.mayMatch：匹配分档的必要条件）。3000 条直接排序要逐条切词，
    // Debug 构建实测本机 3000 条一次按键约 45 ms，粗筛后 10–15 ms。
    // ponytail: 还嫌慢就在 BrowserHistory 里存好拼接的小写名字，只做一次 contains
    let tokens = LauncherMatch.tokens(query)
    let candidates = pages.filter { page in
      LauncherMatch.mayMatch(tokens, page) && !seen.contains(page.target.lowercased())
    }
    let now = Date.now
    return LauncherMatch.rank(candidates, query: query) { _ in (0, 0) }
      .prefix(Self.historyLimit).map { item in
        var item = item
        item.subtitle = BrowserHistory.subtitle(item, now: now)
        return item
      }
  }

  /// quit / hide / forcequit / eject / kill / port 模式：进模式时列一次，之后按输入的词过滤（不加使用分，全按名字；
  /// kill 的「:3000」「:」只按进程监听的端口筛，port 只输数字时按端口号的开头筛）。kill、port 的进程在进程外列，
  /// 到之前写「正在读取进程…」/「正在读取端口…」
  private func showTargets(_ request: SystemCommands.Request) {
    let verb = request.verb
    if commandItems?.verb != verb {
      guard verb.listsProcesses else {
        commandItems = (verb, commandTargets(verb))
        return showTargets(request)
      }
      results = []
      emptyText = verb == .port ? "正在读取端口…" : "正在读取进程…"
      // 同一个关键词还在列就等它（打字不重列）；换了关键词，上一次的不要了
      if processTask?.verb != verb {
        processTask?.task.cancel()
        let task = Task {
          let items = await processTargets(verb)
          guard !Task.isCancelled else { return }
          processTask = nil
          guard let request = commandRequest, request.verb == verb else { return }
          commandItems = (verb, items)
          showTargets(request)
        }
        processTask = (verb, task)
      }
      return
    }
    let targets = commandItems?.items ?? []
    let terms = request.terms.joined(separator: " ")
    // port 只输了数字（前面带不带冒号都行）：要找的是端口
    let port = verb == .port ? terms.wholeMatch(of: /:?(\d*)/)?.1 : nil
    results =
      if terms.isEmpty {
        targets
      } else if verb == .kill, terms.hasPrefix(":") {
        // 只按监听的端口筛、保持原顺序（「postgres: walwriter」这类进程名里也有冒号）
        targets.filter { Processes.listens($0, on: terms) }
      } else if let port {
        // 按端口号的开头筛、保持端口顺序（按匹配排的话「80」会带出 5180、18080）
        targets.filter { $0.title.hasPrefix(":" + port) }
      } else {
        LauncherMatch.rank(targets, query: terms) { _ in (0, 0) }
      }
    // port 写「没有找到」：别的用户、系统的进程在监听时这里看不到，不能说「没有」
    emptyText =
      switch (verb, terms.isEmpty) {
      case (.eject, true): "没有可推出的磁盘"
      case (.eject, false): "没有匹配的磁盘"
      case (.kill, true): "没有后台进程"
      case (.kill, false) where terms.hasPrefix(":"): "没有进程在监听这个端口"
      case (.port, true): "没有找到在监听端口的进程"
      case (.port, false) where port != nil: "没有找到监听这个端口的进程"
      case (.kill, false), (.port, false): "没有匹配的进程"
      case (_, true): "没有正在运行的 App"
      case (_, false): "没有匹配的 App"
      }
  }

  /// 等 kill / port 的进程列完（单测、截图自检用）
  func processLookup() async { await processTask?.task.value }

  /// 文件搜索：查询还在跑时留着上一次的结果（约 40 ms 后换掉，免得列表先空再长）；1 个字母不查
  private func searchFiles(_ request: FileSearch.Request) {
    guard !request.isTooShort else {
      files.stop()
      results = []
      emptyText = "再输入一个字母"
      return
    }
    guard !isFixture else { return }
    if checksFolderAccess {
      checksFolderAccess = false
      folderHint = FileSearch.accessHint(denied: Permissions.deniedFolders())
    }
    files.start(request) { [weak self] hits in self?.showFiles(hits, for: request) }
  }

  /// 文件结果到了（分批，每批都是到目前为止的全部）：排好序，前面放整句（连关键词）匹配到的 App / 内置动作
  /// （「find my」照样能打开「查找」，修旧版被文件搜索截走，§11 #38；关键词也得匹配上，所以很少见）。
  /// 空格开头是明确要搜文件，不放
  func showFiles(_ hits: [FileSearch.Hit], for request: FileSearch.Request) {
    guard request == fileRequest else { return }  // 已经换了查询
    // 按路径缓存的条目（每批只转新到的）；查询词里没有拉丁字母时不转拼音（P3）
    let pinyin = FileSearch.needsPinyin(request.terms)
    let found = FileSearch.rank(
      hits, terms: request.terms, item: { files.item($0, pinyin: pinyin) },
      boost: { usage.boost(for: $0, query: query) })
    let whole = query.trimmingCharacters(in: .whitespaces)
    let named =
      request.terms.isEmpty || query.first?.isWhitespace == true
      ? []
      : LauncherMatch.rank(apps + builtIns, query: whole) {
        usage.boost(for: $0, query: whole)
      }
    let selected = results.indices.contains(selection) ? results[selection].id : nil
    var seen = Set<String>()
    results = (named + found + [folderHint].compactMap { $0 }).filter {
      seen.insert($0.id).inserted
    }
    emptyText = request.terms.isEmpty ? "最近没有打开或下载的文件" : "没有匹配的文件"
    selectionMotion = .instant
    selection =
      request == shownFileRequest && userMovedSelection
      ? selected.flatMap { id in results.firstIndex { $0.id == id } } ?? 0 : 0
    shownFileRequest = request
  }

  /// 「cb」或「cb 关键词」（不分大小写：「CB 会议」也算）
  static func clipQuery(_ query: String) -> String? {
    let lower = query.lowercased()
    guard lower == "cb" || lower.hasPrefix("cb ") else { return nil }
    return String(query.dropFirst(2)).trimmingCharacters(in: .whitespaces)
  }

  /// cb 那一行：启动器里不再列剪贴板条目，↩ 交给剪贴板面板去搜（类型图标、透镜、⌘K、多选都在那边）
  static func clipItem(_ keyword: String) -> LauncherItem {
    LauncherItem(
      kind: .clip, target: keyword,
      title: keyword.isEmpty ? "打开剪贴板历史" : "在剪贴板历史里搜索「\(keyword)」",
      // 只输 cb 时说一下还能带关键词（2026-11-04：每个提示行都写怎么用）
      subtitle: keyword.isEmpty ? "↩ 打开剪贴板面板；输入「cb 空格 关键词」直接搜" : "")
  }

  /// 「fy 文本」的文本（不分大小写；只输 fy 不算，出补全提示）
  static func translateQuery(_ query: String) -> String? {
    guard query.lowercased().hasPrefix("fy ") else { return nil }
    let text = query.dropFirst(3).trimmingCharacters(in: .whitespaces)
    return text.isEmpty ? nil : text
  }

  /// fy 那一行（副标题是单个英文词的词典释义，查到了再换上）
  static func translateItem(_ text: String, definition: String = "") -> LauncherItem {
    LauncherItem(kind: .translate, target: text, title: "翻译「\(text)」", subtitle: definition)
  }

  /// 单输 fy：↩ / Tab 补全关键词的提示（同 open / find）；打「翻译」「fanyi」时排在本地结果（输入翻译）后面
  static func translatePrompts(for query: String) -> (
    exact: [LauncherItem], partial: [LauncherItem]
  ) {
    let item = LauncherItem(
      kind: .prompt, target: "translate-fy", title: "翻译…",
      subtitle: "输入「fy 空格 文字」，↩ 或 Tab 补全关键词", completion: "fy ")
    switch LauncherMatch.promptMatch(query, keywords: ["fy"], aliases: ["翻译", "fanyi"]) {
    case .exact: return ([item], [])
    case .partial: return ([], [item])
    case nil: return ([], [])
    }
  }

  /// 单输「提醒」「tx」「remind」：↩ / Tab 补全关键词的提示（同 fy）
  static func reminderPrompts(for query: String) -> [LauncherItem] {
    guard ReminderPhrase.isKeyword(query) else { return [] }
    // 用法里写打的那个词（「提醒」「tx」「remind」都认）
    let typed = query.trimmingCharacters(in: .whitespaces)
    return [
      LauncherItem(
        kind: .prompt, target: "reminder-new", title: "新建提醒…",
        subtitle: "输入「\(typed) 空格 时间 内容」，如「\(typed) 10分钟 喝水」；↩ 或 Tab 补全关键词",
        completion: typed + " ")
    ]
  }

  /// 「提醒 …」那几行（纯函数）：认出了时间的先是「建一条」，再是已有的提醒——没写别的时全列，写了的只列标题里带着这些字的；
  /// 认不出、已经过了、写的是重复的给一行提示，排在已有的后面（「提醒 眼睛」是在找那一条，↩ 落在它上面）
  static func reminderItems(
    _ rest: String, list: [Reminder], now: Date, calendar: Calendar = .current
  ) -> [LauncherItem] {
    var create: [LauncherItem] = []
    var hint: [LauncherItem] = []
    if !rest.isEmpty {
      let parsed = ReminderPhrase.parse(rest, now: now, calendar: calendar)
      if let parsed, parsed.date > now {
        let when = Reminder.Schedule(kind: .once, date: parsed.date).summary(
          now: now, calendar: calendar)
        create.append(
          LauncherItem(
            kind: .reminder, target: "", title: "提醒我：\(parsed.title)", subtitle: when,
            payload: rest))
      } else {
        let repeating = ReminderPhrase.isRepeating(ReminderPhrase.halfWidth(rest))
        hint.append(
          LauncherItem(
            kind: .prompt, target: Self.reminderHint,
            title: repeating ? "重复的提醒到设置里建" : parsed == nil ? "认不出时间" : "这个时间已经过了",
            subtitle: repeating
              ? "这里只建一次的；每天、每周、每隔一阵的到 设置 › 提醒 里加"
              : "试试「10分钟 喝水」「明天9点 交周报」「下午3点半 开会」"))
      }
    }
    let folded = LauncherMatch.fold(rest)
    let existing = list.filter { rest.isEmpty || LauncherMatch.fold($0.title).contains(folded) }
      .map { reminder in
        var item = LauncherItem(
          kind: .reminder, target: reminder.id, title: reminder.title,
          subtitle: reminder.summary(now: now, calendar: calendar)
            + (reminder.isOn ? "" : " · 已暂停"))
        item.presetEmoji = reminder.symbol.isEmpty ? nil : reminder.symbol
        return item
      }
    return create + existing + hint
  }

  /// 「提醒 …」认不出时那一行提示的目标（↩ 什么都不做，只响提示音）
  static let reminderHint = "reminder-hint"
  /// 下拉参数的一个选项那一行（第三轮 C1）：目标是「前缀 脚本路径⏎第几个参数⏎第几个选项」
  static let choicePrefix = "script-choice\n"

  /// 「fy 单词」：系统词典的第一条释义，到了再换副标题，不改行高（体检 D10；首查约 0.3 s）
  private func lookUpDefinition(_ text: String) {
    guard text.wholeMatch(of: /[A-Za-z][A-Za-z'’\-]*/) != nil else { return }
    let item = Self.translateItem(text)
    definitionTask = Task {
      guard let definition = await lookUp(text), !Task.isCancelled,
        let index = results.firstIndex(of: item)
      else { return }
      results[index] = Self.translateItem(text, definition: definition)
    }
  }

  /// 等副标题的释义查完（截图自检、单测用）
  func definitionLookup() async { await definitionTask?.value }

  /// 「ip」那几行：本机地址，再是外网地址。外网这次呼出里没查过、上次没查到的，等 0.3 s 再问（还在打字就撤掉）；
  /// 查到一家换一次行，行数可能多一行（两家看到的不一样），选中留在原来那一项上
  private func ipItems() -> [LauncherItem] {
    let local = ipLocal ?? localAddresses()
    ipLocal = local
    for service in IPAddresses.Service.allCases where ipTasks[service] == nil {
      if case .found = ipLookups[service] { continue }
      ipLookups[service] = .pending
      ipTasks[service] = Task {
        try? await Task.sleep(for: IPAddresses.lookupDelay)
        guard !Task.isCancelled else { return }
        let address = await publicAddress(service)
        guard !Task.isCancelled else { return }
        ipTasks[service] = nil
        ipLookups[service] = address.map { .found($0) } ?? .failed
        guard let start = results.firstIndex(where: { $0.kind == .ip }) else { return }
        let kept = selectedItem?.id
        results.removeAll { $0.kind == .ip }
        results.insert(contentsOf: local + IPAddresses.publicItems(ipLookups), at: start)
        selection = kept.flatMap { id in results.firstIndex { $0.id == id } } ?? selection
      }
    }
    return local + IPAddresses.publicItems(ipLookups)
  }

  /// 计算结果那一行。是汇率换算时顺带看要不要取汇率表：一份都没有、或者存着的过了 6 小时，停 0.3 s 再取（打字路过不发请求），
  /// 取到了原地换掉那一行（id 不变，选中不跳）；一份都没有时先是占位行（正在取 / 没取到），存着旧的就先用旧的
  /// currency：「命令」表里汇率换算开着（关着时只算算式、单位、进制，不换算货币、不取汇率表）
  private func calculationItem(_ query: String, currency: Bool = true) -> LauncherItem? {
    guard currency else { return Calculator.item(for: query, rates: nil) }
    if ExchangeRates.request(for: query) != nil,
      ratesTask == nil, rates.map({ ExchangeRates.isStale($0, now: .now) }) ?? true
    {
      ratesFailed = false
      ratesTask = Task {
        try? await Task.sleep(for: ExchangeRates.fetchDelay)
        guard !Task.isCancelled else { return }
        let table = await fetchRates()
        guard !Task.isCancelled else { return }
        ratesTask = nil
        if let table {
          rates = table
          if !isFixture { ExchangeRates.save(table) }
        } else {
          ratesFailed = true
        }
        let query = self.query.trimmingCharacters(in: .whitespaces)
        guard let index = results.firstIndex(where: { $0.kind == .calculation }) else { return }
        results[index] =
          calculationRow(query) ?? ExchangeRates.placeholder(for: query, failed: true)
      }
    }
    return calculationRow(query)
  }

  /// 算出来的那一行；汇率换算还没有表时是占位行（不取表，取表在 calculationItem）
  private func calculationRow(_ query: String) -> LauncherItem? {
    if let item = Calculator.item(for: query, rates: rates) { return item }
    guard rates == nil, ExchangeRates.request(for: query) != nil else { return nil }
    return ExchangeRates.placeholder(for: query, failed: ratesFailed)
  }

  /// 等汇率表取完（截图自检、单测用）
  func ratesFetch() async { await ratesTask?.value }

  /// 用了一次汇率换算（↩ 粘贴、⌘↩ / ⌘C / ⌘K 复制）：记下它的两种货币，下次候选里排前面（不是汇率换算的不动）
  private func rememberCurrencies(_ item: LauncherItem) {
    guard item.kind == .calculation, item.payload != nil else { return }
    let updated = ExchangeRates.remembering(item.target, in: recentCurrencies)
    guard updated != recentCurrencies else { return }
    recentCurrencies = updated
    if !isFixture { ExchangeRates.saveRecents(updated) }
  }

  /// 撤掉还在等 / 在查的外网查询（查到的、没查到的留着）
  private func cancelIPLookups() {
    for (service, task) in ipTasks {
      task.cancel()
      ipLookups[service] = nil
    }
    ipTasks = [:]
  }

  /// 等外网地址查完（截图自检、单测用）
  func ipLookup() async {
    for task in ipTasks.values { await task.value }
  }

  /// 用过的网址 / 文件：不在任何目录里，靠使用记录找回来；和书签同一网址（不分大小写）时只留书签。
  /// 系统设置面板在 App 目录里，不另列；从书签 / 快捷链接打开的（listed）不在这里找回——还在的那份列表自己会列，
  /// 浏览器里删了就该搜不到（issue #10）
  private func usedLocations(excluding bookmarks: [LauncherItem]) -> [LauncherItem] {
    let bookmarked = Set(bookmarks.map { $0.target.lowercased() })
    return usage.entries.values
      .filter {
        $0.query.isEmpty && ($0.kind == .url || $0.kind == .path) && !$0.listed
          && !bookmarked.contains($0.target.lowercased()) && !AppCatalog.isSettingsPane($0.target)
      }
      .map(Self.item(for:))
  }

  static func item(for entry: LauncherUsage.Entry) -> LauncherItem {
    item(kind: entry.kind, target: entry.target, title: entry.title)
  }

  /// 网址 / 文件：不在任何目录里，按记下的标题还原
  static func item(kind: LauncherItem.Kind, target: String, title: String) -> LauncherItem {
    LauncherItem(
      kind: kind, target: target, title: title,
      subtitle: kind == .url ? target : (target as NSString).abbreviatingWithTildeInPath,
      names: [title, target].map(LauncherMatch.fold))
  }

  /// 空查询（体检 A22 D13）：先「收藏」（按加入顺序），再按全局使用分（14 天衰减）用「常用」补足到 8 行；
  /// 都只留还能还原的（App 还在、文件还在）。设置里关掉「列出常用」时只有收藏（issue #2；使用记录照记、照样给排序加成）
  private func home() -> [LauncherItem] {
    let actions = builtIns
    var items = favorites(actions)
    favoriteCount = items.count
    guard showsFrequent() else { return items }
    // 从书签 / 快捷链接打开的只从它们现在的列表里找（issue #10）：源头删了就不列，记录留着、加回来照旧
    lazy var listed = bookmarkItems() + WebSearch.quicklinkItems(engines: engines())
    // 全部按分排好再往下找：前面几条失效（App 已卸载、文件已删、书签删了）时后面的补上
    for entry in usage.top(Int.max) where items.count < Self.recentLimit {
      let restored =
        entry.listed
        ? listed.first { $0.kind == entry.kind && $0.target == entry.target }
        : restore(entry.kind, entry.target, entry.title, actions)
      guard let item = restored, !items.contains(where: { $0.id == item.id }) else { continue }
      items.append(item)
    }
    return items
  }

  /// 还原得出来的收藏。还原不出来的（App 没装 / 已卸载、文件已删）**只藏起来、不删**（全局同步：别的 Mac 收藏了这台没装的
  /// App，装上就回来——删了的话会同步删掉每一台的），也不占 8 个名额（⌘D 按看得见的数，LauncherUsage.toggleFavorite）。
  /// 有时有、有时没有的内置动作（钉图）不让收藏（canFavorite）。
  /// ⌥⌘↑↓ 只和看得见的邻居换（moveFavorite）。
  /// 归关着的功能（Feature）的内置动作：不显示，收藏也**不删**（打开功能就回来）——按全部功能都开着时的列表认
  private func favorites(_ actions: [LauncherItem]) -> [LauncherItem] {
    usage.favorites.compactMap { restore($0.kind, $0.target, $0.title, actions) }
  }

  private func restore(
    _ kind: LauncherItem.Kind, _ target: String, _ title: String, _ actions: [LauncherItem]
  ) -> LauncherItem? {
    switch kind {
    case .app:
      if let app = apps.first(where: { $0.target == target }) { return app }
      // 应用程序目录以外的 App
      return FileManager.default.fileExists(atPath: target) ? AppCatalog.item(path: target) : nil
    case .action:
      return actions.first { $0.target == target }
        ?? (scriptsOn() ? LauncherItem.scriptActions.first { $0.target == target } : nil)
    case .system: return systemItems.first { $0.target == target }
    // 文件删了、脚本命令关了：藏起来，收藏不删（同 App）
    case .script: return scriptItems.first { $0.target == target }
    // 系统设置面板从目录里取（副标题「系统设置」、图标）；目录里没有的（系统更新后没了、自己建的这类链接）退回普通网址，
    // 不删收藏
    case .url:
      return apps.first { $0.target == target }
        ?? Self.item(kind: .url, target: target, title: title)
    case .path:
      return FileManager.default.fileExists(atPath: target)
        ? Self.item(kind: .path, target: target, title: title) : nil
    // 不记使用，不会出现
    case .search, .calculation, .clip, .prompt, .translate, .process, .ip, .reminder,
      .scriptResult:
      return nil
    }
  }

  /// 列表变了（收藏、移除、调顺序）之后重算，选中留在那一项上；它不在了就留在原来的位置
  private func refresh(keeping id: String?) {
    let index = selection
    search()
    if let id, reselect(id) { return }
    selection = min(index, max(results.count - 1, 0))
  }

  @discardableResult private func reselect(_ id: String) -> Bool {
    guard let index = results.firstIndex(where: { $0.id == id }) else { return false }
    selection = index
    // 文件搜索的后续批次到了也留在这一项上
    userMovedSelection = true
    shownFileRequest = fileRequest
    return true
  }

  // MARK: 执行

  func execute(_ item: LauncherItem) {
    if let request = commandRequest, [.app, .path, .process].contains(item.kind) {
      return runTarget(item, rowVerb(item, in: request))
    }
    switch item.kind {
    case .calculation:
      // 汇率还没取到的占位行没有 payload（同 ip）
      guard let payload = item.payload else { return NSSound.beep() }
      rememberCurrencies(item)
      paste { Paster.write(string: payload, record: true) }
    case .ip:
      guard let address = item.payload else { return NSSound.beep() }
      paste { Paster.write(string: address, record: true) }
    case .clip:
      close()
      openClipboard(item.target)
    case .translate:
      close()
      translate(item.target)
    case .reminder where item.target.isEmpty:
      // 「建一条」：按 ↩ 的这一刻再解析一遍（行列出来之后过了一会儿，「10分钟」要从现在算）
      guard let text = item.payload, let parsed = ReminderPhrase.parse(text), parsed.date > .now
      else { return NSSound.beep() }
      close()
      createReminder(
        Reminder(
          id: UUID().uuidString, title: parsed.title,
          schedule: .init(kind: .once, date: parsed.date)))
    case .reminder:
      // 打开 / 暂停：启动器不收，摘要里的「已暂停」当场跟上，选中留在这一行
      toggleReminder(item.target)
      let kept = selection
      search()
      selection = min(kept, max(results.count - 1, 0))
    case .prompt where item.target == FileSearch.accessTarget:
      close()
      requestFolderAccess()
    case .prompt where item.target == Self.reminderHint:
      NSSound.beep()
    case .prompt:
      if let completion = item.completion { query = completion }
    case .search:
      guard let url = URL(string: item.target) else {
        error = "打不开搜索页"
        return
      }
      open(url, nil)
    case .action:
      // 退出本 App、进入状态屏不记使用：不进「常用」，也不会越用越排到别的前缀查询前面（↩ 不确认）
      if item.target != MenuExtra.quit.rawValue, !item.isStatusPreset {
        usage.record(item, query: query)
      }
      close()
      runAction(item.target)
    case .system:
      guard let command = SystemCommand(rawValue: item.target) else { return }
      if let text = command.confirmation, !confirm(item, commandKey: false, text: text) { return }
      usage.record(item, query: query)
      close()
      perform(.command(command))
    case .app, .path:
      if revealsOnReturn(item) {
        reveal(item)
      } else {
        open(URL(filePath: item.target), item)
      }
    case .url:
      guard let url = URL(string: item.target) else {
        error = "打不开「\(item.title)」"
        return
      }
      open(url, item)
    case .process: break  // 只在 kill / port 模式里出现，上面已经处理
    case .script:
      guard let script = activeScripts.first(where: { $0.path == item.target }) else {
        return NSSound.beep()
      }
      // 从网上下载、还没看过的：先给用户看一眼（B5）；列表脚本也是（看过之前不会打一个字跑一次）
      if script.isDownloaded, !approvedScripts.contains(script.path) {
        return showReview(script, arguments: item.arguments)
      }
      // 要参数的普通那一行：先补「关键词 空格」；参数没填够的只响提示音（副标题写着要填什么）
      guard let arguments = item.arguments ?? (script.takesInput ? nil : []) else {
        query = (scriptAlias(script) ?? script.title) + " "
        return
      }
      // 参数没填够、下拉参数填的不是选项（第三轮 C1）：只响提示音，副标题写着
      guard arguments.count >= script.requiredCount, script.invalidChoice(arguments) == nil else {
        return NSSound.beep()
      }
      if let text = script.confirmation, !confirm(item, commandKey: false, text: text) { return }
      record(script, item)
      start(script, arguments: arguments)
    case .scriptResult:
      // 这一次还在跑（显示的是上一次的、或者「正在运行…」）：等结果到了执行第一条
      if isPending(item) {
        runsWhenListed = true
        return
      }
      guard let payload = item.payload else { return NSSound.beep() }
      // 写了 url / path 的打开它（第三轮 B1；不记使用：结果每次由脚本重新列）
      switch item.opens {
      case .url(let url): open(url, nil)
      case .file(let path): open(URL(filePath: path), nil)
      case nil: paste { Paster.write(string: payload, record: true) }
      }
    }
  }

  /// 「关键词 空格 文字」那几行（B2），排在普通结果前面（不吞掉普通结果：「time machine」照样搜得到时间机器）：参数没填够时
  /// 副标题写「输入「tq 空格 城市」」；列表脚本是它的结果行——跑完之前留着这条脚本上一次的结果（不闪），第一次是一行
  /// 「正在运行…」（↩ 按在它上面等结果到了再执行，不落到下面的网页搜索上）
  private func invocationRows(_ invocation: ScriptCommand.Invocation) -> [LauncherItem] {
    let script = invocation.script
    var row = LauncherItem.script(script, alias: scriptAlias(script))
    row.arguments = invocation.arguments
    // 已经在传参数了：Tab 不补全（第三轮评审：补成「tq 」把打好的「北京」清掉了）
    row.completion = nil
    // 正在打的是下拉参数、还没对上一个选项：选项排在前面，↩ / ⇥ 填进去（第三轮 C1）
    let choices = choiceRows(invocation)
    if !choices.isEmpty {
      row.subtitle = "从下面选一个「\(script.arguments[invocation.typing].placeholder)」"
      return choices + [row]
    }
    if invocation.isMissing {
      let missing = script.arguments[invocation.arguments.count..<script.requiredCount]
      row.subtitle =
        "输入「\(invocation.keyword) 空格 \(missing.map(\.placeholder).joined(separator: " "))」"
      return [row]
    }
    if let bad = script.invalidChoice(invocation.arguments) {
      let argument = script.arguments[bad]
      row.subtitle =
        "「\(invocation.arguments[bad])」不是「\(argument.placeholder)」能选的："
        + argument.options.map(\.title).joined(separator: " / ")
      return [row]
    }
    let downloaded = script.isDownloaded && !approvedScripts.contains(script.path)
    guard script.mode == .list, !downloaded else {
      if downloaded {
        row.subtitle = "从网上下载的脚本，↩ 先看一眼"
      } else if !invocation.arguments.isEmpty {
        // 密码参数不回显（第三轮 C3）
        row.subtitle = invocation.arguments.enumerated().map { index, value in
          index < script.arguments.count && script.arguments[index].isSecret ? "•••" : "「\(value)」"
        }.joined(separator: " ")
      }
      return [row]
    }
    // 自己过滤的：跑过了就按关键词后面的字过滤这一次的结果，不再跑（第三轮 B3）
    if script.filters, let cached = filterRows[script.path] {
      return cached.failed
        ? cached.rows : Self.filtered(cached.rows, by: invocation.arguments.first ?? "")
    }
    let kept = results.filter { $0.isResult(of: script) && $0.payload != nil }
    guard kept.isEmpty else { return kept }
    var pending = LauncherItem(
      kind: .scriptResult, target: script.path + "\n…", title: "正在运行「\(script.title)」…",
      subtitle: "")
    pending.scriptIcon = script.icon
    pending.scriptIconDark = script.iconDark
    return [pending]
  }

  /// 下拉参数的选项（第三轮 C1）：正在打的那个参数有选项、打的还没对上某一个时，按打的字过滤（认拼音）；↩ / ⇥ 把它填进
  /// 搜索框（带空白的括上引号，后面还有参数的接一个空格）。交给脚本的是选项的 value（ScriptCommand.passed）
  private func choiceRows(_ invocation: ScriptCommand.Invocation) -> [LauncherItem] {
    let script = invocation.script
    let index = invocation.typing
    guard index < script.arguments.count else { return [] }
    let argument = script.arguments[index]
    let typed = index < invocation.arguments.count ? invocation.arguments[index] : ""
    guard !argument.options.isEmpty, argument.option(for: typed) == nil || typed.isEmpty else {
      return []
    }
    // 只有一个参数的脚本整段就是它，不括引号（第 3 批评审：括了的话「"New York"」连引号交给脚本、也对不上选项）
    let quotes = script.arguments.count > 1
    func quote(_ text: String) -> String { quotes ? ScriptCommand.quoted(text) : text }
    let before = invocation.arguments.prefix(index).map(quote)
    let rows = argument.options.enumerated().map { number, option in
      var row = Self.searchable(
        LauncherItem(
          kind: .prompt, target: Self.choicePrefix + script.path + "\n\(index)\n\(number)",
          title: option.title, subtitle: ""))
      row.subtitle = argument.placeholder
      row.completion =
        ([invocation.keyword] + before + [quote(option.title)])
        .joined(separator: " ") + (index + 1 < script.arguments.count ? " " : "")
      row.scriptIcon = script.icon
      row.scriptIconDark = script.iconDark
      return row
    }
    return Self.filtered(rows, by: typed)
  }

  /// 列表脚本（C2）：停手 0.15 s 跑一遍，新的一跑就撤掉上一次；结果换掉这条脚本的那几行，下面的普通结果不动。
  /// 跑失败了、下面又有别的结果：不留那行错误（「time machine」不是在给时间戳传参数）
  private func startList(_ invocation: ScriptCommand.Invocation) {
    let script = invocation.script
    // 下拉参数还没对上选项时不跑（第 3 批评审：打一个字跑一次，结果还挤在选项前面）
    guard script.mode == .list, !invocation.isMissing,
      script.invalidChoice(invocation.arguments) == nil,
      !script.isDownloaded || approvedScripts.contains(script.path)
    else { return }
    if script.filters { return startFilter(invocation) }
    let key = query
    listPath = script.path
    listTask = Task { [weak self] in
      try? await Task.sleep(for: Self.listDelay)
      guard let self, !Task.isCancelled else { return }
      var quick = script
      quick.timeout = min(script.limit == 0 ? Self.listTimeout : script.limit, Self.listTimeout)
      let outcome = await runScript(quick, invocation.arguments, nil)
      guard !Task.isCancelled, query == key else { return }
      listTask = nil
      let selected = userMovedSelection ? selectedItem?.id : nil
      let rest = results.filter { !$0.isResult(of: script) }
      // 传 quick：超时说的秒数是这次真用的（列表最多 10 秒）
      let rows = Self.resultRows(outcome, of: quick, keyword: invocation.keyword)
      // 只有网页搜索、提示这些兜底的行不算：那时留着错误那行，让人知道脚本为什么没给结果
      let failed = Self.failure(outcome, of: quick) != nil
      let found = rest.contains { ![.search, .prompt].contains($0.kind) }
      results = (failed && found ? [] : rows) + rest
      selection = selected.flatMap { id in results.firstIndex { $0.id == id } } ?? 0
      emptyText = "「\(script.title)」没有给出结果"
      // 结果到之前按了 ↩：执行这次的第一条
      if runsWhenListed {
        runsWhenListed = false
        if let first = results.first, first.isResult(of: script) { execute(first) }
      }
    }
  }

  /// 自己过滤的列表脚本（第三轮 B3）：这次呼出里第一次打到「关键词 空格」时跑一次（不带参数），之后打字不撤它、也不再跑；
  /// 结果到了重搜一次（按那时打的字过滤），结果到之前按了 ↩ 的执行第一条
  private func startFilter(_ invocation: ScriptCommand.Invocation) {
    let script = invocation.script
    guard filterRows[script.path] == nil, filterTask?.path != script.path else { return }
    filterTask?.task.cancel()
    let task = Task { [weak self] in
      guard let self else { return }
      var quick = script
      quick.timeout = min(script.limit == 0 ? Self.listTimeout : script.limit, Self.listTimeout)
      let outcome = await runScript(quick, [], nil)
      guard !Task.isCancelled else { return }
      filterTask = nil
      let rows = Self.resultRows(outcome, of: quick, keyword: invocation.keyword)
      let failed = Self.failure(outcome, of: quick) != nil
      filterRows[script.path] = (failed ? rows : rows.map(Self.searchable), failed)
      // 现在打的已经不是在用这条脚本了：结果先记着，不动眼前的列表（第 2 批评审：选中跳回第一行、上膛被撤、
      // 别的列表脚本被重跑）
      guard
        ScriptCommand.invocation(for: query, in: activeScripts, alias: scriptAlias)?.script.path
          == script.path
      else { return }
      let runs = runsWhenListed
      let selected = userMovedSelection ? selectedItem?.id : nil
      search()
      if let selected, let index = results.firstIndex(where: { $0.id == selected }) {
        selection = index
        userMovedSelection = true
      }
      emptyText = "「\(script.title)」没有给出结果"
      if runs, let first = results.first, first.isResult(of: script) { execute(first) }
    }
    filterTask = (script.path, task)
  }

  /// 过滤用的名字：标题、说明，中文标题的全拼和首字母（同搜 App）
  static func searchable(_ row: LauncherItem) -> LauncherItem {
    var row = row
    let pinyin = AppCatalog.pinyin(row.title)
    row.names = [row.title, row.subtitle, pinyin?.full].compactMap { $0.map(LauncherMatch.fold) }
    row.initials = [LauncherMatch.initials(row.title), pinyin?.initials].compactMap { $0 }
    return row
  }

  /// 按打的字过滤：对得上的按匹配分排，同分按脚本给的顺序；没打字就是全部。纯函数，配单测
  static func filtered(_ rows: [LauncherItem], by text: String) -> [LauncherItem] {
    guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return rows }
    return rows.enumerated()
      .compactMap { index, row -> (LauncherItem, Double, Int)? in
        let score = LauncherMatch.score(text, item: row)
        return score > 0 ? (row, score, index) : nil
      }
      .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
      .map(\.0)
  }

  /// 等列表脚本这一次跑完（单测）
  func listRun() async {
    await listTask?.value
    await filterTask?.task.value
  }

  /// 列表脚本跑完 → 一条条结果；出错的是一行写原因（↩ 只响提示音）。keyword：打的关键词（结果的 autocomplete 接在它后面
  /// 填进搜索框）。纯函数，配单测
  static func resultRows(
    _ outcome: ScriptRunner.Outcome, of script: ScriptCommand, keyword: String = ""
  ) -> [LauncherItem] {
    func row(_ index: Int, _ title: String, _ subtitle: String, _ payload: String?) -> LauncherItem
    {
      var item = LauncherItem(
        kind: .scriptResult, target: script.path + "\n\(index)", title: title, subtitle: subtitle,
        payload: payload)
      item.scriptIcon = script.icon
      item.scriptIconDark = script.iconDark
      return item
    }
    if let failure = failure(outcome, of: script) {
      return [row(0, failure.title, failure.detail, nil)]
    }
    return ScriptCommand.lines(outcome.output, folder: script.folder).enumerated().map {
      index, line in
      var item = row(index, line.title, line.subtitle, line.isValid ? line.value : nil)
      // 不能选的不写「网址」「文件」、不当能打开的（↩ 只响提示音）
      item.opens = line.isValid ? line.opens : nil
      item.copyText = line.copyText
      // 这一条自己的图标；没写、是文件的用它在访达里的图标（同启动器里的文件行）
      if let icon = line.icon
        ?? line.opens.flatMap({
          if case .file(let path) = $0 { .file(path) } else { nil }
        })
      {
        item.scriptIcon = icon
        item.scriptIconDark = nil
      }
      if let text = line.autocomplete {
        item.completion = keyword.isEmpty ? text : keyword + " " + text
      }
      return item
    }
  }

  /// 没跑成的那一句（岛上、全文页、列表里同一套说法）；跑成了是 nil
  static func failure(_ outcome: ScriptRunner.Outcome, of script: ScriptCommand) -> (
    title: String, detail: String
  )? {
    let name = "「\(script.title)」"
    switch outcome.end {
    case .stopped: return ("已停止" + name, "")
    case .timedOut:
      return (name + "超时，已停止", "跑了 \(script.limit) 秒还没完；脚本里写 @kitty.timeout 能改")
    case .failedToStart(let reason): return ("运行不了" + name, reason)
    case .tooMuchOutput:
      return (name + "输出太多，已停止", "输出超过 \(ScriptRunner.outputLimit * 4 / 1_048_576) MB")
    case .finished(let status) where status != 0:
      let reason =
        ScriptCommand.lastLine(outcome.error) ?? ScriptCommand.lastLine(outcome.output)
        ?? "退出码 \(status)"
      return (name + "出错了", reason)
    case .finished: return nil
    }
  }

  // MARK: 脚本命令

  /// 搜索框里打着密码参数（第三轮 C3）：不留到下次呼出；⌥↩ / ⌃↩ 不拿它去访达、网页里搜（第 3 批评审：按住 ⌃ 时的说明还会
  /// 把整句连密码显示出来）
  private var holdsSecret: Bool {
    ScriptCommand.invocation(for: query, in: activeScripts, alias: scriptAlias).map {
      $0.script.hasSecret && !$0.arguments.isEmpty
    } ?? false
  }

  /// 记一次使用。有密码参数的（第三轮 C3）：查询里有密码，按关键词记，不把打的字存进使用记录；搜索框先清空（全文输出时
  /// 启动器留着，不清就一直看得见）
  private func record(_ script: ScriptCommand, _ item: LauncherItem) {
    guard script.hasSecret else { return usage.record(item, query: query) }
    usage.record(item, query: scriptAlias(script) ?? script.title)
    query = ""
  }

  /// 跑一条脚本（B1 B4）：先收起再跑，粘贴的目标在收起前定（焦点原本在自家便签里时直接粘进去）；
  /// 超过 1 秒还没完，岛上出「正在运行」带「停止」。同一个还在跑：不重复起，岛上说一声
  private func start(_ script: ScriptCommand, arguments: [String]) {
    let name = "「\(script.title)」"
    guard runningScripts[script.path] == nil else {
      close()
      // 岛上那条「正在运行」会被这一条换掉、挂满 60 秒也会收：这里再给一个「停止」（第三轮评审）
      let path = script.path
      island?.show(
        name + "还在运行", detail: "等它跑完，或者点「停止」", tone: .info,
        actions: [Island.Action("停止") { [weak self] in self?.runningScripts[path]?.cancel() }])
      return
    }
    if script.mode == .full { return startFull(script, arguments: arguments) }
    let target = script.mode == .paste ? pasteTargetView() : nil
    close()
    let path = script.path
    let progress = "正在运行" + name
    runningScripts[path] = Task { [weak self] in
      guard let self else { return }
      let outcome = await Island.whenSlow(after: .seconds(1)) { [weak self] in
        self?.island?.show(
          progress, tone: .progress, symbol: "terminal.fill",
          actions: [Island.Action("停止") { [weak self] in self?.runningScripts[path]?.cancel() }])
      } work: {
        await self.runScript(script, arguments, nil)
      }
      runningScripts[path] = nil
      deliver(outcome, of: script, arguments: arguments, into: target, progress: progress)
    }
  }

  /// 全文输出（B1 full）：启动器留着，列表换成输出那一页；边跑边把写到现在的放上去（第三轮 A1，错误输出并在里面、
  /// 同终端），跑完换成最终的那一份。⌘R 重跑也走这里（第三轮 A3：别的模式的脚本从「看输出」那一页重跑，同样在这一页上看结果）
  private func startFull(_ script: ScriptCommand, arguments: [String]) {
    let path = script.path
    showsActions = false
    output = ScriptOutput(script: script, arguments: arguments)
    let started = output?.startedAt
    runningScripts[path] = Task { [weak self] in
      guard let self else { return }
      let outcome = await runScript(script, arguments) { [weak self] raw in
        guard let self, output?.startedAt == started, output?.isRunning == true else { return }
        output?.showLive(raw)
      }
      runningScripts[path] = nil
      // 跑着时启动器收起了：岛上说结果、带「看输出」；Esc 停掉的、换成别的页的不说。⌘R 重跑的别的模式的脚本也按全文交
      // （第 1 批评审：按它自己的模式交，粘贴脚本会把结果粘进收起后在前面的 App）
      if detachedOutputs.remove(path) != nil {
        var shown = script
        shown.mode = .full
        return deliver(
          outcome, of: shown, arguments: arguments, into: nil,
          progress: "正在运行「\(script.title)」")
      }
      guard output?.startedAt == started else { return }
      var page = Self.outputPage(outcome, of: script, arguments: arguments)
      page.startedAt = started ?? page.startedAt
      output = page
      Island.announce(page.failure ?? "「\(script.title)」运行完了")
    }
  }

  /// 输出那一页的 ⌘R：用同样的参数再跑一次（第三轮 A3）。按的是脚本现在的样子（改完脚本再跑一次看结果）；还在跑的、
  /// 写了 confirm 的（重跑不该绕过「按两次」）、已经不在了的不跑
  func rerunOutput() {
    guard let output, !output.isRunning, runningScripts[output.script.path] == nil else {
      return NSSound.beep()
    }
    guard let script = activeScripts.first(where: { $0.path == output.script.path }),
      !script.isDownloaded || approvedScripts.contains(script.path)
    else {
      island?.show("「\(output.script.title)」不在了", detail: "脚本被删掉、关掉或者换过了", tone: .info)
      return NSSound.beep()
    }
    guard script.confirmation == nil else { return NSSound.beep() }
    startFull(script, arguments: output.arguments)
  }

  /// 这一页能不能 ⌘R：底栏的「重跑」跟着它
  var canRerunOutput: Bool {
    guard let output else { return false }
    return !output.isRunning && output.script.confirmation == nil
  }

  /// 全文脚本跑着时启动器收起了：接着跑，岛上挂「正在运行」带「停止」，跑完由 startFull 交给 deliver
  private func detach(_ script: ScriptCommand) {
    let path = script.path
    detachedOutputs.insert(path)
    island?.show(
      "正在运行「\(script.title)」", tone: .progress, symbol: "terminal.fill",
      actions: [Island.Action("停止") { [weak self] in self?.runningScripts[path]?.cancel() }])
  }

  /// 全文那一页上的东西：输出，没跑成时接上错误输出；没跑成的那一句（红字）。全文输出和岛上「看输出」同一份
  static func outputPage(
    _ outcome: ScriptRunner.Outcome, of script: ScriptCommand, arguments: [String]
  ) -> ScriptOutput {
    var raw = outcome.output
    if !outcome.succeeded, !ScriptCommand.payload(outcome.error).isEmpty {
      while raw.last?.isNewline == true { raw.removeLast() }
      raw += (raw.isEmpty ? "" : "\n\n") + outcome.error
    }
    let failure = Self.failure(outcome, of: script).map {
      [$0.title, $0.detail].filter { !$0.isEmpty }.joined(separator: "：")
    }
    var page = ScriptOutput(
      script: script, arguments: arguments, isRunning: false, failure: failure)
    page.show(raw)
    return page
  }

  /// 岛上「看输出」：叫出启动器，原地显示那一次的全部输出（同全文输出那一页：↩ 粘贴、⌘C 复制、Esc 回到结果）。
  /// 只留着最近一次的：后来又有脚本要看输出，早先那座岛上的按钮就说没留着
  func showOutput(_ id: UUID) {
    guard let lastOutput, lastOutput.id == id else {
      island?.show("那次的输出没留着", detail: "只留最近一次的输出", tone: .info)
      return
    }
    // 先叫出来再换上：收起着时呼出会按「过了 60 秒」清掉查询，那会顺手关掉输出页；正在跑的全文脚本停掉（同 Esc）。
    // 启动器功能关着叫不出来：不留一张过期的输出页（第三轮评审）
    if output != nil { closeOutput() }
    guard showPanel() else { return }
    review = nil
    showsActions = false
    output = lastOutput.page
  }

  /// 输出那一页：回到结果（还在跑就停掉）
  func closeOutput() {
    guard let output else { return }
    if output.isRunning { runningScripts[output.script.path]?.cancel() }
    self.output = nil
  }

  /// 输出那一页的 ↩：把全部输出粘贴到前台 App（同计算结果的粘贴）
  func pasteOutput() {
    guard let output, !output.isRunning, !output.text.isEmpty else { return NSSound.beep() }
    let text = output.text
    self.output = nil
    paste { Paster.write(string: text, record: true) }
  }

  /// 输出那一页的 ⌘C：全部复制，收起，岛上说一声
  func copyOutput() {
    guard let output, !output.isRunning, !output.text.isEmpty else { return NSSound.beep() }
    let text = output.text
    self.output = nil
    Paster.write(string: text, record: true)
    close()
    island?.show("已复制「\(output.script.title)」的输出", detail: Island.excerpt(text))
  }

  /// 等脚本跑完（单测）
  func scriptRun(_ path: String) async { await runningScripts[path]?.value }

  /// 把结果交出去（B1）：出错的一律岛上红字（最后一行；没有就写退出码），成功的按 mode
  private func deliver(
    _ outcome: ScriptRunner.Outcome, of script: ScriptCommand, arguments: [String],
    into target: NSTextView?, progress: String
  ) {
    let name = "「\(script.title)」"
    if let failure = Self.failure(outcome, of: script) {
      let stopped = outcome.end == .stopped
      // 出错了带「看输出」（D3）：前面几行才说得清为什么；自己停的、什么都没输出的不带
      let page = Self.outputPage(outcome, of: script, arguments: arguments)
      let keeps = !stopped && !page.text.isEmpty
      let id = UUID()
      if keeps { lastOutput = (id, page) }
      island?.show(
        failure.title, detail: failure.detail.isEmpty ? nil : failure.detail,
        tone: stopped ? .info : .error,
        actions: keeps
          ? [Island.Action("看输出", opens: true) { [weak self] in self?.showOutput(id) }] : [])
      return
    }
    let text = ScriptCommand.payload(outcome.output)
    switch script.mode {
    case .paste, .copy:
      guard !text.isEmpty else {
        island?.show(name + "没有输出", tone: .warning)
        return
      }
      if script.mode == .copy {
        Paster.write(string: text, record: true)
        island?.show("已复制" + name + "的输出", detail: Island.excerpt(text))
      } else {
        island?.dismiss(ifShowing: progress)
        pasteOutput(text, into: target)
      }
    case .none:
      island?.dismiss(ifShowing: progress)
    // 全文：跑着时启动器收起了的才走这里（detach）。岛上说一声，带「看输出」
    case .full:
      let page = Self.outputPage(outcome, of: script, arguments: arguments)
      let id = UUID()
      if !page.text.isEmpty { lastOutput = (id, page) }
      island?.show(
        name + "运行完了", detail: ScriptCommand.lastLine(outcome.output),
        actions: page.text.isEmpty
          ? [] : [Island.Action("看输出", opens: true) { [weak self] in self?.showOutput(id) }])
    // list 平时不走这里（列表行）；万一走到了按岛上一行
    case .island, .list:
      if let line = ScriptCommand.lastLine(outcome.output) {
        island?.show(line, detail: script.title)
      } else {
        island?.show("已运行" + name)
      }
    }
  }

  /// 粘贴脚本的输出（同计算结果的粘贴：自家便签直接粘进去；没有辅助功能授权时只复制、岛上说去授权）。脚本的输出是本 App
  /// 给出的新文字，同时记进剪贴板历史（mac-native §5）
  private func pasteOutput(_ text: String, into target: NSTextView?) {
    if let target {
      Paster.paste(into: target) { Paster.write(string: text, record: true) }
      return
    }
    Paster.write(string: text, record: true)
    guard Permissions.isAccessibilityTrusted else {
      island?.show(
        "已复制到剪贴板", detail: "授权辅助功能后才能直接粘贴", tone: .warning,
        actions: [.settings(for: .accessibility)])
      return
    }
    _ = Paster.pasteToFrontmost()
  }

  /// 从网上下载的脚本：面板里换成它的全文（读到之前写「正在读取…」）
  private func showReview(_ script: ScriptCommand, arguments: [String]? = nil) {
    armed = nil
    showsActions = false
    review = ScriptReview(script: script, arguments: arguments)
    Task {
      let read = await readScript(script)
      guard review?.script.path == script.path else { return }
      review?.reading = read
      review?.shownAt = .now
      try? await Task.sleep(for: reviewDwell)
      guard review?.script.path == script.path else { return }
      review?.isSettled = true
    }
    Island.announce("这个脚本是从网上下载的，先看一眼再运行。按回车运行，按 Esc 返回")
  }

  /// 看过了（↩ / 「运行」）：记下、去掉隔离标记，然后照常跑（写了 confirm 的不再上膛：看全文就是确认）
  func approveReview() {
    // 全文还没读到、没显示全、藏着打乱显示顺序的字符：不跑（看不全的脚本别运行；去编辑器里看）。刚显示出来那 1 秒的 ↩
    // 也不算：呼出时照习惯连按两下 ↩ 的第二下不能直接放行（第三轮评审）
    guard let review, review.isRunnable, let shown = review.shownAt,
      ContinuousClock.now - shown >= reviewDwell
    else { return NSSound.beep() }
    let script = review.script
    self.review = nil
    approvedScripts.insert(script.path)
    Task { await approveScript(script) }
    // 要参数、却是从普通那一行来的：补「关键词 空格」；列表脚本重搜一次（这下可以跑了）
    guard let arguments = review.arguments ?? (script.takesInput ? nil : []) else {
      query = (scriptAlias(script) ?? script.title) + " "
      return
    }
    guard arguments.count >= script.requiredCount, script.invalidChoice(arguments) == nil else {
      return NSSound.beep()
    }
    if script.mode == .list { return search() }
    record(script, LauncherItem.script(script, alias: scriptAlias(script)))
    start(script, arguments: arguments)
  }

  /// 不跑了（Esc / 「返回」）：回到结果
  func cancelReview() { review = nil }

  /// 执行了东西、面板跟着收起：这次的查询不留
  private func close() {
    executed = true
    hidePanel()
  }

  /// 带对象模式里这一行按哪个命令办：port 列的是进程，后台进程同 kill（↩ 结束、⌘↩ 强制结束），程序坞里的 App 同 quit
  /// （↩ 正常退出——有没存的内容它会先问，⌘↩ 强制退出）；别的模式就是当前的命令
  private func rowVerb(_ item: LauncherItem, in request: SystemCommands.Request)
    -> SystemCommands.Verb
  {
    guard request.verb == .port else { return request.verb }
    return item.process?.app == nil ? .kill : .quit
  }

  /// 带对象模式的行：↩ 退出 / 隐藏 / 强制退出 / 推出 / 结束进程（verb 是 rowVerb 给的）。不记使用（退出过的 App
  /// 不该因此在普通搜索里排前面）。强制退出（forcequit 的 ↩、quit / hide 的 ⌘↩）、强制结束（kill 的 ⌘↩）不可撤销：先上膛
  private func runTarget(
    _ item: LauncherItem, _ verb: SystemCommands.Verb, commandKey: Bool = false
  ) {
    let force = verb == .forcequit || commandKey
    if force {
      // port 的行标题是端口号：提示里写上是谁
      let name = commandRequest?.verb == .port ? item.process?.label : nil
      let text =
        verb == .kill
        ? SystemCommands.killConfirmation(name: name)
        : SystemCommands.forceQuitConfirmation(key: commandKey ? "⌘↩" : "↩", name: name)
      guard confirm(item, commandKey: commandKey, text: text) else { return }
    }
    // port 列的程序坞 App：目标是「PID:端口」，包路径在 process 里
    let path = item.process?.app?.path ?? item.target
    let action: SystemControl.Action
    if verb == .kill {
      guard let process = item.process else { return }
      action = .signal(pid: process.pid, name: process.name, force: force)
    } else if force {
      action = .forceQuit(path)
    } else {
      action =
        switch verb {
        case .eject: .eject(item.target)
        case .hide: .hide(item.target)
        default: .quit(path)
        }
    }
    close()
    perform(action)
  }

  /// 不可撤销的：第一下只上膛（选中这一行、副标题换成确认提示、播报），同一行同一个键再按一次才放行
  private func confirm(_ item: LauncherItem, commandKey: Bool, text: String) -> Bool {
    let armed = Armed(id: item.id, commandKey: commandKey, text: text)
    if self.armed == armed {
      // 按住不放的自动连发、三击的第三下都不算「再按一次」：确认必须是新的一下
      guard !Self.isContinuation else { return false }
      self.armed = nil
      return true
    }
    // ⌘1–9 执行的不一定是选中那行：先选中它，提示才看得见
    if let index = results.firstIndex(of: item), index != selection {
      selectionMotion = .snap
      selection = index
    }
    self.armed = armed
    Island.announce(text)
    return false
  }

  func isArmed(_ item: LauncherItem) -> Bool { armed?.id == item.id }

  /// 这一行的 ↩（commandKey = false）/ ⌘↩（true）现在是不是危险操作（mac-whisker §3「危险色」）：等着再按一次确认的，
  /// 和强制退出 / 强制结束本身（没存的内容会丢）。⌘K 里那一行、底栏主动作的字和 ↩ 键帽据此换危险色；
  /// 哪个键是强制的照 primaryAction / commandReturnAction 的分法
  func isDangerous(_ item: LauncherItem, commandKey: Bool) -> Bool {
    if armed?.id == item.id, armed?.commandKey == commandKey { return true }
    guard let request = commandRequest, [.app, .process].contains(item.kind) else { return false }
    let verb = rowVerb(item, in: request)
    guard commandKey else { return verb == .forcequit }
    return verb == .kill || (verb != .forcequit && item.target != SystemCommands.finderPath)
  }

  /// 这次按键 / 点击是不是上一下的延续：键盘自动连发，或连击的第三下以后
  private static var isContinuation: Bool {
    if Style.isKeyRepeat { return true }
    guard let event = NSApp.currentEvent,
      event.type == .leftMouseDown || event.type == .leftMouseUp
    else { return false }
    return event.clickCount > 2
  }

  /// find 搜到的文件：↩ 在访达中显示、⌘↩ 打开（和 open 反过来）
  func revealsOnReturn(_ item: LauncherItem) -> Bool {
    fileRequest?.mode == .find && item.contentType != nil
  }

  /// 文件搜索搜到的文件 / 文件夹（有 Spotlight 类型，不是宗卷）：才有快速查看、打开方式、移到废纸篓（体检 C7）
  func isFile(_ item: LauncherItem) -> Bool {
    item.kind == .path && commandRequest == nil && item.contentType != nil
      && item.contentType?.conforms(to: .volume) == false
  }

  /// http(s) 网址（直达、书签、用过的、搜索页）：才有「用 X 打开」、Markdown 链接、复制标题（体检 D7）
  func isWebLink(_ item: LauncherItem) -> Bool {
    (item.kind == .url || item.kind == .search)
      && ["http://", "https://"].contains(where: item.target.lowercased().hasPrefix)
  }

  /// 在访达里选中（find 的 ↩ 记使用，和打开一样）；先收起再叫访达
  private func reveal(_ item: LauncherItem) {
    usage.record(item, query: query)
    close()
    NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: item.target)])
  }

  /// ⌥↩ / ⌃↩ 搜的文字：文件搜索时去掉关键词、fy 时是要翻译的那段；cb、系统命令是指令，没有可搜的
  private var searchText: String {
    let features = features
    if features.contains(.translate), let text = Self.translateQuery(query) { return text }
    let query = query.trimmingCharacters(in: .whitespaces)
    guard !features.contains(.clipboard) || Self.clipQuery(query) == nil, commandRequest == nil
    else { return "" }
    return fileRequest.map { $0.terms.joined(separator: " ") } ?? query
  }

  /// 计算结果：收起后写剪贴板、发 ⌘V 粘贴回原 App（和剪贴板面板一样不激活本 App、不等待）。
  /// 没有辅助功能授权时只复制，刘海岛警告去授权（授权框一点启动器就收了，面板里的提示会丢）
  private func paste(_ copy: () -> Void) {
    executed = true
    // 第 8 批：焦点原本在自家便签里 → 收起启动器、把 key 还给它、直接调它的 paste(_:)（不发合成按键、不要授权）
    if let target = pasteTargetView() {
      hidePanel()
      Paster.paste(into: target, write: copy)
      return
    }
    guard Permissions.isAccessibilityTrusted else {
      copy()
      // 系统授权框一点，启动器就收了，面板里的提示会跟着丢
      island?.show(
        "已复制到剪贴板", detail: "授权辅助功能后才能直接粘贴", tone: .warning,
        actions: [.settings(for: .accessibility)])
      return Permissions.requestAccessibility()
    }
    hidePanel()
    copy()
    _ = Paster.pasteToFrontmost()
  }

  /// ⌥↩：在访达里用 Spotlight 搜当前查询（不需要额外授权）
  private func searchInFinder() {
    let text = searchText
    guard !text.isEmpty, !holdsSecret, NSWorkspace.shared.showSearchResults(forQueryString: text)
    else {
      return NSSound.beep()
    }
    close()
  }

  /// ⌃↩：不管有没有本地结果，用第一个兜底搜索搜当前查询
  private func searchWeb() {
    let text = searchText
    guard !text.isEmpty, !holdsSecret, let engine = WebSearch.primary(in: engines()),
      let url = URL(string: WebSearch.url(engine, text))
    else { return NSSound.beep() }
    open(url, nil)
  }

  /// Tab：把选中项（右键菜单里是被点的那一项）补进输入框（计算结果接着算、目录接着往下找、「关键词 」接着输搜索词）
  func complete(_ item: LauncherItem? = nil) {
    guard let item = item ?? selectedItem, let text = Self.completion(for: item) else { return }
    query = text
  }

  static func completion(for item: LauncherItem) -> String? {
    if let completion = item.completion { return completion }
    switch item.kind {
    case .app, .action, .url, .system: return item.title
    case .path:
      var isDirectory: ObjCBool = false
      let exists = FileManager.default.fileExists(atPath: item.target, isDirectory: &isDirectory)
      let path = (item.target as NSString).abbreviatingWithTildeInPath
      return exists && isDirectory.boolValue && !path.hasSuffix("/") ? path + "/" : path
    case .script: return item.arguments == nil ? item.title : nil
    case .search, .calculation, .clip, .prompt, .translate, .process, .ip, .reminder,
      .scriptResult:
      return nil
    }
  }

  /// 按住修饰键时选中行的副标题：说明松手前按 ↩ 会做什么；上了膛的换成确认提示
  func alternateSubtitle(for item: LauncherItem) -> String? {
    if let armed, armed.id == item.id { return armed.text }
    return switch alternate {
    case .none: nil
    case .command: commandReturnAction(for: item).map { "⌘↩ " + $0.title }
    case .option: finderSearchTitle.map { "⌥↩ " + $0 }
    case .control: webSearchTitle.map { "⌃↩ " + $0 }
    }
  }

  /// ↩ 做什么：底栏右侧的主动作和 ⌘K 菜单的第一行（名字随种类）
  func primaryAction(for item: LauncherItem) -> (title: String, symbol: String) {
    let confirming = armed?.id == item.id && armed?.commandKey == false
    if let request = commandRequest, [.app, .path, .process].contains(item.kind) {
      let verb = rowVerb(item, in: request)
      return ((confirming ? "确认" : "") + verb.title, verb.symbol)
    }
    return switch item.kind {
    case .app, .path:
      revealsOnReturn(item) ? ("在访达中显示", "folder") : ("打开", "arrow.up.forward.app")
    case .action:
      item.isStatusPreset ? ("进入状态屏", HotKeyAction.statusScreen.symbol) : ("运行", "command")
    case .system:
      confirming
        ? ("确认" + item.title, "exclamationmark.triangle")
        : ("运行", SystemCommand(rawValue: item.target)?.symbol ?? "power")
    case .url where AppCatalog.isSettingsPane(item.target): ("打开", "gearshape")
    case .url: ("打开网址", "safari")
    case .search: ("搜索", "magnifyingglass")
    case .prompt where item.target == Self.reminderHint: ("改一下再建", "pencil")
    case .prompt where item.target.hasPrefix(Self.choicePrefix): ("选这个", "text.cursor")
    case .prompt:
      item.target == FileSearch.accessTarget
        ? ("授权", "lock.open")
        : item.target == ExchangeRates.promptTarget
          ? ("填进示例", "text.cursor")
          : item.target.hasPrefix(ExchangeRates.suggestionPrefix)
            ? ("补全货币", "text.cursor") : ("补全关键词", "text.cursor")
    case .calculation, .ip: ("粘贴", "arrow.turn.down.left")
    case .clip: (item.target.isEmpty ? "打开" : "搜索", "doc.on.clipboard")
    case .translate: ("翻译", "character.bubble")
    case .process: ("结束", "stop.circle")
    case .reminder where item.target.isEmpty: ("建好提醒", "alarm")
    case .reminder:
      reminders().first { $0.id == item.target }?.isOn == true
        ? ("暂停", "pause.circle") : ("打开", "play.circle")
    case .script where item.arguments == nil && item.completion != nil: ("补全关键词", "text.cursor")
    // 参数没填够：↩ 只响提示音，副标题写着要填什么
    case .script where isMissingArguments(item): ("先填参数", "text.cursor")
    case .script: (confirming ? "确认运行" : "运行", "play")
    case .scriptResult:
      switch item.opens {
      case .url: ("打开", "safari")
      case .file: ("打开", "arrow.up.forward.app")
      case nil: ("粘贴", "arrow.turn.down.left")
      }
    }
  }

  /// ⌘↩ 做什么；没有就是 nil（网址没有第二个浏览器时也是 nil：副标题不写，按了只响提示音）
  /// 「关键词 空格」后参数没填够的那一行：↩ 只响提示音（底栏的 ↩ 不画成能按的主按钮）
  func isMissingArguments(_ item: LauncherItem) -> Bool {
    guard item.kind == .script, let arguments = item.arguments,
      let script = activeScripts.first(where: { $0.path == item.target })
    else { return false }
    return arguments.count < script.requiredCount || script.invalidChoice(arguments) != nil
  }

  func commandReturnAction(for item: LauncherItem) -> (title: String, symbol: String)? {
    let confirming = armed?.id == item.id && armed?.commandKey == true
    if let request = commandRequest, [.app, .process].contains(item.kind) {
      let verb = rowVerb(item, in: request)
      if verb == .kill { return (confirming ? "确认强制结束" : "强制结束", "xmark.octagon") }
      // 访达只能隐藏（hide 里列着它），不给强制退出
      guard verb != .forcequit, item.target != SystemCommands.finderPath else { return nil }
      return (confirming ? "确认强制退出" : "强制退出", "xmark.octagon")
    }
    if isWebLink(item) {
      return otherBrowsers.first.map { ("用「\(Self.appName($0))」打开", "safari") }
    }
    return switch item.kind {
    case .app, .path:
      revealsOnReturn(item) ? ("打开", "arrow.up.forward.app") : ("在访达中显示", "folder")
    case .scriptResult where item.payload != nil:
      switch item.opens {
      case .url: ("复制网址", "doc.on.doc")
      case .file: ("在访达中显示", "folder")
      case nil: ("只复制，不粘贴", "doc.on.doc")
      }
    case .calculation where item.payload != nil, .ip where item.payload != nil:
      ("只复制，不粘贴", "doc.on.doc")
    case .reminder where !item.target.isEmpty: ("在设置里编辑", "gearshape")
    case .script: ("在访达中显示", "folder")
    default: nil
    }
  }

  /// ⌘C 复制什么；内置动作、提示、cb / fy 那一行、进程、系统设置面板没有，⌘C 交给输入框
  func copyTitle(for item: LauncherItem) -> String? {
    switch item.kind {
    case .app, .path, .script: "复制路径"
    case .url where AppCatalog.isSettingsPane(item.target): nil
    case .url, .search: "复制网址"
    case .calculation: item.payload == nil ? nil : "复制结果"
    case .ip: item.payload == nil ? nil : "复制地址"
    case .scriptResult where item.payload == nil: nil
    case .scriptResult where item.copyText == nil && item.opens != nil:
      if case .url = item.opens { "复制网址" } else { "复制路径" }
    case .scriptResult: "复制结果"
    case .action, .system, .prompt, .clip, .translate, .process, .reminder: nil
    }
  }

  /// ⌥↩ / ⌃↩ 做什么：没有查询（或没有兜底搜索）时 nil
  private var finderSearchTitle: String? {
    let text = searchText
    return text.isEmpty || holdsSecret ? nil : "在访达里搜索「\(text)」"
  }

  private var webSearchTitle: String? {
    let text = searchText
    guard !text.isEmpty, !holdsSecret, let engine = WebSearch.primary(in: engines()) else {
      return nil
    }
    return "用 \(engine.name) 搜索「\(text)」"
  }

  /// 打开 App / 文件 / 网址 / 搜索页（app：用指定的 App 打开）：先收起，再交给系统在后台打开（NSWorkspace 同步的 open
  /// 要等 App 启动完才返回，面板会一直挂着）；打开成功才记使用（item 为 nil 的搜索页不记），打不开时面板已经收起，用刘海岛说
  private func open(_ url: URL, _ item: LauncherItem?, with app: URL? = nil) {
    let query = query  // 收起时查询会被清空
    close()
    let done: @Sendable (NSRunningApplication?, (any Error)?) -> Void = { [weak self] _, error in
      Task { @MainActor in
        guard let self else { return }
        if error == nil {
          if let item { self.usage.record(item, query: query) }
        } else {
          self.island?.show(
            "打不开「\(item?.title ?? url.absoluteString)」", detail: error?.localizedDescription,
            tone: .error)
        }
      }
    }
    if let app {
      NSWorkspace.shared.open(
        [url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(),
        completionHandler: done)
    } else {
      NSWorkspace.shared.open(
        url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: done)
    }
  }

  func click(_ item: LauncherItem) {
    showsActions = false
    if Style.isDoubleClick {
      execute(item)
    } else if let index = results.firstIndex(of: item) {
      if armed?.id != item.id { armed = nil }
      forgotten = nil
      selectionMotion = .glide
      selection = index
      userMovedSelection = true
    }
  }

  var selectedItem: LauncherItem? {
    results.indices.contains(selection) ? results[selection] : nil
  }

  // MARK: 收藏与常用（体检 A22 D13 B38）

  /// 能收藏的：记使用的那几类（App、内置动作、网址、文件、系统命令），带对象模式里的 App / 宗卷不算，
  /// 只在有钉图时才有的两个内置动作也不算（没钉图时还原不出来，收藏会自己消失）
  func canFavorite(_ item: LauncherItem) -> Bool {
    item.kind.isRecorded && commandRequest == nil
      && item.contentType?.conforms(to: .volume) != true
      && !(item.kind == .action && item.target.hasPrefix("pins-"))
  }

  func isFavorite(_ item: LauncherItem) -> Bool { usage.isFavorite(item) }

  /// 空查询里「常用」那一组的（收藏的不算）：⌘⌫ 能移除
  func isCommon(_ item: LauncherItem) -> Bool {
    guard isShowingRecent, item.kind.isRecorded, let index = results.firstIndex(of: item) else {
      return false
    }
    return index >= favoriteCount
  }

  /// ⌘D：加入 / 取消收藏；满 8 个时提示音 + 底栏说一声。空查询时列表跟着变，选中留在这一项上
  func toggleFavorite(_ item: LauncherItem) {
    guard canFavorite(item) else { return NSSound.beep() }
    let adding = !usage.isFavorite(item)
    guard usage.toggleFavorite(item, visible: adding ? favorites(builtIns).count : nil) else {
      NSSound.beep()
      return show(.warning("收藏最多 \(LauncherUsage.favoriteLimit) 个，先取消一个"))
    }
    show(.message(adding ? "已加入收藏" : "已取消收藏"))
    if isShowingRecent { refresh(keeping: item.id) }
  }

  /// ⌥⌘↑↓：空查询里选中的收藏和上一个 / 下一个换位置（⌘1–N 跟着固定下来）；不是收藏时不接这个键
  /// 和**看得见的**上一个 / 下一个换（藏着的收藏——这台还原不出来的——不挡着，换了看得出变化）
  private func moveFavorite(by offset: Int) -> Bool {
    guard isShowingRecent, let item = selectedItem, selection < favoriteCount else { return false }
    let neighbor = selection + offset
    if (0..<favoriteCount).contains(neighbor), usage.swapFavorites(item, results[neighbor]) {
      refresh(keeping: item.id)
    } else {
      NSSound.beep()
    }
    return true
  }

  /// 「常用」里 ⌘⌫：忘掉这一项的使用记录，底栏「已从常用中移除 · 撤销 ⌘Z」，⌘Z 原样放回（体检 B38）
  func forget(_ item: LauncherItem) {
    let entries = usage.forget(item)
    refresh(keeping: nil)
    forgotten = (item, entries)
    show(.undo("已从常用中移除"), spoken: "已从常用中移除，按 Command-Z 撤销")
  }

  func undoForget() {
    guard let forgotten else { return }
    usage.restore(forgotten.entries)
    self.forgotten = nil
    refresh(keeping: forgotten.item.id)
    Island.announce("已撤销移除")
  }

  /// 底栏就地提示（剪贴板底栏同一种，BarNotice），同时播报。⌘Y 预览开着时底栏被它盖住：另走刘海岛
  /// （岛自己会播报，同剪贴板；底栏照样设上，缩回预览后还看得到）
  private func show(_ notice: BarNotice, spoken: String? = nil) {
    noticeTask?.cancel()
    self.notice = notice
    if isQuickLooking, let island {
      switch notice {
      case .message(let text): island.show(text)
      case .warning(let text): island.show(text, tone: .warning)
      case .undo(let text):
        island.show(text, detail: "⌘Z 撤销", tone: .info, symbol: "minus.circle.fill")
      }
    } else {
      Island.announce(spoken ?? notice.text)
    }
    noticeTask = Task {
      try? await Task.sleep(for: .seconds(notice.seconds))
      guard !Task.isCancelled else { return }
      self.notice = nil
    }
  }

  // MARK: 快速查看、打开方式、废纸篓（体检 C7）

  /// ⌘Y：打开 / 缩回快速查看（选中的不是文件时只有提示音）
  func toggleQuickLook() {
    if isQuickLooking {
      isQuickLooking = false
      closeQuickLook(true)
    } else if let item = selectedItem, isFile(item) || Self.resultFile(item) != nil {
      isQuickLooking = true
      showsQuickLookContent = true
      openQuickLook()
    } else {
      NSSound.beep()
    }
  }

  /// 预览浮层收走了（缩回放完、点了外面、跟着启动器收起）：同步状态、拆掉预览
  func quickLookDidHide() {
    isQuickLooking = false
    showsQuickLookContent = false
  }

  /// 预览的文件：选中的不是文件时 nil（浮层里写「没有可预览的文件」）
  var quickLookURL: URL? {
    guard let item = selectedItem else { return nil }
    if let path = Self.resultFile(item) { return URL(filePath: path) }
    guard isFile(item) else { return nil }
    return URL(filePath: item.target)
  }

  /// 列表脚本给的文件结果（第三轮 B1）：⌘Y 快速查看它；不能选的（payload 是 nil）不算
  static func resultFile(_ item: LauncherItem) -> String? {
    guard item.kind == .scriptResult, item.payload != nil, case .file(let path) = item.opens else {
      return nil
    }
    return path
  }

  /// 右键菜单里的「快速查看」：先选中被点的那一行
  private func quickLook(_ item: LauncherItem) {
    if let index = results.firstIndex(of: item) { selection = index }
    if !isQuickLooking { toggleQuickLook() }
  }

  /// 移到废纸篓（能放回，按 D2「只确认不可撤销的」不二次确认）：刘海岛说一声，结果行原地删掉（settle）
  private func moveToTrash(_ item: LauncherItem) {
    Task {
      do {
        try await recycle(URL(filePath: item.target))
      } catch {
        island?.show("没能移到废纸篓", detail: error.localizedDescription, tone: .error)
        return
      }
      island?.show("已移到废纸篓「\(item.title)」", symbol: "trash.circle.fill")
      let index = selection
      withAnimation(Style.Motion.settle.animation(reduced: Style.reduceMotion)) {
        if isShowingRecent {
          search()
        } else {
          results.removeAll { $0.id == item.id }
        }
      }
      selection = min(index, max(results.count - 1, 0))
    }
  }

  /// 默认浏览器以外能开网页的 App（按 https 问 LaunchServices，不读网页）。
  /// ponytail: 登记了 https 的非浏览器 App 也会列出来，真碰到再按 bundle id 滤
  static func otherBrowsers() -> [URL] {
    guard let https = URL(string: "https:") else { return [] }
    let workspace = NSWorkspace.shared
    let resolved = { (url: URL) in url.resolvingSymlinksInPath().path }
    var seen = Set([workspace.urlForApplication(toOpen: https).map(resolved)].compactMap { $0 })
    return workspace.urlsForApplications(toOpen: https).filter {
      seen.insert(resolved($0)).inserted
    }
  }

  /// 能打开这种类型的 App：默认的排第一（标「默认」），最多 5 个；按类型问，不读文件本身
  static func applications(toOpen type: UTType) -> [(url: URL, isDefault: Bool)] {
    let workspace = NSWorkspace.shared
    let preferred = workspace.urlForApplication(toOpen: type)
    var seen = Set<String>()
    return ([preferred].compactMap { $0 } + workspace.urlsForApplications(toOpen: type))
      .filter { seen.insert($0.resolvingSymlinksInPath().path).inserted }
      .prefix(5)
      .map { ($0, $0 == preferred) }
  }

  /// App 的显示名（访达开着「显示所有扩展名」时去掉 .app）
  static func appName(_ url: URL) -> String {
    let name = FileManager.default.displayName(atPath: url.path)
    return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
  }

  private var otherBrowsers: [URL] {
    if let browserCache { return browserCache }
    let found = browsers()
    browserCache = found
    return found
  }

  /// 「用 X 打开」的 App：网址是默认浏览器以外的浏览器，文件是能开这种类型的 App
  private func openers(for item: LauncherItem) -> [(url: URL, isDefault: Bool)] {
    if isWebLink(item) { return otherBrowsers.map { ($0, false) } }
    guard isFile(item), let type = item.contentType else { return [] }
    if let cached = applicationCache[type.identifier] { return cached }
    let found = applications(type)
    applicationCache[type.identifier] = found
    return found
  }

  // MARK: 键盘

  func handleCommand(_ selector: Selector) -> Bool {
    if showsActions { return handleMenuCommand(selector) }
    if review != nil { return handleReviewCommand(selector) }
    if output != nil { return handleOutputCommand(selector) }
    switch selector {
    case #selector(NSResponder.moveUp(_:)): move(by: -1)
    case #selector(NSResponder.moveDown(_:)): move(by: 1)
    // ⌥↩ 来的是 insertNewlineIgnoringFieldEditor:、⌃↩ 是 insertLineBreak:；⌃O 这类别的键绑定也会发这两个，
    // 所以要确认真是回车键，再按当时按住的修饰键分（别的键绑定吞掉，不做事）
    case #selector(NSResponder.insertNewline(_:)),
      #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
      #selector(NSResponder.insertLineBreak(_:)):
      guard Style.isReturnKey, let event = NSApp.currentEvent else { return true }
      if event.modifierFlags.contains(.option) {
        searchInFinder()
      } else if event.modifierFlags.contains(.control) {
        searchWeb()
      } else if let selectedItem {
        execute(selectedItem)
      }
    case #selector(NSResponder.insertTab(_:)):
      complete()  // 没得补也吞掉，不让焦点跳到别的控件
    // →：光标在搜索词末尾、有选中项时打开动作菜单（同剪贴板），否则照常往右移光标
    case #selector(NSResponder.moveRight(_:))
    where selectedItem != nil && Self.caretAtEnd(of: query):
      toggleActions()
    case #selector(NSResponder.cancelOperation(_:)):
      forgotten = nil
      if isQuickLooking {
        toggleQuickLook()  // 先缩回预览
      } else if armed != nil {
        armed = nil  // 先撤掉上膛，再清空搜索
      } else {
        guard !query.isEmpty else { return false }  // 没有查询：交给窗口关闭
        query = ""
      }
    default: return false
    }
    return true
  }

  /// 看全文 / 输出那一页的 ↑↓、PageUp / PageDown：滚正文（是这几个键就接了，返回 true）
  private func scrollsPage(_ selector: Selector) -> Bool {
    let step: Int
    switch selector {
    case #selector(NSResponder.moveUp(_:)): step = -1
    case #selector(NSResponder.moveDown(_:)): step = 1
    case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)): step = -2
    case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)): step = 2
    default: return false
    }
    pageScroll = PageScroll(step: step, tick: pageScroll.tick + 1)
    return true
  }

  /// 看脚本全文那一页：↩ 运行、Esc 回去，↑↓ / PageUp / PageDown 滚正文，打字照常（会回到结果）
  private func handleReviewCommand(_ selector: Selector) -> Bool {
    switch selector {
    // 按住 ↩ 的自动连发不算：打开这一页的那一下连发过来不能直接放行
    case #selector(NSResponder.insertNewline(_:)):
      if Style.isReturnKey, !Style.isKeyRepeat { approveReview() }
    case #selector(NSResponder.cancelOperation(_:)): cancelReview()
    case _ where scrollsPage(selector): break
    case #selector(NSResponder.insertTab(_:)),
      #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
      #selector(NSResponder.insertLineBreak(_:)):
      break
    default: return false
    }
    return true
  }

  /// 全文输出那一页：↩ 粘贴、Esc 返回（还在跑就停掉），↑↓ / PageUp / PageDown 滚正文，打字照常（会回到结果）
  private func handleOutputCommand(_ selector: Selector) -> Bool {
    switch selector {
    // 按住 ↩ 的自动连发不算：跑得快的脚本跑完时连发过来的那一下不能直接粘贴出去
    case #selector(NSResponder.insertNewline(_:)):
      if Style.isReturnKey, !Style.isKeyRepeat { pasteOutput() }
    case #selector(NSResponder.cancelOperation(_:)): closeOutput()
    case _ where scrollsPage(selector): break
    case #selector(NSResponder.insertTab(_:)),
      #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
      #selector(NSResponder.insertLineBreak(_:)):
      break
    default: return false
    }
    return true
  }

  /// 搜索框的光标在最后（没有选中文字）；拿不到字段编辑器时（单测）看有没有字（同剪贴板）
  private static func caretAtEnd(of text: String) -> Bool {
    guard let editor = NSApp.currentEvent?.window?.firstResponder as? NSTextView,
      editor.isFieldEditor
    else { return text.isEmpty }
    let selection = editor.selectedRange()
    return selection.length == 0 && selection.location == (editor.string as NSString).length
  }

  /// 动作菜单开着（和剪贴板一致）：↑↓ 选、↩ 执行、Esc 只关菜单；菜单里标着的 ⇥ ⌥↩ ⌃↩ 和 ⌘ 键一样先关菜单再照常做，
  /// ⌃O 这类也发换行命令的别的键吞掉（不往过滤框里插换行），其余（左右移光标、删字）交还输入框
  private func handleMenuCommand(_ selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.moveUp(_:)): moveAction(by: -1)
    case #selector(NSResponder.moveDown(_:)): moveAction(by: 1)
    case #selector(NSResponder.insertNewline(_:)): runSelectedAction()
    case #selector(NSResponder.cancelOperation(_:)): showsActions = false
    case #selector(NSResponder.moveLeft(_:)) where actionQuery.isEmpty: showsActions = false
    case #selector(NSResponder.insertTab(_:)):
      showsActions = false
      complete()
    case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
      #selector(NSResponder.insertLineBreak(_:)):
      guard Style.isReturnKey else { break }
      showsActions = false
      return handleCommand(selector)
    default: return false
    }
    return true
  }

  func handleKeyEquivalent(_ event: NSEvent) -> Bool {
    // 不看大写锁定、fn 和数字键盘标志（方向键带着后两个），和 OverlayPanel 的 ⌘W 同一套判断
    let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
    let key = Int(event.keyCode)
    // 看脚本全文那一页：⌘1–9、⌘Y、⌘D 这些对着藏在后面的行的键都不做，编辑搜索框的（剪切、复制、粘贴、全选、撤销）照常
    if review != nil {
      let editing = [kVK_ANSI_X, kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_A, kVK_ANSI_Z]
      return !(modifiers == .command && editing.contains(key))
        && !(modifiers == [.command, .shift] && key == kVK_ANSI_Z)
    }
    // 全文输出那一页：⌘C 全部复制（搜索框里选着字时交还输入框）、⌘R 重跑
    if output != nil {
      guard modifiers == .command else { return false }
      if key == kVK_ANSI_R {
        // 按住不放的自动连发不算：一秒起十几个进程（第 1 批评审）
        if !event.isARepeat { rerunOutput() }
        return true
      }
      guard key == kVK_ANSI_C, !Self.fieldHasSelection(event) else { return false }
      copyOutput()
      return true
    }
    let handled: Bool
    switch modifiers {
    case .command where key == kVK_ANSI_K:
      toggleActions()
      return true
    case .command: handled = handleCommandKey(event)
    case [.command, .option] where key == kVK_UpArrow || key == kVK_DownArrow:
      handled = moveFavorite(by: key == kVK_UpArrow ? -1 : 1)
    case [.command, .shift] where key == kVK_ANSI_C:
      guard let item = selectedItem, isWebLink(item), !Self.fieldHasSelection(event) else {
        return false
      }
      copy(item, .markdown)
      handled = true
    default: return false
    }
    // 做了就收起动作菜单；没做的（过滤框里的复制、粘贴）菜单留着
    if handled { showsActions = false }
    return handled
  }

  private static func fieldHasSelection(_ event: NSEvent) -> Bool {
    ((event.window?.firstResponder as? NSTextView)?.selectedRange().length ?? 0) > 0
  }

  private func handleCommandKey(_ event: NSEvent) -> Bool {
    switch Int(event.keyCode) {
    case kVK_Return:
      if let item = selectedItem { commandReturn(item) }
    // 「常用」里 ⌘⌫：忘掉这一项（有查询、或 ⌘K 过滤框里有字时 ⌘⌫ 照常删到行首）；收藏上没有这个动作，响提示音
    case kVK_Delete where isShowingRecent && (!showsActions || actionQuery.isEmpty):
      if let item = selectedItem, isCommon(item) { forget(item) } else { NSSound.beep() }
    // ⌘Z：撤销刚才的移除；没有可撤的、或 ⌘K 过滤框里有字时交还输入框自己的撤销
    case kVK_ANSI_Z
    where query.isEmpty && forgotten != nil && (!showsActions || actionQuery.isEmpty):
      undoForget()
    case kVK_ANSI_C where !Self.fieldHasSelection(event):
      guard let item = selectedItem, copyTitle(for: item) != nil else { return false }
      copy(item)
    case kVK_ANSI_D:
      guard let item = selectedItem, canFavorite(item) else { return false }
      toggleFavorite(item)
    case kVK_ANSI_Y:
      toggleQuickLook()
    case kVK_ANSI_E:
      guard let item = selectedItem, let script = script(of: item) else { return false }
      edit(script)
    case kVK_ANSI_Comma:
      close()
      openSettings()
    default:
      guard let digit = Self.digitKeys.firstIndex(of: Int(event.keyCode)) else { return false }
      // 列表脚本正在重跑时的结果行：⌘N 会落到新结果的第一条上，不执行
      if digit < results.count, !isPending(results[digit]) {
        execute(results[digit])
      } else if digit < results.count {
        NSSound.beep()
      }
    }
    return true
  }

  /// ⌘↩：App / 文件在访达中显示（find 搜到的文件反过来是打开），计算结果只复制，网址用第二个浏览器打开
  /// （没有就提示音，体检 D7）
  func commandReturn(_ item: LauncherItem) {
    if let request = commandRequest, [.app, .process].contains(item.kind) {
      let verb = rowVerb(item, in: request)
      if verb == .kill || (verb != .forcequit && item.target != SystemCommands.finderPath) {
        runTarget(item, verb, commandKey: true)
      }
      return
    }
    if isWebLink(item) {
      guard let browser = otherBrowsers.first, let url = URL(string: item.target) else {
        return NSSound.beep()
      }
      return open(url, item.kind == .url ? item : nil, with: browser)
    }
    switch item.kind {
    case .app, .path:
      if revealsOnReturn(item) { return open(URL(filePath: item.target), item) }
      close()
      NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: item.target)])
    case .scriptResult where item.payload != nil:
      // 文件结果在访达中显示（同文件行）；别的只复制 ↩ 会打开 / 粘贴的那个（text.copy 归 ⌘C）
      if isPending(item) { return NSSound.beep() }
      guard case .file(let path) = item.opens else {
        var plain = item
        plain.copyText = nil
        return copy(plain)
      }
      close()
      NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
    case .calculation where item.payload != nil, .ip where item.payload != nil:
      copy(item)
    case .reminder where !item.target.isEmpty:
      close()
      openReminder(item.target)
    case .script:
      close()
      NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: item.target)])
    default:
      NSSound.beep()  // 以前吞掉这个键、什么都不响
    }
  }

  enum CopyFormat {
    /// 路径 / 网址 / 计算结果（⌘C）
    case value
    /// [标题](网址)（⇧⌘C）
    case markdown
    case title
    /// 计算结果 ⌘K 里的「复制原始数字」「复制十六进制」…（体检 D11）
    case calculation(Calculator.Copy)
  }

  /// ⌘C：复制路径 / 网址 / 计算结果（⌘↩ 的计算结果也走这里）；网址另有 Markdown 链接、标题。面板同时收起，用刘海说
  /// 复制了什么；这些是本 App 给出的新文字，同时记进剪贴板历史（mac-native §5）
  func copy(_ item: LauncherItem, _ format: CopyFormat = .value) {
    // 列表脚本正在按新输入重跑：看得见的是上一次的结果，不拷它（同 ↩ 等结果的那一处，第三轮评审）
    if isPending(item) { return NSSound.beep() }
    rememberCurrencies(item)
    let text: String
    let title: String?
    switch format {
    // 列表结果：text.copy 写了的复制它，写了 url / path 的复制网址 / 路径（第三轮 B1 B2）
    case .value:
      (text, title) = (
        item.copyText ?? item.opens?.text ?? item.payload ?? item.target, copyTitle(for: item)
      )
    case .markdown:
      (text, title) = (Self.markdownLink(title: item.title, url: item.target), "复制为 Markdown 链接")
    case .title: (text, title) = (item.title, "复制标题")
    case .calculation(let copy): (text, title) = (copy.text, copy.title)
    }
    Paster.write(string: text, record: true)
    close()
    guard let title else { return }
    let isPath = (item.kind == .app || item.kind == .path) && copyTitle(for: item) == title
    island?.show(
      "已" + title,
      detail: isPath ? (text as NSString).abbreviatingWithTildeInPath : Island.excerpt(text))
  }

  /// [标题](网址)：标题里的方括号、网址里的空格和右括号转义，粘进 Markdown 不断链
  static func markdownLink(title: String, url: String) -> String {
    let title = title.replacing("[", with: "\\[").replacing("]", with: "\\]")
    let url = url.replacing(" ", with: "%20").replacing(")", with: "%29")
    return "[\(title)](\(url))"
  }

  private func move(by offset: Int) {
    guard !results.isEmpty else { return }
    armed = nil
    forgotten = nil
    selectionMotion = Style.isKeyRepeat ? .instant : .snap
    selection = (selection + offset + results.count) % results.count
    userMovedSelection = true
  }

  private static let digitKeys = [
    kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8,
    kVK_ANSI_9,
  ]

  // MARK: ⌘K 动作菜单 / 右键菜单

  /// 选中项的动作（⌘K）
  var actions: [ActionMenu.Item] { selectedItem.map(actions(for:)) ?? [] }

  /// 一项能做的全部动作（N8；右键菜单同一份，体检 C8）：主动作 ↩ 在最前，每行写上键位，执行的和按键是同一段代码。
  /// 分节：打开 ｜ 用别的 App 打开（脚本是编辑、改别名、关掉）｜ 复制 ｜ 搜索框（补全、⌥↩、⌃↩）｜ 收藏、移除、废纸篓
  func actions(for item: LauncherItem) -> [ActionMenu.Item] {
    var actions: [ActionMenu.Item] = []
    func add(
      _ title: String, _ symbol: String?, _ shortcut: String? = nil, image: NSImage? = nil,
      detail: String? = nil, section: Int, destructive: Bool = false,
      _ run: @escaping () -> Void
    ) {
      actions.append(
        ActionMenu.Item(
          title: title, symbol: symbol, image: image, detail: detail, shortcut: shortcut,
          id: "\(actions.count)", section: section, isDestructive: destructive, run: run))
    }
    // 0 打开
    let primary = primaryAction(for: item)
    add(
      primary.title, primary.symbol, "↩", section: 0,
      destructive: isDangerous(item, commandKey: false)
    ) { [unowned self] in execute(item) }
    // 网址的 ⌘↩ 就是下面浏览器里的第一个
    if !isWebLink(item), let secondary = commandReturnAction(for: item) {
      add(
        secondary.title, secondary.symbol, "⌘↩", section: 0,
        destructive: isDangerous(item, commandKey: true)
      ) { [unowned self] in commandReturn(item) }
    }
    if isFile(item) || Self.resultFile(item) != nil {
      add("快速查看", "eye", "⌘Y", section: 0) { [unowned self] in quickLook(item) }
    }
    // 1 脚本（第二轮 D1）：发现一条不对劲，就地改它、换个词、关掉；自带的复制一份成自己的。
    // 脚本没有「用别的 App 打开」，接在打开后面，不用滚就看得到
    if let script = script(of: item) {
      // 自带的在 App 包里（改了会被更新盖掉、坏签名）：⌘E 是复制一份成自己的再改
      if script.isBundled {
        add("复制一份到我的脚本", "plus.square.on.square", "⌘E", section: 1) { [unowned self] in
          edit(script)
        }
      } else {
        add("编辑脚本", "pencil", "⌘E", section: 1) { [unowned self] in edit(script) }
      }
      add("改别名…", "keyboard", section: 1) { [unowned self] in
        close()
        openCommandSettings(LauncherCommands.scriptID(script))
      }
      add("关掉这条命令", "nosign", section: 1) { [unowned self] in disable(script) }
    }
    // 1 用别的 App 打开：网址是默认浏览器以外的浏览器（第一个是 ⌘↩），文件是能开这种类型的 App（默认的排第一）
    let web = isWebLink(item)
    for (index, app) in openers(for: item).enumerated() {
      add(
        "用「\(Self.appName(app.url))」打开", nil, web && index == 0 ? "⌘↩" : nil,
        image: LauncherIcons.icon(for: app.url.path), detail: app.isDefault ? "默认" : nil,
        section: 1
      ) { [unowned self] in
        if web {
          if let url = URL(string: item.target) {
            open(url, item.kind == .url ? item : nil, with: app.url)
          }
        } else {
          open(URL(filePath: item.target), item, with: app.url)
        }
      }
    }
    // 2 复制（计算结果、ip 的 ⌘C 和 ⌘↩ 一样，不重复列）；复制路径和剪贴板 ⌘K 的「复制路径」同一个符号 link（mac-whisker §3）
    // 列表结果的 ⌘↩ 是在访达中显示（文件）、或者另给了 ⌘C 复制的（text.copy）：⌘C 另列
    let copiesOnCommandReturn =
      [.calculation, .ip].contains(item.kind)
      || (item.kind == .scriptResult && Self.resultFile(item) == nil && item.copyText == nil)
    if !copiesOnCommandReturn, let title = copyTitle(for: item) {
      let symbol =
        [.app, .path, .script].contains(item.kind) || Self.resultFile(item) != nil
        ? "link" : "doc.on.doc"
      add(title, symbol, "⌘C", section: 2) { [unowned self] in copy(item) }
    }
    if web {
      add("复制为 Markdown 链接", "text.badge.plus", "⇧⌘C", section: 2) { [unowned self] in
        copy(item, .markdown)
      }
      add("复制标题", "text.quote", section: 2) { [unowned self] in copy(item, .title) }
    }
    // 计算结果：原始数字（不分组、不带单位）、别的进制（体检 D11）
    if item.kind == .calculation {
      for extra in Calculator.result(for: item.target, rates: rates)?.copies ?? [] {
        add(extra.title, "doc.on.doc", detail: extra.text, section: 2) { [unowned self] in
          copy(item, .calculation(extra))
        }
      }
    }
    // 3 搜索框：提示行、要参数的脚本那一行的主动作就是补全
    let completesOnReturn =
      item.kind == .prompt
      || (item.kind == .script && item.arguments == nil && item.completion != nil)
    if !completesOnReturn, Self.completion(for: item) != nil {
      add("补全到搜索框", "arrow.right.to.line", "⇥", section: 3) { [unowned self] in
        complete(item)
      }
    }
    if let title = finderSearchTitle {
      add(title, "doc.text.magnifyingglass", "⌥↩", section: 3) { [unowned self] in
        searchInFinder()
      }
    }
    if let title = webSearchTitle {
      add(title, "globe", "⌃↩", section: 3) { [unowned self] in searchWeb() }
    }
    // 4 收藏、移除、废纸篓
    if canFavorite(item) {
      let favorite = isFavorite(item)
      add(favorite ? "取消收藏" : "加入收藏", favorite ? "star.slash" : "star", "⌘D", section: 4) {
        [unowned self] in toggleFavorite(item)
      }
    }
    if isCommon(item) {
      add("从常用中移除", "clock.badge.xmark", "⌘⌫", section: 4) { [unowned self] in forget(item) }
    }
    if isFile(item) {
      add("移到废纸篓", "trash", section: 4, destructive: true) { [unowned self] in
        moveToTrash(item)
      }
    }
    return actions
  }

  /// 选中的是一条脚本命令（不是列表脚本给的结果行）
  private func script(of item: LauncherItem) -> ScriptCommand? {
    guard item.kind == .script else { return nil }
    return activeScripts.first { $0.path == item.target }
  }

  /// ⌘E / ⌘K「编辑脚本」：收起，用编辑器打开；自带的复制一份到我的脚本再打开（同时关掉自带那条）
  private func edit(_ script: ScriptCommand) {
    close()
    if script.isBundled { copyBundledScript(script) } else { editScript(script) }
  }

  /// ⌘K「关掉这条命令」：从搜索里拿掉（就是 设置 › 启动器「命令和别名」里那个开关），启动器留着、重搜；岛上带「撤销」
  func disable(_ script: ScriptCommand) {
    let id = LauncherCommands.scriptID(script)
    setCommandOn(id, false)
    search()
    island?.show(
      "已关掉「\(script.title)」", detail: "设置 › 启动器「命令和别名」里能再打开",
      actions: [
        Island.Action("撤销") { [weak self] in
          guard let self else { return }
          setCommandOn(id, true)
          // 收起着就不搜（留着的查询可能正好会跑一个列表脚本）；下次呼出自己会搜
          if isShown { search() }
        }
      ])
  }

  /// 按 actionQuery 过滤（和剪贴板的两个菜单同一个 ActionMenu.filter：子串 + 中文标题的拼音前缀）
  var filteredActions: [ActionMenu.Item] { ActionMenu.filter(actions, query: actionQuery) }

  /// ⌘K / 底栏「动作」：没有选中项时不打开。⌘Y 预览开着时先缩回它：菜单画在被预览盖住的启动器里，
  /// 不然搜索框悄悄变成过滤动作、↑↓ 改的是看不见的菜单
  func toggleActions() {
    guard showsActions || selectedItem != nil, review == nil, output == nil else { return }
    if isQuickLooking { toggleQuickLook() }
    showsActions.toggle()
  }

  private func moveAction(by offset: Int) {
    let count = filteredActions.count
    guard count > 0 else { return }
    actionSelection = (actionSelection + offset + count) % count
  }

  private func runSelectedAction() {
    let actions = filteredActions
    guard actions.indices.contains(actionSelection) else { return NSSound.beep() }
    run(actions[actionSelection])
  }

  /// 先关菜单再执行：执行里要改查询（补全）、收起面板
  func run(_ action: ActionMenu.Item) {
    showsActions = false
    action.run()
  }
}
