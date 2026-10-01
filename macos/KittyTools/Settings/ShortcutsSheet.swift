// 快捷键速查表（N11，mac-whisker §6 设置）：设置各页不写整段按键说明，只留一句话 +「查看全部快捷键…」
// （`ShortcutsButton`，哪一页都能直接放），点开是这张 sheet：按家族分组（20 pt 家族色块 + 组名），Whisker 键帽。
// 全局快捷键从 HotKeyAction 实时读（当前设的组合）；面板里的按键散在各面板的按键处理里、没有集中定义，
// 就集中写在本文件的 groups 里，每组注明对应的规则章节和代码。改了面板按键要同步这里（mac-whisker §10 第 7 条）。

import SwiftUI

/// 「查看全部快捷键…」文字按钮，自己管 sheet 的开关，任何设置页都能直接放
struct ShortcutsButton: View {
  @State private var isPresented = false

  var body: some View {
    Button("查看全部快捷键…") { isPresented = true }
      .buttonStyle(.plain)
      .foregroundStyle(Style.brandInk)
      .pointerStyle(.link)
      .sheet(isPresented: $isPresented) { Self.sheet() }
  }

  /// 速查表 sheet（这个按钮和启动器的「快捷键速查表」共用），按打开时窗口的可用高度定高
  static func sheet() -> some View {
    ShortcutsSheet().frame(
      width: 560, height: sheetHeight(available: NSApp.keyWindow?.contentLayoutRect.height ?? 548))
  }

  /// sheet 挂在设置窗工具栏下沿，不能比窗口内容区（去掉工具栏）高：设置窗默认 600、最小 460，工具栏约 52。
  /// 按打开时窗口的可用高度取，最高 520，最矮 360（内容在 ScrollView 里）
  static func sheetHeight(available: CGFloat) -> CGFloat {
    min(520, max(360, available - 16))
  }
}

