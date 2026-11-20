// 设置 › 截图（2026-11-18 设置改版 S4）：外面是常用的——⌘S 快速保存的位置（访达里的名字，选过的能恢复默认，体检 A28；录屏、
// 录音也存这里，「录制」页的「保存到」是同一行 SaveDirectoryRow）、截图拷贝为图像还是 PNG 文件（2026-11-06）、截完图放哪、
// 快门声（可试听）；「截图历史 ›」推进子页（开关、保留多久、最多占用、打开历史、现在清空；改短保留期 / 改小占用会删掉东西时
// 先问，第四轮体检 E24，改了当场清一次）；按键两行（N11：速查表、「截图里的快捷键…」跳快捷键页）。
// 「高级…」：带上鼠标指针、隐藏桌面图标（第四轮体检 X8 X9）、窗口截图带阴影、延时截图倒数几秒（第五轮体检 N1 N2）、
// 框选时的提示和放大镜（2026-11-17）、工具栏靠哪边（录屏的录制条同一个设置）、保持屏幕原色、悬停时识别（窗口里的元素 /
// 连网页里的也认，两个开关合成一个选单，S6；要辅助功能授权：没授权时下面出授权那一行）、钉图上的字可选、识字后接换行
// （旁边实时对照效果，体检 A32）、空闲时释放识字模型。录屏、录音的设置在「录制」页（RecordTab）。
// 页头画在自己的 NavigationStack 里，推进子页时一起换掉。

import AppKit
import SwiftUI

struct ScreenshotTab: View {
  /// 截图历史（2026-10-26 拍板 B3：开关、保留多久、占多少、现在清空都在这里）
  let shots: ShotHistory?
  /// 打开历史窗口（AppDelegate 给）
  var openHistory: () -> Void = {}
  /// 截图自检直接画「高级…」表单（sheet 画不进屏外截图）
  var drawsAdvanced = false
  @AppStorage(Prefs.ocrJoinLines) private var joinLines = false
  @AppStorage(Prefs.ocrReleaseWhenIdle) private var releaseOCRWhenIdle = true
  @AppStorage(Prefs.screenshotShutterSound) private var shutterSound = true
  @AppStorage(Prefs.screenshotCursor) private var cursor = false
  @AppStorage(Prefs.captureHideDesktopIcons) private var hidesDesktopIcons = false
  @AppStorage(Prefs.screenshotPlacement) private var placement = Prefs.ShotPlacement.corner
    .rawValue
  @AppStorage(Prefs.screenshotToolbarAlign) private var toolbarAlign = "right"
  @AppStorage(Prefs.screenshotCopyAs) private var copyAs = "image"
  @AppStorage(Prefs.screenshotKeepsColors) private var keepsColors = false
  @AppStorage(Prefs.screenshotShowsHint) private var showsHint = true
  @AppStorage(Prefs.pinSelectsText) private var pinSelectsText = true
  @AppStorage(Prefs.screenshotLoupe) private var loupe = Prefs.Loupe.full.rawValue
  @AppStorage(Prefs.screenshotFindsElements) private var findsElements = false
  @AppStorage(Prefs.screenshotFindsWebElements) private var findsWebElements = false
  @AppStorage(Prefs.screenshotWindowShadow) private var windowShadow = true
  @AppStorage(Prefs.screenshotCornerRadius) private var cornerRadius = Prefs
    .screenshotCornerRadiusDefault
  @AppStorage(Prefs.screenshotDelay) private var delay = 5
  /// 认元素要辅助功能授权（拍板 D2：没授权只在这里说，不弹框）；从系统设置授权回来、设置窗重新当 key 时刷新
  @State private var trusted = Permissions.isAccessibilityTrusted
  /// 「截图拷贝为」「框选时保持屏幕原色」那两行的「新」（0.7.3，WhatsNew）
  @Environment(SettingsNavigation.self) private var navigation
  @AppStorage(Prefs.shotHistory) private var keepsHistory = true
  @AppStorage(Prefs.shotHistoryDays) private var historyDays = 30
  @AppStorage(Prefs.shotHistoryMegabytes) private var historyMegabytes = 2 * 1024
  @State private var confirmClear = false
  /// 改短保留期 / 改小占用会删掉历史：先问，确认了才改（第四轮体检 E24，同剪贴板的 E4）
  @State private var limitChange: HistoryLimit?
  /// 确认框收起后让两个选项重建一次：取消时值没改，弹出菜单却可能停在点的那一项上
  @State private var limitPickers = 0
  /// 悬停预览：「截完图放哪」那一组顶上的舞台演停着的那一行（设置改版 S10）
  @State private var previewFocus = PreviewFocus()

