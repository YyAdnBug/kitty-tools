// 插件的声明（2026-11-17 插件页改版，拍板页 https://claude.ai/artifact/FddFbxDbUETWmu2x7asZQv「全部按推荐」，PLAN §10「插件页改版」）：
// 每个插件归哪一组（A2）、要哪些授权和各自为什么要（C1：结构化，各自现查这台给没给）、添加状态跟不跟同步（F2）、
// 介绍页的「能做什么」「怎么用」「后台」（A5）。「全部插件」页、介绍页、插件自己页的「权限」组、同步留在本机的键
// （SettingsSync.localKeys）都读这里；新加插件在这里补齐（PluginTests 查每个插件都写了）。

import Foundation

/// 插件要的一项授权：哪一种、为什么要（介绍页和插件页「权限」组那一行的说明）、什么时候才要
struct PluginPermission {
  let kind: Permissions.Kind
  let reason: LocalizedStringResource
  /// 打开这个偏好（Bool，没存过 = 关）才要；nil = 添加了就要
  var option: String? = nil

  /// 此刻缺不缺：要它（添加了就要，或开关开着）、而且这台确定没给（查不了的不算缺）
  func isMissing(isOn: (String) -> Bool, granted: (Permissions.Kind) -> Bool?) -> Bool {
    (option.map(isOn) ?? true) && granted(kind) == false
  }
}

extension Feature {
  /// 「全部插件」页的分组（拍板 A2：按用途；组内按 Feature 的先后，空的组不画）。「键盘与鼠标」是拍板页上预留的，
  /// 2026-11-17 平滑滚动先来、建了这一组
  enum PluginGroup: CaseIterable {
    case notesAndReminders, desktop, keyboardAndMouse, sleepAndScreen

    var title: LocalizedStringResource {
      switch self {
      case .notesAndReminders: "记录与提醒"
      case .desktop: "桌面"
      case .keyboardAndMouse: "键盘与鼠标"
      case .sleepAndScreen: "睡眠与屏幕"
      }
    }

    /// 这一组里这台系统上有的插件（按 Feature 的先后）
    var plugins: [Feature] {
      Feature.allCases.filter { $0.isPlugin && $0.isAvailable && $0.pluginGroup == self }
    }
  }

  /// 归哪一组；不是插件的 nil
  var pluginGroup: PluginGroup? {
    switch self {
    case .notes, .reminders: .notesAndReminders
    case .launchpad, .dockPreview, .finderMenu, .island: .desktop
    case .smoothScroll, .appShortcuts, .keyRemapping, .snippetExpand: .keyboardAndMouse
    case .statusScreen, .keepAwake, .bluetoothSnooze: .sleepAndScreen
    default: nil
    }
  }

  /// 要的授权（拍板 C1）。只列这个插件自己要的；「打开某个开关才要」的写 option
  @MainActor var pluginPermissions: [PluginPermission] {
    switch self {
    case .statusScreen:
      [PluginPermission(kind: .accessibility, reason: "进入时拦住键盘鼠标；没有它进不了状态屏")]
    case .dockPreview:
      [
        PluginPermission(kind: .accessibility, reason: "知道鼠标停在哪个图标上，列出、切换和关掉窗口；没有它用不了"),
        PluginPermission(kind: .screenRecording, reason: "截窗口的缩略图；没有它只列窗口的名字"),
      ]
    case .finderMenu:
      [
        PluginPermission(kind: .finderExtension, reason: "系统要你自己打开一次访达扩展，右键里才会出现这几项"),
        PluginPermission(
          kind: .accessibility, reason: "打开「⌘X 剪切、⌘V 移动」时接住访达里的这两个键", option: Prefs.finderMenuKeys),
      ]
    case .bluetoothSnooze:
      [PluginPermission(kind: .bluetooth, reason: "开关蓝牙；没有它这个插件什么都不做")]
    case .smoothScroll:
      [PluginPermission(kind: .accessibility, reason: "接住鼠标滚轮再滑出去；没有它用不了")]
    case .appShortcuts:
      [PluginPermission(kind: .accessibility, reason: "知道那个键有没有按住、读当前 App 的菜单；没有它用不了")]
    case .snippetExpand:
      [PluginPermission(kind: .accessibility, reason: "认出你打的关键词，再把它换成片段的内容；没有它用不了")]
    case .island:
      [
        PluginPermission(kind: .calendar, reason: "打开「下一个日程」时读日历", option: Prefs.islandNextEvent),
        PluginPermission(
          kind: .accessibility, reason: "打开「音量和亮度」时接管那五个键", option: Prefs.islandKeyLevels),
        PluginPermission(
          kind: .automation, reason: "正在播放读不到时，控制「音乐」「Spotify」的播放", option: Prefs.islandNowPlaying),
      ]
    default: []
    }
  }

