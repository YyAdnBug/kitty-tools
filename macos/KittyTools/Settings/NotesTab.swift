// 设置 › 便签（PLAN §10「便签」F②，排在「录制」后面）。三组：
// 「便签」——正文的字号（四档单选）、行距（三档单选，手测反馈第 4 批）——全部便签窗口、屏幕边缘的便签、浮动便签共用——、
// Markdown 样式的开关（默认开）；
// 「屏幕边缘」（第 3 批）——总开关（关掉一个窗口都不建）、哪条边、放在哪块显示器（只有一块屏时不显示这一行）、样式、
// 大小、感应范围、一直展开、不显示药丸、悬停预览、悬停即打开、盖在全屏 App 上、打开的便签多大；总开关关着时下面的行停用；
// 「同步」（便签未来计划 A2，2026-10-23；NoteSyncSection）——几台 Mac 用同一个文件夹同步，默认关；
// 「数据」——打开全部便签窗口的按钮、按键速查，页脚说便签存在哪、怎么备份、删掉的留多久、导出导入在哪。
// 页头由 SettingsRoot 画（家族色黄）。偏好的键和默认值在 Prefs，读它们的是 NoteDeckOptions。

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NotesTab: View {
  /// 打开全部便签窗口（AppDelegate.showNotes；便签这次用不了时它自己说）
  let openNotes: () -> Void
  /// 便签仓库（导出导入要 flush、adopt）；便签这次用不了时给 nil，两个按钮停用
  var notes: () -> NoteStore? = { nil }
  /// 图片目录（导出时从这拷、导入时存到这里）
  var images: () -> NoteImageStore? = { nil }
  /// 刘海岛（导出导入的结果）
  var island: Island?
  /// 同步（便签这次用不了时给 nil，「同步」一节不显示）
  var sync: () -> NoteSyncer? = { nil }
  /// 接着的显示器的名字（主显示器在前；同名的第二块起加序号，和 NoteDeckScreen.attached 同一个口径）；截图自检传固定的
  var displays: [String] = NoteDeckLayout.uniqueNames(NSScreen.screens.map(\.localizedName))
  @AppStorage(Prefs.notesFontSize) private var fontSize = 15
  @AppStorage(Prefs.notesMarkdown) private var markdown = true
  @AppStorage(Prefs.notesLineSpacing) private var lineSpacing = NoteStyles.Spacing.standard
  @AppStorage(Prefs.notesDeckEnabled) private var deckEnabled = true
  @AppStorage(Prefs.notesDeckEdge) private var deckEdge = NoteDeckOptions.Edge.right
  @AppStorage(Prefs.notesDeckDisplay) private var deckDisplay = NoteDeckOptions.DisplayMode.main
  @AppStorage(Prefs.notesDeckChosenDisplay) private var chosenDisplay = ""
  @AppStorage(Prefs.notesDeckStyle) private var deckStyle = NoteDeckOptions.TabStyle.tabs
  @AppStorage(Prefs.notesDeckSize) private var deckSize = NoteDeckOptions.Size.standard
  @AppStorage(Prefs.notesDeckSense) private var sense = 14
  @AppStorage(Prefs.notesDeckAlwaysFanned) private var alwaysFanned = false
  @AppStorage(Prefs.notesDeckHidesPill) private var hidesPill = false
  @AppStorage(Prefs.notesDeckPreview) private var showsPreview = true
  @AppStorage(Prefs.notesDeckOpensOnHover) private var opensOnHover = false
  @AppStorage(Prefs.notesDeckOverFullScreen) private var overFullScreen = false
  @AppStorage(Prefs.notesDeckNoteSize) private var noteSize = NoteDeckOptions.NoteSize.medium

  private static let fontTitles = [13: "小", 15: "标准", 17: "大", 20: "特大"]
  private static let senseTitles = [8: "窄", 14: "标准", 28: "宽", 44: "很宽"]

  var body: some View {
    // 关着时（Feature）变灰；Markdown 导出、导入管的是已有的便签，照常能用
    Form {
      Section { FeatureToggle(feature: .notes, inPage: true) }
      Group {
        Section {
          // 横排单选包进 LabeledContent：贴着右边线（同设置 › 剪贴板「图片最多占用」）
          radios("正文字号", "全部便签窗口、屏幕边缘和浮在屏幕上的便签里正文的大小", selection: $fontSize) {
            ForEach(Prefs.notesFontSizeChoices, id: \.self) {
              Text(Self.fontTitles[$0] ?? "\($0)").tag($0)
            }
          }
          radios("行距", "全部便签窗口、屏幕边缘和浮在屏幕上的便签里正文一行一行之间隔多远", selection: $lineSpacing) {
            ForEach(NoteStyles.Spacing.allCases, id: \.self) { Text($0.title).tag($0) }
          }
          Toggle(isOn: $markdown) {
            Text("Markdown 样式")
            // verbatim：SwiftUI 的 Text 自己会把字面量里的 ** ` [] 当 Markdown 画掉，这里要原样写给人看
            Text(
              verbatim:
                "# 标题、**粗体**、*斜体*、`代码`、[链接](地址)、三个反引号围起来的代码块，这些写法直接显示成样式，标记只在光标所在的那一行露出来"
            )
          }
        } header: {
          Text("便签")
        }
        deck
        if let syncer = sync() { NoteSyncSection(syncer: syncer) }
      }
      .gated(by: .notes)
      Section {
        Group {
          LabeledContent {
            Button("打开全部便签…", action: openNotes)
          } label: {
            Text(HotKeyAction.noteAll.title)
            Text("看、改、搜索、归档便签，找回删掉的")
          }
          LabeledContent {
            ShortcutsButton()
          } label: {
            Text("便签的按键")
            Text("快速记一条、屏幕边缘的便签和全部便签窗口里按什么键")
          }
        }
        .gated(by: .notes)
        LabeledContent {
          Button("导出…") { exportMarkdown() }
            .disabled(notes() == nil || isTransferring)
        } label: {
          Text("导出为 Markdown")
          Text("每条便签一个 .md 文件，正文里的图片放在旁边的 attachments 文件夹")
        }
        LabeledContent {
          Button("导入…") { importMarkdown() }
            .disabled(notes() == nil || isTransferring)
        } label: {
          Text("从 Markdown 导入")
          Text("导回导出过的文件夹不会重复；别处的 .md 文件每个变成一条新便签")
        }
      } header: {
        Text("数据")
      } footer: {
        SectionFootnote(
          "便签存在这台 Mac 上，和剪贴板历史分开：清空历史、保留天数都碰不到它。每天自动备份一份，留最近 7 份（正文里的图片跟着一起备）。删掉的便签在「最近删除」里留 \(NoteStore.trashDays) 天。设置 › 通用 里的导出与导入带便签的文字、不带图片；要连图片一起带走、或者拿别的工具看，用上面的 Markdown 导出。"
        )
      }
    }
    .formStyle(.grouped)
  }

  /// 导出 / 导入的选文件面板开着、或者后台正在读写：两个按钮先停用
  @State private var isTransferring = false

  // MARK: Markdown 导出 / 导入

  /// 「导出…」：选文件夹 → 在里头**新建**一个「Kitty Tools 便签 日期」→ 后台写（界面不卡）
  private func exportMarkdown() {
    guard let store = notes(), !isTransferring else { return }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "导出到这里"
    panel.message = "选一个文件夹，里面会新建「\(NoteMarkdownFiles.folderName())」"
    isTransferring = true
    panel.begin { response in
      guard response == .OK, let parent = panel.url else {
        isTransferring = false
        return
      }
      // 先让仓库把攒着的改动落盘再取（导出的是现在的样子）
      store.flush()
      let list = store.exportable
      let imageDirectory = store.images?.directory
      Task {
        let result = await NoteMarkdownFiles.export(
          notes: list, imageDirectory: imageDirectory, to: parent)
        isTransferring = false
        if let failure = result.failure {
          island?.show(
            "导出到一半", detail: failure, tone: .error, symbol: "exclamationmark.triangle.fill")
          return
        }
        var detail = "「\(result.folderName)」"
        if result.missingImages > 0 { detail += " · \(result.missingImages) 张图片不在，没导出" }
        island?.show(
          "已导出 \(result.count) 条便签", detail: detail,
          symbol: "square.and.arrow.up.circle.fill")
      }
    }
  }

  /// 「导入…」：可以选文件夹（读第一层的 .md / .markdown）也可以多选文件；读文件、存图片在后台，合并回主线程
  private func importMarkdown() {
    guard let store = notes(), !isTransferring else { return }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = true
    panel.prompt = "导入"
    panel.message = "选一个文件夹，或者多选 .md / .markdown / .txt 文件"
    panel.allowedContentTypes =
      [.plainText]
      + ["md", "markdown"].compactMap {
        UTType(filenameExtension: $0)
      }
    isTransferring = true
    panel.begin { response in
      guard response == .OK else {
        isTransferring = false
        return
      }
      let roots = panel.urls.map { url -> URL in
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return isDirectory.boolValue ? url : url.deletingLastPathComponent()
      }
      var sources: [NoteMarkdownFiles.Source] = []
      for (index, url) in panel.urls.enumerated() {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
          for file in NoteMarkdownFiles.markdownFiles(in: url) {
            sources.append(NoteMarkdownFiles.Source(url: file, root: url))
          }
        } else if ["md", "markdown", "txt"].contains(url.pathExtension.lowercased()) {
          sources.append(NoteMarkdownFiles.Source(url: url, root: roots[index]))
        }
      }
      sources.sort {
        $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent)
          == .orderedAscending
      }
      let imageDirectory = store.images?.directory
      Task {
        let result = await NoteMarkdownFiles.importNotes(
          sources: sources, imageDirectory: imageDirectory)
        isTransferring = false
        guard !result.notes.isEmpty else {
          island?.show("没有导入", detail: "选的地方没有 .md 文件", tone: .warning)
          return
        }
        // 读出来的都是没删的：和导出文件同一个换法（自定义纸色拆成预设 + 色值）
        let entries = result.notes.compactMap(SettingsArchive.NoteEntry.init)
        let adoption = store.adopt(entries)
        var detail = "新增 \(adoption.added) · 更新 \(adoption.updated) · 跳过 \(result.skipped)"
        if result.missingImages > 0 { detail += " · \(result.missingImages) 张图片没导进来" }
        if result.limitHit { detail += " · 只导了前 \(NoteMarkdownFiles.maxFiles) 个" }
        if !adoption.saved {
          island?.show("便签没存上", detail: "导入的内容在内存里，稍后会自动再试", tone: .warning)
        } else {
          island?.show(
            "已导入 \(result.notes.count) 条便签", detail: detail,
            symbol: "square.and.arrow.down.circle.fill")
        }
      }
    }
  }

  // MARK: 屏幕边缘

  private var deck: some View {
    Section {
      Toggle(isOn: $deckEnabled) {
        Text("在屏幕边缘显示便签")
        Text("有了第一条便签才出现；关掉后便签照样能从快捷键、启动器和全部便签窗口打开")
      }
      Group {
        Picker("位置", selection: $deckEdge) {
          Text("右边").tag(NoteDeckOptions.Edge.right)
          Text("左边").tag(NoteDeckOptions.Edge.left)
        }
        .pickerStyle(.segmented)
        if displays.count > 1 {
          Picker("显示器", selection: display) {
            Text("主显示器").tag(DisplayChoice.main)
            Text("所有显示器").tag(DisplayChoice.all)
            Divider()
            ForEach(displays, id: \.self) { Text($0).tag(DisplayChoice.named($0)) }
          }
        }
        Picker("样式", selection: $deckStyle) {
          Text("带标题的标签").tag(NoteDeckOptions.TabStyle.tabs)
          Text("只有色块").tag(NoteDeckOptions.TabStyle.chips)
        }
        .pickerStyle(.segmented)
        Picker("大小", selection: $deckSize) {
          Text("小").tag(NoteDeckOptions.Size.small)
          Text("标准").tag(NoteDeckOptions.Size.standard)
          Text("大").tag(NoteDeckOptions.Size.large)
        }
        .pickerStyle(.segmented)
        radios("感应范围", "鼠标离屏幕边缘多近就展开", selection: $sense) {
          ForEach(NoteDeckOptions.senseChoices, id: \.self) {
            Text(Self.senseTitles[$0] ?? "\($0)").tag($0)
          }
        }
        Toggle(isOn: $alwaysFanned) {
          Text("一直展开")
          Text("不缩成药丸，标签一直排在边上")
        }
        Toggle(isOn: $hidesPill) {
          Text("不显示药丸")
          Text("边上什么都不画，鼠标靠过去照样展开")
        }
        .disabled(alwaysFanned)
        Toggle(isOn: $showsPreview) {
          Text("悬停预览")
          Text("鼠标停在标签上时，旁边显示这条便签的开头几行")
        }
        .disabled(opensOnHover)
        Toggle(isOn: $opensOnHover) {
          Text("悬停即打开")
          Text("鼠标在标签上停一下就打开，不用点")
        }
        Toggle(isOn: $overFullScreen) {
          Text("盖在全屏 App 上")
          Text("别的 App 全屏时边缘也有便签")
        }
        radios("便签大小", "从边缘打开的便签多大", selection: $noteSize) {
          Text("小").tag(NoteDeckOptions.NoteSize.small)
          Text("中").tag(NoteDeckOptions.NoteSize.medium)
          Text("大").tag(NoteDeckOptions.NoteSize.large)
          Text("特大").tag(NoteDeckOptions.NoteSize.extraLarge)
        }
      }
      .disabled(!deckEnabled)
    } header: {
      Text("屏幕边缘")
    } footer: {
      SectionFootnote(
        "鼠标靠到屏幕边上的药丸就展开一列标签，点一张，便签从边缘滑出来。按住 ⌥ 拖药丸可以换边、换高度。右键一张标签可以直接固定、换颜色、浮到屏幕上、归档、删除；右键「+」或标签之间的空处有新建便签、全部便签和设置。两块显示器相接的那条边不放，自动换到另一侧。打开的便签点别处就收起，固定（⌘P）之后不收。按住打开的便签侧边那张标签往外拖，它就浮在屏幕上、可以拉大小；浮着的便签固定之后一直在别的窗口上面，重启后回到原处。"
      )
    }
  }

  /// 「显示器」那一行的选项
  private typealias DisplayChoice = NoteDeckOptions.Display

  /// 「显示器」那一行选的是哪个：主显示器 / 所有显示器 / 指定的那一块。偏好里是两个键——哪种（DisplayMode，设置）和
  /// 指定的是哪块（这台电脑自己的状态，不跟设置的导出走）；指定的那块没接着时显示成主显示器（NoteDeckOptions 也是
  /// 这么退的），偏好不动：它插回来还回去
  private var display: Binding<DisplayChoice> {
    Binding {
      switch deckDisplay {
      case .main: .main
      case .all: .all
      case .chosen: displays.contains(chosenDisplay) ? .named(chosenDisplay) : .main
      }
    } set: { choice in
      switch choice {
      case .main: deckDisplay = .main
      case .all: deckDisplay = .all
      case .named(let name):
        chosenDisplay = name
        deckDisplay = .chosen
      }
    }
  }

  /// 一行横排的单选（3–5 个选项，mac-whisker-settings）：贴着右边线，说明写成副标题
  private func radios<Value: Hashable, Options: View>(
    _ title: String, _ detail: String, selection: Binding<Value>,
    @ViewBuilder options: () -> Options
  ) -> some View {
    LabeledContent {
      Picker(title, selection: selection, content: options)
        .pickerStyle(.radioGroup)
        .horizontalRadioGroupLayout()
        .labelsHidden()
        .fixedSize()
    } label: {
      Text(title)
      Text(detail)
    }
  }
}

