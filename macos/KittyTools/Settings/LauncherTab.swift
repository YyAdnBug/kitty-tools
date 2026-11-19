// 设置 › 启动器（2026-11-18 设置改版 S4）：外面是搜索（空搜索框里列出常用，issue #2；搜索快捷指令，X10）、浏览器书签与历史
// （第 12 批：只列本机装了的，每家一行 16 pt App 图标 + 名字 + 书签开关，写读到了几条 / 没找到书签文件 / 需要完全磁盘访问权限
// （体检 B39）；开着时下面缩进一行「也搜浏览历史」，默认关，体检 D8）、文件搜索的文件夹授权，四个推进行：「应用别名 ›」
// 「网页搜索与快捷链接 ›」（WebSearchPage）「脚本命令 ›」（子页，里面是 ScriptsSection；「怎么写脚本」再推一层 ScriptGuidePage）
// 「命令和别名 ›」（LauncherCommandsPage），按键行。「高级…」：呼出时切英文输入法、面板位置（屏幕上方 / 跟随鼠标 / 上次位置，
// 同翻译浮窗）、面板大小、清空使用记录（管数据，功能关着也能点）。页头画在自己的 NavigationStack 里，推进时一起换掉。
// 按键说明不写在这里（N11，进快捷键速查表）；启动器没有固定，失焦就收起（N8）。

import SwiftUI

struct LauncherTab: View {
  /// 脚本库（脚本命令那两节列脚本、读不成的原因；截图自检给固定的或 nil）
  var scripts: ScriptLibrary? = nil
  /// 清空使用记录（LauncherUsage.clearAll）
  var clearUsage: () -> Void = {}
  /// 截图自检直接画「高级…」表单（sheet 画不进屏外截图）
  var drawsAdvanced = false
  @AppStorage(Prefs.launcherRomanInput) private var romanInput = false
  @AppStorage(Prefs.launcherShortcuts) private var searchesShortcuts = true
  @AppStorage(Prefs.launcherPanelPosition) private var panelPosition = "top"
  @AppStorage(Prefs.launcherShowsFrequent) private var showsFrequent = true
  @AppStorage(Prefs.launcherAppAliases) private var appAliasesText = ""
  /// 书签 / 浏览历史开着的浏览器 id（换行分隔，Browsers.ids 拆）
  @AppStorage(Prefs.launcherBrowserBookmarks) private var bookmarkIDs = Prefs.defaultBookmarkIDs
  @AppStorage(Prefs.launcherBrowserHistory) private var historyIDs = ""
  /// 网页搜索列表（只读：那一行的小字；改在 WebSearchPage）
  @AppStorage(Prefs.launcherWebSearchEngines) private var enginesData: Data?
  @AppStorage(Prefs.launcherScripts) private var scriptsOn = true
  /// 推进的详情页在 navigation.path（主菜单「返回」也要读写它）
  @Environment(SettingsNavigation.self) private var navigation
  @State private var confirmsClear = false
  /// 文件搜索的文件夹授权：nil = 还没问过，否则是被拒绝的文件夹（出现、设置窗成为 key 时刷新；
  /// 不写成初始值：初始值每次重建视图都会求值，要去读受保护目录）
  @State private var deniedFolders: [String]?
  /// 本机装了的浏览器和它的 App 位置（出现、设置窗变成 key 时重查；不写成初始值，同上）
  @State private var browsers: [(browser: Browsers.Browser, app: URL)] = []
  /// 设置窗变成 key 时加一：页面重画（书签条数重读）、浏览历史重读一次（去系统设置给了完全磁盘访问权限回来就能看到）
  @State private var checks = 0

  /// 「应用别名」那一行的小字（先算成不可选的：可选参数里直接写三元式，抽字时第二个分支会漏掉）
  private var aliasesDetail: LocalizedStringResource {
    let count = AppAliases(text: appAliasesText).count
    return count == 0 ? "用顺手的名字搜索应用" : "已为 \(count) 个应用设置别名"
  }

