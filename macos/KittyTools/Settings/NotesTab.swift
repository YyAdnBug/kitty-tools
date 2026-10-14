// 设置 › 便签（PLAN §10「便签」F②，排在「录制」后面）。三组：
// 「便签」——正文的字号（四档单选，全部便签窗口和屏幕边缘的便签共用）、Markdown 样式的开关（默认开）；
// 「屏幕边缘」（第 3 批）——总开关（关掉一个窗口都不建）、哪条边、放在哪块显示器（只有一块屏时不显示这一行）、样式、
// 大小、感应范围、一直展开、不显示药丸、悬停预览、悬停即打开、盖在全屏 App 上、打开的便签多大；总开关关着时下面的行停用；
// 「数据」——打开全部便签窗口的按钮、按键速查，页脚说便签存在哪、怎么备份、删掉的留多久、导出导入在哪。
// 页头由 SettingsRoot 画（家族色黄）。偏好的键和默认值在 Prefs，读它们的是 NoteDeckOptions。

import SwiftUI

struct NotesTab: View {
  /// 打开全部便签窗口（AppDelegate.showNotes；便签这次用不了时它自己说）
  let openNotes: () -> Void
  /// 接着的显示器的名字（主显示器在前；同名的第二块起加序号，和 NoteDeckScreen.attached 同一个口径）；截图自检传固定的
  var displays: [String] = NoteDeckLayout.uniqueNames(NSScreen.screens.map(\.localizedName))
  @AppStorage(Prefs.notesFontSize) private var fontSize = 15
  @AppStorage(Prefs.notesMarkdown) private var markdown = true
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
  @AppStorage(Prefs.notesDeckTilt) private var tiltsTabs = false

  private static let fontTitles = [13: "小", 15: "标准", 17: "大", 20: "特大"]
  private static let senseTitles = [8: "窄", 14: "标准", 28: "宽", 44: "很宽"]

  var body: some View {
    Form {
      Section {
        // 横排单选包进 LabeledContent：贴着右边线（同设置 › 剪贴板「图片最多占用」）
        radios("正文字号", "全部便签窗口和屏幕边缘的便签里正文的大小", selection: $fontSize) {
          ForEach(Prefs.notesFontSizeChoices, id: \.self) {
            Text(Self.fontTitles[$0] ?? "\($0)").tag($0)
          }
        }
        Toggle(isOn: $markdown) {
          Text("Markdown 样式")
          // verbatim：SwiftUI 的 Text 自己会把字面量里的 ** ` [] 当 Markdown 画掉，这里要原样写给人看
          Text(verbatim: "# 标题、**粗体**、*斜体*、`代码`、[链接](地址) 这些写法直接显示成样式，标记只在光标所在的那一行露出来")
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
      } header: {
        Text("数据")
      } footer: {
        SectionFootnote(
          "便签存在这台 Mac 上，和剪贴板历史分开：清空历史、保留天数都碰不到它。每天自动备份一份，留最近 7 份。删掉的便签在「最近删除」里留 \(NoteStore.trashDays) 天。导出与导入在 设置 › 通用 里。"
        )
      }
    }
    .formStyle(.grouped)
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
        Toggle(isOn: $tiltsTabs) {
          Text("标签倾斜")
          Text("标签微微斜着叠在边上；打开的便签仍是正的")
        }
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
        "鼠标靠到屏幕边上的药丸就展开一列标签，点一张，便签从边缘滑出来。按住 ⌥ 拖药丸可以换边、换高度；右键药丸有新建便签、全部便签和设置。两块显示器相接的那条边不放，自动换到另一侧。打开的便签点别处就收起，固定（⌘P）之后不收。"
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
