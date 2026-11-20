// 设置 › 刘海岛的六个子页（2026-11-18 设置改版 S3，规格 SPEC §2.8）：快捷动作（那张有序列表）、正在播放、日程与月历、
// 音量与亮度、专注模式、系统提示。外面（IslandTab）一页一行推进行，行尾写开着几样 / 关；推进行的状态和子页页头那一句
// 是同一个纯函数（各页的 value）。每页自己读自己那几个偏好，「恢复默认」只管这一页登记的键（SettingsReset）。
// 正在播放、日程与月历、音量与亮度三页顶上钉一块悬停预览（SubpageForm 的 preview，2026-11-20）：主开关那一行（音量那页还有
// 细条的两样）停着时演，细条的颜色、百分比一拨舞台上就跟着变。

import SwiftUI

/// 设置 › 刘海岛 › 快捷动作：点刘海、快捷键「打开刘海岛」叫出来的那一张上，开哪几个、什么先后（拖动排序；右键和读屏有
/// 上移 / 下移，同翻译服务的列表）。功能关着的动作照样列、开关变灰（那一张上本来就不出），重新打开后照原来的选择回来
struct IslandActionsPage: View {
  @AppStorage(Prefs.islandActionOrder) private var order = ""
  @AppStorage(Prefs.islandActionsOff) private var offText = ""

  /// 推进行行尾：开着几个（功能关着的不算）
  static func value(order: String, off: String) -> LocalizedStringResource {
    let shown = HotKeyAction.islandOrder(order).filter {
      $0.isActive && !HotKeyAction.islandOff(off).contains($0)
    }
    return "开着 \(shown.count) 个"
  }

  var body: some View {
    let actions = HotKeyAction.islandOrder(order)
    SubpageForm(subpage: .islandActions, status: Self.value(order: order, off: offText)) {
      Section {
        List {
          ForEach(actions, id: \.self) { action in
            ActionRow(
              action: action, isOn: shows(action), isFirst: action == actions.first,
              isLast: action == actions.last
            ) { move(action, by: $0) }
          }
          .onMove { from, to in
            var list = actions
            list.move(fromOffsets: from, toOffset: to)
            save(list)
          }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .orderedListFrame(rows: actions.count)
      } header: {
        InfoHeader(
          "快捷动作",
          info:
            "点刘海、两指往下滑或者按「打开刘海岛」的快捷键（到 设置 › 快捷键 里设）叫出来的就是这一排。刘海两边挂着东西（在放歌、在录制）时，点刘海先展开它，再往下滑一次才是这一排。拖动调整先后。"
        )
        .settingsAnchor(.islandActions)
      }
    }
  }

  /// 那一张上出不出这一个：关掉的存成一行一个，按 islandShortcuts 的先后写（同步按字节比，别每次换个排法）
  private func shows(_ action: HotKeyAction) -> Binding<Bool> {
    Binding {
      !HotKeyAction.islandOff(offText).contains(action)
    } set: { isOn in
      var off = HotKeyAction.islandOff(offText)
      if isOn { off.remove(action) } else { off.insert(action) }
      offText = HotKeyAction.islandShortcuts.filter(off.contains).map(\.rawValue)
        .joined(separator: "\n")
    }
  }

  /// 右键菜单和读屏的上移（-1）/ 下移（+1）；到头了什么都不做
  private func move(_ action: HotKeyAction, by offset: Int) {
    var list = HotKeyAction.islandOrder(order)
    guard let index = list.firstIndex(of: action), list.indices.contains(index + offset) else {
      return
    }
    list.swapAt(index, index + offset)
    save(list)
  }

  private func save(_ list: [HotKeyAction]) {
    order = list.map(\.rawValue).joined(separator: "\n")
  }
}

/// 一行：家族色块、名字（功能关着时下面一行说明）、开关；右键和读屏能上移 / 下移
private struct ActionRow: View {
  let action: HotKeyAction
  @Binding var isOn: Bool
  let isFirst: Bool
  let isLast: Bool
  /// 上移（-1）/ 下移（+1）
  let move: (Int) -> Void

