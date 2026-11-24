// 设置 › 通用（2026-11-18 设置改版 S2：外面只留常用的，成组的推进子页，零散的收进「高级…」）。外面三组：
// ① 功能 ›（各功能的开关，FeaturesPage；Shell/Feature.swift）、插件 ›（侧栏的「插件」那一页）；
// ② 语言（跟随系统 / 简体中文 / English，重新打开后生效；Shell/InterfaceLanguage.swift）、外观（三张缩略图）、强调色、登录时自动打开；
// ③ 权限 ›（辅助功能、屏幕录制、麦克风、15.4 起的剪贴板访问，同一种 PermissionRow；缺授权时这一组挪到最上面、行尾橙字）、
// 同步 ›（SyncSection 原样搬进子页，行尾写上次同步）、备份与导出导入 ›（TransferSection 原样搬进子页）。
// 「高级…」：呼出面板时挤压弹开、菜单栏图标（显示 / 隐藏、单色 / 彩色）、程序坞图标（只在 26 上）、数据目录。
// 页头画在自己的 NavigationStack 里，推进子页时一起换掉。

import AVFoundation
import ServiceManagement
import SwiftUI

struct GeneralTab: View {
  /// 导出 / 导入要用到的翻译服务列表和导入后的收尾（AppDelegate 给）；不给就没有「备份与导出导入 ›」那一行
  var transfer: SettingsTransfer?
  /// 同步（便签这次用不了时给 nil，「同步 ›」那一行不显示）
  var sync: NoteSyncer?
  /// 截图自检直接画「高级…」表单（sheet 画不进屏外截图）
  var drawsAdvanced = false
  @AppStorage(Prefs.appearance) private var appearance = AppAppearance.system
  /// 「备份与导出导入 ›」行尾：每天自动备份开没开、这台 Mac 上那份没备成的原因（不注册默认值，初值 true 同 SettingsBackup.isEnabled）
  @AppStorage(Prefs.settingsBackupEnabled) private var backsUp = true
  @AppStorage(Prefs.settingsBackupProblem) private var backupProblem: String?
  /// 最近一份自动备份是什么时候写的（出现、设置窗重新当 key 时重读）
  @State private var latestBackup: Date?
  @AppStorage(Prefs.statusItemVisible) private var statusItemVisible = true
  @AppStorage(Prefs.dockIconOnTahoe) private var dockIconOnTahoe = true
  @AppStorage(Prefs.statusItemStyle) private var statusItemStyle = StatusItem.IconStyle.template
  @AppStorage(Prefs.panelSqueezeEntrance) private var squeezeEntrance = false
  /// 悬停预览：「高级…」里「挤压弹开」那一组顶上的舞台（设置改版 S10）
  @State private var previewFocus = PreviewFocus()
  /// 界面语言（InterfaceLanguage：本 App 自己偏好域里的 AppleLanguages，不注册默认值，@AppStorage 读不到「没存过」）
  @State private var language = InterfaceLanguage.stored
  @State private var languageNeedsRelaunch = InterfaceLanguage.needsRelaunch
  /// 初值用上一次读到的：@State 的初值每建一次这个视图都会算一遍，读一次是一次跨进程调用（约 35 ms），出现时 recheck 再读
  @State private var loginStatus = LaunchAtLogin.status
  @State private var loginError: String?
  /// 此刻开着的功能（「功能」那一行的小字）：偏好变了跟着重算
  @State private var enabled = Feature.enabled
  /// 缺几项授权（「权限 ›」那一行）：页面出现、设置窗重新当 key 时重查（跨进程问系统，别放进初始值）
  @State private var missing = 0
  /// 新功能标记读它（截图自检单独画这一页时没有）
  @Environment(SettingsNavigation.self) private var navigation: SettingsNavigation?

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
      PageHeader(page: .general)
      form
    }
    .navigationTitle(SettingsPage.general.title)
    .navigationDestination(for: String.self) { route in
      if route == FeaturesPage.route {
        FeaturesPage()
      } else {
        switch SettingsSubpage(route: route) {
        case .generalPermissions?: GeneralPermissionsPage()
        case .generalSync?:
          if let sync {
            GeneralSyncPage(syncer: sync)
          } else {
            // 便签这次用不了（同步也跟着用不了）时搜到「同步」：给一页说明，别推进一页空白
            SubpageForm(subpage: .generalSync, status: "关") {
              Section { Text("这次运行里便签用不了，同步也用不了") }
            }
          }
        case .generalBackup?: transfer.map { GeneralBackupPage(transfer: $0) }
        default: EmptyView()
        }
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
      let now = Feature.enabled
      if now != enabled {
        enabled = now
        recheck()
      }
    }
    .advancedSheet(.general, summary: "不常改的外观和图标", inline: drawsAdvanced) { advanced }
  }

  /// 显式 key：翻译页也有一组「语言」（英文是复数）。新功能标记（WhatsNew，0.10.0）按它认这一行
  static let languageLabel = LocalizedStringResource("general.language", defaultValue: "语言")

  /// 语言（拍板 D2）：跟随系统 / 简体中文 / English，写本 App 自己的 AppleLanguages，重新打开后生效
  private var languageRow: some View {
    LabeledContent {
      HStack(spacing: 10) {
        InfoButton("也可以在 系统设置 › 通用 › 语言与地区 › 应用程序 里选。", about: Self.languageLabel)
        if languageNeedsRelaunch {
          Button("现在重新打开") {
            // 起不了「等退出后重新打开」的那个 sh 就不退：用户自己退出再打开也一样
            if (try? Updater.relaunch(Bundle.main.bundleURL)) != nil { NSApp.terminate(nil) }
          }
        }
        Picker(selection: $language) {
          ForEach(InterfaceLanguage.allCases) { Text($0.title).tag($0) }
        } label: {
          Text(Self.languageLabel)
        }
        .labelsHidden()
        .fixedSize()
      }
    } label: {
      NewTitle(Self.languageLabel, page: .general, fresh: navigation?.fresh ?? [])
      if languageNeedsRelaunch { Text("重新打开 Kitty Tools 后换成新的语言") }
    }
    .onChange(of: language) {
      // 拨过这一行，「新」就算看过了（光点进这一页不算；WhatsNew）
      WhatsNew.touch(section: Self.languageLabel, of: .general)
      InterfaceLanguage.store(language)
      languageNeedsRelaunch = InterfaceLanguage.needsRelaunch
    }
  }

  /// 外面三组：功能和插件；语言、外观、强调色、登录时打开；权限、同步、备份三行推进行（缺授权时这一组挪到最上面）
  private var form: some View {
    Form {
      if missing > 0 { Section { subpageRows } }
      Section {
        SettingsPushRow(
          title: "功能",
          detail: "\(FeaturesPage.summary(on: enabled, available: Feature.listed))",
          // 新功能标记：0.8.0 加的（WhatsNew），拨过其中一个开关、换页之后才没
          isNew: navigation.map { WhatsNew.marks(section: "功能", of: .general, in: $0.fresh) }
            ?? false
        ) {
          navigation?.path = [FeaturesPage.route]
        }
        .settingsAnchor(.generalFeatures)
        // 插件页改版 D1：插件挪进侧栏的「插件」那一页（原名「全部插件」），这里一行带过去
        SettingsPushRow(
          title: "插件",
          detail: pluginsDetail,
          isNew: navigation.map { WhatsNew.marks(section: "插件", of: .general, in: $0.fresh) }
            ?? false
        ) {
          navigation?.page = .plugins
        }
        .settingsAnchor(.generalPlugins)
      }
      Section {
        languageRow
          .settingsAnchor(.generalLanguage)
        LabeledContent("外观") { AppearancePicker(selection: $appearance) }
          .onChange(of: appearance) { AppAppearance.apply() }
          .settingsAnchor(.generalAppearance)
        LabeledContent {
          HStack(spacing: 10) {
            if Accent.shared.choice != .system {
              InfoButton("菜单高亮和焦点环由系统绘制，仍使用系统强调色。", about: "强调色")
            }
            AccentPicker()
          }
        } label: {
          Text("强调色")
          if Accent.shared.choice == .system {
            Text("系统强调色选「多色」时使用品牌粉")
          } else {
            Text("菜单高亮和焦点环仍跟系统")
          }
        }
        .settingsAnchor(.generalAccent)
        Toggle(isOn: launchAtLogin) {
          Text("登录时自动打开")
          if let loginError { Text(loginError).foregroundStyle(.red) }
        }
        .disabled(!LaunchAtLogin.isInstalled)
        .settingsAnchor(.generalLogin)
        if LaunchAtLogin.isInstalled, loginStatus == .requiresApproval {
          LabeledContent {
            Button("打开登录项设置") { SMAppService.openSystemSettingsLoginItems() }
          } label: {
            // 这一行只有说明、没有标题：照行副标题的样子（11 pt secondary）
            Text("需要在 系统设置 › 通用 › 登录项与扩展 里允许本 App 在后台运行")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
        }
      } footer: {
        // 开关置灰的原因放页脚：写成开关的副标题会跟着一起变淡
        if !LaunchAtLogin.isInstalled {
          SectionFootnote("正在从磁盘映像或临时位置运行。请先把 App 拖进「应用程序」文件夹，再开启这一项。")
        }
      }
      if missing == 0 { Section { subpageRows } }
      Section {
      } footer: {
        AdvancedButton(page: .general)
      }
    }
    .formStyle(.grouped)
    .settingsScrollTarget()
    .onAppear(perform: recheck)
    .onSettingsBecameKey(perform: recheck)
  }

  /// 权限、同步、备份与导出导入三行推进行（设置改版 S2）：行尾写现在的状态
  @ViewBuilder private var subpageRows: some View {
    SettingsPushRow(
      title: SettingsSubpage.generalPermissions.title,
      isNew: isNew(.generalPermissions),
      value: Self.permissionsValue(missing: missing), valueIsProblem: missing > 0
    ) {
      navigation?.path = [SettingsSubpage.generalPermissions.route]
    }
    if let sync {
      let value = Self.syncValue(status: sync.status, lastSync: sync.lastSync)
      SettingsPushRow(
        title: SettingsSubpage.generalSync.title,
        isNew: isNew(.generalSync)
          || navigation.map { WhatsNew.marks(section: "同步", of: .general, in: $0.fresh) } ?? false,
        value: value.text, valueIsProblem: value.isProblem
      ) {
        navigation?.path = [SettingsSubpage.generalSync.route]
      }
    }
    if transfer != nil {
      let value = Self.backupValue(
        isOn: backsUp, failed: backupProblem != nil, latest: latestBackup)
      SettingsPushRow(
        title: SettingsSubpage.generalBackup.title, isNew: isNew(.generalBackup),
        value: value.text, valueIsProblem: value.isProblem
      ) {
        navigation?.path = [SettingsSubpage.generalBackup.route]
      }
    }
  }

  /// 「插件」那一行的小字（先算成不可选的：可选参数里直接写三元式，抽字时第二个分支会漏掉）
  private var pluginsDetail: LocalizedStringResource {
    enabled.contains(where: \.isPlugin)
      ? "添加了 \(enabled.filter(\.isPlugin).count) 个" : "还没添加；便签、提醒、刘海岛这些都在里面"
  }

  private func isNew(_ subpage: SettingsSubpage) -> Bool {
    navigation.map { SettingsItem.subpageIsNew(subpage, fresh: $0.fresh) } ?? false
  }

  /// 「高级…」表单：动效、菜单栏和程序坞的图标、数据目录
  @ViewBuilder private var advanced: some View {
    Section {
      PreviewStage(still: .squeeze)
      SettingRow(
        title: "呼出面板时挤压弹开", subtitle: "面板从小一点弹到原尺寸",
        info: "剪贴板、启动器和翻译浮窗都这样；减弱动态效果时不弹。"
      ) {
        Toggle("呼出面板时挤压弹开", isOn: $squeezeEntrance)
          .toggleStyle(.switch)
      }
      .previews(.squeeze)
      .settingsAnchor(.generalSqueeze)
    }
    .environment(previewFocus)
    Section {
      SettingRow(
        title: "在菜单栏显示图标", subtitle: "隐藏后快捷键照常能用",
        info: "隐藏后，再打开一次 Kitty Tools（在启动器或访达里）会打开主界面。"
      ) {
        Toggle("在菜单栏显示图标", isOn: $statusItemVisible)
          .toggleStyle(.switch)
      }
      .settingsAnchor(.generalMenuBarIcon)
      // 分段左边是菜单栏上现在那张图（1:1 实时预览）：分段控件只显示文字，塞不进图。
      // LabeledContent 的标签不随 .disabled 变淡，图标隐藏时自己淡成 .tertiary（同系统禁用文字）
      LabeledContent {
        HStack(spacing: 10) {
          if let image = statusItemStyle.image {
            Image(nsImage: image)
              .opacity(statusItemVisible ? 1 : Style.disabledOpacity)
              .accessibilityHidden(true)
          }
          Picker("图标样式", selection: $statusItemStyle) {
            ForEach(StatusItem.IconStyle.allCases) { Text($0.title).tag($0) }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .fixedSize()
        }
      } label: {
        Text("图标样式").foregroundStyle(statusItemVisible ? .primary : .tertiary)
      }
      .disabled(!statusItemVisible)
      .settingsAnchor(.generalIconStyle)
      // 只在 macOS 26 上有（PR #1）：别的系统没有关掉设置后面板接不到键盘的问题
      if ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26 {
        SettingRow(
          title: "在程序坞显示图标", subtitle: "关掉后面板可能接不到键盘",
          info: "这一版系统上，收起程序坞图标会让之后弹出的面板接不到键盘（启动台、启动器不能直接打字），所以默认一直留着。关掉后，设置窗口关上时图标跟着收起。"
        ) {
          Toggle("在程序坞显示图标", isOn: $dockIconOnTahoe)
            .toggleStyle(.switch)
        }
        .settingsAnchor(.generalDockIcon)
      }
    }
    Section {
      // 设置在系统的偏好设置里、日志在系统日志里，都不在这个目录：说明里不提（2026-10-29 照 Windows 的「数据目录」加）
      LabeledContent {
        Button("在访达中显示") { NSWorkspace.shared.open(AppDelegate.supportDirectory) }
          .accessibilityLabel("在访达中显示数据目录")
      } label: {
        Text("数据目录")
        Text("数据库、图片和每日备份都在这里")
      }
      .settingsAnchor(.generalDataFolder)
    }
  }

  private func recheck() {
    loginStatus = LaunchAtLogin.readStatus()
    let now = Self.missingPermissions()
    if now != missing { missing = now }
    latestBackup = Self.latestBackup(transfer)
  }

  /// 数据目录 backups/ 里最近一份（本机的，列一次目录）
  static func latestBackup(_ transfer: SettingsTransfer?) -> Date? {
    transfer?.backupFolder.flatMap { SettingsBackup.list(in: $0).first }.map(SettingsBackup.written)
  }

  private var launchAtLogin: Binding<Bool> {
    Binding {
      loginStatus == .enabled || loginStatus == .requiresApproval
    } set: { isOn in
      do {
        try LaunchAtLogin.set(isOn)
        loginError = nil
      } catch {
        loginError = String(localized: "设置失败：\(error.localizedDescription)")
      }
      loginStatus = LaunchAtLogin.readStatus()
    }
  }

  /// 缺几项授权：开着的功能用得着、却没给的辅助功能和屏幕录制（同欢迎引导的口径），加上剪贴板开着、剪贴板访问被拒绝或
  /// 要问；麦克风用到时才问，不算（不然新装的人一直挂着「缺 1 项」）
  static func missingPermissions(
    needs: [Permissions.Kind], granted: (Permissions.Kind) -> Bool, clipboardBlocked: Bool
  ) -> Int {
    needs.filter { !granted($0) }.count + (clipboardBlocked ? 1 : 0)
  }

  static func missingPermissions() -> Int {
    let features = Feature.enabled
    var blocked = false
    if #available(macOS 15.4, *), features.contains(.clipboard) {
      let behavior = NSPasteboard.general.accessBehavior
      blocked = behavior == .ask || behavior == .alwaysDeny
    }
    return missingPermissions(
      needs: OnboardingView.permissions(for: features), granted: { $0.isGranted ?? true },
      clipboardBlocked: blocked)
  }

  /// 「权限 ›」行尾
  static func permissionsValue(missing: Int) -> LocalizedStringResource {
    missing == 0 ? "都已允许" : "缺 \(missing) 项"
  }

  /// 「同步 ›」行尾：关 / 正在同步… / 上次同步的时刻（相对说法）/ 停了 / 等你确认（后两种橙字）。
  /// 一律写 return：switch 当表达式用时，里面的字面量抽字时会漏掉
  static func syncValue(
    status: NoteSyncer.Status, lastSync: Date?
  ) -> (text: LocalizedStringResource, isProblem: Bool) {
    switch status {
    case .off: return ("关", false)
    case .syncing: return ("正在同步…", false)
    case .stopped: return ("停了", true)
    case .waiting: return ("等你确认", true)
    case .idle:
      guard let lastSync else { return ("开着", false) }
      return (
        "\(lastSync.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))", false
      )
    }
  }

  /// 「备份与导出导入 ›」行尾：自动备份开着时是最近一份的时刻（「今天 09:12」）；关着；这台 Mac 上那份没备成时橙字
  static func backupValue(isOn: Bool, failed: Bool, latest: Date?) -> (
    text: LocalizedStringResource, isProblem: Bool
  ) {
    // 别写成三元式：元组里三元式的第二个分支抽字时会漏掉
    if !isOn { return ("自动备份关着", false) }
    if failed { return ("没备成", true) }
    guard let latest else { return ("还没有备份", false) }
    return ("\(SettingsBackup.when(latest))", false)
  }
}