  var body: some View {
    NavigationStack(path: Bindable(navigation).path) {
      VStack(spacing: 0) {
        PageHeader(page: .screenshot)
        form
      }
      .navigationTitle(SettingsPage.screenshot.title)
      .navigationDestination(for: String.self) { route in
        if SettingsSubpage(route: route) == .screenshotHistory { historyPage }
      }
      .advancedSheet(.screenshot, summary: "框选和识别的细节", inline: drawsAdvanced) { advanced }
    }
    // 从系统设置授权回来（只认设置窗自己，同通用页）；「高级…」表单开着时当 key 的是表单、设置窗收不到，再认 App 回到前台
    .onSettingsBecameKey { trusted = Permissions.isAccessibilityTrusted }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    {
      _ in trusted = Permissions.isAccessibilityTrusted
    }
    .confirmationDialog("清空截图历史？", isPresented: $confirmClear) {
      Button("清空", role: .destructive) { shots?.clear() }
    } message: {
      Text("\(shots?.items.count ?? 0) 条历史连同留着的原图一起删掉，不能撤销；已经存到文件夹里的文件不动。")
    }
    .confirmationDialog(
      limitChange.map(Self.title) ?? "", isPresented: confirmsLimit, titleVisibility: .visible,
      presenting: limitChange
    ) { change in
      Button("删除", role: .destructive) { apply(change) }
      Button("取消", role: .cancel) {}
    } message: { change in
      Text("会删掉 \(change.count) 条截图历史，连同留着的原图；已经存到文件夹里的文件不动。")
    }
  }