  var body: some View {
    let active = action.isActive
    HStack(spacing: 10) {
      KindTile(symbol: action.symbol, color: action.color)
        .opacity(active ? 1 : Style.disabledOpacity)
      VStack(alignment: .leading, spacing: 1) {
        Text(action.title).font(.system(size: 13))
        if !active, let feature = action.feature {
          Text(
            feature.isPlugin ? "「\(feature.title)」插件没添加，这一排上不出现" : "「\(feature.title)」功能关着，这一排上不出现"
          )
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
        }
      }
      .lineLimit(1)
      .truncationMode(.tail)
      .accessibilityElement(children: .combine)
      Spacer(minLength: 8)
      Toggle("显示「\(action.title)」", isOn: $isOn)
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.mini)
        .disabled(!active)
    }
    .frame(height: OrderedList.rowHeight - 8)
    .contextMenu {
      Button("上移") { move(-1) }.disabled(isFirst)
      Button("下移") { move(1) }.disabled(isLast)
    }
    .accessibilityAction(named: "上移") { move(-1) }
    .accessibilityAction(named: "下移") { move(1) }
  }
}

/// 设置 › 刘海岛 › 正在播放（刘海岛扩展第 2 期，默认关）
struct IslandMediaPage: View {
  @AppStorage(Prefs.islandNowPlaying) private var nowPlaying = false
  @AppStorage(Prefs.islandTrackPeek) private var trackPeek = true
  @AppStorage(Prefs.islandMediaColor) private var mediaColor = Island.MediaColor.artwork.rawValue
  @AppStorage(Prefs.islandMusicFavorite) private var musicFavorite = true
  @AppStorage(Prefs.islandNowPlayingHidesWhenActive) private var hidesWhenActive = false

  /// 开着 / 关（推进行行尾、页头那一句；别写成三元式：抽字会漏）
  static func value(on: Bool) -> LocalizedStringResource {
    if on { return "开着" }
    return "关"
  }

  var body: some View {
    SubpageForm(subpage: .islandMedia, status: Self.value(on: nowPlaying), preview: .nowPlaying) {
      Section {
        SettingRow(
          title: "在刘海上显示正在播放", subtitle: "刘海两边显示封面和跳动条",
          info:
            "音乐、播客、浏览器里的视频都认，点开能暂停、切歌、拖进度。读系统的「正在播放」要另起一个小进程（约 3 MB，没在放时不耗电），关掉就退出。暂停 30 秒后刘海两边收起；想接着放，点刘海再两指往下滑一次还找得到它。"
        ) {
          Toggle("在刘海上显示正在播放", isOn: $nowPlaying)
            .toggleStyle(.switch)
        }
        // 0.9.0 的「新」挂在「正在播放」（WhatsNew 的 island-now-playing）：拨过这个开关才算看过
        .onChange(of: nowPlaying) { WhatsNew.touch(section: "正在播放", of: .island) }
        .previews(.nowPlaying)
        .settingsAnchor(.islandNowPlaying)
        Group {
          Toggle(isOn: $trackPeek) {
            Text("换歌时显示歌名")
            Text("从刘海垂下一小条歌名和艺人，约 2 秒收回")
          }
          .settingsAnchor(.islandTrackPeek)
          Picker(selection: $mediaColor) {
            Text("封面的颜色").tag(Island.MediaColor.artwork.rawValue)
            Text("强调色").tag(Island.MediaColor.accent.rawValue)
            Text("白色").tag(Island.MediaColor.white.rawValue)
          } label: {
            Text("跳动条和进度条的颜色")
            Text("封面的颜色：跟着每首歌的封面变")
          }
          .settingsAnchor(.islandMediaColor)
          SettingRow(
            title: "播放卡片上显示收藏按钮", subtitle: "放「音乐」时卡片上一颗心",
            info: "点了收藏这首；第一次点会问能不能控制「音乐」。"
          ) {
            Toggle("播放卡片上显示收藏按钮", isOn: $musicFavorite)
              .toggleStyle(.switch)
          }
          .settingsAnchor(.islandMusicFavorite)
          SettingRow(
            title: "正在用放歌的 App 时不显示", subtitle: "切到放歌的 App 时收起",
            info: "比如音乐、浏览器里放视频的那个；切走再出来。"
          ) {
            Toggle("正在用放歌的 App 时不显示", isOn: $hidesWhenActive)
              .toggleStyle(.switch)
          }
          .settingsAnchor(.islandHidesWhenActive)
        }
        .disabled(!nowPlaying)
      }
    }
  }
}

