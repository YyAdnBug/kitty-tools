// 设置 › 刘海岛（2026-11-12，PR #17 SeyoZhou 提的，收进来时改成本 App 的写法）：点刘海、快捷键「打开刘海岛」叫出来的
// 那一张上，快捷动作开哪几个、什么先后（拖动排序；右键和读屏有上移 / 下移，同翻译服务的列表），列不列最近的提示
// （2026-11-14 起默认不列）。
// 岛上的提示是全 App 的轻提示，没有总开关（mac-native §1）。功能关着的动作照样列、开关变灰（那一张上本来就不出），
// 重新打开功能后照原来的选择回来。2026-11-13 起这一页是刘海岛插件的页（点刘海那一张、两边的活动、系统提示归它，
// 拍板 P1b）：没添加时不在侧栏，页底「关于这个插件」（后台、同步、移除）。最上面一组是正在播放（刘海岛扩展第 2 期，默认关；2026-11-13 拍板放在这一页、
// 不单独成插件）。

import SwiftUI

struct IslandTab: View {
  @AppStorage(Prefs.islandActionOrder) private var order = ""
  @AppStorage(Prefs.islandActionsOff) private var offText = ""
  @AppStorage(Prefs.islandShowsHistory) private var showsHistory = false
  @AppStorage(Prefs.islandNotchClicks) private var notchClicks = true
  @AppStorage(Prefs.islandNoticePower) private var noticePower = false
  @AppStorage(Prefs.islandNoticeBattery) private var noticeBattery = false
  @AppStorage(Prefs.islandNoticeHeadphones) private var noticeHeadphones = false
  @AppStorage(Prefs.islandNoticeNetwork) private var noticeNetwork = false
  @AppStorage(Prefs.islandNoticeLowPower) private var noticeLowPower = false
  @AppStorage(Prefs.islandHourlyChime) private var hourlyChime = false
  @AppStorage(Prefs.islandEventChime) private var eventChime = false
  @AppStorage(Prefs.islandHidesFromCapture) private var hidesFromCapture = false
  @AppStorage(Prefs.islandNoticeLength) private var noticeLength = Island.DwellLength.standard
    .rawValue
  @AppStorage(Prefs.islandHoverDelay) private var hoverDelay = 0.3
  @AppStorage(Prefs.islandLevelStay) private var levelStay = 2.2
  @AppStorage(Prefs.islandLevelAccent) private var levelAccent = false
  @AppStorage(Prefs.islandLevelPercent) private var levelPercent = false
  @AppStorage(Prefs.islandNowPlayingHidesWhenActive) private var hidesWhenActive = false
  @AppStorage(Prefs.islandCalendarColors) private var calendarColors = false
  @AppStorage(Prefs.islandShowDeclined) private var showDeclined = false
  @AppStorage(Prefs.islandCalendarDots) private var calendarDots = false
  @AppStorage(Prefs.islandHiddenCalendars) private var hiddenCalendars = ""
  /// 这台 Mac 上的日历（有「日历」授权时，这一页出现时读一次）
  @State private var eventCalendars: [NextEvent.CalendarInfo] = []
  @AppStorage(Prefs.islandOutlined) private var outlined = false
  @AppStorage(Prefs.islandHidesInFullScreen) private var hidesInFullScreen = false
  @AppStorage(Prefs.islandMediaColor) private var mediaColor = Island.MediaColor.artwork.rawValue
  @AppStorage(Prefs.islandMusicFavorite) private var musicFavorite = true
  @AppStorage(Prefs.islandNowPlaying) private var nowPlaying = false
  @AppStorage(Prefs.islandTrackPeek) private var trackPeek = true
  @AppStorage(Prefs.islandNextEvent) private var nextEvent = false
  @AppStorage(Prefs.islandCalendar) private var monthCalendar = false
  @AppStorage(Prefs.islandKeyLevels) private var keyLevels = false
  /// 本 App 回到前台 / 问完授权时加一：让下面那行橙字照现在的授权重算（从系统设置里打开授权回来）
  @State private var accessChecks = 0
  @AppStorage(Prefs.islandHoverExpands) private var hoverExpands = false
  @AppStorage(Prefs.islandHaptics) private var haptics = true
  @AppStorage(Prefs.islandBlur) private var blur = true
  @AppStorage(Prefs.islandFocus) private var focus = true
  @AppStorage(Prefs.islandFocusSleepSound) private var focusSleepSound = false
  @AppStorage(Prefs.islandFocusWaveform) private var focusWaveform = false
  @AppStorage(Prefs.islandFocusQuiet) private var focusQuiet = false
  @AppStorage(Prefs.islandFocusPinned) private var focusPinned = true
  /// 这一次打开开关时系统没给授权（偏好没打开，橙字留着告诉怎么开）
  @State private var calendarDenied = false
  @Environment(SettingsNavigation.self) private var navigation: SettingsNavigation?