  /// 外面：快速保存到、截图拷贝为、截完图放哪、快门声、截图历史 ›、按键两行、高级…
  private var form: some View {
    // 关着时（Feature）变灰；存到哪个文件夹录制也在用，照常能改
    Form {
      Section { FeatureToggle(feature: .screenshot, inPage: true) }
      Section {
        SaveDirectoryRow(
          title: "快速保存到", subtitle: "录屏、录音也存这里",
          info: "按 ⌘S 或工具栏的「存储」存到这里，文件名是「截图 日期 时间.png」，重名自动加序号。没选过时跟随系统截屏的存储位置。"
        )
        .settingsAnchor(.screenshotSaveFolder)
      }
      Group {
        Section {
          SettingRow(
            title: "截图拷贝为", subtitle: "选 PNG 文件能粘进聊天和文件夹",
            info: "选 PNG 文件时，剪贴板里是一个图片文件，和拷贝一个文件一样：只认文件的跨电脑剪贴板工具也传得过去；只收图像的程序粘不进去。",
            isNew: WhatsNew.marks(section: "截图拷贝为", of: .screenshot, in: navigation.fresh)
          ) {
            Picker("截图拷贝为", selection: $copyAs) {
              Text("图像").tag("image")
              Text("PNG 文件").tag("file")
            }
            .pickerStyle(.segmented)
          }
          // 拨过这一行，「新」就算看过了（光点进这一页不算；WhatsNew）
          .onChange(of: copyAs) { WhatsNew.touch(section: "截图拷贝为", of: .screenshot) }
          .settingsAnchor(.screenshotCopyAs)
          SettingRow(
            title: "截图圆角", subtitle: "框选的框和截出来的图都是这个圆角",
            info:
              "拖到最左是直角。截出来的图四角透明（PNG），粘进不认透明的程序时四角可能是黑的或白的。单击整扇窗口截下、开着「窗口截图带阴影」时按窗口自己的圆角；录屏、长截图是直角。",
            isNew: WhatsNew.marks(section: "截图圆角", of: .screenshot, in: navigation.fresh)
          ) {
            HStack(spacing: 8) {
              Slider(value: $cornerRadius, in: Prefs.screenshotCornerRadii, step: 2) {
                Text("截图圆角")
              }
              .tint(Style.brand)  // 根视图的 .accentColor 管不到滑块（同译文字号）
              .frame(width: 140)
              Text(cornerRadius > 0 ? "\(Int(cornerRadius)) 点" : "直角")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
            }
          }
          // 拖过这一行，「新」就算看过了（0.10.2，WhatsNew）
          .onChange(of: cornerRadius) { WhatsNew.touch(section: "截图圆角", of: .screenshot) }
          .settingsAnchor(.screenshotCorners)
        }
        Section {
          PreviewStage(still: .placement)
          SettingRow(
            title: "截完图放哪", subtitle: Self.placementSubtitle(placement),
            info: "角落的缩略图可以拖出、钉图、存储。晾衣绳：鼠标停到菜单栏那一条上它就滑下来，单击拷贝、双击改标注、拖出去发一份，点右上角的叉取下；取下不删历史。"
          ) {
            Picker("截完图放哪", selection: $placement) {
              ForEach(Prefs.ShotPlacement.allCases, id: \.rawValue) { choice in
                Text(choice.title).tag(choice.rawValue)
              }
            }
          }
          .previews(.placement)
          .settingsAnchor(.screenshotPlacement)
          // 晾衣绳挂的是截图历史里的那几条：历史关着时说一声，旁边一个文字按钮推进去打开（设置改版起历史在子页里）
          if placement == Prefs.ShotPlacement.clothesline.rawValue, !keepsHistory {
            HStack(spacing: 8) {
              Text("晾衣绳挂的是截图历史，先打开截图历史")
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: .systemOrange))
              Spacer(minLength: 0)
              Button("去打开") { navigation.open(.screenshotHistory) }
                .buttonStyle(.plain)
                .foregroundStyle(Style.brandInk)
                .pointerStyle(.link)
                .font(.system(size: 11))
            }
          }
        }
        Section {
          SettingRow(
            title: "截图时播放快门声",
            info: "拷贝、存储、钉图时响；还要 系统设置 › 声音 里的「播放用户界面音效」开着。截图翻译、识字不出声。"
          ) {
            Button("试听", systemImage: "speaker.wave.2.fill") { FlyCard.playShutter() }
              .labelStyle(.iconOnly)
              .buttonStyle(.borderless)
              .disabled(!shutterSound)
              .help("试听快门声")
            Toggle("截图时播放快门声", isOn: $shutterSound)
              .toggleStyle(.switch)
          }
          .settingsAnchor(.screenshotShutter)
        }
      }
      .gated(by: .screenshot)
      // 截图历史管的是已有的数据（保留多久、清空）：功能关着也能改（同剪贴板的保留天数）
      Section {
        SettingsPushRow(
          title: SettingsSubpage.screenshotHistory.title,
          isNew: SettingsItem.subpageIsNew(.screenshotHistory, fresh: navigation.fresh),
          value: Self.historyValue(
            keeps: keepsHistory, days: historyDays, megabytes: historyMegabytes)
        ) {
          navigation.path = [SettingsSubpage.screenshotHistory.route]
        }
      }
      Section {
        LabeledContent {
          ShortcutsButton()
        } label: {
          Text("框选、标注、长截图和录屏的按键")
          Text("拖动框选，数字键换标注工具，↩ 拷贝")
        }
        .settingsAnchor(.screenshotKeys)
        // 截图时的快捷键在快捷键页改（2026-11-06 拍板 A3）
        LabeledContent {
          Button("截图里的快捷键…") { navigation.page = .hotkeys }
            .buttonStyle(.plain)
            .foregroundStyle(Style.brandInk)
            .pointerStyle(.link)
        } label: {
          Text("改按键")
          Text("截图时的按键能自己改")
        }
        .settingsAnchor(.screenshotEditKeys)
      }
      .gated(by: .screenshot)
      Section {
      } footer: {
        AdvancedButton(page: .screenshot)
      }
    }
    .formStyle(.grouped)
    .settingsScrollTarget()
    .environment(previewFocus)
  }

  /// 「截完图放哪」的副标题：跟着选的那一项（别写成三元式：抽字会漏）
  static func placementSubtitle(_ placement: String) -> LocalizedStringResource {
    switch Prefs.ShotPlacement(rawValue: placement) ?? .corner {
    case .corner: return "角落留一张缩略图"
    case .clothesline: return "挂到屏幕顶上的绳子上，最多 8 张"
    case .none: return "只在右下角闪一下，照样进历史"
    }
  }

  /// 「截图历史 ›」行尾：开着「30 天 · 2 GB」（一直留着、不限照写），关着「关」
  static func historyValue(keeps: Bool, days: Int, megabytes: Int) -> LocalizedStringResource {
    keeps ? "\(daysTitle(days)) · \(megabytesTitle(megabytes))" : "关"
  }

  /// 设置 › 截图 › 截图历史：开关、保留多久、最多占用、打开历史、现在清空（两个上限改小时先问：确认框挂在页面的栈外面）
  private var historyPage: some View {
    SubpageForm(
      subpage: .screenshotHistory,
      status: Self.historyValue(keeps: keepsHistory, days: historyDays, megabytes: historyMegabytes)
    ) {
      Section {
        SettingRow(
          title: "保留截图历史", subtitle: "能回头改标注、再钉一次",
          info: "截图、长截图、录屏录音都留在这里；打码会直接打进存下的图。历史只在这台 Mac 上，不跟着同步。"
        ) {
          Toggle("保留截图历史", isOn: $keepsHistory)
            .toggleStyle(.switch)
        }
        .settingsAnchor(.screenshotHistory)
        if keepsHistory {
          Picker("保留", selection: limited(days: true)) {
            ForEach([7, 30, 90, 0], id: \.self) { Text(Self.daysTitle($0)).tag($0) }
          }
          .id("days \(limitPickers)")  // 两个选项的 id 不能一样：同一个 id 的兄弟视图会被当成同一个
          .settingsAnchor(.screenshotHistoryDays)
          Picker("最多占用", selection: limited(days: false)) {
            ForEach(Prefs.shotHistoryMegabyteChoices, id: \.self) {
              Text(Self.megabytesTitle($0)).tag($0)
            }
          }
          .id("megabytes \(limitPickers)")
          .settingsAnchor(.screenshotHistorySize)
        }
        HStack {
          Button("打开截图历史…", action: openHistory)
            .settingsAnchor(.screenshotHistoryOpen)
          Spacer()
          DangerButton("现在清空…") { confirmClear = true }
            .disabled(shots?.items.isEmpty ?? true)
            .settingsAnchor(.screenshotHistoryClear)
        }
      } footer: {
        SectionFootnote("超过保留期或占用时先删最旧的；存到文件夹里的不动。")
      }
    }
  }

  /// 「高级…」表单：框选时的细节、识别、钉图、识字
  @ViewBuilder private var advanced: some View {
    Section {
      SettingRow(title: "截图带上鼠标指针", info: "带上的是按快捷键那一刻的指针；识字、截图翻译不带。") {
        Toggle("截图带上鼠标指针", isOn: $cursor)
          .toggleStyle(.switch)
      }
      .settingsAnchor(.screenshotCursor)
      SettingRow(
        title: "截图、录屏时隐藏桌面图标",
        info: "桌面上的文件不进截图和录屏，桌面本身照常；录屏中访达新弹出的菜单、窗口最多晚 1 秒才录进去。"
      ) {
        Toggle("截图、录屏时隐藏桌面图标", isOn: $hidesDesktopIcons)
          .toggleStyle(.switch)
      }
      .settingsAnchor(.screenshotHideDesktop)
    }
    .gated(by: .screenshot)
    // 第五轮体检 N1 N2：单击窗口截下的样子、延时截图倒数多久
    Section {
      SettingRow(
        title: "窗口截图带阴影", subtitle: "单击窗口截下时四角透明、四周带阴影",
        info:
          "画面就是框选时看到的；别的 App 的窗口挡住的地方换成这扇窗口自己的，拷贝、存储、钉图都带透明边。框选时这扇窗口的框照它自己的圆角画；选区拖动过、窗口有一部分在屏幕外、关掉这项时按「截图圆角」裁。"
      ) {
        Toggle("窗口截图带阴影", isOn: $windowShadow)
          .toggleStyle(.switch)
      }
      .settingsAnchor(.screenshotWindowShadow)
      SettingRow(
        title: "延时截图倒数", subtitle: "从菜单栏、启动器或自己设的快捷键开始",
        info: "数完再冻结屏幕、开始框选，工具提示、菜单这类一按键就消失的也截得到。倒数时按 Esc 或点 ✕ 取消，点数字马上截；快捷键在快捷键页设。"
      ) {
        Picker("延时截图倒数", selection: $delay) {
          ForEach(Prefs.screenshotDelayChoices, id: \.self) { Text("\($0) 秒").tag($0) }
        }
      }
      .settingsAnchor(.screenshotDelay)
    }
    .gated(by: .screenshot)
    Section {
      SettingRow(
        title: "框选时显示操作提示", subtitle: "开始框选时屏幕上方的一行提示",
        info: "拖动框选、单击选中、双击直接拷贝这些，3 秒后自己淡出。"
      ) {
        Toggle("框选时显示操作提示", isOn: $showsHint)
          .toggleStyle(.switch)
      }
      .settingsAnchor(.screenshotHint)
      SettingRow(
        title: "框选时的放大镜", subtitle: "按 C 拷贝放大镜下的色值",
        info: "不显示色值时 C 不取色，标注里的吸管照常能取。"
      ) {
        Picker("框选时的放大镜", selection: $loupe) {
          ForEach(Prefs.Loupe.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
        }
      }
      .settingsAnchor(.screenshotLoupe)
      SettingRow(
        title: "工具栏位置", subtitle: "框选完工具栏贴在选区下方",
        info: "放不下时在上方。靠右时从左上往右下拖完，✓ 就在鼠标旁边；录屏的录制条也这样摆。"
      ) {
        Picker("工具栏位置", selection: $toolbarAlign) {
          Text("靠右").tag("right")
          Text("居中").tag("center")
        }
        .pickerStyle(.segmented)
      }
      .settingsAnchor(.screenshotToolbar)
      SettingRow(
        title: "框选时保持屏幕原色", subtitle: "不压暗、不染色，取色时打开",
        info: "悬停的窗口只描边、不染色，放大镜正中的像素也不染色。",
        isNew: WhatsNew.marks(section: "框选时保持屏幕原色", of: .screenshot, in: navigation.fresh)
      ) {
        Toggle("框选时保持屏幕原色", isOn: $keepsColors)
          .toggleStyle(.switch)
      }
      // 拨过这一行，「新」就算看过了（光点进这一页不算；WhatsNew）
      .onChange(of: keepsColors) { WhatsNew.touch(section: "框选时保持屏幕原色", of: .screenshot) }
      .settingsAnchor(.screenshotKeepsColors)
      SettingRow(
        title: "悬停时识别", subtitle: "停在侧栏、按钮上就框出那一块",
        info:
          "单击截下；滚轮往上换大一块、往下换小一块，Tab 只认整扇窗口；游戏这类自己画界面的认不出来。选「连网页里的也认」时，第一次停到浏览器或用网页技术做的 App 上会请它打开辅助功能（只有位置和名字的那一档），一直开到它退出，可能让它稍慢一点。",
        isNew: WhatsNew.marks(section: "悬停时识别", of: .screenshot, in: navigation.fresh)
      ) {
        Picker("悬停时识别", selection: elementDetection) {
          ForEach(ElementDetection.allCases, id: \.self) { Text(plain: $0.title).tag($0) }
        }
      }
      // 拨过这一行，「新」就算看过了（0.10.0 的「也认网页里的元素」并进了这一行）
      .onChange(of: ElementDetection(finds: findsElements, web: findsWebElements)) {
        WhatsNew.touch(section: "悬停时识别", of: .screenshot)
      }
      .settingsAnchor(.screenshotElements)
      if findsElements, !trusted {
        PermissionRow(
          title: "辅助功能", detail: "识别窗口里的元素要它；没授权时只认窗口",
          symbol: "hand.raised.fill", color: Style.Family.command, granted: trusted
        ) { Permissions.grant(.accessibility) }
      }
    }
    .gated(by: .screenshot)
    Section {
      SettingRow(
        title: "钉图上的字可以直接选", subtitle: "在钉图的字上拖动就是选字",
        info: "⌘C 拷贝。空白处照旧拖着挪，按住 ⌥ 在哪都能挪。"
      ) {
        Toggle("钉图上的字可以直接选", isOn: $pinSelectsText)
          .toggleStyle(.switch)
      }
      .settingsAnchor(.screenshotPinText)
    }
    .gated(by: .screenshot)
    Section {
      SettingRow(
        title: "识字后把同一段里的换行接起来",
        info: "同一段里的行接起来，段和段之间保留换行：中文、日文的行直接接上，其它文字之间加空格。截图翻译总是这样接。框选里有二维码或条码时复制它的内容。"
      ) {
        Toggle("识字后把同一段里的换行接起来", isOn: $joinLines)
          .toggleStyle(.switch)
      }
      .settingsAnchor(.screenshotJoinLines)
      JoinLinesPreview(joins: joinLines)
      SettingRow(
        title: "空闲时释放识字模型",
        info: "面板收起两分钟后释放识字模型占用的内存，下次识字时要重新加载。关掉后模型一直留着，开着截图或翻译时启动就在后台加载好，第一次识字快一点。"
      ) {
        Toggle("空闲时释放识字模型", isOn: $releaseOCRWhenIdle)
          .toggleStyle(.switch)
      }
      .settingsAnchor(.screenshotReleaseOCR)
    }
    .gated(by: .screenshot)
  }

  /// 「悬停时识别」（设置改版 S6：原来「悬停时识别窗口里的元素」「也认网页里的元素」两个开关）：读写的照旧是那两个键，
  /// 只写变了的那个；选「关」时网页那个不动（它只在认元素开着时管用）
  enum ElementDetection: CaseIterable {
    case off, windows, web

    init(finds: Bool, web: Bool) {
      self = finds ? (web ? .web : .windows) : .off
    }

    var title: LocalizedStringResource {
      switch self {
      case .off: "关"
      case .windows: "窗口里的元素"
      case .web: "连网页里的也认"
      }
    }

    /// 从 old 换成这一项要写哪几个键（没变的不写）：old 由两个键读出来，web 是那个键原来的值
    func writes(finds: Bool, web: Bool) -> [(key: String, value: Bool)] {
      var writes: [(String, Bool)] = []
      let wantsFinds = self != .off
      if wantsFinds != finds { writes.append((Prefs.screenshotFindsElements, wantsFinds)) }
      if self != .off, (self == .web) != web {
        writes.append((Prefs.screenshotFindsWebElements, self == .web))
      }
      return writes
    }
  }

  private var elementDetection: Binding<ElementDetection> {
    Binding {
      ElementDetection(finds: findsElements, web: findsWebElements)
    } set: { choice in
      // 经 @AppStorage 写（截图自检给的临时偏好域也认）
      for write in choice.writes(finds: findsElements, web: findsWebElements) {
        if write.key == Prefs.screenshotFindsElements {
          findsElements = write.value
        } else {
          findsWebElements = write.value
        }
      }
    }
  }

  /// 要改的那一项（保留天数 / 最多占用的 MB）、新值和改了会删掉几条
  private struct HistoryLimit: Equatable {
    var isDays: Bool
    var value: Int
    var count: Int
  }

  /// 两个上限选项的绑定：改到会删掉历史的那一档先不写偏好，记下来问；不会删的照旧直接生效。
  /// 和清理同一套条件干跑（ShotHistory.pruneCount）。改了就当场清一次（原来要等下一次截图才清）
  private func limited(days: Bool) -> Binding<Int> {
    Binding {
      days ? historyDays : historyMegabytes
    } set: { value in
      guard value != (days ? historyDays : historyMegabytes) else { return }
      let change = HistoryLimit(
        isDays: days, value: value,
        count: shots?.pruneCount(
          days: days ? value : historyDays, megabytes: days ? historyMegabytes : value) ?? 0)
      guard change.count > 0 else { return apply(change) }
      limitChange = change
    }
  }

  /// 只写变了的那一项（同剪贴板 E4：没动的那项写进持久域，同步会当成本机刚改的发出去），再按新的上限清一次
  private func apply(_ change: HistoryLimit) {
    if change.isDays { historyDays = change.value } else { historyMegabytes = change.value }
    shots?.prune()
  }

  /// 确认框以任何方式收起（删除、取消、Esc）都让两个选项重建一次
  private var confirmsLimit: Binding<Bool> {
    Binding {
      limitChange != nil
    } set: {
      guard !$0 else { return }
      limitChange = nil
      limitPickers += 1
    }
  }

  /// 确认框的标题：「截图历史改成保留「7 天」？」「截图历史最多占用改成「1 GB」？」
  private static func title(_ change: HistoryLimit) -> String {
    change.isDays
      ? String(localized: "截图历史改成保留「\(daysTitle(change.value))」？")
      : String(localized: "截图历史最多占用改成「\(megabytesTitle(change.value))」？")
  }

  static func daysTitle(_ days: Int) -> String {
    days == 0 ? String(localized: "一直留着") : String(localized: "\(days) 天")
  }

  static func megabytesTitle(_ megabytes: Int) -> String {
    megabytes == 0 ? String(localized: "不限") : "\(megabytes / 1024) GB"
  }
}