/// 设置 › 刘海岛 › 日程与月历：下一个日程（打开时才问「日历」授权，mac-native §2「日历」）、日程开始时响一声、整点报时、
/// 月历和它的几样、选择日历。从系统设置授权回来（本 App 回到前台）时重查
struct IslandCalendarPage: View {
  @AppStorage(Prefs.islandNextEvent) private var nextEvent = false
  @AppStorage(Prefs.islandEventChime) private var eventChime = false
  @AppStorage(Prefs.islandHourlyChime) private var hourlyChime = false
  @AppStorage(Prefs.islandCalendar) private var monthCalendar = false
  @AppStorage(Prefs.islandCalendarDots) private var calendarDots = false
  @AppStorage(Prefs.islandCalendarColors) private var calendarColors = false
  @AppStorage(Prefs.islandShowDeclined) private var showDeclined = false
  @AppStorage(Prefs.islandHiddenCalendars) private var hiddenCalendars = ""
  /// 这台 Mac 上的日历（有「日历」授权时，这一页出现时读一次）
  @State private var eventCalendars: [NextEvent.CalendarInfo] = []
  /// 本 App 回到前台 / 问完授权时加一：让下面那行橙字照现在的授权重算（从系统设置里打开授权回来）
  @State private var accessChecks = 0
  /// 这一次打开开关时系统没给授权（偏好没打开，橙字留着告诉怎么开）
  @State private var calendarDenied = false

  /// 开着几样（下一个日程、月历、整点报时）/ 关
  static func value(nextEvent: Bool, calendar: Bool, hourly: Bool) -> LocalizedStringResource {
    let count = [nextEvent, calendar, hourly].filter { $0 }.count
    if count == 0 { return "关" }
    return "开着 \(count) 样"
  }

