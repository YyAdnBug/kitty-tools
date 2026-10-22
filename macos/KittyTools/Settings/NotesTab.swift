// 设置 › 便签（PLAN §10「便签」F②，排在「录制」后面）。三组：
// 「便签」——正文的字号（四档单选）、行距（三档单选，手测反馈第 4 批）——全部便签窗口、屏幕边缘的便签、浮动便签共用——、
// Markdown 样式的开关（默认开）；
// 「屏幕边缘」（第 3 批）——总开关（关掉一个窗口都不建）、哪条边、放在哪块显示器（只有一块屏时不显示这一行）、样式、
// 大小、感应范围、一直展开、不显示药丸、悬停预览、悬停即打开、盖在全屏 App 上、打开的便签多大；总开关关着时下面的行停用；
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
    Form {
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
      Section {
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