/// 快速保存的文件夹一行：截图页「快速保存到」和录制页「保存到」是同一个偏好、同一行。文件夹符号 + 访达里的名字
/// （完整路径在悬停提示里），选过的能「恢复默认」，「更改…」选别的文件夹。
/// **选过的这一行不去碰那个文件夹**（第五轮体检 P2，同自动备份「另存一份到」那一行：它可能在卡住的网络盘上，在主线程上
/// 问一句名字、要一个图标就能把设置窗卡住）：名字是选的那一刻取了存下的，图标用符号
struct SaveDirectoryRow: View {
  let title: LocalizedStringResource
  /// 一句副标题、行尾 ⓘ（设置改版 S5）
  var subtitle: LocalizedStringResource? = nil
  var info: LocalizedStringResource? = nil
  /// 选过的文件夹（没选过 = nil，跟随系统截屏的存储位置）；实际位置按 ScreenshotOutput.directory 算（有兜底）
  @AppStorage(Prefs.screenshotSaveDirectory) private var savedDirectory: String?
  /// 它在访达里的名字（选的那一刻存下的）
  @AppStorage(Prefs.screenshotSaveDirectoryName) private var savedName: String?

  var body: some View {
    LabeledContent {
      HStack(spacing: 8) {
        if let info { InfoButton(info, about: title) }
        // 没选过的是系统截屏的存储位置（多半是桌面，在本机）：现取。ponytail: 它也能在 ⌘⇧5 里设成网络盘，那时这里会卡，
        // 升级路径见 ScreenshotOutput.saveFolderName
        let path = savedDirectory ?? ScreenshotOutput.directory(saved: nil).path
        let name =
          savedDirectory == nil
          ? FileManager.default.displayName(atPath: path)
          : savedName ?? (path as NSString).lastPathComponent
        // 同工具栏「存储到「桌面」」：访达里的名字 + 文件夹图标，完整路径在悬停提示里
        Label(name, systemImage: "folder")
          .lineLimit(1)
          .truncationMode(.middle)
          .foregroundStyle(.secondary)
          .help((path as NSString).abbreviatingWithTildeInPath)
        if savedDirectory != nil {
          Button("恢复默认") { pick(nil) }
            .buttonStyle(.plain)
            .foregroundStyle(Style.brandInk)
            .pointerStyle(.link)
            .help("跟随系统截屏的存储位置")
        }
        Button("更改…", action: chooseDirectory)
      }
    } label: {
      Text(plain: title)
      if let subtitle { Text(plain: subtitle) }
    }
  }