/// 设置 › 通用 › 权限：辅助功能、屏幕录制、麦克风、剪贴板访问（15.4 起），同一种 PermissionRow；设置窗重新当 key 时刷新
private struct GeneralPermissionsPage: View {
  // 授权状态出现时、设置窗重新当 key 时现查（别放进初始值：通用页每重画一次这一页就重建一次）
  @State private var trusted = false
  @State private var screenRecording = false
  @State private var microphone = AVAuthorizationStatus.notDetermined
  /// NSPasteboard.AccessBehavior 的 rawValue（这个类型 macOS 15.4 才有），窗口变成 key 时刷新
  @State private var pasteboardBehavior = Self.currentPasteboardBehavior
  /// 页头那一句（缺几项）：出现时、设置窗重新当 key 时重查（跨进程问系统，别放进初始值：每次重建视图都会算一遍）
  @State private var missing = 0

  var body: some View {
    SubpageForm(
      subpage: .generalPermissions, status: GeneralTab.permissionsValue(missing: missing),
      statusIsProblem: missing > 0
    ) {
      Section {
        PermissionRow.accessibility(granted: trusted, short: true)
          .settingsAnchor(.generalAccessibility)
        PermissionRow.screenRecording(granted: screenRecording, short: true)
          .settingsAnchor(.generalScreenRecording)
        // 没问过时请求（系统弹框，回来就刷新）；拒绝过 / 受限的系统不再弹框，打开系统设置的麦克风页
        PermissionRow(
          title: "麦克风", detail: "录屏、录音时录下你的声音", symbol: "mic.fill",
          color: Style.Family.screenshot, granted: microphone == .authorized
        ) {
          guard microphone == .notDetermined else {
            return Permissions.Kind.microphone.openSettings()
          }
          Task {
            _ = await Permissions.requestMicrophone()
            microphone = Permissions.microphoneStatus
          }
        }
        .settingsAnchor(.generalMicrophone)
        if #available(macOS 15.4, *) { pasteboardAccess }
      }
    }
    .onAppear(perform: refresh)
    .onSettingsBecameKey(perform: refresh)
  }

