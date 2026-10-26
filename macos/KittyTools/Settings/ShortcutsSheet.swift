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

  /// 页头（40 pt 色块 + 标题 + 说明）+ 各家族的跳转胶囊。胶囊一行 5 枚、折成两行：加了状态屏、便签是 9 枚（5 + 4），
  /// 一行（560 宽的表单里 520）放不下，系统会把字截成「剪…」
  private func header(_ proxy: ScrollViewProxy) -> some View {
    // 有全局快捷键的组就是一个家族的第一组
    let chips = Self.groups.filter { !$0.globals.isEmpty }
    let rows = stride(from: 0, to: chips.count, by: 5).map { Array(chips[$0...].prefix(5)) }
    return VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        KindTile(symbol: "keyboard.fill", color: Style.Family.keyboard, size: 40)
        VStack(alignment: .leading, spacing: 2) {
          Text("快捷键速查").font(.title2.weight(.semibold))
          Text("标着「全局」的在任何 App 里都能按，可到 设置 › 快捷键 里改；其余是面板和设置窗里的按键。")
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
      }
      .accessibilityElement(children: .combine)
      VStack(alignment: .leading, spacing: 6) {
        ForEach(rows, id: \.first?.id) { row in
          HStack(spacing: 6) {
            ForEach(row) { group in
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
    /// 指向别的功能的那一行（剪贴板的 ⌘T 翻译、启动器的 cb / fy、截图里按 R 录屏）：那个功能关着时不列
    let needs: Feature?

    init(_ keys: String..., text: String, needs: Feature? = nil) {
      self.keys = keys
      self.text = text
      self.needs = needs
    }
  }

  struct Group: Identifiable {
    let title: String
    let symbol: String
    let color: Color
    /// 归哪些功能（Feature，有一个开着就列）；空 = 按全局快捷键各自的功能，再空就总是列（设置那一组）
    var features: [Feature] = []
    /// 这一组的全局快捷键（排在最前，带「全局」标记）
    var globals: [HotKeyAction] = []
    var entries: [Entry]
    var id: String { title }
  }

  /// 只列开着的功能（Feature；macOS 15 上没有启动台那一组）
  static var groups: [Group] { groups(enabled: Feature.enabled) }

  /// 单测喂集合：关着的功能的组不列；列出来的组里关着的功能的全局键、指向关着的功能的行也去掉
  static func groups(enabled: Set<Feature>) -> [Group] {
    allGroups.compactMap { group in
      let owners = group.features.isEmpty ? group.globals.compactMap(\.feature) : group.features
      guard owners.isEmpty || owners.contains(where: enabled.contains) else { return nil }
      var group = group
      group.globals = group.globals.filter { $0.feature.map(enabled.contains) ?? true }
      group.entries = group.entries.filter { $0.needs.map(enabled.contains) ?? true }
      return group
    }
  }

  /// 每次打开现算：录屏组里「停止」那行写当前设的录屏快捷键
  private static var allGroups: [Group] {
    [
      // mac-clipboard §4 面板交互表（Lens Bar，N1–N4）；代码在 ClipboardPanelModel
      Group(
        title: "剪贴板", symbol: "doc.on.clipboard.fill", color: Style.Family.clipboard,
        globals: [.clipboard],
        entries: [
          Entry("↩", text: "粘贴选中的条目（双击同样，设置里可改成点一下就粘贴；多选时全是文本合并、全是文件一起粘贴，其余依次粘贴）"),
          Entry("⌥↩", text: "粘贴为纯文本（打开「默认粘贴为纯文本」后是保留格式粘贴）"),
          Entry("⌘↩", "⌘C", text: "只复制，不粘贴"),
          Entry("⌘1–9", text: "直接粘贴第 1–9 条"),
          Entry("↑↓", text: "移动选中，透镜跟着走"),
          Entry("⇧↑↓", text: "扩展多选（⇧ 单击选一段，⌘ 单击逐条勾选）"),
          Entry("Tab", text: "打开 / 关闭筛选面板（范围、收藏夹、类型、来源）"),
          Entry("⇧Tab", text: "在 全部 / 收藏 / 片段 之间切换"),
          Entry("⌘K", "→", text: "打开 / 关闭操作菜单（→ 要在搜索词末尾按；在「移到收藏夹 ›」上按 → 或 ↩ 进去）"),
          Entry("←", text: "操作菜单开着、过滤词为空时回上一级 / 关掉它"),
          Entry("⌫", text: "搜索框为空时：选中最后一个筛选标签，再按一次删掉"),
          Entry("⌘Y", text: "放大预览"),
          Entry("⌘T", text: "翻译（文本，或识别出文字的图片）", needs: .translate),
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
          Entry("⌘K", "→", text: "打开 / 关闭操作菜单：选中项的全部操作（→ 要在搜索词末尾按；右键同一份）"),
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
          Entry("Esc", text: "先关预览和操作菜单，再撤掉待确认的命令，再清空搜索，最后关闭"),
          Entry("⌘W", text: "关闭"),
          Entry("open", text: "搜文件并打开（空格开头同样）"),
          Entry("find", text: "搜文件并在访达中显示"),
          Entry("cb", text: "在剪贴板历史里搜索", needs: .clipboard),
          Entry("fy", text: "翻译输入的文字（单个英文词另有词典释义）", needs: .translate),
        ]),
      // mac-whisker §6 启动器「系统命令」；代码在 SystemCommands / SystemControl。在启动器里输入关键词（中文名、拼音也行）
      Group(
        title: "系统命令", symbol: "power", color: Style.Family.command,
        features: [.launcher],
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
          Entry("port", text: "列出在监听的端口：↩ 结束占用它的进程，⌘↩ 强制结束（再按一次确认）"),
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
        features: [.translate],
        entries: [
          Entry("↑↓", text: "移动选中"),
          Entry("↩", text: "重新翻译这条（双击同样）"),
          Entry(
            "⌘K", "→",
            text: "打开 / 关闭操作菜单：这条的全部操作、导出、清空历史（→ 要在搜索词末尾按；在「导出 ›」上按 → 或 ↩ 进去）"),
          Entry("←", text: "操作菜单开着、过滤词为空时回上一级 / 关掉它"),
          Entry("⇧Tab", text: "在 全部 / 收藏 之间切换"),
          Entry("⌘C", text: "复制译文"),
          Entry("⇧⌘C", text: "复制原文"),
          Entry("⌘D", text: "收藏 / 取消收藏这条"),
          Entry("⌘⌫", text: "删除（⌘Z 撤销）"),
          Entry("Esc", text: "先关操作菜单，再清空搜索，最后回到浮窗"),
        ]),
      // mac-whisker §6 截图「待选」「框选 / 拖边」「键盘调整」；代码在 SelectionView.keyDown
      Group(
        title: "截图 · 框选", symbol: "camera.viewfinder", color: Style.Family.screenshot,
        features: [.screenshot, .translate, .record],
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
        features: [.screenshot],
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
        features: [.screenshot],
        entries: [
          Entry("↩", "⌘C", text: "拷贝（双击选区同样）"),
          Entry("⌘S", text: "快速保存"),
          Entry("⇧⌘S", text: "另存为…"),
          Entry("T", text: "钉在屏幕上"),
          Entry("S", text: "长截图"),
          Entry("R", text: "录屏（选区不变；有标注时不切）", needs: .record),
          Entry("O", text: "识字并拷贝"),
        ]),
      // mac-overlay-panel §10 长截图；代码在 ScrollCapturePanel.keyDown
      Group(
        title: "长截图", symbol: "arrow.up.and.down.text.horizontal", color: Style.Family.screenshot,
        features: [.screenshot],
        entries: [
          Entry("空格", text: "自动滚动 / 停下（要辅助功能授权）"),
          Entry("A", text: "标注（在长图上画，画完再出图）"),
          Entry("↩", "⌘C", text: "拷贝"),
          Entry("⌘S", text: "快速保存"),
          Entry("⇧⌘S", text: "另存为…"),
          Entry("Esc", text: "取消"),
        ]),
      // 截图历史（2026-10-26 拍板 C1）：全局的「截图历史」不设默认键，没设时那一行写「未设置」。
      // 窗口里的键在 ShotHistoryView
      Group(
        title: "截图历史", symbol: "clock.arrow.circlepath", color: Style.Family.screenshot,
        features: [.screenshot], globals: [.shotHistory],
        entries: [
          Entry("双击", text: "改标注（录制的是用默认 App 打开）"),
          Entry("⌫", text: "删掉选中的那条"),
        ]),
      // 长图标注窗口（2026-10-26）；代码在 ScrollCanvas.keyDown 和 ScrollEditor.key
      Group(
        title: "长图标注", symbol: "pencil.tip.crop.circle", color: Style.Family.screenshot,
        features: [.screenshot],
        entries: [
          Entry("1", "0", text: "十种标注工具（再按一次收起）"),
          Entry("⌫", text: "删除选中的标注"),
          Entry("⌘D", text: "复制选中的标注"),
          Entry("⌘Z", "⇧⌘Z", text: "撤销 / 重做"),
          Entry("空格", text: "按住拖动平移画面"),
          Entry("⌘0", "⌘1", text: "适配宽度 / 原始大小"),
          Entry("⌘+", "⌘-", text: "放大 / 缩小"),
          Entry("↩", "⌘C", text: "拷贝"),
          Entry("⌘S", text: "快速保存"),
          Entry("⇧⌘S", text: "另存为…"),
          Entry("O", text: "识字并拷贝"),
          Entry("Esc", text: "收起工具 / 关闭（画过会问一次）"),
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
      // mac-whisker §6 截图「录音」（录音第 5 批，AudioRecorder；手测反馈第 3 批：第一下先出控制条，设置 › 录制可改成
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
      // mac-overlay-panel §9 钉图；代码在 PinView.keyDown / performKeyEquivalent。全局的「钉住剪贴板里的图」（第二轮体检 F1）
      // 不设默认键，没设时那一行写「未设置」
      Group(
        title: "钉图", symbol: "pin.fill", color: Style.Family.screenshot,
        globals: [.pinClipboard],
        entries: [
          Entry("⌘C", text: "拷贝"),
          Entry("O", text: "识字并拷贝（翻译在右键菜单里）"),
          Entry("⌘S", text: "快速保存"),
          Entry("⇧⌘S", text: "另存为…"),
          Entry("⌘0", text: "原始大小（滚轮、捏合缩放）"),
          Entry("⌘W", "Esc", text: "关闭（双击同样）"),
        ]),
      // 便签（PLAN §10「便签」）：快速记一条的键在 NoteCaptureModel.handleKeyEquivalent 和 SourceTextView（提交模式）。
      // 新建便签、全部便签不设默认键，没设时那两行写「未设置」
      Group(
        title: "便签", symbol: HotKeyAction.noteAll.symbol, color: Style.Family.notes,
        globals: [.noteCapture, .noteNew, .noteAll],
        entries: [
          Entry("↩", text: "快速记一条里：记下"),
          Entry("⇧↩", "⌘↩", text: "快速记一条里：换行"),
          Entry("Tab", text: "快速记一条里：记成新便签时去填标题，再按一次（或 ↩）回到正文"),
          Entry("⌘1", text: "快速记一条里：记成新便签"),
          Entry("⌘2–9", text: "快速记一条里：接在最近改过的某一条便签后面"),
          Entry("Esc", text: "快速记一条里：清空并关闭（点面板外面、再按一次全局快捷键、⌘W 也是关闭，写了一半的留着）"),
        ]),
      // 屏幕边缘那叠里打开的便签（第 3 批）：⌘ 组合在 NoteDeckModel.handleKeyEquivalent，Esc 是面板的 cancelOperation（cancel），
      // 操作菜单开着时的方向键在 handleMenuKey。⌘⌫ 不写：在标题、正文里它就是输入框的删到行首。
      // 第 5 批：⌘T 任务、⌘F 便签内查找（同一处）；⌘Z / ⇧⌘Z 是面板直接动焦点所在输入框的撤销栈（OverlayPanel.undoRedo）；
      // 回车续行、Tab 缩进在正文编辑器里（NoteTextView.doCommand）。第 6 批：⌘ 点链接（NoteTextView.linkToOpen）。
      // 手测反馈第 4 批：⌘B ⌘I ⇧⌘X ⌘E 在正文编辑器里（NoteTextView.performKeyEquivalent，规则 NoteMarkdown.toggle），
      // 选中字时粘贴网址成链接（NoteTextView.paste）
      Group(
        title: "便签 · 屏幕边缘", symbol: "sidebar.right", color: Style.Family.notes,
        features: [.notes],
        entries: [
          Entry("Esc", "⌘W", text: "关掉打开的便签，那一列标签也一起收回，接着打字回到原来的 App"),
          Entry("⌘P", text: "固定 / 取消固定（固定的便签点别处不收起；浮在屏幕上的便签固定后一直在别的窗口上面，重启后回到原处）"),
          Entry(
            "⌘K",
            text: "操作菜单：固定、颜色、任务、归档、删除、浮在屏幕上、在「全部便签」里打开、导出为 Markdown、便签设置（↑↓ 选，↩ 执行，→ ← 进出「颜色」）"),
          Entry("⌘.", text: "换成下一种纸色"),
          Entry("⇧⌘A", text: "归档"),
          Entry("⌘T", text: "任务：光标所在的行（选了几行就是那几行）变成任务，再按一次变回普通行；点行首的方框打勾"),
          Entry("↩", "Tab", text: "正文里：任务行、列表行回车接着下一条，空的那条上回车退出列表；Tab / ⇧Tab 缩进、退回"),
          Entry("⌘F", text: "在这条便签里查找（Esc 先关查找条，再按才关便签）"),
          Entry("⌘Z", "⇧⌘Z", text: "撤销 / 重做打的字（勾任务、回车接出来的下一条也能撤）"),
          Entry("⌘", text: "按住它点正文里的链接：打开（网址和邮件地址；不按 ⌘ 是放光标）"),
          Entry("⌘B", "⌘I", text: "正文里：粗体、斜体（选区整段一种：不全是就全加上、原来有的并成一段；全都是就去掉、拆开；没选字插一对，光标在中间）"),
          Entry("⇧⌘X", "⌘E", text: "正文里：删除线（同上）、代码（只在没选字时插一对；代码块里不加）"),
          Entry("⌘V", text: "选中一段字时粘贴一个网址：粘成链接，字不变"),
          Entry(
            "⌘V",
            text: "正文里：剪贴板里是图片（截图、复制的图）时插一张；也可以把图片文件拖进来，或右键「插入图片…」"),
          Entry(
            "⌃↩",
            text: "正文里：弹出右键菜单（任务状态、文字颜色、格式：粗体、斜体、删除线、代码、链接、标题 1–3、引用、无序列表、有序列表、代码块、清除格式；插入图片…）"),
          Entry(text: "正文里右键：任务状态（五种）、文字颜色（红橙绿蓝紫灰 / 默认）；点在方框上只弹五种状态"),
          Entry("⌘,", text: "打开 设置 › 便签（打开的便签先收起）"),
          Entry("⌥", text: "按住它拖边上的药丸：换边、换高度"),
        ]),
      // 浮动便签（第 4 批）：面板的按键入口和那叠是同一份（Notes/NotePanel.swift → NoteSheetModel.handleKeyEquivalent），
      // 所以别的键（⌘P ⌘K ⌘. ⌘T ⌘F ⌘Z ⇧⌘A…）和上一组一样，这里只写不一样的几行
      Group(
        title: "便签 · 浮在屏幕上", symbol: NotesWindowModel.floatSymbol(isFloating: false),
        color: Style.Family.notes, features: [.notes],
        entries: [
          Entry("Esc", "⌘W", text: "收回边缘（固定着的也收），接着打字回到原来的 App"),
          Entry("⌘K", text: "操作菜单里的「收回边缘」；别的键同屏幕边缘里打开的便签"),
          Entry("⌘,", text: "打开 设置 › 便签（浮着的便签留在原处）"),
        ]),
      // 全部便签窗口里的键：NotesWindowView.shortcuts（看不见的按钮上挂着），动作在 NotesWindowModel；
      // ⌘⌫ 和 ⇧⌘Z、便签墙上收编辑卡的 ⌘W 是窗口的按键监听认的（NotesWindow.handlesKeyDown）；便签墙上的方向键、
      // ↩ / 空格、Esc 在 NotesWallView（onKeyPress / onExitCommand）；⌘B ⌘I ⇧⌘X ⌘E、粘贴成链接在正文编辑器里
      Group(
        title: "便签 · 全部便签", symbol: "rectangle.split.2x1", color: Style.Family.notes,
        features: [.notes],
        entries: [
          Entry("⌘1", "⌘2", text: "便签墙 / 列表（同工具栏上的切换；下次打开是上次用的那种）"),
          Entry("↑↓", "←→", text: "便签墙上：在卡片之间挑（↑↓ 同一列上下，←→ 旁边那列）"),
          Entry("↩", "空格", text: "便签墙上：把选中的那张放大成编辑卡，接着写"),
          Entry("Esc", "⌘W", text: "便签墙上：收回编辑卡（点旁边变暗的地方也行）；没开着编辑卡时 ⌘W 关窗口"),
          Entry("⌘N", text: "新建便签（便签墙上直接打开它的编辑卡）"),
          Entry("⌘F", text: "搜索便签；光标在正文里时是在这条便签里查找"),
          Entry("⌘T", text: "任务：正文里光标所在的行变成任务，再按一次变回普通行"),
          Entry("⌘⌫", text: "焦点在列表或便签墙上时：删除选中的便签，进「最近删除」（⌫ 也行；在最近删除里是永久删除，要确认）。光标在标题、正文里时是删到行首"),
          Entry("⌘Z", text: "放回刚删的便签（连着删了几条就一条条放回；光标在正文、标题、搜索框里时先撤销那里打的字）"),
          Entry("⇧⌘Z", text: "重做刚撤销的打字"),
          Entry("⌘", text: "按住它点正文里的链接：打开（网址和邮件地址；不按 ⌘ 是放光标）"),
          Entry("⌘B", "⌘I", text: "正文里：粗体、斜体（选区整段一种：不全是就全加上、原来有的并成一段；全都是就去掉、拆开；没选字插一对，光标在中间）"),
          Entry("⇧⌘X", "⌘E", text: "正文里：删除线（同上）、代码（只在没选字时插一对；代码块里不加）"),
          Entry("⌘V", text: "选中一段字时粘贴一个网址：粘成链接，字不变"),
          Entry(
            "⌃↩",
            text: "正文里：弹出右键菜单（任务状态、文字颜色、格式：粗体、斜体、删除线、代码、链接、标题 1–3、引用、无序列表、有序列表、代码块、清除格式；插入图片…）"),
          Entry(text: "正文里右键：任务状态（五种）、文字颜色（红橙绿蓝紫灰 / 默认）；点在方框上只弹五种状态"),
          Entry("⇧⌘A", text: "归档 / 取消归档"),
          Entry("⌘P", text: "固定 / 取消固定"),
          Entry("⌘.", text: "换成下一种纸色"),
          Entry("⌘,", text: "打开 设置 › 便签（同工具栏的「便签设置」）"),
        ]),
      // 启动台（第八族，2026-10-18；mac-launchpad）。全局键默认不设，没设时那一行写「未设置」；
      // 面板里的按键入口在 LaunchpadPanel（⌘← / ⌘→ / ⌘W）和 LaunchpadView 的搜索框（doCommandBy）
      Group(
        title: "启动台", symbol: HotKeyAction.launchpad.symbol,
        color: Style.Family.launchpad, globals: [.launchpad],
        entries: [
          Entry("←→", "↑↓", text: "在图标之间挪选中（鼠标指着不高亮），到页边接着翻页"),
          Entry("↩", text: "打开选中的 App（鼠标单击同样；打开后启动台自己收起）"),
          Entry("⌘←", "⌘→", text: "到第一页 / 最后一页"),
          Entry("两指左右滑", text: "翻页，跟手；鼠标滚轮上下滚也行，点底下的圆点跳页"),
          Entry(text: "一打开就直接打字：搜 App 的中文名、拼音、首字母或英文名，文件夹里的也算"),
          Entry("↩", text: "搜索时：打开第一个（或方向键选中的）"),
          Entry("Esc", text: "先清空搜索，再按一次收起；点空白处也收起"),
          Entry("⌘W", text: "收起"),
        ]),
      // mac-overlay-panel §11 状态屏。全局键不设默认，没设时那一行写「未设置」；它先出选状态的面板（设置里可改成直接
      // 进排在最前面的状态，那一行的名字跟着变，HotKeyAction.rowTitle）。面板里的按键在 StatusPicker.key；
      // 退出判断在 ExitHold（只按着 esc、或左键按在退出提示上满 2 秒）；设了退出密码时按住满了还要输密码（Passcode）
      Group(
        title: "状态屏", symbol: HotKeyAction.statusScreen.symbol, color: Style.Family.statusScreen,
        globals: [.statusScreen],
        entries: [
          Entry("←→", "↑↓", text: "选状态时：换一张（Tab、⇧Tab，或再按一次全局快捷键也行）"),
          Entry("1–9", text: "选状态时：直接进入第 1–9 个状态"),
          Entry("↩", text: "选状态时：进入选中的状态（单击卡片同样）"),
          Entry("Esc", "⌘W", text: "选状态时：不进了，关闭"),
          Entry("Esc", text: "进入之后按住 2 秒：退出"),
          Entry(text: "进入之后用鼠标按住屏幕底部的提示 2 秒：退出（动一下鼠标，提示就出现）"),
          Entry("0–9", text: "设了退出密码时：按住满 2 秒后输入密码（⌫ 删一位，Esc 不输了）"),
        ]),
      // 刘海岛（mac-whisker S2，2026-10-26）：不属于哪个功能，一直列
      Group(
        title: "刘海岛", symbol: HotKeyAction.island.symbol, color: Style.Family.general,
        globals: [.island],
        entries: [
          Entry(text: "点刘海：打开 / 收起最近的提示和快捷动作（指针停在刘海上时岛会鼓起一点）"),
          Entry(text: "鼠标挪到弹出的提示上：停住、展开看全文和按钮；在岛上双指往上滑收起"),
        ]),
      // mac-whisker §6 设置；代码在 SettingsWindow 的 SettingsCommands（主菜单「显示 › 返回」）
      Group(
        title: "设置", symbol: "gearshape.fill", color: Style.Family.general,
        entries: [
          Entry("⌘[", text: "从翻译服务、网页搜索、状态屏的状态的详情页返回列表")
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
              Text(action.rowTitle)
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
    .padding(.vertical, 6)
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
    HStack(spacing: 6) {
      ForEach(keys, id: \.self) { key in
        HStack(spacing: 6) {
          if key != keys.first { Text("/").foregroundStyle(.tertiary) }
          KeyCombo(key)
        }
      }
    }
  }
}