  private func chooseDirectory() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    // 不先看它在不在（可能在卡住的网络盘上）：面板自己去
    panel.directoryURL =
      savedDirectory.map { URL(filePath: $0, directoryHint: .isDirectory) }
      ?? ScreenshotOutput.directory(saved: nil)
    panel.prompt = String(localized: "选取")
    panel.begin { response in
      if response == .OK, let url = panel.url { pick(url) }
    }
  }

  /// 换文件夹（nil = 恢复默认）：名字跟着换。刚在面板里选的，这时候问名字不会卡
  private func pick(_ url: URL?) {
    savedName = url.map { FileManager.default.displayName(atPath: $0.path) }
    savedDirectory = url?.path
  }
}

/// 「接起来」的实时对照：两段四行的识别结果（带行框，两段之间空出一行），开关打开时按 OCR.text 分段接好
/// （中文直接连、英文加空格，段间换行）
private struct JoinLinesPreview: View {
  let joins: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// 行高 0.1、行距 0.03，两段之间空 0.15（> 1.2 倍行高）。示例故意一段中文、一段英文（看两种接法），不翻
  private static let sample: [OCR.Line] = [
    ("敏捷的棕色狐狸", 0.9, 0.7), ("跳过了懒狗。", 0.77, 0.6), ("The quick brown", 0.52, 0.75),
    ("fox jumps over it.", 0.39, 0.7),
  ].map { OCR.Line(text: $0.0, box: CGRect(x: 0.1, y: $0.1 - 0.1, width: $0.2, height: 0.1)) }

  var body: some View {
    let text = OCR.text(Self.sample, joined: joins)
    Text(text)
      .font(.system(size: 12, design: .monospaced))
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(8)
      .background(
        Style.controlFill, in: .rect(cornerRadius: Style.Radius.control, style: .continuous)
      )
      .contentTransition(.opacity)
      .animation(Style.Motion.settle.animation(reduced: reduceMotion), value: joins)
      .accessibilityLabel("效果示例")
      .accessibilityValue(text)
  }
}
