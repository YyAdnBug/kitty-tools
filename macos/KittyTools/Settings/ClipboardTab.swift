// 设置 › 剪贴板：保留普通历史（一行按时间，体检 A4）与普通图片占用、面板行为（带实时示意图：单列 + 透镜 + 底栏）、
// 粘贴方式与图片文字、隐私（敏感文本 / 清空时机）、排除的 App（按 bundle ID 精确匹配的 App 列表，体检 A11）。
// 上限类设置改了立即生效（执行一次清理）；会删掉东西时先问（第四轮体检 E4，取消就不改）。控件分工（Whisker §6）：
// > 5 项弹出菜单、3–5 项单选。排除的 App 跟着偏好走：同步 / 导入换了列表，开着的页面跟上，改的时候也从偏好现读（E19）。

import SwiftUI
import UniformTypeIdentifiers

struct ClipboardTab: View {
  let store: ClipboardStore
  @AppStorage(Prefs.clipboardRetentionDays) private var retentionDays = 7
  @AppStorage(Prefs.clipboardImageBudgetMB) private var imageBudgetMB = 512
  @AppStorage(Prefs.clipboardShowPreview) private var showPreview = true
  @AppStorage(Prefs.clipboardLinkPreview) private var linkPreview = true
  @AppStorage(Prefs.clipboardPasteOnClick) private var pasteOnClick = false
  @AppStorage(Prefs.clipboardPanelPosition) private var panelPosition = "top"
  @AppStorage(Prefs.clipboardPastePlain) private var pastePlain = false
  @AppStorage(Prefs.clipboardImageOCR) private var imageOCR = true
  @AppStorage(Prefs.clipboardBlockSensitive) private var blockSensitive = true
  @AppStorage(Prefs.clipboardClearOnQuit) private var clearOnQuit = false
  @AppStorage(Prefs.clipboardClearOnLock) private var clearOnLock = false
  /// 排除的 App（显示用的一份；偏好变了跟着换，改的时候从偏好现读，见 changeExcluded）
  @State private var excluded = Self.storedExcluded
  @State private var excludedSelection: String?
  @State private var confirmClear = false
  /// 改短保留天数 / 改小图片占用会删掉东西：先问，确认了才改（E4）
  @State private var limitChange: LimitChange?
  /// 确认框收起后让两个选项重建一次：取消时值没改，但弹出菜单 / 单选可能已经停在点的那一项上
  @State private var limitPickers = 0
  @Environment(Island.self) private var island: Island?