  private func refresh() {
    trusted = Permissions.isAccessibilityTrusted
    screenRecording = Permissions.isScreenRecordingAllowed
    microphone = Permissions.microphoneStatus
    pasteboardBehavior = Self.currentPasteboardBehavior
    missing = GeneralTab.missingPermissions()
  }

  /// macOS 15.4 起的剪贴板隐私，和上面两行同一种权限行：「默认」（本 App 还不在系统设置的列表里）和「始终允许」
  /// 都算已授权；「询问」「拒绝」给「打开设置」。拒绝的后果写进说明，不另加红字
  @available(macOS 15.4, *)
  private var pasteboardAccess: some View {
    let behavior = pasteboardBehavior.flatMap(NSPasteboard.AccessBehavior.init(rawValue:))
    return PermissionRow(
      title: "剪贴板访问", detail: Self.pasteboardDetail(denied: behavior == .alwaysDeny),
      symbol: HotKeyAction.clipboard.symbol, color: Style.Family.clipboard,
      granted: behavior != .ask && behavior != .alwaysDeny, button: "打开设置",
      info: "到 系统设置 › \(Permissions.privacyPane) › 从其他 App 粘贴 里改成「始终允许」。"
    ) {
      // ponytail: 打开隐私那一栏的总页；「从其他 App 粘贴」的专用锚点真机查到再换
      NSWorkspace.shared.open(
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
    }
    .settingsAnchor(.generalClipboardAccess)
  }

  /// 剪贴板访问那一行的一句（别写成三元式：抽字会漏）
  private static func pasteboardDetail(denied: Bool) -> LocalizedStringResource {
    if denied { return "已被拒绝，剪贴板历史不再记新的" }
    return "后台记录剪贴板历史要它"
  }

  private static var currentPasteboardBehavior: Int? {
    if #available(macOS 15.4, *) { NSPasteboard.general.accessBehavior.rawValue } else { nil }
  }
}

/// 设置 › 通用 › 同步：原来通用页上的那一节原样搬进来（SyncSection）
private struct GeneralSyncPage: View {
  let syncer: NoteSyncer