/// 设置 › 便签「同步」（便签未来计划 A2，2026-10-23；执行在 NoteSyncer）。没开时一行「选择文件夹…」（打开面板先指到
/// iCloud 云盘）；选的文件夹里已经有别的 Mac 的便签，先问一句合不合在一起。开着时：文件夹（悬停看路径）+「停止同步」
/// +「立即同步」（刹车时换成「继续同步」），说明是状态（上次同步、还在下载几个），出了问题橙字说为什么、能怎么办；下面一行
/// 列出别的 Mac 和它们上次有改动的时刻。**这一节不去碰那个文件夹**（可能在卡住的网络盘上）：名字取路径最后一段，读写都在
/// NoteSyncer / NoteSyncDisk 的主线程外
struct NoteSyncSection: View {
  let syncer: NoteSyncer
  /// 开同步没成的原因（橙字）
  @State private var problem: String?
  /// 面板开着、正在看文件夹、正在开
  @State private var isBusy = false
  /// 正在看选的文件夹、正在开（卡住的网络盘上可能要等一会儿：副标题说一声）
  @State private var looking = false
  /// 每分钟走一下：「上次同步：3 分钟前」自己往前走（便签关着时没有新的一轮来刷新）
  @State private var tick = Date.now
  /// 要不要和文件夹里的合在一起（确认框开着时有值）
  @State private var joining: Joining?

