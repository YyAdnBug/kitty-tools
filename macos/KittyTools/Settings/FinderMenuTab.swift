// 设置 › 访达右键（第十一族，2026-11-08 拍板，PLAN §10「访达右键」；页头由 SettingsRoot 画，家族色石板蓝）。几组：
// （2026-11-17 拍板 A1）第一组另有一行「控制访达」：访达工具栏按钮在 iCloud 云盘、网盘的文件夹里要它问访达选中了什么——
//   没问过点「授权…」让系统问，拒绝过点「去打开…」到 系统设置 › 自动化；页脚说工具栏按钮怎么放上去，桌面或文稿同步在 iCloud
//   里时多一行橙字（那里右键没有这些项）。
// 「访达右键」——启用开关（Feature.finderMenu，默认关）；系统里扩展开没开（FIFinderSyncController.isExtensionEnabled）和
//   「去打开…」；「收进一个子菜单」（Prefs.finderMenuGrouped，默认关）（拍板 D3：直接到 系统设置 › 通用 › 登录项与扩展）。15.0、15.1 的系统设置里没有扩展的入口，那两版上给一条
//   终端命令和「拷贝命令」（不替用户跑）。页脚说在哪右键、哪里不出现。
// 「新建文件」——右键里显示不显示、模板文件夹一行 +「在访达中显示」，页脚说菜单里有什么、建好后怎样。
// 「压缩和解压」里另有一行「压缩时跳过 ›」（2026-11-13 拍板 Z1，Prefs.finderCompressSkip）：小字写跳哪几个，推进 CompressSkipPage
//   （2026-11-15 原来的一行文本框改成推进去的一页）。页头画在自己的 NavigationStack 里，推进时一起换掉。
// 「拷贝」「整理文件」「压缩和解压」「隐藏、哈希、删除」——每一项一个开关（FinderMenuItem，2026-11-08 右键扩充拍板 A2；同几家成熟产品每项能单独关），页脚说做法。
//   「整理文件」里另有「在访达里用 ⌘X 剪切、⌘V 移动」（Prefs.finderMenuKeys，默认关，FinderKeys，issue #33）：开着又没有辅助功能
//   授权时下面一行橙字 + 打开辅助功能设置的按钮（同 设置 › 刘海岛「音量和亮度」）。
// 「「移动到」「复制到」的常用文件夹」——Prefs.finderTransferFolders（~ 开头的写法，默认桌面、文稿、下载）：加、移除。
// 「在 App 中打开」——访达右键里列哪几个 App（菜单项照访达自己的写法「在“终端”中打开」）（Prefs.finderOpenWithApps，默认只有终端）：加（正在运行的 / 从「应用程序」里选）、移除；
//   列表的写法同 剪贴板 › 不记录这些 App（从偏好现读再改、写回）。功能关着时这一组变灰。

import FinderSync
import SwiftUI
import UniformTypeIdentifiers

struct FinderMenuTab: View {
  /// 系统里扩展开没开（截图自检传固定的：屏外问不到真的状态）
  var extensionEnabled: Bool?
  /// 截图自检传固定的：控制访达的授权、桌面 / 文稿是不是同步在 iCloud 里
  var finderAutomation: Permissions.AutomationState?
  var desktopInICloud: Bool?
  /// 截图自检传固定的：辅助功能给没给（「⌘X 剪切、⌘V 移动」开着时下面那行橙字）
  var accessibilityTrusted: Bool?
  @State private var automation = Permissions.automation(Self.finderID)
  @State private var enabled = FIFinderSyncController.isExtensionEnabled
  @State private var folders = Self.storedFolders
  @State private var folderSelection: String?
  @State private var apps = Self.storedApps
  @State private var selection: String?
  @State private var copied = false
  @AppStorage(Prefs.finderMenuGrouped) private var grouped = false
  @AppStorage(Prefs.finderCompressSkip) private var compressSkip = ""
  @AppStorage(Prefs.finderTrashAfterExtract) private var trashAfterExtract = false
  @AppStorage(Prefs.finderMenuKeys) private var keys = false
  /// 设置窗重新当 key 时 +1：从系统设置给完辅助功能回来，「没有授权」那一行跟着重查
  @State private var accessChecks = 0
  /// 推进「压缩时跳过」用（截图自检单独画这一页时没有）
  @Environment(SettingsNavigation.self) private var navigation: SettingsNavigation?