  var body: some View {
    let value = GeneralTab.syncValue(status: syncer.status, lastSync: syncer.lastSync)
    SubpageForm(subpage: .generalSync, status: value.text, statusIsProblem: value.isProblem) {
      SyncSection(syncer: syncer)
    }
  }
}

/// 设置 › 通用 › 备份与导出导入：原来通用页上的「导出与导入」一节原样搬进来（TransferSection：导出、导入、每天自动备份、
/// 从备份恢复、另存一份到）
private struct GeneralBackupPage: View {
  let transfer: SettingsTransfer
  @AppStorage(Prefs.settingsBackupEnabled) private var backsUp = true
  @AppStorage(Prefs.settingsBackupProblem) private var backupProblem: String?
  @State private var latest: Date?

  var body: some View {
    let value = GeneralTab.backupValue(isOn: backsUp, failed: backupProblem != nil, latest: latest)
    SubpageForm(subpage: .generalBackup, status: value.text, statusIsProblem: value.isProblem) {
      TransferSection(transfer: transfer)
    }
    .onAppear { latest = GeneralTab.latestBackup(transfer) }
    .onSettingsBecameKey { latest = GeneralTab.latestBackup(transfer) }
  }
}

/// 一行权限：家族色块 + 名字 + 用途，右边是状态（未授权时带「去授权」）。从未授权变已授权时符号替换 + 弹一下
/// （Whisker §6 设置）；通用页和欢迎引导共用
struct PermissionRow: View {
  let title: LocalizedStringResource
  let detail: LocalizedStringResource
  let symbol: String
  let color: Color
  let granted: Bool
  /// 未授权时的按钮文字
  var button: LocalizedStringResource = "去授权"
  /// 行尾 ⓘ（设置改版 S5；引导里不用）
  var info: LocalizedStringResource? = nil
  let grant: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      KindTile(symbol: symbol, color: color, size: 24)
      VStack(alignment: .leading, spacing: 1) {
        Text(plain: title)
        // 11 pt：和系统画的行副标题同一个字号
        Text(plain: detail).font(.subheadline).foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      if let info { InfoButton(info, about: title) }
      PermissionStatus(granted: granted, button: button, grant: grant)
    }
    // 整行合成一个元素时 ⓘ 点不开：全文挂在整行的提示上，读屏不点也听得到
    .accessibilityHint(info.map { String(localized: $0) } ?? "")
    .accessibilityElement(children: .combine)
  }
}

