// 设置 › 访达右键（第十一族，2026-11-08 拍板，PLAN §10「访达右键」；页头由 SettingsRoot 画，家族色石板蓝）。几组：
// 「访达右键」——启用开关（Feature.finderMenu，默认关）；系统里扩展开没开（FIFinderSyncController.isExtensionEnabled）和
//   「去打开…」（拍板 D3：直接到 系统设置 › 通用 › 登录项与扩展）。15.0、15.1 的系统设置里没有扩展的入口，那两版上给一条
//   终端命令和「拷贝命令」（不替用户跑）。页脚说在哪右键、哪里不出现。
// 「新建文件」——右键里显示不显示、模板文件夹一行 +「在访达中显示」，页脚说菜单里有什么、建好后怎样。
// 「拷贝」「整理文件」「压缩和解压」——每一项一个开关（FinderMenuItem，2026-11-08 右键扩充拍板 A2；同几家成熟产品每项能单独关），页脚说做法。
// 「「移动到」「复制到」的常用文件夹」——Prefs.finderTransferFolders（~ 开头的写法，默认桌面、文稿、下载）：加、移除。
// 「在 App 中打开」——访达右键里列哪几个 App（菜单项照访达自己的写法「在“终端”中打开」）（Prefs.finderOpenWithApps，默认只有终端）：加（正在运行的 / 从「应用程序」里选）、移除；
//   列表的写法同 剪贴板 › 不记录这些 App（从偏好现读再改、写回）。功能关着时这一组变灰。

import FinderSync
import SwiftUI
import UniformTypeIdentifiers

struct FinderMenuTab: View {
  /// 系统里扩展开没开（截图自检传固定的：屏外问不到真的状态）
  var extensionEnabled: Bool?
  @State private var enabled = FIFinderSyncController.isExtensionEnabled
  @State private var folders = Self.storedFolders
  @State private var folderSelection: String?
  @State private var apps = Self.storedApps
  @State private var selection: String?
  @State private var copied = false

  var body: some View {
    // 从系统设置打开扩展回来，设置窗重新当 key 时刷新那一行（同程序坞预览页的授权）
    form.onSettingsBecameKey { enabled = FIFinderSyncController.isExtensionEnabled }
  }

  private var form: some View {
    Form {
      Section {
        FeatureToggle(feature: .finderMenu, inPage: true)
        PermissionRow(
          title: "在系统设置里打开", detail: "系统要你自己打开一次访达扩展，右键里才会出现这几项",
          symbol: "puzzlepiece.extension.fill", color: Style.Family.finderMenu,
          granted: extensionEnabled ?? enabled, button: "去打开…"
        ) { Self.openExtensionSettings() }
        .gated(by: .finderMenu)
      } header: {
        Text("访达右键")
      } footer: {
        VStack(alignment: .leading, spacing: 6) {
          SectionFootnote(
            "在访达里右键文件、文件夹，或者文件夹窗口的空白处，就有下面开着的这几项。iCloud 云盘和网盘的文件夹里，系统不显示这些项。"
          )
          if !Self.settingsHaveEntry { oldSystemHint }
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
        Text("新建文件")
      } footer: {
        SectionFootnote(
          "「新建文件」里有文本文件、Markdown、Word 文档、Excel 表格、PPT 演示文稿，和模板文件夹里放的文件；「自定义后缀…」建一个任意后缀的空文件，可以顺手记进菜单。建好后在访达里选中它、直接改名（要「辅助功能」授权，没有就只选中）；重名的自动加「 2」。"
        )
      }
      .gated(by: .finderMenu)
      Section {
        ItemToggle(.copyPath)
        ItemToggle(.copyName)
      } header: {
        Text("拷贝")
      } footer: {
        SectionFootnote("路径是完整路径、不加引号，选了几个就一行一个，空白处是这个文件夹的路径；拷好后刘海岛说一声，剪贴板历史里也有。")
      }
      .gated(by: .finderMenu)
      Section {
        ItemToggle(.transfer)
        ItemToggle(.cut)
        ItemToggle(.deskAlias)
      } header: {
        Text("整理文件")
      } footer: {
        SectionFootnote(
          "不会覆盖：重名的自动加「 2」。搬得久时刘海岛显示进度、能停下，做完带「在访达中显示」。剪切之后又拷了别的东西，剪切就作废。"
        )
      }
      .gated(by: .finderMenu)
      Section {
        ItemToggle(.compress)
        ItemToggle(.extract)
        ItemToggle(.fixNames)
      } header: {
        Text("压缩和解压")
      } footer: {
        SectionFootnote(
          "压缩包放在旁边，重名的自动加「 2」；zip 里的中文名到别的系统上解开也不乱码，也不夹带 Mac 的隐藏文件。解压时只有一样东西就直接放在包旁边，几样就放进和包同名的文件夹；别的系统打的 zip，中文名也解得对。修复乱码文件名之后，刘海岛上能撤销。"
        )
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
        Text("「移动到」「复制到」的常用文件夹")
      } footer: {
        SectionFootnote("子菜单里按这个顺序列，最后总有「选择文件夹…」。")
      }
      .gated(by: .finderMenu)
      Section {
        appList
        ListEditBar(
          removeTitle: "移除所选的 App", canRemove: selection != nil, remove: removeSelected
        ) {
          Menu {
            Menu("正在运行的 App") {
              ForEach(runningApps, id: \.bundleID) { app in
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
        Text("在 App 中打开")
      } footer: {
        SectionFootnote(
          "文件夹原样交给 App；文件交给认得它的 App，不认得的改成打开它所在的文件夹。脚本和可执行文件只交给编辑器，交给终端的是它所在的文件夹，不会运行它。选了几样时编辑器全打开，终端只开第一个。"
        )
      }
      .gated(by: .finderMenu)
    }
    .formStyle(.grouped)
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
        Text("只有「选择文件夹…」").foregroundStyle(.secondary)
      }
      ForEach(folders, id: \.self) { FolderRow(path: $0).tag($0) }
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
    panel.prompt = "添加"
    panel.message = "选择的文件夹会出现在访达右键的「移动到」「复制到」里"
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
    let panel = NSOpenPanel()
    panel.directoryURL = URL(filePath: "/Applications")
    panel.allowedContentTypes = [.applicationBundle]
    panel.allowsMultipleSelection = true
    panel.prompt = "添加"
    panel.message = "选择的 App 会出现在访达右键里：在“这个 App”中打开"
    guard panel.runModal() == .OK else { return }
    for url in panel.urls {
      if let id = Bundle(url: url)?.bundleIdentifier { add(id) }
    }
  }

  /// 正在运行的普通 App（有程序坞图标的），按名称排序
  private var runningApps: [(bundleID: String, name: String)] {
    NSWorkspace.shared.runningApplications
      .filter { $0.activationPolicy == .regular && $0 != .current }
      .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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
      Text(exists ? path : "这台 Mac 上没有")
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
