// 设置 › 刘海岛（2026-11-12，PR #17 SeyoZhou 提的，收进来时改成本 App 的写法；2026-11-18 设置改版 S3 拆成子页）。
// 外面：点刘海（点刘海打开、停在刘海上自动展开、停多久展开、列出最近的提示），「快捷动作 ›」，活动五个推进行
// （正在播放、日程与月历、音量与亮度、专注模式、系统提示；子页在 IslandPages.swift，行尾写开着几样 / 关），「高级…」
// （提示停多久、触感反馈、模糊四周、细边、全屏时藏起来、截图录屏时不显示）。
// 岛上的提示是全 App 的轻提示，没有总开关（mac-native §1）。2026-11-13 起这一页是刘海岛插件的页（点刘海那一张、两边的活动、
// 系统提示归它，拍板 P1b）：没添加时不在侧栏，页底「关于这个插件」（后台、同步、移除）。
// 页头画在自己的 NavigationStack 里，推进子页时一起换掉。悬停预览的舞台钉在页头下面（停到「活动」那几行时也看得见，
// 2026-11-20 用户反馈），正在播放 / 日程与月历 / 音量与亮度三个子页各自也有一块。

import SwiftUI

struct IslandTab: View {
  /// 音量、亮度键的那个拦截（AppDelegate 给）：建不起来时「音量与亮度」那一页一行橙字（第五轮体检 U6）
  private let mediaKeys: MediaKeys?
  /// 截图自检摆一种状态（不建真的拦截）；nil = 看 mediaKeys
  private let keyStatus: MediaKeys.Status?
  /// 截图自检直接画「高级…」表单（sheet 画不进屏外截图）
  private let drawsAdvanced: Bool
  @AppStorage(Prefs.islandActionOrder) private var order = ""
  @AppStorage(Prefs.islandActionsOff) private var offText = ""
  @AppStorage(Prefs.islandShowsHistory) private var showsHistory = false
  @AppStorage(Prefs.islandNotchClicks) private var notchClicks = true
  @AppStorage(Prefs.islandHoverExpands) private var hoverExpands = false
  @AppStorage(Prefs.islandHoverDelay) private var hoverDelay = 0.3
  // 推进行行尾要的几样（改在各自的子页）
  @AppStorage(Prefs.islandNowPlaying) private var nowPlaying = false
  @AppStorage(Prefs.islandNextEvent) private var nextEvent = false
  @AppStorage(Prefs.islandCalendar) private var monthCalendar = false
  @AppStorage(Prefs.islandHourlyChime) private var hourlyChime = false
  @AppStorage(Prefs.islandKeyLevels) private var keyLevels = false
  @AppStorage(Prefs.islandFocus) private var focus = true
  @AppStorage(Prefs.islandNoticePower) private var noticePower = false
  @AppStorage(Prefs.islandNoticeBattery) private var noticeBattery = false
  @AppStorage(Prefs.islandNoticeHeadphones) private var noticeHeadphones = false
  @AppStorage(Prefs.islandNoticeNetwork) private var noticeNetwork = false
  @AppStorage(Prefs.islandNoticeLowPower) private var noticeLowPower = false
  // 「高级…」
  @AppStorage(Prefs.islandNoticeLength) private var noticeLength = Island.DwellLength.standard
    .rawValue
  @AppStorage(Prefs.islandHaptics) private var haptics = true
  @AppStorage(Prefs.islandBlur) private var blur = true
  @AppStorage(Prefs.islandOutlined) private var outlined = false
  @AppStorage(Prefs.islandHidesInFullScreen) private var hidesInFullScreen = false
  @AppStorage(Prefs.islandHidesFromCapture) private var hidesFromCapture = false
  @Environment(SettingsNavigation.self) private var navigation: SettingsNavigation?
  /// 本 App 回到前台时加一：「音量与亮度」行尾照现在的辅助功能授权重算（从系统设置授权回来）
  @State private var accessChecks = 0
  /// 悬停预览：页面最上面那一组顶上的舞台演停着的那一行（设置改版 S10）
  @State private var previewFocus = PreviewFocus()