extension PermissionRow {
  /// 辅助功能、屏幕录制这两行：通用 › 权限和欢迎引导的「授权」一屏共用，用途只写这一处。
  /// 「去授权」只弹一个窗（U10）：没请求过弹系统授权框，请求过了才打开系统设置
  /// short：设置 › 通用 › 权限 里的写法（一句 + 行尾 ⓘ 里的完整清单，设置改版 S5）；引导里照旧写全
  static func accessibility(granted: Bool, short: Bool = false) -> PermissionRow {
    let full: LocalizedStringResource =
      "粘贴回原 App、划词翻译、截图识别窗口里的元素、长截图自动滚动、录屏显示按键、状态屏拦住键鼠、程序坞预览、平滑滚动"
    return PermissionRow(
      title: "辅助功能", detail: short ? "粘贴回原 App、划词翻译这些要它" : full,
      symbol: "hand.raised.fill", color: Style.Family.command, granted: granted,
      info: short
        ? "粘贴回原 App、划词翻译、截图识别窗口里的元素、长截图自动滚动、录屏显示按键、状态屏拦住键鼠、程序坞预览、平滑滚动都要它。"
        : nil
    ) { Permissions.grant(.accessibility) }
  }

  static func screenRecording(granted: Bool, short: Bool = false) -> PermissionRow {
    let full: LocalizedStringResource = "截图、截图翻译、识字、录屏、录系统声音、程序坞预览的缩略图；授权后可能要重新打开本 App 才生效"
    return PermissionRow(
      title: "屏幕录制", detail: short ? "截图、录屏、识字要它" : full,
      symbol: HotKeyAction.screenRecord.symbol, color: Style.Family.screenshot, granted: granted,
      info: short
        ? "截图、截图翻译、识字、录屏、录系统声音、程序坞预览的缩略图都要它；授权后可能要重新打开本 App 才生效。"
        : nil
    ) { Permissions.grant(.screenRecording) }
  }
}