  var body: some View {
    NavigationStack(path: Bindable(navigation).path) {
      VStack(spacing: 0) {
        PageHeader(page: .launcher)
        form
      }
      .navigationTitle(SettingsPage.launcher.title)
      .navigationDestination(for: String.self) { id in
        switch id {
        case SettingsSubpage.launcherScripts.route: scriptsPage
        case LauncherCommandsPage.route: LauncherCommandsPage(library: scripts)
        case AppAliasesPage.route: AppAliasesPage()
        case ScriptGuidePage.route: ScriptGuidePage(library: scripts)
        case WebSearchPage.route: WebSearchPage()
        default: SearchEngineDetail(id: id)
        }
      }
      .advancedSheet(.launcher, summary: "输入法、面板和使用记录", inline: drawsAdvanced) { advanced }
    }
    .onAppear(perform: recheck)
    .onSettingsBecameKey(perform: recheck)
    // 开关变了、设置窗重新变 key：该读的浏览历史 / Firefox 书签在进程外读，关掉的扔掉
    .task(id: "\(bookmarkIDs)|\(historyIDs)|\(checks)") { await BrowserHistory.shared.refresh() }
  }

  /// 外面：搜索、浏览器、文件搜索、四个推进行、按键、高级…
  private var form: some View {
    Form {
      Section { FeatureToggle(feature: .launcher, inPage: true) }
      Group {
        Section {
          SettingRow(
            title: "空搜索框里列出常用", subtitle: "关掉后只有搜索框和收藏",
            info:
              "启动器按用过的次数和时间排序，空搜索框里先列收藏（⌘D 加入），再列「常用」。在「常用」里选中一项按 ⌘⌫ 可以单独移除，⌘Z 撤销。关掉后排序照样按用过的学。",
            isNew: WhatsNew.marks(section: "空搜索框里列出常用", of: .launcher, in: navigation.fresh)
          ) {
            Toggle("空搜索框里列出常用", isOn: $showsFrequent)
              .toggleStyle(.switch)
          }
          // 拨过这一行，「新」就算看过了（光点进这一页不算；WhatsNew）
          .onChange(of: showsFrequent) { WhatsNew.touch(section: "空搜索框里列出常用", of: .launcher) }
          .settingsAnchor(.launcherFrequent)
          // 快捷指令（X10）
          SettingRow(
            title: "搜索快捷指令", subtitle: "打快捷指令的名字就能运行",
            info: "不带输入；改了快捷指令，下次打开启动器时跟上。"
          ) {
            Toggle("搜索快捷指令", isOn: $searchesShortcuts)
              .toggleStyle(.switch)
          }
          .settingsAnchor(.launcherShortcuts)
        } header: {
          Text("搜索")
        }
        Section {
          ForEach(browsers, id: \.browser.id) { browserRows($0.browser, app: $0.app) }
        } header: {
          InfoHeader("浏览器书签与历史", info: "只列这台 Mac 上装了的浏览器。")
            .settingsAnchor(.launcherBrowsers)
        }
        Section {
          PermissionRow(
            title: "桌面、文稿、下载、iCloud 云盘", detail: "\(folderDetail)", symbol: "folder.fill",
            color: Style.Family.general, granted: deniedFolders == [],
            info:
              "「open 文件名」搜文件并打开，「find 文件名」在访达中显示；不想被搜到的文件夹加到 系统设置 › Spotlight › 搜索隐私。"
          ) {
            if deniedFolders == nil {
              deniedFolders = Permissions.requestFolderAccess()
            } else {
              Permissions.Kind.filesAndFolders.openSettings()
            }
          }
          .settingsAnchor(.launcherFileSearch)
        } header: {
          Text("文件搜索")
        }
        Section {
          SettingsPushRow(
            title: "应用别名",
            detail: aliasesDetail,
            isNew: WhatsNew.marks(section: "应用别名", of: .launcher, in: navigation.fresh)
          ) {
            navigation.path = [AppAliasesPage.route]
          }
          .settingsAnchor(.launcherAppAliases)
          SettingsPushRow(
            title: "网页搜索与快捷链接",
            detail: "\(WebSearchPage.summary(SearchEngineDetail.decode(enginesData)))"
          ) {
            navigation.path = [WebSearchPage.route]
          }
          .settingsAnchor(.launcherWebSearch)
          let scriptsState = Self.scriptsValue(
            on: scriptsOn, scripts: scripts?.scripts.count ?? 0,
            problems: scripts?.problems.count ?? 0)
          SettingsPushRow(
            title: SettingsSubpage.launcherScripts.title,
            isNew: SettingsItem.subpageIsNew(.launcherScripts, fresh: navigation.fresh),
            value: scriptsState.text, valueIsProblem: scriptsState.isProblem
          ) {
            navigation.path = [SettingsSubpage.launcherScripts.route]
          }
          .settingsAnchor(.launcherScripts)
          LauncherCommandsRow(library: scripts)
        }
        Section {
          SettingRow(
            title: "启动器里的按键", subtitle: "↩ 打开，⌘K 看全部操作",
            info: "能搜 App、系统设置、文件、书签、网址、路径、算式（也能换算单位和进制）和系统命令（lock、quit、kill 这些）。"
          ) {
            ShortcutsButton()
          }
          .settingsAnchor(.launcherKeys)
        }
      }
      .gated(by: .launcher)
      Section {
      } footer: {
        AdvancedButton(page: .launcher)
      }
    }
    .formStyle(.grouped)
    .settingsScrollTarget()
  }