  var body: some View {
    // 截图自检单独画这一页时没有导航状态：给一个自己的栈（同通用页）
    if let navigation {
      NavigationStack(path: Bindable(navigation).path) { page }
    } else {
      NavigationStack { page }
    }
  }

  private var page: some View {
    VStack(spacing: 0) {
      PageHeader(page: .finderMenu)
      // 从系统设置打开扩展回来，设置窗重新当 key 时刷新那一行（同程序坞预览页的授权）
      form.onSettingsBecameKey {
        enabled = FIFinderSyncController.isExtensionEnabled
        automation = Permissions.automation(Self.finderID)
        accessChecks += 1
      }
    }
    .navigationTitle(SettingsPage.finderMenu.title)
    .navigationDestination(for: String.self) { route in
      if route == CompressSkipPage.route { CompressSkipPage() }
    }
  }

  private var form: some View {
    Form {
      Section {
        PermissionRow(
          title: "在系统设置里打开", detail: "系统要你自己打开一次访达扩展，右键里才会出现这几项",
          symbol: "puzzlepiece.extension.fill", color: Style.Family.finderMenu,
          granted: extensionEnabled ?? enabled, button: "去打开…"
        ) { Self.openExtensionSettings() }
        .gated(by: .finderMenu)
        PermissionRow(
          title: "控制访达", detail: "访达工具栏上的「Kitty Tools」按钮在 iCloud 云盘、网盘的文件夹里要它，才知道你选中了什么",
          symbol: "gearshape.2.fill", color: Style.Family.finderMenu,
          granted: (finderAutomation ?? automation) == .granted, button: automationButton
        ) { requestFinderAutomation() }
        .gated(by: .finderMenu)
        Toggle(isOn: $grouped) {
          Text("收进一个子菜单")
          Text("右键第一层只多一项「Kitty Tools」，下面开着的这几项都在它里面")
        }
        .gated(by: .finderMenu)
      } header: {
        InfoHeader(
          "访达右键",
          info:
            "在访达里右键文件、文件夹，或者文件夹窗口的空白处，就有下面开着的这几项；也能把「Kitty Tools」按钮放到访达的工具栏上（访达 › 显示 › 自定工具栏…，把它拖上去），点它是同样的几项。iCloud 云盘（包括同步到 iCloud 的桌面、文稿）和网盘的文件夹里，系统不在右键里显示这些项，用工具栏按钮。"
        )
        .settingsAnchor(.finderMenu)
      } footer: {
        // 橙字是状态（桌面在 iCloud 里、旧系统没有那一项），照旧写在页脚
        let inICloud = desktopInICloud ?? Self.desktopInICloud
        if inICloud || !Self.settingsHaveEntry {
          VStack(alignment: .leading, spacing: 6) {
            if inICloud { iCloudHint }
            if !Self.settingsHaveEntry { oldSystemHint }
          }
        }
      }
      Section {
        ItemToggle(.newFile)
        LabeledContent {
          Button("在访达中显示") { NewFile.showTemplates() }
        } label: {
          Text("模板文件夹")
          Text("放进去的任何文件，右键「新建文件」里就多一项")
        }
      } header: {
        InfoHeader(
          "新建文件",
          info:
            "「新建文件」里有文本文件、Markdown、Word 文档、Excel 表格、PPT 演示文稿，和模板文件夹里放的文件；「从剪贴板新建」把剪贴板里的图存成 PNG、文字存成文本文件；「自定义后缀…」建一个任意后缀的空文件，可以顺手记进菜单。建好后在访达里选中它、直接改名；重名的自动加「 2」。"
        )
        .settingsAnchor(.finderNewFile)
      } footer: {
        SectionFootnote("建好后直接改名要「辅助功能」授权，没有就只选中。")
      }
      .gated(by: .finderMenu)
      Section {
        ItemToggle(.copyPath)
        ItemToggle(.copyName)
        ItemToggle(.copyText)
      } header: {
        InfoHeader("拷贝", info: "路径是完整路径、不加引号，选了几个就一行一个，空白处是这个文件夹的路径；拷好后刘海岛说一声，剪贴板历史里也有。")
          .settingsAnchor(.finderCopy)
      }
      .gated(by: .finderMenu)
      Section {
        ItemToggle(.transfer)
        ItemToggle(.cut)
        // 访达里的 ⌘X / ⌘V（FinderKeys，issue #33，默认关）
        Toggle(isOn: $keys) {
          HStack(spacing: 6) {
            Text("在访达里用 ⌘X 剪切、⌘V 移动")
            if let navigation,
              WhatsNew.marks(section: "在访达里用 ⌘X 剪切、⌘V 移动", of: .finderMenu, in: navigation.fresh)
            {
              NewTag()
            }
          }
          Text("和右键「剪切」是同一个剪切；剪切之后按 ⌘V 是移动，没剪切时照常粘贴")
        }
        .onChange(of: keys) { WhatsNew.touch(section: "在访达里用 ⌘X 剪切、⌘V 移动", of: .finderMenu) }
        // 开关关着时不去查授权
        if keys, !(accessibilityTrusted ?? Permissions.isAccessibilityTrusted) {
          LabeledContent {
            Button(Permissions.Kind.accessibility.settingsTitle) {
              Permissions.Kind.accessibility.openSettings()
            }
          } label: {
            Text("没有「辅助功能」授权，接不住这两个键").foregroundStyle(.orange)
          }
          .id(accessChecks)
        }
        ItemToggle(.deskAlias)
      } header: {
        InfoHeader(
          "整理文件",
          info:
            "不会覆盖：重名的自动加「 2」。搬得久时刘海岛显示进度、能停下，做完带「在访达中显示」。剪切之后又拷了别的东西，剪切就作废。⌘X、⌘V 只管按给访达的：改名、搜索时照常剪切粘贴，别的 App 不受影响；⌘V 的移动是访达自己做的（同 ⌥⌘V），重名时访达会问，撤销按 ⌘Z。要「辅助功能」授权。"
        )
        .settingsAnchor(.finderOrganize)
      }
      .gated(by: .finderMenu)
      Section {
        ItemToggle(.compress)
        // 压缩时另外跳过的名字（2026-11-13 拍板 Z1 Z2）：开关和列表在推进去的那一页
        SettingsPushRow(title: "压缩时跳过", detail: "\(CompressSkipPage.summary(compressSkip))") {
          navigation?.path = [CompressSkipPage.route]
        }
        ItemToggle(.extract)
        // 解压后把压缩包移到废纸篓（2026-11-17 拍板 B2，默认关）
        Toggle(isOn: $trashAfterExtract) {
          Text("解压后把压缩包移到废纸篓")
          Text("解压成功了才移；在废纸篓里能放回原处")
        }
        ItemToggle(.fixNames)
      } header: {
        InfoHeader(
          "压缩和解压",
          info:
            "压缩包放在旁边，重名的自动加「 2」；zip 里的中文名到别的系统上解开也不乱码，也不夹带 Mac 的隐藏文件（.DS_Store、._*、__MACOSX）。解压时只有一样东西就直接放在包旁边，几样就放进和包同名的文件夹；按住 ⌥ 右键是「解压到…」，自己选放在哪；别的系统打的 zip，中文名也解得对。修复乱码文件名之后，刘海岛上能撤销。包里不带访达的标签、替身和自定义图标，要在 Mac 之间原样传，用访达自带的「压缩」。"
        )
        .settingsAnchor(.finderArchive)
      }
      .gated(by: .finderMenu)
      Section {
        ItemToggle(.showHidden)
        ItemToggle(.hide)
        ItemToggle(.hash)
        ItemToggle(.erase)
      } header: {
        InfoHeader(
          "隐藏、哈希、删除",
          info:
            "这几项默认关着。点开头的文件本来就是隐藏的，不出现「取消隐藏」；隐藏了的东西，在访达里按 ⇧⌘. 就能看到。拷贝哈希只给文件算，算完也记进剪贴板历史。"
        )
        .settingsAnchor(.finderHidden)
      } footer: {
        SectionFootnote("彻底删除每次都先问，删了不进废纸篓，找不回来。")
      }
      .gated(by: .finderMenu)
      Section {
        folderList
        ListEditBar(
          removeTitle: "移除所选的文件夹", canRemove: folderSelection != nil, remove: removeFolder
        ) {
          Button {
            chooseFolders()
          } label: {
            Image(systemName: "plus")
          }
          .buttonStyle(.borderless)
          .help("添加文件夹")
        }
      } header: {
        InfoHeader("「移动到」「复制到」的常用文件夹", info: "子菜单里按这个顺序列（拖动调整），后面接最近用「选择文件夹…」选过的 3 个；这次用不上的会变灰。")
          .settingsAnchor(.finderFolders)
      }
      .gated(by: .finderMenu)
      Section {
        appList
        ListEditBar(
          removeTitle: "移除所选的 App", canRemove: selection != nil, remove: removeSelected
        ) {
          Menu {
            if !installedTools.isEmpty {
              Menu("这台 Mac 上的终端和编辑器") {
                ForEach(installedTools, id: \.bundleID) { app in
                  Button(app.name) { add(app.bundleID) }.disabled(apps.contains(app.bundleID))
                }
              }
            }
            Menu("正在运行的 App") {
              ForEach(AppListRow.runningApps, id: \.bundleID) { app in
                Button(app.name) { add(app.bundleID) }.disabled(apps.contains(app.bundleID))
              }
            }
            Button("选择 App…", action: chooseApps)
          } label: {
            Image(systemName: "plus")
          }
          .menuStyle(.borderlessButton)
          .menuIndicator(.hidden)
          .help("添加 App")
        }
      } header: {
        InfoHeader(
          "在 App 中打开",
          info:
            "文件夹原样交给 App；文件交给认得它的 App，不认得的改成打开它所在的文件夹。脚本和可执行文件只交给编辑器，交给终端的是它所在的文件夹，不会运行它。选了几样时编辑器全打开，终端只开第一个。"
        )
        .settingsAnchor(.finderOpenWith)
      }
      .gated(by: .finderMenu)
      PluginAboutSection(plugin: .finderMenu)
    }
    .formStyle(.grouped)
    .settingsScrollTarget()
    // 同步、导入落下了新的列表：页面跟上（同剪贴板页的排除列表）
    .task {
      for await _ in NotificationCenter.default.notifications(
        named: UserDefaults.didChangeNotification)
      {
        let stored = Self.storedApps
        if stored != apps { apps = stored }
        let storedFolders = Self.storedFolders
        if storedFolders != folders { folders = storedFolders }
      }
    }
  }