/// 授权状态：未授权时一个授权按钮 + 橙色 !，已授权是绿色 ✓（从未授权变已授权时符号替换 + 弹一下）。
/// PermissionRow 和欢迎引导的功能行共用；button 是按钮文字（引导里写明授权哪一项）
struct PermissionStatus: View {
  let granted: Bool
  var button: LocalizedStringResource = "去授权"
  let grant: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      if !granted { Button(button, action: grant) }
      Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(Color(nsColor: granted ? .systemGreen : .systemOrange))
        .contentTransition(.symbolEffect(.replace))
        .symbolEffect(.bounce, value: granted)
        .accessibilityLabel(granted ? "已授权" : "未授权")
    }
  }
}

/// 外观：和系统设置 › 外观一样的三张小缩略图，名字写在下面；选中的名字加粗，外面一圈强调色描边（隔 1.5 pt 缝，快速淡入）
private struct AppearancePicker: View {
  @Binding var selection: AppAppearance

  /// 缩略图四周给选中圈留的位置
  private static let ring: CGFloat = 4

  var body: some View {
    HStack(spacing: 6) {
      ForEach(AppAppearance.allCases) { option($0) }
    }
    // 选中圈往外露：最右一张缩略图自己的右边贴着同组控件的右边线（下面那排强调色色块、别的行的开关）
    .padding(.trailing, -Self.ring)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("外观")
  }