  /// 设置 › 启动器 › 脚本命令（ScriptsSection 整段；「怎么写脚本」再推一层）
  private var scriptsPage: some View {
    let state = Self.scriptsValue(
      on: scriptsOn, scripts: scripts?.scripts.count ?? 0, problems: scripts?.problems.count ?? 0)
    return SubpageForm(
      subpage: .launcherScripts, status: state.text, statusIsProblem: state.isProblem
    ) {
      ScriptsSection(library: scripts)
        .gated(by: .launcher)
    }
  }

  /// 「高级…」表单：输入法、面板位置和大小、清空使用记录（管数据，功能关着也能点；确认框挂在表单里）
  @ViewBuilder private var advanced: some View {
    Section {
      SettingRow(title: "呼出时切到英文输入法", subtitle: "只在搜索框里，离开后恢复", info: "要搜中文时先关掉。") {
        Toggle("呼出时切到英文输入法", isOn: $romanInput)
          .toggleStyle(.switch)
      }
      .settingsAnchor(.launcherRomanInput)
      SettingRow(
        title: "面板位置", info: "屏幕上方是鼠标所在屏幕的上方正中，跟随鼠标是光标旁边，上次位置是上次拖到的地方。"
      ) {
        Picker("面板位置", selection: $panelPosition) {
          Text("屏幕上方").tag("top")
          Text("跟随鼠标").tag("mouse")
          Text("上次位置").tag("last")
        }
        .pickerStyle(.segmented)
      }
      .settingsAnchor(.launcherPanelPosition)
      PanelSizeRow(
        detail: "拖面板的边改大小", info: "拖左右两边改宽度，拖下边改最多显示几行。",
        widthKey: Prefs.launcherPanelWidth,
        heightKey: Prefs.launcherPanelRows, defaultWidth: Style.listPanelWidth
      )
      .settingsAnchor(.launcherPanelSize)
    }
    .gated(by: .launcher)
    Section {
      // 确认框挂在按钮上（挂在 Section 上会分到每一行）
      DangerButton("清空使用记录…") { confirmsClear = true }
        .confirmationDialog("清空启动器的使用记录？", isPresented: $confirmsClear) {
          Button("清空", role: .destructive, action: clearUsage)
        } message: {
          Text("「常用」和按使用习惯的排序会从头开始学，收藏不动。")
        }
        .settingsAnchor(.launcherClearUsage)
    } header: {
      Text("使用记录")
    } footer: {
      SectionFootnote("「常用」和按使用习惯的排序会从头开始学，收藏不动。")
    }
  }

  /// 「脚本命令 ›」行尾：开着「n 个脚本」，有读不成的橙「n 个有问题」；关着「关」（别写成三元式：抽字会漏）
  static func scriptsValue(on: Bool, scripts: Int, problems: Int) -> (
    text: LocalizedStringResource, isProblem: Bool
  ) {
    if !on { return ("关", false) }
    if problems > 0 { return ("\(problems) 个有问题", true) }
    return ("\(scripts) 个脚本", false)
  }

  private func recheck() {
    deniedFolders = Permissions.deniedFolders()
    browsers = Browsers.installed()
    checks += 1
    // 设置窗回到前台：脚本文件夹可能刚在访达里改过
    if UserDefaults.standard.bool(forKey: Prefs.launcherScripts) { scripts?.refresh() }
  }