  var body: some View {
    SubpageForm(
      subpage: .islandCalendar,
      status: Self.value(nextEvent: nextEvent, calendar: monthCalendar, hourly: hourlyChime),
      preview: .calendar
    ) {
      Section {
        // 打开时先问「日历」授权，给了才真的打开（偏好开着 = 当时授权过）；没给就留在关着、橙字说怎么开
        Toggle(
          isOn: Binding {
            nextEvent
          } set: { isOn in
            guard isOn else {
              nextEvent = false
              calendarDenied = false
              return
            }
            // 已经授权过：直接开（不绕一圈异步，开关不闪）
            if NextEvent.isAuthorized {
              nextEvent = true
              return
            }
            askCalendar()
          }
        ) {
          Text("在刘海上显示下一个日程")
          Text("开始前 10 分钟在刘海两边倒数")
        }
        .previews(.calendar)
        .settingsAnchor(.islandNextEvent)
        // 开关关着、也没被拒绝过时不去查授权（截图自检画这一页不碰 EventKit）
        if calendarDenied || (nextEvent && !NextEvent.isAuthorized) {
          LabeledContent {
            // 系统还没问过（设置从别处带过来的）：按钮就是去问；问过了只能去系统设置里开
            if NextEvent.canAsk {
              Button("允许访问日历") { askCalendar() }
            } else {
              Button(Permissions.Kind.calendar.settingsTitle) {
                Permissions.Kind.calendar.openSettings()
              }
            }
          } label: {
            Text("没有「日历」授权，读不了日程").foregroundStyle(.orange)
          }
          .id(accessChecks)
        }
        Toggle(isOn: $eventChime) {
          Text("日程开始时响一声")
          Text("刘海上倒数的那个日程开始的那一刻")
        }
        .disabled(!nextEvent)
        .settingsAnchor(.islandEventChime)
        Toggle(isOn: $hourlyChime) {
          Text("整点报时")
          Text("每到整点响一声轻的；开着专注模式、录屏或录音时不响")
        }
        .settingsAnchor(.islandHourlyChime)
        SettingRow(
          title: "点刘海打开时显示月历", subtitle: "快捷动作下面一块这个月的日历",
          info: "点它打开「日历」；已经允许读取「日历」时，旁边还列今天的日程。"
        ) {
          Toggle("点刘海打开时显示月历", isOn: $monthCalendar)
            .toggleStyle(.switch)
        }
        .settingsAnchor(.islandCalendar)
        Toggle(isOn: $calendarDots) {
          Text("月历上标出有日程的日子")
          Text("那几天的数字下面一个小点")
        }
        .disabled(!monthCalendar)
        .settingsAnchor(.islandCalendarDots)
        Group {
          Toggle(isOn: $calendarColors) {
            Text("用日历的颜色")
            Text("日程图标用它所在日历的颜色")
          }
          .settingsAnchor(.islandCalendarColors)
          Toggle(isOn: $showDeclined) {
            Text("显示已拒绝的日程")
            Text("拒绝了的、取消了的日程也倒数、也列出来")
          }
          .settingsAnchor(.islandShowDeclined)
        }
        .disabled(!nextEvent && !monthCalendar)
        if !eventCalendars.isEmpty, nextEvent || monthCalendar {
          DisclosureGroup("选择日历") {
            ForEach(eventCalendars) { item in
              Toggle(isOn: shows(calendar: item.id)) {
                HStack(spacing: 6) {
                  Circle().fill(item.color.map { Color(cgColor: $0) } ?? .secondary)
                    .frame(width: 8, height: 8)
                  Text(verbatim: item.title)
                }
              }
            }
          }
        }
      } header: {
        InfoHeader(
          "日程",
          info: "点开刘海上的日程能加入会议、打开日历。全天的、已拒绝的不算下一个日程；日程的内容只留在这台 Mac 上，不进最近的提示。月历本身不用授权。"
        )
      } footer: {
        SectionFootnote("要「日历」授权，打开「下一个日程」时会问一次。")
      }
    }
    .task(id: "\(accessChecks)|\(nextEvent)|\(monthCalendar)") {
      eventCalendars = NextEvent.eventCalendars()
    }
    .onReceive(
      NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
    ) { _ in
      accessChecks += 1
      if NextEvent.isAuthorized, calendarDenied {
        calendarDenied = false
        nextEvent = true
      }
    }
  }

  /// 「选择日历」里一行的开关：开着 = 不在关掉的名单里
  private func shows(calendar id: String) -> Binding<Bool> {
    Binding {
      !hiddenCalendars.split(separator: "\n").contains { $0 == id }
    } set: { isOn in
      var hidden = Set(hiddenCalendars.split(separator: "\n").map(String.init))
      if isOn { hidden.remove(id) } else { hidden.insert(id) }
      hiddenCalendars = hidden.sorted().joined(separator: "\n")
    }
  }

  /// 问「日历」授权（系统框只弹一次）：给了才把开关打开；没给留在关着、橙字说怎么开
  private func askCalendar() {
    Task {
      let allowed = await NextEvent.requestAccess()
      nextEvent = allowed
      calendarDenied = !allowed
      accessChecks += 1
    }
  }
}

/// 设置 › 刘海岛 › 音量与亮度：按音量键、亮度键时显示在刘海上（要辅助功能授权）、停多久、细条的样子；接不住时橙字（第五轮体检 U6）
struct IslandLevelsPage: View {
  /// 音量、亮度键的那个拦截（AppDelegate 给）
  let mediaKeys: MediaKeys?
  /// 截图自检摆一种状态（不建真的拦截）；nil = 看 mediaKeys
  let keyStatus: MediaKeys.Status?
  @AppStorage(Prefs.islandKeyLevels) private var keyLevels = false
  @AppStorage(Prefs.islandLevelStay) private var levelStay = 2.2
  @AppStorage(Prefs.islandLevelAccent) private var levelAccent = false
  @AppStorage(Prefs.islandLevelPercent) private var levelPercent = false
  /// 本 App 回到前台时加一：授权那行照现在的授权重算
  @State private var accessChecks = 0