  private func option(_ appearance: AppAppearance) -> some View {
    let selected = selection == appearance
    return Button {
      selection = appearance
    } label: {
      VStack(spacing: 4) {
        AppearanceThumbnail(appearance: appearance)
          .padding(Self.ring)
          .overlay {
            if selected {
              RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
                .strokeBorder(Style.brand, lineWidth: 2.5)
                .transition(.opacity)
            }
          }
        Text(appearance.title)
          .font(.system(size: 12, weight: selected ? .semibold : .regular))
          .foregroundStyle(selected ? .primary : .secondary)
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .animation(.easeOut(duration: Style.fadeIn), value: selected)
    .accessibilityLabel(appearance.title)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

/// 一张外观缩略图：桌面渐变 + 一扇从左上角露出来的小窗口（标题栏、两条内容、一个强调色小点）；
/// 跟随系统 = 浅色、深色沿斜线各取一半。颜色是示意用的定值，不跟当前外观走（强调色点按缩略图自己的深浅取）
struct AppearanceThumbnail: View {
  let appearance: AppAppearance
  static let size = CGSize(width: 58, height: 38)

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Style.Radius.control, style: .continuous)
    let (w, h) = (Self.size.width, Self.size.height)
    ZStack {
      switch appearance {
      case .light: Self.desktop(dark: false)
      case .dark: Self.desktop(dark: true)
      case .system:
        Self.desktop(dark: false)
        Self.desktop(dark: true).mask(
          Path {
            $0.addLines([
              CGPoint(x: w * 0.62, y: 0), CGPoint(x: w, y: 0), CGPoint(x: w, y: h),
              CGPoint(x: w * 0.38, y: h),
            ])
          })
      }
    }
    .frame(width: w, height: h)
    .clipShape(shape)
    .overlay(shape.hairlineBorder())
  }

  /// 缩略图的桌面壁纸（设置里悬停预览的小桌面也用它）
  static func wallpaper(dark: Bool) -> [Color] {
    dark
      ? [Color(red: 0.11, green: 0.16, blue: 0.29), Color(red: 0.20, green: 0.15, blue: 0.31)]
      : [Color(red: 0.62, green: 0.74, blue: 0.92), Color(red: 0.84, green: 0.80, blue: 0.94)]
  }

  private static func desktop(dark: Bool) -> some View {
    let window = RoundedRectangle(cornerRadius: Style.Radius.mini, style: .continuous)
    let bar = Color(white: dark ? 1 : 0, opacity: dark ? 0.22 : 0.13)
    return LinearGradient(colors: wallpaper(dark: dark), startPoint: .top, endPoint: .bottom)
      .overlay(alignment: .topLeading) {
        VStack(alignment: .leading, spacing: 4) {
          Color(white: dark ? 0.24 : 0.91).frame(height: 7)  // 标题栏
          HStack(spacing: 3) {
            Circle().fill(Style.brand).frame(width: 5, height: 5)
            Capsule().fill(bar).frame(width: 20, height: 3)
          }
          .padding(.leading, 5)
          Capsule().fill(bar).frame(width: 28, height: 3).padding(.leading, 5)
        }
        .frame(width: 50, height: 32, alignment: .topLeading)
        .background(Color(white: dark ? 0.16 : 1))
        .clipShape(window)
        .overlay(window.strokeBorder(Color(white: dark ? 1 : 0, opacity: 0.12), lineWidth: 0.5))
        .offset(x: 10, y: 8)
      }
      .environment(\.colorScheme, dark ? .dark : .light)
  }
}

/// 强调色：和系统设置同样的一排色块（第一个多色 = 跟随系统），选中的那个中间一个白点、名字写在它下面
private struct AccentPicker: View {
  private let accent = Accent.shared
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: 10) {
      ForEach(AccentChoice.allCases) { swatch($0) }
    }
    // 选中项的名字挂在色块下面
    .padding(.bottom, 16)
    .animation(Style.Motion.pop.animation(reduced: reduceMotion), value: accent.choice)
  }