  /// 添加着时此刻缺的授权（「全部插件」那一行的「要授权」、插件页「权限」组排到最上面，拍板 C2）；没添加的不算缺。
  /// 查授权要跨进程问系统：列表这种常重画的地方在页面出现、设置窗重新当 key 时查一次存起来，别在每次画行时调
  @MainActor func missingPermissions(_ defaults: UserDefaults = .standard) -> [PluginPermission] {
    guard isOn else { return [] }
    return pluginPermissions.filter {
      $0.isMissing(isOn: defaults.bool(forKey:), granted: \.isGranted)
    }
  }

  /// 添加状态跟不跟同步（拍板 F2）：一添加就要这台弹授权框、去系统设置打开的（程序坞预览、访达右键、睡眠关蓝牙、平滑滚动、
  /// App 快捷键、片段展开——同步
  /// 过去会在那台凭空弹框；平滑滚动还跟这台接没接鼠标有关），和跟这台的屏幕、触控板有关的（启动台，连同它整页的设置）只在这台。
  /// 状态屏只在进入时才要辅助功能，跟着同步
  var syncsAddition: Bool {
    ![
      .launchpad, .dockPreview, .finderMenu, .bluetoothSnooze, .smoothScroll, .appShortcuts,
      .keyRemapping, .snippetExpand,
    ]
    .contains(self)
  }

  /// 介绍页「能做什么」：两三条
  var pluginPoints: [LocalizedStringResource] {
    switch self {
    case .notes:
      Self.points(
        "快速记一条，记完就收起来", "屏幕边缘的那一叠：鼠标靠过去就扇开，点开就能改",
        "Markdown 样式、任务清单、行内图片；能导出导入、几台 Mac 同步")
    case .reminders:
      Self.points(
        "一次、每天、每周、每月，或每隔一阵提醒一次", "到点在刘海岛、屏幕边框或全屏提醒你，能稍后再响",
        "启动器里打一句话就能建一条")
    case .statusScreen:
      Self.points(
        "离开电脑时盖住所有屏幕，显示「马上回来」这类告示", "拦住键盘鼠标，擦屏幕、孩子乱按都不怕；按住 Esc 退出",
        "有哪些状态、各是什么样子都能自己改")
    case .launchpad:
      Self.points("全屏的 App 图标网格：翻页、搜索、拖成文件夹", "触控板捏合或触发角打开")
    case .dockPreview:
      Self.points("鼠标停在程序坞的 App 图标上，弹出它所有窗口的缩略图", "点一张切过去，悬停点 ✕ 关掉；按 ⌘Tab 时也能显示")
    case .finderMenu:
      Self.points(
        "在访达里右键：新建文件、拷贝路径、用指定的 App 打开", "移动、复制到常用的位置，压缩和解压",
        "能在访达里用 ⌘X 剪切、⌘V 移动")
    case .keepAwake:
      Self.points("手动开一段：无限期、几小时，或到某一刻", "按时段自动开，比如工作日 9:00–18:00", "可以只防系统睡眠、让屏幕照常熄")
    case .bluetoothSnooze:
      Self.points("合上盖子睡下去时关掉蓝牙，放进包里不会被蓝牙鼠标、键盘弄醒", "醒来时只打开睡前自己关掉的蓝牙；接着外接显示器时不关")
    case .smoothScroll:
      Self.points(
        "普通鼠标的滚轮像触控板那样滑着滚；滑多久、一格滚多远都能调", "鼠标单独反向（妙控鼠标也行），触控板不变",
        "在游戏、虚拟机这类自己管滚轮的 App 里自动照原样，也能自己加")
    case .appShortcuts:
      Self.points(
        "在任何 App 里单独按住 ⌘ 一会儿，弹出它菜单里的全部快捷键，按菜单分组；按哪个键能换成 ⌥ ⌃ ⇧",
        "按着那个键再按别的键，这一下照常给 App；点一行直接执行",
        "点一下搜索框能留住，打字搜菜单里的名字；启动器里打字也搜得到当前 App 的菜单项，没有快捷键的也算")
    case .keyRemapping:
      Self.points("为每把键盘分别选择源键和目标键", "支持 F1–F24 和苹果的 🌐 Globe / Fn")
    case .snippetExpand:
      Self.points(
        "给剪贴板里的片段设一个关键词，比如 ;mail，在任何 App 里打出它就换成片段的内容",
        "日期、剪贴板、光标停在哪这些占位符照样展开；带填空的会先打开剪贴板面板问你",
        "密码框、密码管理器里不展开；中文输入法正在打拼音时也不展开")
    case .island:
      Self.points(
        "点刘海叫出快捷动作和最近的提示", "录屏计时、提醒倒数、正在播放的歌挂在刘海两边", "能另外打开下一个日程、音量和亮度")
    default: []
    }
  }