  init(
    mediaKeys: MediaKeys? = nil, keyStatus: MediaKeys.Status? = nil, drawsAdvanced: Bool = false
  ) {
    self.mediaKeys = mediaKeys
    self.keyStatus = keyStatus
    self.drawsAdvanced = drawsAdvanced
  }

  var body: some View {
    // 截图自检单独画这一页时没有导航状态：给一个自己的栈
    if let navigation {
      NavigationStack(path: Bindable(navigation).path) { page }
    } else {
      NavigationStack { page }
    }
  }

  private var page: some View {
    VStack(spacing: 0) {
      PageHeader(page: .island)
      PreviewStage(still: .notchClick).pinned()
      form
    }
    .environment(previewFocus)
    .navigationTitle(SettingsPage.island.title)
    .navigationDestination(for: String.self) { route in
      switch SettingsSubpage(route: route) {
      case .islandActions?: IslandActionsPage()
      case .islandMedia?: IslandMediaPage()
      case .islandCalendar?: IslandCalendarPage()
      case .islandLevels?: IslandLevelsPage(mediaKeys: mediaKeys, keyStatus: keyStatus)
      case .islandFocus?: IslandFocusPage()
      case .islandNotices?: IslandNoticesPage()
      default: EmptyView()
      }
    }
    .advancedSheet(.island, summary: "刘海岛的手感和样子", inline: drawsAdvanced) { advanced }
    .onReceive(
      NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
    ) { _ in accessChecks += 1 }
  }

  /// 外面：点刘海、快捷动作、活动、高级…、关于这个插件
  private var form: some View {
    Form {
      Section {
        SettingRow(
          title: "点刘海打开", subtitle: "停上去鼓起一点，点一下打开",
          info: "两指往下滑也行；刘海两边挂着东西时打开它的卡片，没有时是快捷动作。装了别的刘海 App 时可以关掉：提示和挂在刘海两边的录制计时这些照常，快捷键照样能叫出快捷动作。"
        ) {
          Toggle("点刘海打开", isOn: $notchClicks)
            .toggleStyle(.switch)
        }
        .previews(.notchClick)
        .settingsAnchor(.islandNotchClicks)
        SettingRow(
          title: "停在刘海上自动展开", subtitle: "停一下就展开，不用点",
          info: "关着时停上去只鼓起一点、点一下才展开；打开后刘海两边挂着东西时，指针停一下就展开成卡片。"
        ) {
          Toggle("停在刘海上自动展开", isOn: $hoverExpands)
            .toggleStyle(.switch)
        }
        .previews(.hoverExpand)
        .settingsAnchor(.islandHoverExpands)
        Picker("停多久展开", selection: $hoverDelay) {
          Text("0.3 秒").tag(0.3)
          Text("0.6 秒").tag(0.6)
          Text("1 秒").tag(1.0)
        }
        .disabled(!hoverExpands)
        .previews(.hoverExpand)
        .settingsAnchor(.islandHoverDelay)
        SettingRow(
          title: "列出最近的提示", subtitle: "快捷动作下面列最近 10 条",
          info: "本次启动以来的，新的在前；不列也不影响提示照常弹出。"
        ) {
          Toggle("列出最近的提示", isOn: $showsHistory)
            .toggleStyle(.switch)
        }
        .settingsAnchor(.islandShowsHistory)
        pushRow(.islandActions, value: IslandActionsPage.value(order: order, off: offText))
      } header: {
        Text("点刘海")
      }
      Section("活动") {
        pushRow(.islandMedia, value: IslandMediaPage.value(on: nowPlaying))
          .previews(.nowPlaying)
        pushRow(
          .islandCalendar,
          value: IslandCalendarPage.value(
            nextEvent: nextEvent, calendar: monthCalendar, hourly: hourlyChime)
        )
        .previews(.calendar)
        let _ = accessChecks  // 授权回来重画
        let levels = IslandLevelsPage.value(
          on: keyLevels,
          catches: !keyLevels || IslandLevelsPage.catches(keyStatus ?? mediaKeys?.status))
        pushRow(.islandLevels, value: levels.text, isProblem: levels.isProblem)
          .previews(.levels)
        pushRow(.islandFocus, value: IslandMediaPage.value(on: focus))
        pushRow(
          .islandNotices,
          value: IslandNoticesPage.value([
            noticePower, noticeBattery, noticeHeadphones, noticeNetwork, noticeLowPower,
          ]))
      }
      Section {
      } footer: {
        AdvancedButton(page: .island)
      }
      PluginAboutSection(plugin: .island)
    }
    .formStyle(.grouped)
    .settingsScrollTarget()
  }

