// 设置 › 启动器：呼出时切英文输入法、面板位置（屏幕上方 / 跟随鼠标 / 上次位置，同翻译浮窗）、文件搜索的文件夹授权、浏览器书签与历史（第 12 批：只列本机装了的，每家一行
// 16 pt App 图标 + 名字 + 书签开关，写读到了几条 / 没找到书签文件 / 需要完全磁盘访问权限（体检 B39）；开着时下面缩进
// 一行「也搜浏览历史」，默认关，体检 D8）、网页搜索与快捷链接、使用记录（「空搜索框里列出常用」开关，issue #2；清空使用记录）
// （2026-11-07 起这一页只留一行「网页搜索与快捷链接 ›」写几个搜索、几个快捷链接、谁兜底，那张列表推进 WebSearchPage，
// 同「命令和别名」）、清空使用记录。页头画在自己的 NavigationStack 里，推进时一起换掉。
// 按键说明不写在这里（N11，进快捷键速查表）；启动器没有固定，失焦就收起（N8）。
// 2026-11-07 脚本命令：网页搜索后面是「脚本命令」「命令」两节（ScriptsSection），「怎么写脚本」（ScriptGuidePage）和
// 「命令和别名」那张表（LauncherCommandsPage）推进去看，同网页搜索的详情页。

import SwiftUI

struct LauncherTab: View {
  /// 脚本库（脚本命令那两节列脚本、读不成的原因；截图自检给固定的或 nil）
  var scripts: ScriptLibrary? = nil
  /// 清空使用记录（LauncherUsage.clearAll）
  var clearUsage: () -> Void = {}
  @AppStorage(Prefs.launcherRomanInput) private var romanInput = false
  @AppStorage(Prefs.launcherPanelPosition) private var panelPosition = "top"
  @AppStorage(Prefs.launcherShowsFrequent) private var showsFrequent = true
  /// 书签 / 浏览历史开着的浏览器 id（换行分隔，Browsers.ids 拆）
  @AppStorage(Prefs.launcherBrowserBookmarks) private var bookmarkIDs = Prefs.defaultBookmarkIDs
  @AppStorage(Prefs.launcherBrowserHistory) private var historyIDs = ""
  /// 网页搜索列表（只读：那一行的小字；改在 WebSearchPage）
  @AppStorage(Prefs.launcherWebSearchEngines) private var enginesData: Data?
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

  var body: some View {
    NavigationStack(path: Bindable(navigation).path) {
      VStack(spacing: 0) {
        PageHeader(page: .launcher)
        form
      }
      .navigationTitle(SettingsPage.launcher.title)
      .navigationDestination(for: String.self) { id in
        switch id {
        case LauncherCommandsPage.route: LauncherCommandsPage(library: scripts)
        case ScriptGuidePage.route: ScriptGuidePage(library: scripts)
        case WebSearchPage.route: WebSearchPage()
        default: SearchEngineDetail(id: id)
        }
      }
    }
    .onAppear(perform: recheck)
    .onSettingsBecameKey(perform: recheck)
    // 开关变了、设置窗重新变 key：该读的浏览历史 / Firefox 书签在进程外读，关掉的扔掉
    .task(id: "\(bookmarkIDs)|\(historyIDs)|\(checks)") { await BrowserHistory.shared.refresh() }
    .confirmationDialog("清空启动器的使用记录？", isPresented: $confirmsClear) {
      Button("清空", role: .destructive, action: clearUsage)
    } message: {
      Text("「常用」和按使用习惯的排序会从头开始学，收藏不动。")
    }
  }