  /// 开着 / 关；开着却接不住（没授权、拦截建不起来）橙「接不住按键」
  static func value(on: Bool, catches: Bool) -> (text: LocalizedStringResource, isProblem: Bool) {
    if !on { return ("关", false) }
    if !catches { return ("接不住按键", true) }
    return ("开着", false)
  }

  /// 这会儿接不接得住（开关开着时才查授权）
  static func catches(_ status: MediaKeys.Status?) -> Bool {
    Permissions.isAccessibilityTrusted && IslandTab.keyWarning(status) == nil
  }

  var body: some View {
    let status = keyStatus ?? mediaKeys?.status
    let state = Self.value(on: keyLevels, catches: !keyLevels || Self.catches(status))
    SubpageForm(
      subpage: .islandLevels, status: state.text, statusIsProblem: state.isProblem, preview: .levels
    ) {
      Section {
        SettingRow(
          title: "按音量键、亮度键时显示在刘海上", subtitle: "换掉系统自己的音量、亮度提示",
          info: "按着 ⌥ 时照旧打开系统设置。只接音量 +、音量 −、静音、亮度 +、亮度 − 这五个键；锁屏时、接着调不了音量的输出设备或者外接显示器时，照旧是系统自己的提示。"
        ) {
          Toggle("按音量键、亮度键时显示在刘海上", isOn: $keyLevels)
            .toggleStyle(.switch)
        }
        .previews(.levels)
        .settingsAnchor(.islandKeyLevels)
        Group {
          Picker("停多久", selection: $levelStay) {
            Text("1 秒").tag(1.0)
            Text("2 秒").tag(2.2)
            Text("3.5 秒").tag(3.5)
          }
          .settingsAnchor(.islandLevelStay)
          Toggle("细条用强调色", isOn: $levelAccent)
            .previews(.levels)
            .settingsAnchor(.islandLevelAccent)
          Toggle("细条旁边显示百分比", isOn: $levelPercent)
            .previews(.levels)
            .settingsAnchor(.islandLevelPercent)
        }
        .disabled(!keyLevels)
        // 开关关着时不去查授权
        if keyLevels, !Permissions.isAccessibilityTrusted {
          LabeledContent {
            Button(Permissions.Kind.accessibility.settingsTitle) {
              Permissions.Kind.accessibility.openSettings()
            }
          } label: {
            Text("没有「辅助功能」授权，接不住这几个键").foregroundStyle(.orange)
          }
          .id(accessChecks)
        }
        // 授权有却接不住（核对字段没过、拦截建不起来）：开关亮着、按键照旧是系统的提示，说清楚（U6，照平滑滚动）
        if keyLevels, let warning = IslandTab.keyWarning(status) {
          Text(verbatim: warning).foregroundStyle(.orange)
        }
      } footer: {
        SectionFootnote("要「辅助功能」授权。")
      }
    }
    .onReceive(
      NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
    ) { _ in accessChecks += 1 }
  }
}

/// 设置 › 刘海岛 › 专注模式：在刘海上显示专注模式（读系统日志，不要授权）和跟着它的四样
struct IslandFocusPage: View {
  @AppStorage(Prefs.islandFocus) private var focus = true
  @AppStorage(Prefs.islandFocusPinned) private var focusPinned = true
  @AppStorage(Prefs.islandFocusSleepSound) private var focusSleepSound = false
  @AppStorage(Prefs.islandFocusWaveform) private var focusWaveform = false
  @AppStorage(Prefs.islandFocusQuiet) private var focusQuiet = false