struct ShortcutsSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ScrollViewReader { proxy in
      VStack(spacing: 0) {
        header(proxy)
        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            ForEach(Self.groups) { GroupCard(group: $0).id($0.id) }
          }
          .padding(.horizontal, 20)
          .padding(.vertical, 14)
        }
        .overlay(alignment: .top) { Hairline() }
        HStack {
          Spacer()
          // 主按钮 = ↩（defaultAction）；Esc 靠下面那个看不见的 cancelAction 按钮（同欢迎引导）
          Button("完成") { dismiss() }
            .buttonStyle(BrandButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .overlay(alignment: .top) { Hairline() }
      }
    }
    .background {
      Button("关闭") { dismiss() }
        .keyboardShortcut(.cancelAction)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
  }

  /// 页头（40 pt 色块 + 标题 + 说明）+ 四个家族的跳转胶囊
  private func header(_ proxy: ScrollViewProxy) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        KindTile(symbol: "keyboard.fill", color: Style.Family.keyboard, size: 40)
        VStack(alignment: .leading, spacing: 2) {
          Text("快捷键速查").font(.title2.weight(.semibold))
          Text("标着「全局」的在任何 App 里都能按，可到「设置 › 快捷键」里改；其余是面板和设置窗里的按键。")
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
      }
      .accessibilityElement(children: .combine)
      HStack(spacing: 6) {
        // 有全局快捷键的组就是一个家族的第一组
        ForEach(Self.groups.filter { !$0.globals.isEmpty }) { group in
          let name = group.title.components(separatedBy: " · ")[0]
          Button {
            withAnimation(Style.Motion.settle.animation(reduced: reduceMotion)) {
              proxy.scrollTo(group.id, anchor: .top)
            }
          } label: {
            HStack(spacing: 6) {
              KindTile(symbol: group.symbol, color: group.color, size: 16)
              Text(name).font(.system(size: 12, weight: .medium))
            }
            .padding(.leading, 4)
            .padding(.trailing, 10)
            .frame(height: 24)
            .background(Style.controlFill, in: .capsule)
            .contentShape(.capsule)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("跳到\(name)")
        }
      }
    }
    .padding(.horizontal, 20)
    .padding(.top, 18)
    .padding(.bottom, 12)
  }

  /// 一行：说明 + 按键（keys 里每项是一种按法，多项之间写「/」）
  struct Entry: Hashable {
    let keys: [String]
    let text: String

    init(_ keys: String..., text: String) {
      self.keys = keys
      self.text = text
    }
  }

  struct Group: Identifiable {
    let title: String
    let symbol: String
    let color: Color
    /// 这一组的全局快捷键（排在最前，带「全局」标记）
    var globals: [HotKeyAction] = []
    let entries: [Entry]
    var id: String { title }
  }

  /// 每次打开现算：录屏组里「停止」那行写当前设的录屏快捷键
  static var groups: [Group] {
    [
      // mac-clipboard §4 面板交互表（Lens Bar，N1–N4）；代码在 ClipboardPanelModel
      Group(
        title: "剪贴板", symbol: "doc.on.clipboard.fill", color: Style.Family.clipboard,
        globals: [.clipboard],
        entries: [
          Entry("↩", text: "粘贴选中的条目（双击同样；多选时全是文本合并、全是文件一起粘贴，其余依次粘贴）"),
          Entry("⌥↩", text: "粘贴为纯文本（打开「默认粘贴为纯文本」后是保留格式粘贴）"),
          Entry("⌘↩", "⌘C", text: "只复制，不粘贴"),
          Entry("⌘1–9", text: "直接粘贴第 1–9 条"),
          Entry("↑↓", text: "移动选中，透镜跟着走"),
          Entry("⇧↑↓", text: "扩展多选（⇧ 单击选一段，⌘ 单击逐条勾选）"),
          Entry("Tab", text: "打开 / 关闭筛选面板（范围、收藏夹、类型、来源）"),
          Entry("⇧Tab", text: "在 全部 / 收藏 / 片段 之间切换"),
          Entry("⌘K", "→", text: "打开 / 关闭操作面板（→ 要在搜索词末尾按；在「移到收藏夹 ›」上按 → 或 ↩ 进去）"),
          Entry("←", text: "操作面板开着、过滤词为空时回上一级 / 关掉它"),
          Entry("⌫", text: "搜索框为空时：选中最后一个筛选标签，再按一次删掉"),
          Entry("⌘Y", text: "放大预览"),
          Entry("⌘T", text: "翻译（文本，或识别出文字的图片）"),
          Entry("⌘O", text: "打开链接，或用默认 App 打开文件"),
          Entry("⌘R", text: "在访达中显示（文件）"),
          Entry("⌥⌘C", text: "复制文件路径（多个按换行分开）"),
          Entry("⌘D", text: "收藏 / 取消收藏（取消时也移出收藏夹）"),
          Entry("⌘E", text: "编辑"),
          Entry("⌘N", text: "新建片段"),
          Entry("⌘⌫", text: "删除（管理收藏夹里是删掉选中的收藏夹，条目留在收藏里）"),
          Entry("⌘Z", text: "撤销（删除、删收藏夹，以及取消收藏后会被清理的；收起面板前可以一步步连着撤）"),
          Entry("⌘A", text: "全选（搜索框为空时）"),
          Entry("⌘P", text: "固定 / 取消固定（固定后点面板外面不收起）"),
          Entry("⌘,", text: "打开 设置 › 剪贴板"),
          Entry("Esc", text: "逐级退出：放大预览、菜单、对话框、待删标签、搜索词、多选，最后关闭（固定着也关）"),
          Entry("⌘W", text: "关闭（固定着也关；对话框开着时先关对话框）"),
          Entry("↑↓", "↩", text: "管理收藏夹里：选择 / 给选中的改名（双击同样；输入框里有字时 ↩ 是新建）"),
        ]),
      // mac-whisker §6 启动器（N8–N10，体检第 5 批）；代码在 LauncherModel.handleCommand / handleKeyEquivalent
      Group(
        title: "启动器", symbol: "command", color: Style.Family.command, globals: [.launcher],
        entries: [
          Entry("↩", text: "打开选中项（计算结果是粘贴；双击同样）"),
          Entry("⌘↩", text: "在访达中显示（find 搜到的是打开，计算结果只复制，网址用第二个浏览器打开）"),
          Entry("⌥↩", text: "在访达里搜索输入的文字"),
          Entry("⌃↩", text: "用第一个网页搜索搜输入的文字"),
          Entry("⌘K", "→", text: "打开 / 关闭动作菜单：选中项的全部动作（→ 要在搜索词末尾按；右键同一份）"),
          Entry("Tab", text: "补全（计算结果接着算、目录接着往下找）"),
          Entry("⌘C", text: "复制路径、网址或计算结果"),
          Entry("⇧⌘C", text: "把网址复制为 Markdown 链接"),
          Entry("⌘D", text: "加入 / 取消收藏（收藏排在空搜索框的最上面）"),
          Entry("⌥⌘↑↓", text: "空搜索框里调整选中的收藏的顺序"),
          Entry("⌘Y", text: "快速查看选中的文件"),
          Entry("⌘1–9", text: "打开第 1–9 项"),
          Entry("↑↓", text: "移动选中"),
          Entry("⌘⌫", text: "从「常用」里移除"),
          Entry("⌘Z", text: "撤销移除"),
          Entry("⌘,", text: "打开 设置 › 启动器"),
          Entry("Esc", text: "先关预览和动作菜单，再撤掉待确认的命令，再清空搜索，最后关闭"),
          Entry("⌘W", text: "关闭"),
          Entry("open", text: "搜文件并打开（空格开头同样）"),
          Entry("find", text: "搜文件并在访达中显示"),
          Entry("cb", text: "在剪贴板历史里搜索"),
          Entry("fy", text: "翻译输入的文字（单个英文词另有词典释义）"),
        ]),
      // mac-whisker §6 启动器「系统命令」；代码在 SystemCommands / SystemControl。在启动器里输入关键词（中文名、拼音也行）
      Group(
        title: "系统命令", symbol: "power", color: Style.Family.command,
        entries: SystemCommand.allCases.map { command in
          let note =
            command.confirmation != nil
            ? "（再按一次 ↩ 确认）" : [.logout, .restart, .shutdown].contains(command) ? "（弹系统确认框）" : ""
          return Entry(command.rawValue, text: command.title.replacing("…", with: "") + note)
        } + [
          Entry("quit", text: "列出正在运行的 App：↩ 退出，⌘↩ 强制退出（再按一次确认）"),
          Entry("hide", text: "列出正在运行的 App：↩ 隐藏，⌘↩ 强制退出（再按一次确认）"),
          Entry("forcequit", text: "列出正在运行的 App：↩ 强制退出（再按一次确认）"),
          Entry("eject", text: "列出可推出的磁盘：↩ 推出"),
          Entry("kill", text: "列出后台进程（kill :端口 按端口列）：↩ 结束，⌘↩ 强制结束（再按一次确认）"),
        ]),
      // mac-translate「浮窗快捷键」「翻译浮窗」（N5–N6）；代码在 TranslateCoordinator.handleKeyEquivalent、SourceTextView
      Group(
        title: "翻译", symbol: "character.bubble.fill", color: Style.Family.translate,
        globals: [.selectionTranslate, .inputTranslate, .translateReplace, .screenshotTranslate],
        entries: [
          Entry("↩", text: "翻译"),
          Entry("⇧↩", "⌘↩", text: "换行"),
          Entry("⌘R", text: "重新翻译"),
          Entry("⌘D", text: "收藏这次翻译"),
          Entry("⌘1–9", text: "复制第 1–9 个结果"),
          Entry("⌘Y", text: "打开 / 关闭翻译历史"),
          Entry("⌘P", text: "固定 / 取消固定浮窗（固定后点别处不收起）"),
          Entry("⌘+", "⌘-", "⌘0", text: "放大 / 缩小 / 还原字号"),
          Entry("⌘,", text: "打开 设置 › 翻译"),
          Entry("Esc", "⌘W", text: "关闭（固定着也关；历史开着时 Esc 先关历史）"),
        ]),
      // mac-translate「翻译历史」（N7，体检 C6）；代码在 TranslateCoordinator.handleHistoryCommand、HistoryList.handleKeyEquivalent
      Group(
        title: "翻译 · 历史", symbol: "clock.arrow.circlepath", color: Style.Family.translate,
        entries: [
          Entry("↑↓", text: "移动选中"),
          Entry("↩", text: "重新翻译这条（双击同样）"),
          Entry(
            "⌘K", "→",
            text: "打开 / 关闭动作菜单：这条的全部操作、导出、清空历史（→ 要在搜索词末尾按；在「导出 ›」上按 → 或 ↩ 进去）"),
          Entry("←", text: "动作菜单开着、过滤词为空时回上一级 / 关掉它"),
          Entry("⇧Tab", text: "在 全部 / 收藏 之间切换"),
          Entry("⌘C", text: "复制译文"),
          Entry("⇧⌘C", text: "复制原文"),
          Entry("⌘D", text: "收藏 / 取消收藏这条"),
          Entry("⌘⌫", text: "删除（⌘Z 撤销）"),
          Entry("Esc", text: "先关动作菜单，再清空搜索，最后回到浮窗"),
        ]),
      // mac-whisker §6 截图「待选」「框选 / 拖边」「键盘调整」；代码在 SelectionView.keyDown
      Group(
        title: "截图 · 框选", symbol: "camera.viewfinder", color: Style.Family.screenshot,
        globals: [.screenshot, .screenshotLastRegion, .recognizeText],
        entries: [
          Entry("⇧", text: "锁定比例（新框是正方形）"),
          Entry("⌥", text: "从中心拉框"),
          Entry("空格", text: "按住平移选区"),
          Entry("⌃", text: "暂停吸附"),
          Entry("⌘", text: "按住显示十字准线"),
          Entry("D", text: "选中上次的区域"),
          Entry("方向键", text: "移动选区 1 点（按住 ⇧ 10 点）"),
          Entry("⌘方向键", text: "把那条边往外推（按住 ⇧ 10 点）"),
          Entry("⌥方向键", text: "把那条边往里收（按住 ⇧ 10 点）"),
          Entry("C", text: "复制放大镜里的色值"),
          Entry("Esc", text: "逐级退出，最后取消截图"),
        ]),
      // mac-whisker §6 截图「工具」「标注编辑」
      Group(
        title: "截图 · 标注", symbol: "pencil.tip.crop.circle", color: Style.Family.screenshot,
        entries: [
          Entry(
            "1–0",
            text: "1 矩形 · 2 椭圆 · 3 箭头 · 4 直线 · 5 画笔 · 6 荧光笔 · 7 文字 · 8 序号 · 9 马赛克 · 0 聚光灯；再按一次收起"),
          Entry("⇧", text: "画正方形、正圆、45° 线"),
          Entry("⌫", text: "删除选中的标注"),
          Entry("⌘D", text: "复制一份选中的标注（按住 ⌥ 拖动同样）"),
          Entry("方向键", text: "移动选中的标注"),
          Entry("⌘Z", "⇧⌘Z", text: "撤销 / 重做"),
        ]),
      // mac-whisker §6 截图「出图」
      Group(
        title: "截图 · 出图", symbol: "square.and.arrow.down.fill", color: Style.Family.screenshot,
        entries: [
          Entry("↩", "⌘C", text: "拷贝（双击选区同样）"),
          Entry("⌘S", text: "快速保存"),
          Entry("⇧⌘S", text: "另存为…"),
          Entry("T", text: "钉在屏幕上"),
          Entry("S", text: "长截图"),
          Entry("R", text: "录屏（选区不变；有标注时不切）"),
          Entry("O", text: "识字并拷贝"),
        ]),
      // mac-overlay-panel §10 长截图；代码在 ScrollCapturePanel.keyDown
      Group(
        title: "长截图", symbol: "arrow.up.and.down.text.horizontal", color: Style.Family.screenshot,
        entries: [
          Entry("空格", text: "自动滚动 / 停下（要辅助功能授权）"),
          Entry("↩", "⌘C", text: "拷贝"),
          Entry("⌘S", text: "快速保存"),
          Entry("⇧⌘S", text: "另存为…"),
          Entry("Esc", text: "取消"),
        ]),
      // mac-whisker §6 截图「录屏」（录屏第 1、2 批）；框选、拖边、方向键同「截图 · 框选」，代码在 SelectionView.keyDown，
      // 倒数的 Esc 是 ScreenRecorder 临时注册的热键
      Group(
        title: "录屏", symbol: "record.circle", color: Style.Family.screenshot,
        globals: [.screenRecord],
        entries: [
          Entry("↩", text: "开始录制（双击选区同样）"),
          Entry("Esc", text: "框选时逐级退出，最后取消；倒数中取消"),
          Entry(
            HotKeyAction.screenRecord.hotKey?.display ?? "",
            text: "录制中停止并保存（点菜单栏的 ■ 计时、录屏控制条的 ■ 同样）"),
        ]),
      // mac-whisker §6 截图「录音」（录音第 5 批，AudioRecorder；手测反馈第 3 批：第一下先出控制条，设置 › 截图可改成
      // 按下立即开始）；录音不设默认键，没设时这两行的键帽是空的
      Group(
        title: "录音", symbol: "waveform", color: Style.Family.screenshot,
        globals: [.audioRecord],
        entries: [
          Entry(
            HotKeyAction.audioRecord.hotKey?.display ?? "",
            text: "控制条开着、还没开始时开始录音（点控制条的 ● 同样）"),
          Entry(
            HotKeyAction.audioRecord.hotKey?.display ?? "",
            text: "录制中停止并保存（点菜单栏的 ■ 计时、录音控制条的 ■ 同样）"),
        ]),
      // mac-overlay-panel §9 钉图；代码在 PinView.keyDown / performKeyEquivalent
      Group(
        title: "钉图", symbol: "pin.fill", color: Style.Family.screenshot,
        entries: [
          Entry("⌘C", text: "拷贝"),
          Entry("O", text: "识字并拷贝（翻译在右键菜单里）"),
          Entry("⌘S", text: "快速保存"),
          Entry("⇧⌘S", text: "另存为…"),
          Entry("⌘0", text: "原始大小（滚轮、捏合缩放）"),
          Entry("⌘W", "Esc", text: "关闭（双击同样）"),
        ]),
      // mac-whisker §6 设置；代码在 SettingsWindow 的 SettingsCommands（主菜单「显示 › 返回」）
      Group(
        title: "设置", symbol: "gearshape.fill", color: Style.Family.general,
        entries: [
          Entry("⌘[", text: "从翻译服务、网页搜索的详情页返回列表")
        ]),
    ]
  }
}