  private var form: some View {
    // 关着时（Feature）变灰，只有「清空使用记录」照常能点
    Form {
      Section { FeatureToggle(feature: .launcher, inPage: true) }
      Group {
        Section {
          Toggle(isOn: $romanInput) {
            Text("呼出时切到英文输入法")
            Text("只在搜索框里生效，离开后恢复；要搜中文时先关掉")
          }
          Picker(selection: $panelPosition) {
            Text("屏幕上方").tag("top")
            Text("跟随鼠标").tag("mouse")
            Text("上次位置").tag("last")
          } label: {
            Text("面板位置")
            Text("屏幕上方是鼠标所在屏幕的上方正中，跟随鼠标是光标旁边，上次位置是上次拖到的地方")
          }
          .pickerStyle(.segmented)
          PanelSizeRow(
            detail: "拖左右两边改宽度，拖下边改最多显示几行", widthKey: Prefs.launcherPanelWidth,
            heightKey: Prefs.launcherPanelRows, defaultWidth: Style.listPanelWidth)
          LabeledContent {
            ShortcutsButton()
          } label: {
            Text("启动器里的按键")
            Text(
              "搜 App、系统设置、文件、书签、网址、路径、算式（也能换算单位和进制）和系统命令（lock、quit、kill 这些），"
                + "↩ 打开，⌘K 看这一项的全部操作")
          }
        }
        Section {
          PermissionRow(
            title: "桌面、文稿、下载、iCloud 云盘", detail: folderDetail, symbol: "folder.fill",
            color: Style.Family.general, granted: deniedFolders == []
          ) {
            if deniedFolders == nil {
              deniedFolders = Permissions.requestFolderAccess()
            } else {
              Permissions.Kind.filesAndFolders.openSettings()
            }
          }
        } header: {
          Text("文件搜索")
        } footer: {
          SectionFootnote(
            "「open 文件名」搜文件并打开，「find 文件名」在访达中显示；不想被搜到的文件夹加到 系统设置 › Spotlight › 搜索隐私。")
        }
        Section {
          ForEach(browsers, id: \.browser.id) { browserRows($0.browser, app: $0.app) }
        } header: {
          Text("浏览器书签与历史")
        } footer: {
          SectionFootnote("只列本机装了的浏览器。")
        }
        Section {
          SettingsPushRow(
            title: "网页搜索与快捷链接",
            detail: WebSearchPage.summary(SearchEngineDetail.decode(enginesData))
          ) {
            navigation.path = [WebSearchPage.route]
          }
        } header: {
          Text("网页搜索")
        } footer: {
          SectionFootnote("「关键词 空格 内容」直接用那个网站搜；没有本地结果时用开了兜底的几个搜。")
        }
      }
      .gated(by: .launcher)
      ScriptsSection(library: scripts)
        .gated(by: .launcher)
      Section {
        // 显示的开关跟着功能开关变灰；清空使用记录是管数据的，关着也能点（mac-native §1）
        Toggle(isOn: $showsFrequent) {
          NewTitle("空搜索框里列出常用", page: .launcher, fresh: navigation.fresh)
          Text("关掉后打开启动器只有搜索框，有收藏时只列收藏；排序照样按用过的学")
        }
        .gated(by: .launcher)
        // 拨过这一行，「新」就算看过了（光点进这一页不算；WhatsNew）
        .onChange(of: showsFrequent) { WhatsNew.touch(section: "空搜索框里列出常用", of: .launcher) }
        DangerButton("清空使用记录…") { confirmsClear = true }
      } header: {
        Text("使用记录")
      } footer: {
        SectionFootnote(
          "启动器按用过的次数和时间排序，空搜索框里先列收藏（⌘D 加入），再列「常用」。在「常用」里选中一项按 ⌘⌫ 可以单独移除，⌘Z 撤销。")
      }
    }
    .formStyle(.grouped)
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
                status, noun: "书签", empty: "书签文件里一条书签都没有", missing: "没找到书签文件")
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
            BrowserHistory.shared.status(.init(browser: browser, kind: .history)), noun: "历史",
            empty: "浏览历史里还没有常去的网页", missing: "没找到浏览历史文件")
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
  private func statusText(_ status: Browsers.Status, noun: String, empty: String, missing: String)
    -> some View
  {
    switch status {
    case .reading: Text("正在读取…")
    case .read(let count) where count > 0: Text("已读到 \(count) 条\(noun)")
    case .read: problem(empty)
    case .noFile: problem(missing)
    case .needsAccess: problem("需要完全磁盘访问权限")
    }
  }

  private func problem(_ text: String) -> some View {
    Text(text).foregroundStyle(Color(nsColor: .systemOrange))
  }

  private var folderDetail: String {
    switch deniedFolders {
    case nil: "还没允许：这些文件夹里的文件搜不到"
    case let denied? where denied.isEmpty: "都已允许"
    case let denied?: "没有权限：" + denied.joined(separator: "、") + "（去系统设置里打开）"
    }
  }
}