  var body: some View {
    SubpageForm(subpage: .islandFocus, status: IslandMediaPage.value(on: focus)) {
      Section {
        SettingRow(
          title: "在刘海上显示专注模式", subtitle: "换模式时在刘海两边显示 2 秒",
          info:
            "刘海两边显示模式的图标和名字；勿扰、睡眠、工作和自己建的模式都认。读的是系统日志里专注模式的切换记录，不要授权；开着时常驻一个约 4 MB 的小进程，这里和提醒都用不着时退出。"
        ) {
          Toggle("在刘海上显示专注模式", isOn: $focus)
            .toggleStyle(.switch)
        }
        .settingsAnchor(.islandFocus)
        // 读不到系统日志（不是管理员账户、系统改了日志的写法）
        if focus, SystemFocus.shared.isRunning, !SystemFocus.shared.isReadable {
          Text("读不到系统的专注模式，刘海上显示不了").foregroundStyle(.orange)
        }
        Group {
          SettingRow(
            title: "开着时一直挂在刘海上", subtitle: "开着时刘海左边一直有它的图标",
            info: "放歌、倒数时先让给它们；点开能去专注模式设置。"
          ) {
            Toggle("开着时一直挂在刘海上", isOn: $focusPinned)
              .toggleStyle(.switch)
          }
          .settingsAnchor(.islandFocusPinned)
          Toggle(isOn: $focusSleepSound) {
            Text("睡眠模式打开时响一声")
            Text("一声轻的提示音；录屏、录音时不响")
          }
          .settingsAnchor(.islandFocusSleepSound)
          Toggle(isOn: $focusWaveform) {
            Text("跳动条换成专注模式的图标")
            Text("专注模式开着、正在放歌时，刘海右边画模式的图标")
          }
          .settingsAnchor(.islandFocusWaveform)
          SettingRow(
            title: "专注模式时不弹系统提示", subtitle: "电源、电量、耳机、断网这几样不弹",
            info: "10% 和音量、亮度照常。"
          ) {
            Toggle("专注模式时不弹系统提示", isOn: $focusQuiet)
              .toggleStyle(.switch)
          }
          .settingsAnchor(.islandFocusQuiet)
        }
        .disabled(!focus)
      }
    }
  }
}

/// 设置 › 刘海岛 › 系统提示：电源、电量低、耳机、断网、低电量模式五样，有变化时在岛上弹一下
struct IslandNoticesPage: View {
  @AppStorage(Prefs.islandNoticePower) private var noticePower = false
  @AppStorage(Prefs.islandNoticeBattery) private var noticeBattery = false
  @AppStorage(Prefs.islandNoticeHeadphones) private var noticeHeadphones = false
  @AppStorage(Prefs.islandNoticeNetwork) private var noticeNetwork = false
  @AppStorage(Prefs.islandNoticeLowPower) private var noticeLowPower = false

  /// 开着几样 / 关
  static func value(_ switches: [Bool]) -> LocalizedStringResource {
    let count = switches.filter { $0 }.count
    if count == 0 { return "关" }
    return "开着 \(count) 样"
  }

  var body: some View {
    let status = Self.value([
      noticePower, noticeBattery, noticeHeadphones, noticeNetwork, noticeLowPower,
    ])
    SubpageForm(subpage: .islandNotices, status: status) {
      Section {
        Toggle(isOn: $noticePower) {
          Text("接上、拔掉电源")
          Text("刘海两边出几秒：一句话和现在的电量")
        }
        .settingsAnchor(.islandNoticePower)
        Toggle(isOn: $noticeBattery) {
          Text("电量低")
          Text("没接电源时，降到 20% 和 10% 各说一次")
        }
        .settingsAnchor(.islandNoticeBattery)
        Toggle(isOn: $noticeHeadphones) {
          Text("耳机连上")
          Text("蓝牙耳机、AirPods、USB 耳机：刘海两边出一下，蓝牙耳机带电量")
        }
        .settingsAnchor(.islandNoticeHeadphones)
        Toggle(isOn: $noticeNetwork) {
          Text("断网、网络恢复")
          Text("断了或者好了 3 秒以上才说，醒来时闪一下不算")
        }
        .settingsAnchor(.islandNoticeNetwork)
        Toggle(isOn: $noticeLowPower) {
          Text("低电量模式打开、关掉")
          Text("刘海两边出几秒：「低电量模式」和开 / 关")
        }
        .settingsAnchor(.islandNoticeLowPower)
      } header: {
        InfoHeader("提示这些变化", info: "有变化时在刘海岛上弹一下，同别的提示。没打开的不监听，也不要任何授权。")
      }
    }
  }
}