/// 一组：20 pt 家族色块 + 组名，下面白底卡片里一行一个（全局快捷键排最前），行高 30、行间发丝线
private struct GroupCard: View {
  let group: ShortcutsSheet.Group

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        KindTile(symbol: group.symbol, color: group.color, size: 20)
        Text(group.title).font(.system(size: 13, weight: .semibold))
      }
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(.isHeader)
      VStack(spacing: 0) {
        ForEach(group.globals, id: \.self) { action in
          row(divided: action != group.globals.first) {
            HStack(spacing: 6) {
              Text(action.title)
              Text("全局")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Style.controlFill, in: .rect(cornerRadius: Style.Radius.mini))
            }
          } keys: {
            // 当前设的组合（UserDefaults；sheet 开着时改不了快捷键，不用观察）
            if let hotKey = action.hotKey {
              KeyCombo(hotKey.display)
            } else {
              Text("未设置").foregroundStyle(.tertiary)
            }
          }
        }
        ForEach(group.entries, id: \.self) { entry in
          row(divided: !group.globals.isEmpty || entry != group.entries.first) {
            Text(entry.text)
          } keys: {
            KeyAlternatives(keys: entry.keys)
          }
        }
      }
      .background(.background, in: shape)
      .overlay(shape.hairlineBorder())
    }
  }

  private func row(
    divided: Bool, @ViewBuilder label: () -> some View, @ViewBuilder keys: () -> some View
  ) -> some View {
    HStack(spacing: 12) {
      label().fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 12)
      keys()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 5)
    .frame(minHeight: 30)
    .overlay(alignment: .top) {
      if divided { Hairline().padding(.horizontal, 12) }
    }
    .accessibilityElement(children: .combine)
  }
}

/// 几种按法并排，中间「/」
private struct KeyAlternatives: View {
  let keys: [String]

  var body: some View {
    HStack(spacing: 5) {
      ForEach(keys, id: \.self) { key in
        HStack(spacing: 5) {
          if key != keys.first { Text("/").foregroundStyle(.tertiary) }
          KeyCombo(key)
        }
      }
    }
  }
}