  // MARK: 常用文件夹

  private var folderList: some View {
    List(selection: $folderSelection) {
      if folders.isEmpty {
        Text("没有常用文件夹：子菜单里只有最近选过的和「选择文件夹…」").foregroundStyle(.secondary)
      }
      ForEach(folders, id: \.self) { FolderRow(path: $0).tag($0) }
        .onMove { from, to in changeFolders { $0.move(fromOffsets: from, toOffset: to) } }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .orderedListFrame(rows: folders.count)
    .onDeleteCommand(perform: removeFolder)
  }

  private static var storedFolders: [String] {
    UserDefaults.standard.stringArray(forKey: Prefs.finderTransferFolders)
      ?? Prefs.finderTransferDefault
  }

  /// 改列表：从偏好现读再改、写回
  private func changeFolders(_ edit: (inout [String]) -> Void) {
    var list = Self.storedFolders
    edit(&list)
    UserDefaults.standard.set(list, forKey: Prefs.finderTransferFolders)
    folders = list
  }

  private func removeFolder() {
    guard let path = folderSelection else { return }
    changeFolders { $0.removeAll { $0 == path } }
    folderSelection = nil
  }

  /// 选文件夹（可多选），存成 ~ 开头的写法
  private func chooseFolders() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = true
    panel.prompt = String(localized: "添加")
    panel.message = String(localized: "选择的文件夹会出现在访达右键的「移动到」「复制到」里")
    guard panel.runModal() == .OK else { return }
    changeFolders { list in
      for url in panel.urls {
        let path = (url.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
        if !list.contains(path) { list.append(path) }
      }
    }
  }

  // MARK: 系统设置里的扩展

  /// 15.2 起系统设置里才有访达扩展的入口（15.0、15.1 被 Apple 无意去掉了，开发者论坛 DTS 的说法）
  static var settingsHaveEntry: Bool {
    ProcessInfo.processInfo.isOperatingSystemAtLeast(
      OperatingSystemVersion(majorVersion: 15, minorVersion: 2, patchVersion: 0))
  }

  /// 15.0、15.1 上打开扩展的终端命令（扩展的 id = App 的 id 加 .finder）
  static var enableCommand: String {
    "pluginkit -e use -i \(Bundle.main.bundleIdentifier ?? "com.yy.kitty-tools.native").finder"
  }

  static func openExtensionSettings() {
    FIFinderSyncController.showExtensionManagementInterface()
  }

  /// 访达的 bundle id（控制访达的授权按它查）
  static let finderID = "com.apple.finder"

  /// 桌面或文稿同步在 iCloud 里（系统设置 › Apple 账户 › iCloud 云盘「桌面与文稿文件夹」）：那里右键没有我们的项。
  /// 两路都看：访达自己记的那两个开关（FXICloudDriveDesktop / Documents，只读），文件夹本身是不是 iCloud 的。
  /// ponytail: 开发机没开这项同步，两路都没在开着的机器上验过；有人说橙字该出没出再查
  static var desktopInICloud: Bool {
    let finder = UserDefaults(suiteName: "com.apple.finder")
    if finder?.bool(forKey: "FXICloudDriveDesktop") == true
      || finder?.bool(forKey: "FXICloudDriveDocuments") == true
    {
      return true
    }
    return [FileManager.SearchPathDirectory.desktopDirectory, .documentDirectory].contains { kind in
      FileManager.default.urls(for: kind, in: .userDomainMask).first.map {
        FileManager.default.isUbiquitousItem(at: $0)
      } == true
    }
  }

  private var automationButton: LocalizedStringResource {
    (finderAutomation ?? automation) == .denied ? "去打开…" : "授权…"
  }

  /// 没问过：跑一句真要访达回答的 AppleScript（数访达窗口；「return name」AppleScript 自己就答了、不发事件，系统不问，评审），
  /// 让系统弹「想控制“访达”」的框（进程外，要等用户点）；拒绝过：系统设置里手动打开
  private func requestFinderAutomation() {
    guard automation != .denied else { return Permissions.Kind.automation.openSettings() }
    Task {
      _ = try? await Subprocess.run(
        "/usr/bin/osascript", ["-e", "tell application \"Finder\" to count Finder windows"],
        captures: true,
        timeout: .seconds(150))
      automation = Permissions.automation(Self.finderID)
    }
  }

  private var iCloudHint: some View {
    Text("你的桌面、文稿同步在 iCloud 里：那里右键没有这些项，把「Kitty Tools」按钮放到访达工具栏上用。")
      .font(.caption)
      .foregroundStyle(Color(nsColor: .systemOrange))
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 10)
  }