  private func swatch(_ choice: AccentChoice) -> some View {
    let selected = accent.choice == choice
    return Button {
      accent.select(choice)
    } label: {
      Circle()
        .fill(fill(of: choice))
        .overlay(Circle().hairlineBorder(.black.opacity(0.14)))
        .overlay {
          if selected {
            Circle().fill(.white).frame(width: 6, height: 6)
              .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
          }
        }
        .frame(width: 20, height: 20)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .overlay(alignment: .bottom) {
      if selected {
        Text(choice.title).font(.caption).foregroundStyle(.secondary).fixedSize().offset(y: 17)
      }
    }
    .help(choice.title)
    .accessibilityLabel(choice.title)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  /// 跟随系统 = 系统设置「多色」那样的一圈彩虹
  private func fill(of choice: AccentChoice) -> AnyShapeStyle {
    guard let fixed = choice.fixed else {
      let ring: [AccentChoice] = [.red, .orange, .yellow, .green, .blue, .purple, .pink, .red]
      return AnyShapeStyle(
        AngularGradient(
          colors: ring.compactMap { $0.fixed.map { Color(nsColor: $0.light) } }, center: .center))
    }
    return AnyShapeStyle(Style.dynamic(light: fixed.light, dark: fixed.dark))
  }
}

/// 外观：改 NSApp.appearance，没自己定外观的窗口（浮层毛玻璃、设置窗、菜单栏菜单、欢迎引导）立刻跟着变；
/// 截图 HUD（vibrantDark）、刘海岛（纯黑）、飞行卡片本来就固定深色，不受影响（mac-whisker §2）
enum AppAppearance: String, CaseIterable, Identifiable {
  case system, light, dark

  var id: String { rawValue }

  var title: String {
    switch self {
    // 显式 key：强调色、语言也有「跟随系统」，英文各叫各的（外观是系统设置里的 Auto）
    case .system: String(localized: "appearance.system", defaultValue: "跟随系统")
    case .light: String(localized: "浅色")
    case .dark: String(localized: "深色")
    }
  }

  /// 偏好值 → NSApp.appearance 的名字；nil = 跟随系统（没存过、存了认不得的值都算跟随系统）
  static func name(for pref: String?) -> NSAppearance.Name? {
    switch pref.flatMap(Self.init) {
    case .light: .aqua
    case .dark: .darkAqua
    case .system, nil: nil
    }
  }

  /// 按偏好设 NSApp.appearance：启动时（任何窗口出现前）和设置改了时各调一次
  static func apply() {
    NSApp.appearance = name(for: UserDefaults.standard.string(forKey: Prefs.appearance))
      .flatMap(NSAppearance.init(named:))
  }
}

/// 一个功能的开关（Feature）：通用 › 功能一节里的一行（家族色块 + 名字 + 说明），和每个功能页第一节的「启用剪贴板」
/// （`inPage`，不带色块：页头已经有）。两处绑同一个偏好、互相跟着变；运行中的东西由 AppDelegate 看着偏好跟上
struct FeatureToggle: View {
  let feature: Feature
  var inPage = false
  @AppStorage private var isOn: Bool

  init(feature: Feature, inPage: Bool = false) {
    self.feature = feature
    self.inPage = inPage
    _isOn = AppStorage(wrappedValue: feature.defaultOn, feature.prefsKey)
  }

  var body: some View {
    Toggle(isOn: $isOn) {
      if inPage {
        Text("启用\(feature.title)")
        Text(feature.blurb)
      } else {
        // 自己排的行：说明同快捷键页的行，11 pt secondary（mac-whisker-settings「设置页的说明文字」）
        HStack(spacing: 10) {
          KindTile(symbol: feature.page.symbol, color: feature.page.color, size: 20)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 2) {
            Text(feature.title)
            Text(feature.blurb).font(.subheadline).foregroundStyle(.secondary)
          }
        }
      }
    }
    // 通用页「功能」那一节新加的（WhatsNew 的 features）：拨过其中一个开关才算看过，光点进页面不算（2026-11-06）
    .onChange(of: isOn) { if !inPage { WhatsNew.touch(section: "功能", of: .general) } }
  }
}

extension View {
  /// 功能关着时这块设置变灰（还看得见）。清空、导出、导入、恢复这类管数据的操作不套它：关掉剪贴板的人可能正想清空它
  func gated(by feature: Feature) -> some View { modifier(FeatureGate(feature: feature)) }
}

private struct FeatureGate: ViewModifier {
  @AppStorage private var isOn: Bool

  init(feature: Feature) { _isOn = AppStorage(wrappedValue: feature.defaultOn, feature.prefsKey) }

  /// 分组表单里系统的 .disabled 只让控件变淡、标签和说明不变（屏外实测；同通用页「图标样式」那行的注释），
  /// 一眼看不出这块用不了：整块再乘上禁用的不透明度
  func body(content: Content) -> some View {
    content.disabled(!isOn).opacity(isOn ? 1 : Style.disabledOpacity)
  }
}

/// 登录时打开（登录项）：SMAppService.mainApp，系统设置里显示为本 App；通用页开关和欢迎引导第二屏的勾选框共用
enum LaunchAtLogin {
  /// 从 DMG（/Volumes/…）或 App Translocation 的随机只读路径运行时不注册：登录项会指向一个很快就失效的位置
  static var isInstalled: Bool {
    let path = Bundle.main.bundlePath
    return !path.hasPrefix("/Volumes/") && !path.contains("/AppTranslocation/")
  }

  /// 还没注册过登录项（要用户批准的、已经开着的都不算）
  static var isNotRegistered: Bool { readStatus() == .notRegistered }

  /// 上一次读到的状态（通用页的初值；2026-11-23 美化与提速 P6：sample 里每次换到通用页现读两遍，一遍约 35 ms）
  private(set) static var status = SMAppService.mainApp.status

  /// 现读一遍（跨进程）并记下
  static func readStatus() -> SMAppService.Status {
    status = SMAppService.mainApp.status
    return status
  }

  static func set(_ enabled: Bool) throws {
    if enabled {
      try SMAppService.mainApp.register()
    } else {
      try SMAppService.mainApp.unregister()
    }
  }
}