  /// 一家浏览器：图标 + 名字 + 书签开关，开着时下面写读到了几条，没读到（没有书签文件、文件里一条都没有、没授权）
  /// 橙字（配置问题的语义色）；Safari 没授权时右边「去授权」，下面一行说明怎么加。条数和启动器搜的是同一份缓存，
  /// 文件没变不重读；关着的不读文件。书签开着时下面缩进一行「也搜浏览历史」（体检 D8，默认关）
  @ViewBuilder
  private func browserRows(_ browser: Browsers.Browser, app: URL) -> some View {
    let bookmarks = binding(for: browser, in: $bookmarkIDs)
    let status = bookmarks.wrappedValue ? Bookmarks.status(of: browser) : nil
    Toggle(isOn: bookmarks) {
      // 图标、「去授权」都对着名字那一行（开关也是）；图标 16 + 间距 8 = 下面「也搜浏览历史」缩进的 24
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
          .resizable()
          .frame(width: 16, height: 16)
          .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }  // 图标中线落在字的中线上
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(browser.name)
          Group {
            if let status {
              statusText(
                status, read: { "已读到 \($0) 条书签" }, empty: "书签文件里一条书签都没有",
                missing: "没找到书签文件")
            }
            if status == .needsAccess { Text("在列表里点 +，选中 Kitty Tools") }
          }
          .font(.subheadline)
          .foregroundStyle(.secondary)
        }
        if status == .needsAccess {
          Spacer(minLength: 8)
          Button("去授权", action: Permissions.Kind.fullDiskAccess.openSettings)
        }
      }
    }
    // 读屏在开关上也能直接去授权（按钮在开关的标签里）
    .accessibilityActions {
      if status == .needsAccess {
        Button("去授权", action: Permissions.Kind.fullDiskAccess.openSettings)
      }
    }
    if bookmarks.wrappedValue {
      let history = binding(for: browser, in: $historyIDs)
      Toggle(isOn: history) {
        // 每家下面都有这一行：读屏跳着找开关时要听得出是哪家的
        Text("也搜浏览历史").accessibilityLabel("也搜 \(browser.name) 的浏览历史")
        if history.wrappedValue {
          statusText(
            BrowserHistory.shared.status(.init(browser: browser, kind: .history)),
            read: { "已读到 \($0) 条历史" }, empty: "浏览历史里还没有常去的网页", missing: "没找到浏览历史文件")
        } else {
          // Safari 的库没有「手输过」这一项，只按访问次数
          Text(
            browser.format == .safari
              ? "去过两次以上的网页，排在书签后面" : "去过两次以上或手输过的网页，排在书签后面")
        }
      }
      .padding(.leading, 24)
    }
  }

  /// 开关 ↔ 偏好里的 id 列表
  private func binding(for browser: Browsers.Browser, in ids: Binding<String>) -> Binding<Bool> {
    Binding {
      Browsers.ids(ids.wrappedValue).contains(browser.id)
    } set: {
      ids.wrappedValue = Browsers.setting(browser.id, on: $0, in: ids.wrappedValue)
    }
  }

  /// 开关下的一行：「已读到 N 条书签」；没读到、没授权是橙字
  @ViewBuilder
  private func statusText(
    _ status: Browsers.Status, read: (Int) -> LocalizedStringResource,
    empty: LocalizedStringResource, missing: LocalizedStringResource
  ) -> some View {
    switch status {
    case .reading: Text("正在读取…")
    case .read(let count) where count > 0: Text(read(count))
    case .read: problem(empty)
    case .noFile: problem(missing)
    case .needsAccess: problem("需要完全磁盘访问权限")
    }
  }

  private func problem(_ text: LocalizedStringResource) -> some View {
    Text(plain: text).foregroundStyle(Color(nsColor: .systemOrange))
  }

  private var folderDetail: String {
    switch deniedFolders {
    case nil: String(localized: "还没允许：这些文件夹里的文件搜不到")
    case let denied? where denied.isEmpty: String(localized: "都已允许")
    case let denied?: String(localized: "没有权限：\(denied.joinedAsList())（去系统设置里打开）")
    }
  }
}