  private var oldSystemHint: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text("这台 Mac 的系统设置里没有访达扩展的入口（macOS 15.2 起才有）：在终端里运行「\(Self.enableCommand)」打开它。")
        .font(.caption)
        .foregroundStyle(Color(nsColor: .systemOrange))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button(copied ? "已拷贝" : "拷贝命令") {
        Paster.write(string: Self.enableCommand)
        copied = true
      }
      .controlSize(.small)
    }
    .padding(.horizontal, 10)
  }

  // MARK: 用 App 打开

  private var appList: some View {
    List(selection: $selection) {
      if apps.isEmpty {
        Text("右键里不列「在“X”中打开」").foregroundStyle(.secondary)
      }
      ForEach(apps, id: \.self) { AppListRow(bundleID: $0).tag($0) }
        .onMove { from, to in change { $0.move(fromOffsets: from, toOffset: to) } }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .orderedListFrame(rows: apps.count)
    .onDeleteCommand(perform: removeSelected)
  }

  private static var storedApps: [String] { FinderLink.openWithApps }

  /// 改列表：从偏好现读再改、写回（页面上那份可能还没跟上同步刚落下的）
  private func change(_ edit: (inout [String]) -> Void) {
    var list = Self.storedApps
    edit(&list)
    UserDefaults.standard.set(list, forKey: Prefs.finderOpenWithApps)
    apps = list
  }

  private func add(_ bundleID: String) {
    change { list in
      if !list.contains(bundleID) { list.append(bundleID) }
    }
  }

  private func removeSelected() {
    guard let id = selection else { return }
    change { $0.removeAll { $0 == id } }
    selection = nil
  }

  /// 从「应用程序」里选（可多选），按 App 包的 bundle ID 加进来
  private func chooseApps() {
    AppListRow.chooseApps(prompt: "添加", message: "选择的 App 会出现在访达右键里：在“这个 App”中打开")
      .forEach(add)
  }

  /// 这台 Mac 上装着的常用终端和编辑器（FinderLink.knownTools 里找得到的，同几家成熟产品加 App 时给的预设）
  private var installedTools: [(bundleID: String, name: String)] {
    FinderLink.knownTools.compactMap { id in
      NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { url in
        var name = FileManager.default.displayName(atPath: url.path(percentEncoded: false))
        if name.hasSuffix(".app") { name.removeLast(4) }
        return (id, name)
      }
    }
  }

}

