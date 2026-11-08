// 设置 › 访达右键（第十一族，2026-11-08 拍板，PLAN §10「访达右键」；页头由 SettingsRoot 画，家族色石板蓝）。两组：
// 「访达右键」——启用开关（Feature.finderMenu，默认关）；系统里扩展开没开（FIFinderSyncController.isExtensionEnabled）和
//   「去打开…」（拍板 D3：直接到 系统设置 › 通用 › 登录项与扩展）。15.0、15.1 的系统设置里没有扩展的入口，那两版上给一条
//   终端命令和「拷贝命令」（不替用户跑）。页脚说在哪右键、哪里不出现。
// 「用 App 打开」——访达右键里列哪几个 App（Prefs.finderOpenWithApps，默认只有终端）：加（正在运行的 / 从「应用程序」里选）、移除；
//   列表的写法同 剪贴板 › 不记录这些 App（从偏好现读再改、写回）。功能关着时这一组变灰。

import FinderSync
import SwiftUI
import UniformTypeIdentifiers

struct FinderMenuTab: View {
  /// 系统里扩展开没开（截图自检传固定的：屏外问不到真的状态）
  var extensionEnabled: Bool?
  @State private var enabled = FIFinderSyncController.isExtensionEnabled
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
            "在访达里右键文件、文件夹，或者文件夹窗口的空白处：「拷贝路径」，和下面每个 App 一项「用 X 打开」。iCloud 云盘和网盘的文件夹里，系统不显示这些项。"
          )
          if !Self.settingsHaveEntry { oldSystemHint }
        }
      }
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
        Text("用 App 打开")
      } footer: {
        SectionFootnote("文件夹原样交给 App；文件交给认得它的 App，不认得的（比如终端只认文件夹）改成打开它所在的文件夹。")
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
        Text("右键里不列「用 X 打开」").foregroundStyle(.secondary)
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
    panel.message = "选择的 App 会出现在访达右键的「用 X 打开」里"
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