  var body: some View {
    // 关着时（Feature）变灰的是「怎么记、面板怎么样」；保留多久、退出 / 锁屏清空、立即清空这些管已有数据的照常能改
    Form {
      Section { FeatureToggle(feature: .clipboard, inPage: true) }
      Section {
        Picker("保留普通历史", selection: limited(.days)) {
          ForEach(Prefs.clipboardRetentionChoices, id: \.self) {
            Text(Self.retentionTitle($0)).tag($0)
          }
        }
        .id(limitPickers)
        // 横排单选包进 LabeledContent：贴着右边线（直接放 Picker 的话单选紧跟在标签后面、靠左）
        LabeledContent("图片最多占用") {
          Picker("图片最多占用", selection: limited(.imageMB)) {
            ForEach(Self.imageBudgetChoices, id: \.0) {
              Text($0.1).tag($0.0)
            }
          }
          .pickerStyle(.radioGroup)
          .horizontalRadioGroupLayout()
          .labelsHidden()
          .fixedSize()
          .id(limitPickers)
        }
        LabeledContent("图片当前占用", value: imageUsage)
      } header: {
        Text("历史")
      } footer: {
        SectionFootnote("收藏和片段一直留着，图片占用也只算普通历史里的。")
      }
      Section("面板") {
        ClipboardPanelSketch(showsLens: showPreview, showsLinkPreview: linkPreview)
          .frame(maxWidth: .infinity)
        Toggle(isOn: $showPreview) {
          Text("显示透镜")
          Text("选中的条目在原地展开预览；关掉就是纯列表，一屏多露出几行")
        }
        Toggle(isOn: $linkPreview) {
          Text("链接显示网页标题和图片")
          Text("选中链接时联网读取；本机、内网和带登录令牌的网址不读")
        }
        Toggle(isOn: $pasteOnClick) {
          Text("单击条目直接粘贴")
          Text("关着时单击选中、双击粘贴；打开后点一下就粘贴，想先看内容用 ↑↓，⌘ 单击、⇧ 单击照常多选")
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
          detail: "拖左右两边改宽度，拖下边改最多显示几行", widthKey: Prefs.clipboardPanelWidth,
          heightKey: Prefs.clipboardPanelRows, defaultWidth: Style.listPanelWidth)
      }
      .gated(by: .clipboard)
      Section("内容") {
        Toggle(isOn: $pastePlain) {
          Text("默认粘贴为纯文本")
          Text("打开后 ↩ 粘贴纯文本，⌥↩ 保留格式；文字的格式总是记下来")
        }
        Toggle("识别图片中的文字，用于搜索", isOn: $imageOCR)
      }
      .gated(by: .clipboard)
      Section("隐私") {
        Toggle("不记录疑似密钥和银行卡号", isOn: $blockSensitive)
          .gated(by: .clipboard)
        Toggle("退出 App 时清空普通历史", isOn: $clearOnQuit)
        Toggle("锁屏时清空普通历史", isOn: $clearOnLock)
        DangerButton("立即清空普通历史…") { confirmClear = true }
      }
      Section {
        excludedList
        ListEditBar(
          removeTitle: "移除所选的 App", canRemove: excludedSelection != nil, remove: removeSelected
        ) {
          Menu {
            Menu("正在运行的 App") {
              ForEach(AppListRow.runningApps, id: \.bundleID) { app in
                Button(app.name) { add(app.bundleID) }.disabled(excluded.contains(app.bundleID))
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
        Text("不记录这些 App 里的复制")
      } footer: {
        SectionFootnote("密码管理器通常会自己标记「不要记录」，这里只是兜底。")
      }
      .gated(by: .clipboard)
    }
    .formStyle(.grouped)
    .onChange(of: imageOCR) { store.recognizePendingImages() }
    // 同步、导入落下了新的排除列表：页面跟上（异步序列在主线程上接：偏好不一定是在主线程上改的）。
    // object 不填：UserDefaults 不是 Sendable，填 .standard 会报警告；别的偏好域发来的也只是多比一次
    .task {
      for await _ in NotificationCenter.default.notifications(
        named: UserDefaults.didChangeNotification)
      {
        let stored = Self.storedExcluded
        if stored != excluded { excluded = stored }
      }
    }
    .confirmationDialog(
      limitChange.map(Self.title) ?? "", isPresented: confirmsLimit, titleVisibility: .visible,
      presenting: limitChange
    ) { change in
      Button("删除", role: .destructive) {
        set(change.field, change.value)
        pruned(store.enforceLimits())
      }
      Button("取消", role: .cancel) {}
    } message: { change in
      Text(Self.pruneWarning(items: change.items, images: change.images))
    }
    .confirmationDialog("清空所有普通历史？", isPresented: $confirmClear) {
      Button("清空", role: .destructive) {
        let count = store.clearOrdinary()
        island?.show(
          count > 0 ? "已清空普通历史" : "没有可清空的普通历史",
          detail: count > 0 ? "删了 \(count) 条，收藏和片段留着" : nil,
          tone: count > 0 ? .success : .info, symbol: "trash.circle.fill")
      }
    } message: {
      Text("收藏和片段会保留")
    }
  }

  /// 「图片最多占用」的档位（MB → 名字；0 = 不限）
  static let imageBudgetChoices = [
    (512, "512 MB"), (1024, "1 GB"), (2048, "2 GB"), (5120, "5 GB"), (0, "不限"),
  ]

  /// 两个上限：保留天数、图片占用（MB）
  private enum LimitField { case days, imageMB }

  /// 要改的那一项、新值和改了会删掉几条（其中几张图片）
  private struct LimitChange: Equatable {
    var field: LimitField
    var value: Int
    var items: Int
    var images: Int
  }

  private func limit(_ field: LimitField) -> Int {
    field == .days ? retentionDays : imageBudgetMB
  }

  /// 只写变了的那一项：没动的那项写进持久域的话，同步会把它当成本机刚改的发出去、盖掉另一台的设置
  private func set(_ field: LimitField, _ value: Int) {
    if field == .days { retentionDays = value } else { imageBudgetMB = value }
  }

  /// 两个上限选项的绑定：改到会删掉东西的那一档先不写偏好，记下来问（E4）；不会删的照旧直接生效。
  /// 和清理同一套条件干跑（ClipboardStore.pruneCount），收藏、片段、还能 ⌘Z 的不算
  private func limited(_ field: LimitField) -> Binding<Int> {
    Binding {
      limit(field)
    } set: { value in
      guard value != limit(field) else { return }
      let count = store.pruneCount(
        .init(
          days: field == .days ? value : retentionDays,
          imageMB: field == .imageMB ? value : imageBudgetMB))
      guard count.items > 0 else { return set(field, value) }
      limitChange = LimitChange(
        field: field, value: value, items: count.items, images: count.images)
    }
  }

  /// 确认框以任何方式收起（删除、取消、Esc）都让两个选项重建一次：取消时值没改，弹出菜单 / 单选却可能停在点的那一项上
  private var confirmsLimit: Binding<Bool> {
    Binding {
      limitChange != nil
    } set: {
      guard !$0 else { return }
      limitChange = nil
      limitPickers += 1
    }
  }

  /// 确认框的标题：「保留普通历史改成「1 天」？」「图片最多占用改成「512 MB」？」
  private static func title(_ change: LimitChange) -> String {
    switch change.field {
    case .days: "保留普通历史改成「\(retentionTitle(change.value))」？"
    case .imageMB:
      "图片最多占用改成「\(imageBudgetChoices.first { $0.0 == change.value }?.1 ?? "\(change.value) MB")」？"
    }
  }

  /// 改上限前的确认里那句：会删掉几条普通历史（其中几张图片），收藏和片段不受影响
  static func pruneWarning(items: Int, images: Int) -> String {
    let what =
      switch images {
      case 0: "\(items) 条普通历史"
      case items: "\(images) 张普通历史里的图片"
      default: "\(items) 条普通历史（其中 \(images) 张图片）"
      }
    return "会删掉 \(what)，收藏和片段不受影响。"
  }

  /// 「保留普通历史」的档位名：1 天 / 1 周 / 1 个月 / 3 个月 / 1 年 / 永久
  static func retentionTitle(_ days: Int) -> String {
    switch days {
    case 0: "永久"
    case 7: "1 周"
    case 30: "1 个月"
    case 90: "3 个月"
    case 365: "1 年"
    default: "\(days) 天"
    }
  }

  /// 上限改小、当场删掉的条目在设置页上看不出来：用刘海说一声
  private func pruned(_ count: Int) {
    guard count > 0 else { return }
    island?.show(
      "已按新上限清理 \(count) 条", detail: "收藏和片段不受影响", tone: .info, symbol: "trash.circle.fill")
  }

  /// 「普通 X · 留下的 Y」：只有普通的算进「图片最多占用」（体检 B2）
  private var imageUsage: String {
    let usage = store.imageUsage
    return "普通 \(usage.ordinary.formatted(.byteCount(style: .file))) · 留下的 "
      + usage.retained.formatted(.byteCount(style: .file))
  }

  // MARK: 排除的 App

  /// App 列表（图标 + 名字），不排序；选中后「−」或 ⌫ 移除
  private var excludedList: some View {
    List(selection: $excludedSelection) {
      if excluded.isEmpty {
        Text("没有排除的 App").foregroundStyle(.secondary)
      }
      ForEach(excluded, id: \.self) { AppListRow(bundleID: $0).tag($0) }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .orderedListFrame(rows: excluded.count)
    .onDeleteCommand(perform: removeSelected)
  }

  private static var storedExcluded: [String] {
    UserDefaults.standard.stringArray(forKey: Prefs.clipboardExcludedBundleIDs) ?? []
  }

  /// 改排除列表：从偏好现读再改、写回（页面上那份可能还没跟上同步刚落下的，拿它整张写回会盖掉另一台加的 App，E19）
  private func changeExcluded(_ change: (inout [String]) -> Void) {
    var list = Self.storedExcluded
    change(&list)
    UserDefaults.standard.set(list, forKey: Prefs.clipboardExcludedBundleIDs)
    excluded = list
  }

  private func add(_ bundleID: String) {
    changeExcluded { list in
      if !list.contains(bundleID) { list.append(bundleID) }
    }
  }

  private func removeSelected() {
    guard let id = excludedSelection else { return }
    changeExcluded { $0.removeAll { $0 == id } }
    excludedSelection = nil
  }

  /// 从「应用程序」里选（可多选），按 App 包的 bundle ID 加进来
  private func chooseApps() {
    AppListRow.chooseApps(prompt: "不记录", message: "选择的 App 里复制的内容不进剪贴板历史").forEach(add)
  }
}

/// App 列表的一行（剪贴板的排除列表、访达右键的「用 App 打开」、快捷键的停用名单）：16 pt App 图标 + 名字；本机找不到这个 App 时显示 bundle ID（secondary）
struct AppListRow: View {
  let bundleID: String

  var body: some View {
    let name = AppIcons.name(for: bundleID)
    HStack(spacing: 8) {
      if let icon = AppIcons.icon(for: bundleID) {
        Image(nsImage: icon).resizable().frame(width: 16, height: 16)
      } else {
        Image(systemName: "app.dashed").foregroundStyle(.tertiary).frame(width: 16)
      }
      Text(name ?? bundleID)
        .foregroundStyle(name == nil ? .secondary : .primary)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 0)
    }
    .frame(height: OrderedList.rowHeight - 8)
    .help(bundleID)
    .accessibilityElement(children: .combine)
  }

  /// 正在运行的普通 App（有程序坞图标的），按名称排序（三张 App 列表的「＋」菜单共用）
  static var runningApps: [(bundleID: String, name: String)] {
    NSWorkspace.shared.runningApplications
      .filter { $0.activationPolicy == .regular && $0 != .current }
      .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  /// 从「应用程序」里选（可多选），返回选中的 App 包的 bundle ID
  static func chooseApps(prompt: String, message: String) -> [String] {
    let panel = NSOpenPanel()
    panel.directoryURL = URL(filePath: "/Applications")
    panel.allowedContentTypes = [.applicationBundle]
    panel.allowsMultipleSelection = true
    panel.prompt = prompt
    panel.message = message
    guard panel.runModal() == .OK else { return [] }
    return panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
  }
}

/// 剪贴板面板的示意图（实时预览，Sleeve 式）：单列 + 一块透镜 + 底栏，跟着「显示透镜」「链接显示网页标题和图片」变——
/// 关掉透镜时选中行只是一条中性高亮（纯列表，多露出几行）；透镜里的链接有没有头图。只是线框，不画真内容
private struct ClipboardPanelSketch: View {
  let showsLens: Bool
  let showsLinkPreview: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let panel = RoundedRectangle(cornerRadius: 12, style: .continuous)
    VStack(spacing: 0) {
      // 搜索线：放大镜 + 一枚粉色筛选标签 + 占位
      HStack(spacing: 5) {
        Image(systemName: "magnifyingglass").font(.system(size: 9, weight: .semibold))
          .foregroundStyle(.tertiary)
        Capsule().fill(Style.brand.opacity(0.22)).frame(width: 22, height: 8)
        Capsule().fill(.primary.opacity(0.12)).frame(width: 70, height: 5)
        Spacer()
      }
      .padding(.horizontal, 10)
      .frame(height: 22)
      Hairline()
      VStack(spacing: 0) {
        row(tile: .primary.opacity(0.14))
        lens
        row(tile: .primary.opacity(0.14))
        row(tile: Style.Family.clipboard.opacity(0.5))
        if !showsLens { row(tile: .primary.opacity(0.14)) }
        Spacer(minLength: 0)
      }
      .padding(4)
      Hairline()
      // 底栏：条数 ｜ 粘贴 [↩] · 操作 ⌘K
      HStack(spacing: 4) {
        Capsule().fill(.primary.opacity(0.12)).frame(width: 22, height: 4)
        Spacer()
        Capsule().fill(.primary.opacity(0.16)).frame(width: 14, height: 4)
        RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Style.brand)
          .frame(width: 9, height: 8)
        Capsule().fill(.primary.opacity(0.16)).frame(width: 18, height: 4)
      }
      .padding(.horizontal, 8)
      .frame(height: 14)
    }
    .frame(width: 240, height: 136)
    .background(.background, in: panel)
    .overlay(panel.hairlineBorder())
    .clipShape(panel)
    .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    // 减弱动态效果：直接变（不展开、不缩放）
    .animation(reduceMotion ? nil : Style.Motion.settle.animation(), value: showsLens)
    .animation(reduceMotion ? nil : Style.Motion.settle.animation(), value: showsLinkPreview)
    .padding(.vertical, 6)
    .accessibilityHidden(true)
  }

  private func row(tile: some ShapeStyle) -> some View {
    HStack(spacing: 5) {
      RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(tile).frame(width: 9, height: 9)
      Capsule().fill(.primary.opacity(0.12)).frame(width: 110, height: 4)
      Spacer()
      Capsule().fill(.primary.opacity(0.08)).frame(width: 26, height: 3)
    }
    .padding(.horizontal, 5)
    .frame(height: 14)
  }

  /// 选中行：一块中性高亮；开着透镜时在原地展开成链接预览（头图 + 标题）+ 元信息
  private var lens: some View {
    VStack(alignment: .leading, spacing: 4) {
      row(tile: Style.Family.url.opacity(0.7))
      if showsLens {
        HStack(alignment: .top, spacing: 5) {
          if showsLinkPreview {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
              .fill(
                LinearGradient(
                  colors: [Style.Family.url.opacity(0.5), Style.Family.search.opacity(0.35)],
                  startPoint: .topLeading, endPoint: .bottomTrailing)
              )
              .frame(width: 40, height: 23)
              .transition(.opacity)
          }
          VStack(alignment: .leading, spacing: 4) {
            Capsule().fill(.primary.opacity(0.22)).frame(width: 80, height: 5)
            Capsule().fill(.primary.opacity(0.12)).frame(width: 60, height: 4)
          }
        }
        .padding(.leading, 19)
        .transition(.opacity)
        Capsule().fill(.primary.opacity(0.08)).frame(width: 70, height: 3)
          .padding(.leading, 19)
          .padding(.bottom, 4)
          .transition(.opacity)
      }
    }
    .background(Style.selectedFill, in: .rect(cornerRadius: 4, style: .continuous))
  }
}