  /// 介绍页「怎么用」那一句（快捷键另外按动作自动列）
  var pluginHowTo: LocalizedStringResource? {
    switch self {
    case .notes: "屏幕边缘的那一叠一直在；菜单栏、主界面和启动器里也有"
    case .reminders: "启动器里打一句话，或在菜单栏、主界面里新建"
    case .statusScreen: "从菜单栏、主界面或启动器进入"
    case .launchpad: "触控板捏合、触发角，或从菜单栏、启动器打开"
    case .dockPreview: "添加后自己工作：鼠标停在程序坞的图标上"
    case .finderMenu: "添加后在访达里右键；第一次要在系统设置里打开访达扩展"
    case .keepAwake: "菜单栏、主界面，或在启动器里打「awake 2小时」"
    case .bluetoothSnooze: "添加后自己工作，没有快捷键和菜单"
    case .smoothScroll: "添加后拨鼠标滚轮就是；按住 ⌥ 滚动临时不平滑，按住 ⇧ 左右滚"
    case .appShortcuts: "单独按住 ⌘ 约 1 秒（按哪个键、多久都能改）；不想长按的话在快捷键页另设一个组合"
    case .keyRemapping: "选中键盘，再添加一条映射规则"
    case .snippetExpand: "在剪贴板面板里新建片段时填上关键词，已有的片段在 ⌘K 里选「关键词…」"
    case .island: "点刘海、指针停在刘海上，或用快捷键打开"
    default: nil
    }
  }

  /// 介绍页「后台」那一行：添加着时在后台做什么
  var pluginBackground: LocalizedStringResource? {
    switch self {
    case .notes: "屏幕边缘一条细药丸；开着同步时跟着合"
    case .reminders: "等着下一条提醒；一条都没有时什么都不跑"
    case .statusScreen: "没进入时什么都不跑"
    case .launchpad: "看着触控板捏合和触发角，装卸 App 时重扫一遍"
    case .dockPreview: "看着程序坞；鼠标停在图标上才截缩略图"
    case .finderMenu: "只在你右键时动；打开了「⌘X 剪切、⌘V 移动」才看着按给访达的这两个键，别的键不看、不记"
    case .keepAwake: "开着时让系统别睡；没开时什么都不跑"
    case .bluetoothSnooze: "等着电脑睡下去；醒来时只打开睡前自己关掉的蓝牙"
    case .smoothScroll: "接住鼠标滚轮，在单独一条线程上滑出去；不碰触控板，没在滚时什么都不做"
    case .appShortcuts: "看着设的那个键有没有单独按住；按够了、或者在启动器里打字时才读一次前台 App 的菜单，启动器收起半分钟后丢掉"
    case .keyRemapping: "映射交给系统做，不看你按了什么键；只在键盘连上、断开和电脑醒来时核对一遍"
    case .snippetExpand:
      "在单独一条线程上看着打的字：只在内存里留最近十几个字用来比对关键词，不存盘、不上传、不写进日志，切换 App 或点一下鼠标就清空。一条片段都没设关键词时完全不听键盘"
    case .island:
      "看着指针有没有停在刘海上；打开了系统提示才听电源、耳机、网络，打开了正在播放才起一个读播放信息的小进程，打开了下一个日程才读日历，打开了音量和亮度才接那五个键。不添加时提示照常弹"
    default: nil
    }
  }

  /// switch 的分支是数组字面量时只有第一个分支的字被抽进目录（同元组，TRANSLATION.md 二）：经这个收参数的小函数传
  private static func points(
    _ first: LocalizedStringResource, _ second: LocalizedStringResource,
    _ third: LocalizedStringResource? = nil
  ) -> [LocalizedStringResource] {
    [first, second] + (third.map { [$0] } ?? [])
  }
}