/// 访达右键里一项的开关（FinderMenuItem：偏好键、默认值、名字和小字都从它取）
private struct ItemToggle: View {
  let item: FinderMenuItem
  @AppStorage private var isOn: Bool

  init(_ item: FinderMenuItem) {
    self.item = item
    _isOn = AppStorage(wrappedValue: item.defaultOn, item.prefsKey)
  }

  var body: some View {
    Toggle(isOn: $isOn) {
      Text(item.title)
      Text(item.detail)
    }
  }
}

/// 常用文件夹的一行：访达里的图标和名字，小字是路径；这台 Mac 上没有的写出来
private struct FolderRow: View {
  let path: String

  var body: some View {
    let full = FileMoves.expand(path)
    let exists = FileManager.default.fileExists(atPath: full)
    HStack(spacing: 8) {
      Image(nsImage: NSWorkspace.shared.icon(forFile: full)).resizable().frame(
        width: 16, height: 16)
      Text(FileManager.default.displayName(atPath: full))
        .lineLimit(1)
        .truncationMode(.tail)
      (exists ? Text(verbatim: path) : Text("这台 Mac 上没有"))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 0)
    }
    .frame(height: OrderedList.rowHeight - 8)
    .help(path)
    .accessibilityElement(children: .combine)
  }
}