  struct Joining {
    var folder: URL
    var devices: Int
    var notes: Int
  }

  var body: some View {
    Section {
      if let folder = syncer.folder {
        folderRow(folder)
        LabeledContent {
          EmptyView()
        } label: {
          Text("其他 Mac")
          Text(peersLine)
        }
      } else {
        offRow
      }
    } header: {
      Text("同步")
    } footer: {
      SectionFootnote(
        "同步文件夹里放的是不加密的文本文件和图片，能打开这个文件夹的人都看得到。每台 Mac 只往自己的那份里写、读所有 Mac 的，改动一般几十秒到几分钟传过去（看同步盘多快）。两台都改了同一条时，后改的留下，另一版放进「最近删除」；一轮要放进「最近删除」的太多会先停下来问。停止同步后，文件夹里的东西留着，这台 Mac 上的便签也不动。"
      )
    }
  }

  // MARK: 没开

  private var offRow: some View {
    LabeledContent {
      Button("选择文件夹…", action: choose)
        .disabled(isBusy)
    } label: {
      Text("在几台 Mac 之间同步")
      Text(
        looking ? "正在看这个文件夹…" : "选一个几台 Mac 都看得到的空文件夹，比如在 iCloud 云盘里新建一个；每台 Mac 选同一个")
      if let problem {
        Text(problem).foregroundStyle(Color(nsColor: .systemOrange))
      }
    }
    .confirmationDialog(
      "和这个文件夹里的便签合在一起？",
      isPresented: Binding {
        joining != nil
      } set: {
        if !$0 { joining = nil }
      },
      presenting: joining
    ) { joining in
      Button("合在一起") { start(joining.folder) }
    } message: { joining in
      Text(
        "这个文件夹里已经有 \(joining.devices) 台 Mac 同步的 \(joining.notes) 条便签（含「最近删除」里的）。合在一起后，这台 Mac 上的便签和它们的会出现在每台 Mac 上；同一条两边都改过的，旧的一版放进「最近删除」。"
      )
    }
  }