  var body: some View {
    let actions = HotKeyAction.islandOrder(order)
    Form {
      Section {
        Toggle(isOn: $nowPlaying) {
          Text("在刘海上显示正在播放")
          Text("音乐、播客、浏览器里的视频：刘海两边是封面和跳动条，点开能暂停、切歌、拖进度")
        }
        Group {
          Toggle(isOn: $trackPeek) {
            Text("换歌时显示歌名")
            Text("从刘海垂下一小条歌名和艺人，约 2 秒收回")
          }
          Picker(selection: $mediaColor) {
            Text("封面的颜色").tag(Island.MediaColor.artwork.rawValue)
            Text("强调色").tag(Island.MediaColor.accent.rawValue)
            Text("白色").tag(Island.MediaColor.white.rawValue)
          } label: {
            Text("跳动条和进度条的颜色")
            Text("封面的颜色：跟着每首歌的封面变")
          }
          Toggle(isOn: $musicFavorite) {
            Text("播放卡片上显示收藏按钮")
            Text("放「音乐」时卡片右上角一颗心，点了收藏这首；第一次点会问能不能控制「音乐」")
          }
          Toggle(isOn: $hidesWhenActive) {
            Text("正在用放歌的 App 时不显示")
            Text("切到正在放歌的 App（比如音乐、浏览器里放视频的那个）时，刘海两边收起；切走再出来")
          }
        }
        .disabled(!nowPlaying)
      } header: {
        NewTitle("正在播放", page: .island, fresh: navigation?.fresh ?? [])
      } footer: {
        SectionFootnote(
          "读系统的「正在播放」要另起一个小进程（约 4 MB，没在放时不耗电），关掉就退出。暂停 30 秒后刘海两边收起；想接着放，点刘海再两指往下滑一次还找得到它。")
      }
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
          Text("开始前 10 分钟挂在刘海两边倒数，点开能加入会议、打开日历")
        }
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
        Toggle(isOn: $hourlyChime) {
          Text("整点报时")
          Text("每到整点响一声轻的；开着专注模式、录屏或录音时不响")
        }
        Toggle(isOn: $monthCalendar) {
          Text("点刘海打开时显示月历")
          Text("快捷动作下面一块这个月的日历，点它打开「日历」；已经允许读取「日历」时，旁边还列今天的日程")
        }
        Toggle(isOn: $calendarDots) {
          Text("月历上标出有日程的日子")
          Text("那几天的数字下面一个小点")
        }
        .disabled(!monthCalendar)
        Group {
          Toggle(isOn: $calendarColors) {
            Text("用日历的颜色")
            Text("刘海上的日程图标、月历旁今天的日程，用它所在日历的颜色")
          }
          Toggle(isOn: $showDeclined) {
            Text("显示已拒绝的日程")
            Text("拒绝了的、取消了的日程也倒数、也列出来")
          }
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
        Text("日程")
      } footer: {
        SectionFootnote(
          "读系统「日历」里的日程，打开「下一个日程」时会问一次授权。全天的、已拒绝的不算下一个日程；日程的内容只留在这台 Mac 上，不进最近的提示。月历本身不用授权。")
      }
      Section {
        Toggle(isOn: $keyLevels) {
          Text("按音量键、亮度键时显示在刘海上")
          Text("系统自己的音量、亮度提示不再出现；按着 ⌥ 时照旧打开系统设置")
        }
        Group {
          Picker("停多久", selection: $levelStay) {
            Text("1 秒").tag(1.0)
            Text("2 秒").tag(2.2)
            Text("3.5 秒").tag(3.5)
          }
          Toggle("细条用强调色", isOn: $levelAccent)
          Toggle("细条旁边显示百分比", isOn: $levelPercent)
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
      } header: {
        Text("音量和亮度")
      } footer: {
        SectionFootnote(
          "只接音量 +、音量 −、静音、亮度 +、亮度 − 这五个键，要「辅助功能」授权。锁屏时、接着调不了音量的输出设备或者外接显示器时，照旧是系统自己的提示。")
      }
      Section {
        Toggle(isOn: $focus) {
          Text("在刘海上显示专注模式")
          Text("打开、关掉、换模式时，刘海两边出 2 秒：模式的图标和名字")
        }
        // 读不到系统日志（不是管理员账户、系统改了日志的写法）
        if focus, SystemFocus.shared.isRunning, !SystemFocus.shared.isReadable {
          Text("读不到系统的专注模式，刘海上显示不了").foregroundStyle(.orange)
        }
        Group {
          Toggle(isOn: $focusPinned) {
            Text("开着时一直挂在刘海上")
            Text("专注模式开着的这段时间，刘海左边一直有它的图标；放歌、倒数时先让给它们。点开能去专注模式设置")
          }
          Toggle(isOn: $focusSleepSound) {
            Text("睡眠模式打开时响一声")
            Text("一声轻的提示音；录屏、录音时不响")
          }
          Toggle(isOn: $focusWaveform) {
            Text("跳动条换成专注模式的图标")
            Text("专注模式开着、正在放歌时，刘海右边画模式的图标")
          }
          Toggle(isOn: $focusQuiet) {
            Text("专注模式时不弹系统提示")
            Text("接上或拔掉电源、电量低到 20%、耳机连上、断网这几样不弹；10% 和音量、亮度照常")
          }
        }
        .disabled(!focus)
      } header: {
        Text("专注模式")
      } footer: {
        SectionFootnote(
          "勿扰、睡眠、工作和自己建的模式都认。读的是系统日志里专注模式的切换记录，不要授权；开着时常驻一个约 4 MB 的小进程，这里和提醒都用不着时退出。")
      }
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
        Text("快捷动作")
      } footer: {
        SectionFootnote(
          "点刘海、两指往下滑或者按「打开刘海岛」的快捷键（到 设置 › 快捷键 里设）叫出来的就是这一排。刘海两边挂着东西（在放歌、在录制）时，点刘海先展开它，再往下滑一次才是这一排。拖动调整先后。"
        )
      }
      Section {
        Toggle(isOn: $showsHistory) {
          Text("列出最近的提示")
          Text("列在快捷动作下面：本次启动以来最近 10 条，新的在前；不列也不影响提示照常弹出")
        }
        Toggle(isOn: $notchClicks) {
          Text("点刘海打开")
          Text("停在刘海上会鼓起一点，点一下或者两指往下滑打开：刘海两边挂着东西时是它的卡片，没有时是快捷动作")
        }
        Toggle(isOn: $hoverExpands) {
          Text("停在刘海上自动展开")
          Text("关着时停上去只鼓起一点、点一下才展开；打开后刘海两边挂着东西时，指针停一下就展开成卡片")
        }
        Picker("停多久展开", selection: $hoverDelay) {
          Text("0.3 秒").tag(0.3)
          Text("0.6 秒").tag(0.6)
          Text("1 秒").tag(1.0)
        }
        .disabled(!hoverExpands)
        Picker(selection: $noticeLength) {
          Text("短").tag(Island.DwellLength.short.rawValue)
          Text("标准").tag(Island.DwellLength.standard.rawValue)
          Text("长").tag(Island.DwellLength.long.rawValue)
        } label: {
          Text("提示停多久")
          Text("「已复制」这类提示在刘海上停多久；带按钮的、出错的跟着变长变短，进行中的不算")
        }
        Toggle(isOn: $haptics) {
          Text("触感反馈")
          Text("滑动切歌、展开卡片、进度条拖到头时，触控板轻轻一下")
        }
        Toggle(isOn: $blur) {
          Text("展开时模糊四周")
          Text("卡片背后的东西越靠近卡片越模糊；系统设置里开着「降低透明度」时不模糊")
        }
        Toggle(isOn: $outlined) {
          Text("描一圈细边")
          Text("刘海两边伸出来、展开时，形体外面一圈淡淡的边，深色桌面上也看得清轮廓")
        }
        Toggle(isOn: $hidesInFullScreen) {
          Text("全屏时藏起来")
          Text("刘海那块屏上的 App 全屏时（看视频、玩游戏），刘海岛和它的提示都不出现")
        }
        Toggle(isOn: $hidesFromCapture) {
          Text("截图、录屏时不显示刘海岛")
          Text("截下来、录下来的画面里没有刘海岛和它上面的提示")
        }
      } footer: {
        SectionFootnote("装了别的刘海 App 时可以关掉「点刘海打开」：提示和挂在刘海两边的录制计时这些照常，快捷键照样能叫出快捷动作。")
      }
      Section {
        Toggle(isOn: $noticePower) {
          Text("接上、拔掉电源")
          Text("刘海两边出几秒：一句话和现在的电量")
        }
        Toggle(isOn: $noticeBattery) {
          Text("电量低")
          Text("没接电源时，降到 20% 和 10% 各说一次")
        }
        Toggle(isOn: $noticeHeadphones) {
          Text("耳机连上")
          Text("蓝牙耳机、AirPods、USB 耳机：刘海两边出一下，蓝牙耳机带电量")
        }
        Toggle(isOn: $noticeNetwork) {
          Text("断网、网络恢复")
          Text("断了或者好了 3 秒以上才说，醒来时闪一下不算")
        }
        Toggle(isOn: $noticeLowPower) {
          Text("低电量模式打开、关掉")
          Text("刘海两边出几秒：「低电量模式」和开 / 关")
        }
      } header: {
        Text("系统提示")
      } footer: {
        SectionFootnote("有变化时在刘海岛上弹一下，同别的提示。没打开的不监听，也不要任何授权。")
      }
      PluginAboutSection(plugin: .island)
    }
    .formStyle(.grouped)
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
    // 0.9.0 的「新」挂在「正在播放」（WhatsNew 的 island-now-playing）：拨过那个开关才算看过
    .onChange(of: nowPlaying) { WhatsNew.touch(section: "正在播放", of: .island) }
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