  /// 一个子页的推进行（新功能标记看子页里的行和子页名，如 0.9.0 的「正在播放」）
  private func pushRow(
    _ subpage: SettingsSubpage, value: LocalizedStringResource, isProblem: Bool = false
  ) -> some View {
    SettingsPushRow(
      title: subpage.title,
      isNew: navigation.map { SettingsItem.subpageIsNew(subpage, fresh: $0.fresh) } ?? false,
      value: value, valueIsProblem: isProblem
    ) {
      navigation?.path = [subpage.route]
    }
  }

  /// 「高级…」表单：提示停多久、触感、模糊、细边、全屏时藏起来、截图录屏时不显示
  @ViewBuilder private var advanced: some View {
    Section {
      SettingRow(
        title: "提示停多久", subtitle: "「已复制」这类提示停多久",
        info: "带按钮的、出错的跟着变长变短，进行中的不算。"
      ) {
        Picker("提示停多久", selection: $noticeLength) {
          Text("短").tag(Island.DwellLength.short.rawValue)
          Text("标准").tag(Island.DwellLength.standard.rawValue)
          Text("长").tag(Island.DwellLength.long.rawValue)
        }
      }
      .settingsAnchor(.islandNoticeLength)
      Toggle(isOn: $haptics) {
        Text("触感反馈")
        Text("切歌、展开时触控板轻轻一下")
      }
      .settingsAnchor(.islandHaptics)
    }
    Section {
      SettingRow(
        title: "展开时模糊四周", subtitle: "卡片背后越靠近越模糊",
        info: "系统设置里开着「降低透明度」时不模糊。"
      ) {
        Toggle("展开时模糊四周", isOn: $blur)
          .toggleStyle(.switch)
      }
      .settingsAnchor(.islandBlur)
      Toggle(isOn: $outlined) {
        Text("描一圈细边")
        Text("深色桌面上也看得清轮廓")
      }
      .settingsAnchor(.islandOutlined)
      SettingRow(
        title: "全屏时藏起来", subtitle: "刘海那块屏全屏时不出现",
        info: "看视频、玩游戏时，刘海岛和它的提示都不出现。"
      ) {
        Toggle("全屏时藏起来", isOn: $hidesInFullScreen)
          .toggleStyle(.switch)
      }
      .settingsAnchor(.islandHidesInFullScreen)
      Toggle(isOn: $hidesFromCapture) {
        Text("截图、录屏时不显示刘海岛")
        Text("截下来、录下来的画面里没有刘海岛和它上面的提示")
      }
      .settingsAnchor(.islandHidesFromCapture)
    }
  }

  /// 「音量和亮度」那一节的橙字（纯函数，配单测）：授权有、拦截却接不住时说为什么、怎么办；别的状态（关着、没授权——
  /// 上面另有一行带按钮的、正常）没有
  static func keyWarning(_ status: MediaKeys.Status?) -> String? {
    switch status {
    case .unreadable:
      String(localized: "这一版系统上认不出这几个键，照旧是系统自己的音量、亮度提示。")
    case .failed:
      String(
        localized: "授权显示给了，却接不住这几个键：到 系统设置 › \(Permissions.privacyPane) › 辅助功能 里把它关掉再打开。")
    default: nil
    }
  }

}