  /// 选文件夹：先看一眼（主线程外），已经有别的 Mac 在用就先问，不然直接开。面板是设置窗上的表单（开着时点不到
  /// 便签的开关、换不了页：不然关掉便签之后还会把同步起起来，换了页这一节的状态也丢了）
  private func choose() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    if FileManager.default.fileExists(atPath: Self.iCloudDrive.path) {
      panel.directoryURL = Self.iCloudDrive
    }
    panel.message = "选一个几台 Mac 都看得到的空文件夹（比如在 iCloud 云盘里新建一个「Kitty Tools 便签」），每台 Mac 选同一个"
    panel.prompt = "用这个文件夹同步"
    problem = nil
    isBusy = true
    let chosen: (NSApplication.ModalResponse) -> Void = { response in
      guard response == .OK, let folder = panel.url else {
        isBusy = false
        return
      }
      looking = true
      Task {
        let seen = await NoteSyncDisk.inspect(folder: folder, device: syncer.store.deviceID)
        looking = false
        isBusy = false
        // 有别的 Mac 的便签才问（更新的格式不问：开的时候直接说先更新）
        if let marker = seen.marker, marker.format <= NoteSyncFolder.format, seen.notes > 0 {
          joining = Joining(folder: folder, devices: seen.devices, notes: seen.notes)
        } else {
          start(folder)
        }
      }
    }
    if let window = NSApp.keyWindow {
      panel.beginSheetModal(for: window, completionHandler: chosen)
    } else {
      panel.begin(completionHandler: chosen)
    }
  }

  private func start(_ folder: URL) {
    isBusy = true
    looking = true
    Task {
      problem = await syncer.enable(folder: folder).map(Self.clause)
      looking = false
      isBusy = false
      // 便签关着时只记下文件夹，打开便签时 AppDelegate.applyFeatures 起
      if problem == nil, Feature.notes.isOn { syncer.start() }
    }
  }

  // MARK: 开着

  private func folderRow(_ folder: URL) -> some View {
    LabeledContent {
      HStack(spacing: 8) {
        Label(folder.lastPathComponent, systemImage: "folder")
          .lineLimit(1)
          .truncationMode(.middle)
          .foregroundStyle(.secondary)
          .help(Self.shown(folder))
        Button("停止同步") { syncer.disable() }
          .buttonStyle(.plain)
          .foregroundStyle(Style.brandInk)
          .pointerStyle(.link)
          .help("文件夹里的东西留着，这台 Mac 上的便签不动")
        if case .waiting = syncer.status {
          Button("继续同步") { syncer.confirmTrashing() }
        } else {
          // 不停用：一轮没完时按它排在后面（停用的话每 20 秒闪一下灰）
          Button("立即同步") { syncer.syncNow() }
        }
      }
    } label: {
      Text("同步文件夹")
      Text(statusLine)
      if let trouble {
        Text(trouble).foregroundStyle(Color(nsColor: .systemOrange))
      }
    }
    .task {
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(60))
        tick = .now
      }
    }
  }

  /// 状态：上次同步的时刻（第一轮还没完时说正在同步）、还在下载几个
  private var statusLine: String {
    var line: String
    if let lastSync = syncer.lastSync {
      line = "上次同步：\(Self.ago(lastSync, now: tick))"
    } else if syncer.status == .syncing {
      line = "正在同步…"
    } else {
      line = "还没同步过"
    }
    if syncer.downloading > 0 { line += "；还有 \(syncer.downloading) 个文件在下载" }
    return line
  }

  /// 停了、等确认：为什么、能怎么办（橙字）
  private var trouble: String? {
    switch syncer.status {
    case .off, .syncing, .idle: nil
    case .waiting(let trashing):
      "这一轮要把 \(trashing) 条便签放进「最近删除」，先停下来等你确认"
    case .stopped(let problem):
      switch problem {
      case .missingFolder: "找不到同步文件夹：没接上、被挪走或删了，找到了自己接着同步"
      case .notTheFolder: "同步文件夹里的同步记录被换掉或删了：先停止同步，再选一个新的空文件夹（每台 Mac 都换过去）"
      case .newerFormat: "文件夹里有更新版本的 Kitty Tools 写的东西，先更新这台 Mac 上的 Kitty Tools"
      case .unreadable(let name):
        "\(name.map { "「\($0)」" } ?? "另一台 Mac ")的删除记录还读不出来（多半是还没下载完），读到了自己接着同步"
      case .downloading: "同步文件夹里有文件还没下载到这台 Mac，下载完自己接着同步"
      case .failed(let reason): "上一轮没同步成：\(Self.clause(reason))"
      }
    }
  }

  private var peersLine: String {
    guard !syncer.peers.isEmpty else {
      // 第一轮还没合完（或者合之前就停了）时不知道有没有
      return syncer.lastSync == nil
        ? "同步一轮之后列在这里" : "还没有——在另一台 Mac 的 设置 › 便签 里选同一个文件夹"
    }
    return syncer.peers.map { peer in
      let name = peer.name ?? "没写名字的一台"
      return peer.seen.map { "\(name)（\(Self.ago($0, now: tick))有改动）" } ?? name
    }.joined(separator: "、")
  }

  /// 「刚刚」「3 分钟前」「昨天」
  private static func ago(_ date: Date, now: Date) -> String {
    let now = max(now, .now)
    return now.timeIntervalSince(date) < 60
      ? "刚刚" : date.formatted(.relative(presentation: .named, unitsStyle: .wide))
  }

  /// 系统给的原因（localizedDescription）带句号：行副标题一句话不加
  private static func clause(_ text: String) -> String {
    text.trimmingCharacters(in: ["。", "."])
  }

  /// iCloud 云盘在本机的位置（选文件夹的面板先指到这里）
  static let iCloudDrive = FileManager.default.homeDirectoryForCurrentUser.appending(
    path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)

  /// 悬停时给人看的路径：iCloud 云盘里的写成「iCloud 云盘/…」，家目录写成 ~
  static func shown(_ folder: URL) -> String {
    let drive = iCloudDrive.path(percentEncoded: false)
    let path = folder.path(percentEncoded: false)
    if path.hasPrefix(drive) {
      return "iCloud 云盘/" + path.dropFirst(drive.count).trimmingCharacters(in: ["/"])
    }
    return (path as NSString).abbreviatingWithTildeInPath
  }
}
