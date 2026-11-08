// 启动器根视图（Whisker 设计语言，mac-whisker §6 启动器）：56 pt 大搜索框；单行 40 pt 结果（24 pt 图标 / 种类色块，
// 标题 14 medium 后面紧跟灰色副标题，右侧写类型；文件搜索的结果按 Spotlight 类型取图标、右侧写扩展名；网址 / 书签 /
// 历史 / 网页搜索行是网站图标（SiteIcons，没有才用家族色块，体检 D6），系统设置面板是系统设置的 App 图标），
// 空查询时带「收藏」「常用」、文件搜索只输关键词时带「最近打开和下载的文件」分组标题；计算结果是 64 pt 的大数字卡；
// 一块中性高亮在行间滑动（键盘 snap、连发不动画、点选 glide）；没选中的行悬停铺 fill.hover（HoverTracker，体检 B37）；
// 选中的内置动作右侧多一组全局快捷键键帽（N10）；按住修饰键时选中行的副标题换成替代动作，按住 ⌘ 150 ms 后类型依次
// 换成 ⌘1–9 键帽；系统命令上了膛（清倒废纸篓、全部退出、强制退出的第一下）时选中行副标题换成 systemRed 的「再按 ↩ …」。
// 行上右键是和 ⌘K 同一份动作（ActionContextMenu，体检 C8），VoiceOver 另有主动作、⌘↩、复制、收藏、移除几个动作。
// 底栏 36（N8，对标 Raycast）：左边选中项的种类（16 pt 家族色块 + 种类名；收藏、移除常用时换成就地提示，移除带
// 「撤销 ⌘Z」），右边「主动作 ↩」（品牌粉实心键帽）·「操作 ⌘K」，都能点；⌘K 动作菜单（共用 ActionMenu）锚在右下，
// 开着时面板至少高到放得下它。没有图钉、齿轮（⌘, 照样开设置）。有新版本时左边种类后面常驻「更新到 x」（UpdateBarHint）。
// 面板高度随行数伸缩（带动画），顶边不动。空搜索框里一行都没有时（没收藏、没用过，或关了「列出常用」）只剩搜索框（isBare）。
// 状态和操作都在 LauncherModel。⌘Y 快速查看的预览卡（LauncherQuickLookView）也在这里。
// 脚本命令（2026-11-07）：行图标是头部写的 emoji / SF 符号 / 图片，没写是命令家族紫的 terminal 色块，右侧「脚本」；
// 从网上下载的脚本第一次跑之前，列表换成它的全文（ScriptReviewView：等宽字、能滚，上面一句写明以用户的身份运行、
// 能用本 App 已有的授权），底栏「运行 ↩」「返回 Esc」；全文输出的脚本跑起来后列表换成输出那一页（同一个 ScriptPageView），
// 底栏「粘贴 ↩」「复制 ⌘C」「重跑 ⌘R」「返回 Esc」（还在跑时只有「停止 Esc」；第三轮：边跑边显示、认终端颜色）。列表脚本的结果行同脚本的图标、右侧「脚本」；
// 第三轮：结果写了 url / path 的右侧「网址」「文件」，自己写了图标的用它，文件没写图标的用它在访达里的图标。

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LauncherPanelView: View {
  @Bindable var model: LauncherModel
  /// 拖下边定的最多几行（W2，0 = 默认）
  @AppStorage(Prefs.launcherPanelRows) private var rows = 0.0
  @AppStorage(Prefs.launcherRomanInput) private var romanInput = false
  /// 有新版本时底栏常驻「更新到 x」：只剩搜索框的时候也留着底栏
  @Environment(Updater.self) private var updater: Updater?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// 按住 ⌘ 超过 150 ms：类型标签换成键帽
  @State private var showsShortcuts = false
  /// 列表的滚动位置：选中跟随滚动按前缀和算目标 y（RevealsSelection），不按行 id 滚
  @State private var position = ScrollPosition()

  static let searchHeight: CGFloat = 56
  static let rowHeight: CGFloat = 40
  static let calcHeight: CGFloat = 64
  static let groupHeight: CGFloat = 28
  static let barHeight: CGFloat = 36
  /// 列表四周内缩（面板圆角 16 − 6 = 高亮的圆角 10，同心）
  static let inset: CGFloat = 6
  /// 多出半行，让人看得出下面还能滚（动作菜单同样）
  static let visibleRows = 8.5
  /// 拖下边能定的行数（W2）：按半行吸附，露半行提示下面还有
  static let rowRange = 6.5...14.5
  /// 看脚本全文那一页的高度（不含搜索栏和底栏）
  static let reviewHeight: CGFloat = 320

  var body: some View {
    VStack(spacing: 0) {
      searchBar.frame(height: Self.searchHeight)
      if !bare { Hairline() }
      if let error = model.error {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.system(size: 12))
          .foregroundStyle(Color(nsColor: .systemRed))
          .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
          .padding(.horizontal, 16)
      }
      if let review = model.review {
        ScriptPageView(
          title: review.script.title,
          subtitle: (review.script.path as NSString).abbreviatingWithTildeInPath,
          note: "这个脚本是从网上下载的，第一次运行前先看一眼。它会以你的身份运行，能用 Kitty Tools 已有的辅助功能、屏幕录制、完全磁盘访问授权。",
          noteColor: Color(nsColor: .systemOrange), text: review.text, placeholder: "正在读取…",
          warning: review.reading?.problem.map { $0 + "不能在这里运行，用编辑器打开看完再说。" },
          label: "脚本全文", scroll: model.pageScroll
        )
        .frame(height: Self.reviewHeight)
      } else if let output = model.output {
        ScriptPageView(
          title: output.script.title,
          subtitle: output.isRunning ? "正在运行…" : output.failure == nil ? "运行完了" : "没有跑成",
          since: output.isRunning ? output.startedAt : nil,
          note: output.failure, noteColor: Color(nsColor: .systemRed),
          text: nil, styled: output.styled.characters.isEmpty ? nil : output.styled,
          placeholder: output.isRunning ? "正在运行…" : "（没有输出）",
          warning: output.isCut
            ? "只显示了前 \(LauncherModel.outputDisplayLimit / 10_000) 万字；粘贴、复制的是全部。" : nil,
          label: "脚本输出", scroll: model.pageScroll, follows: true
        )
        .frame(height: Self.reviewHeight)
      } else if showsNoResults {
        Text(model.emptyText)
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: Self.rowHeight + 12)
      } else if !model.results.isEmpty {
        list
      }
      Spacer(minLength: 0)
      if !bare { bar }
    }
    .overlay(alignment: .bottomTrailing) { actionMenu }
    .onChange(of: Self.height(for: model, rows: rows, update: hasUpdate), initial: true) {
      _, height in
      model.resize(height)
    }
    .onModifierKeysChanged(mask: [.command, .option, .control]) { _, keys in
      model.alternate =
        keys.contains(.command)
        ? .command : keys.contains(.option) ? .option : keys.contains(.control) ? .control : .none
    }
    .task(id: model.alternate == .command) {
      guard model.alternate == .command else {
        showsShortcuts = false
        return
      }
      try? await Task.sleep(for: .milliseconds(150))
      if !Task.isCancelled { showsShortcuts = true }
    }
  }

  private var showsNoResults: Bool { !model.isShowingRecent && model.results.isEmpty }
  private var hasUpdate: Bool { updater?.available != nil }
  private var bare: Bool { Self.isBare(model, update: hasUpdate) }

  /// 只剩搜索框（issue #2）：空搜索框里一行都没有，底栏这时没有能「运行 / 操作」的东西，连同上面的发丝线收掉。
  /// 有错误、底栏的就地提示、动作菜单、更新提示（update）时照旧
  static func isBare(_ model: LauncherModel, update: Bool) -> Bool {
    model.isShowingRecent && model.results.isEmpty && model.error == nil && model.notice == nil
      && !model.showsActions && !update && model.review == nil && model.output == nil
  }

  /// 行高：高亮的位置和面板高度都按它的前缀和算
  private func rowHeight(_ item: LauncherItem) -> CGFloat { Self.rowHeight(item) }

  static func rowHeight(_ item: LauncherItem) -> CGFloat {
    item.kind == .calculation ? calcHeight : rowHeight
  }

  /// 第 row 行的顶在列表里的位置：它和它前面的分组标题 + 前面各行的高
  static func offset(ofRow row: Int, in model: LauncherModel) -> CGFloat {
    CGFloat(model.groups.filter { $0.row <= row }.count) * groupHeight
      + model.results.prefix(row).map(rowHeight).reduce(0, +)
  }

  /// 选中跟随滚动要露出来的区间（滚动内容坐标，含四周内缩）：第 row 行；它是一组的第一行时连分组标题一起
  static func span(ofRow row: Int, in model: LauncherModel) -> ClosedRange<CGFloat>? {
    guard model.results.indices.contains(row) else { return nil }
    let top = inset + offset(ofRow: row, in: model)
    let header = model.groups.contains { $0.row == row } ? groupHeight : 0
    return top - header...top + rowHeight(model.results[row])
  }

  /// 面板高度 = 搜索栏 + 发丝线 +（错误）+ 列表（分组标题各 28 + 最多 8.5 行）+ 底栏；⌘K 菜单开着时至少放得下它；
  /// 只剩搜索框（isBare）时就是搜索栏那么高
  /// rows：设置里拖出来的最多几行（0 = 默认 8.5）
  /// 拖下边时面板能多高（W2）：列表 6.5 到 14.5 行
  static func heightRange(for model: LauncherModel) -> ClosedRange<CGFloat> {
    let chrome = listChrome(for: model)
    return chrome + rowRange.lowerBound * rowHeight...chrome + rowRange.upperBound * rowHeight
  }

  /// 拖到这么高对应最多几行：按半行吸附，夹在 rowRange 里（纯函数，配单测）
  static func rows(forHeight height: CGFloat, model: LauncherModel) -> Double {
    let rows = Double((height - listChrome(for: model)) / rowHeight)
    return min(max((rows - 0.5).rounded() + 0.5, rowRange.lowerBound), rowRange.upperBound)
  }

  /// 面板里除了行以外的高度：搜索栏、发丝线、错误、列表上下内缩、分组标题、底栏
  private static func listChrome(for model: LauncherModel) -> CGFloat {
    searchHeight + 0.5 + barHeight + (model.error != nil ? 28 : 0) + inset * 2
      + CGFloat(model.groups.count) * groupHeight
  }

  static func height(for model: LauncherModel, rows limit: Double = 0, update: Bool = false)
    -> CGFloat
  {
    if isBare(model, update: update) { return searchHeight }
    if model.review != nil || model.output != nil {
      return searchHeight + 0.5 + reviewHeight + barHeight
    }
    var height = searchHeight + 0.5 + barHeight
    if model.error != nil { height += 28 }
    if !model.isShowingRecent && model.results.isEmpty {
      height += rowHeight + 12
    } else if !model.results.isEmpty {
      let heights = model.results.map(rowHeight)
      let full = Int(limit > 0 ? limit : visibleRows)
      var rows = heights.prefix(full).reduce(0, +)
      if heights.count > full { rows += heights[full] / 2 }
      height += inset * 2 + CGFloat(model.groups.count) * groupHeight + rows
    }
    // 菜单画在面板里、锚在底栏上方 4 pt，离搜索栏至少 8 pt；按没过滤的动作算，边打字过滤面板不跳。
    // 菜单高 = 行和分节线（最多 8.5 行高）+ 上下内缩各 5
    if model.showsActions {
      let menu = ActionMenu.height(model.actions, maxRows: visibleRows) + 10
      height = max(height, searchHeight + 0.5 + 8 + menu + 4 + barHeight)
    }
    return height
  }

  /// 线头（符号定宽）和左右内边距在 SearchLine 里，和剪贴板的搜索线是同一个
  private var searchBar: some View {
    SearchLine(symbol: model.showsActions ? "command" : "magnifyingglass") {
      // ⌘K 菜单开着时，搜索框改成过滤动作
      CommandTextField(
        text: model.showsActions ? $model.actionQuery : $model.query,
        placeholder: model.showsActions ? "搜索操作" : "搜索 App、网址、命令或文件", fontSize: 20,
        romanOnly: romanInput, onCommand: model.handleCommand)
    }
  }

  private var list: some View {
    ScrollView {
      LazyVStack(spacing: 0) {
        let groups = model.groups
        ForEach(Array(model.results.enumerated()), id: \.element.rowID) { index, item in
          if let group = groups.first(where: { $0.row == index }) {
            groupHeader(group)
          }
          Button {
            model.click(item)
          } label: {
            let isSelected = index == model.selection
            LauncherRow(
              item: item, index: index, showsShortcut: showsShortcuts && index < 9,
              isSelected: isSelected, isArmed: model.isArmed(item),
              alternate: isSelected ? model.alternateSubtitle(for: item) : nil,
              hotKey: isSelected ? item.hotKeyAction.flatMap(model.boundHotKey)?.display : nil
            )
            .frame(height: rowHeight(item))
            .contentShape(.rect)
          }
          .buttonStyle(.plain)
          // 右键和 ⌘K 同一份动作（体检 C8）；包成视图：菜单打开时才算，不在每次画行时建一遍
          .contextMenu { ActionContextMenu { model.actions(for: item) } }
          .accessibilityActions { accessibilityActions(for: item) }
        }
      }
      .background(alignment: .topLeading) { highlight }
      .padding(Self.inset)
    }
    .scrollIndicators(.automatic)
    // 选中跟随滚动（共用 ListReveal，第 10 批）：选中换了、或结果换了都重新露出选中行。新结果时选中回到第 0 行，
    // 露出第 0 行（连分组标题）就是回到顶部；文件结果后续批次保留了用户选的那行时露出那行。上下都留一格内缩
    .modifier(
      RevealsSelection(
        position: $position, key: RevealKey(selection: model.selection, results: model.results),
        motion: model.selectionMotion, coveredTop: Self.inset, inset: Self.inset
      ) { Self.span(ofRow: model.selection, in: model) }
    )
  }

  /// 分组标题：高度必须正好是 groupHeight（高亮和面板高度都按它算）。缩进 10 = 行内边距（和行图标同一条左边线），
  /// 贴底留 2；翻译历史的分组标题同样的摆法（HistoryView.header）
  private func groupHeader(_ group: LauncherModel.Group) -> some View {
    Text(group.title)
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(.tertiary)
      .padding(.leading, 10)
      .padding(.bottom, 2)
      .frame(
        maxWidth: .infinity, minHeight: Self.groupHeight, maxHeight: Self.groupHeight,
        alignment: .bottomLeading
      )
      .accessibilityAddTraits(.isHeader)
  }

  /// VoiceOver 的动作（体检 B37）：按一下行只是选中，这里给直接执行的；和 ⌘K 调的是同一批方法
  @ViewBuilder private func accessibilityActions(for item: LauncherItem) -> some View {
    Button(model.primaryAction(for: item).title) { model.execute(item) }
    if let secondary = model.commandReturnAction(for: item) {
      Button(secondary.title) { model.commandReturn(item) }
    }
    if let copy = model.copyTitle(for: item) {
      Button(copy) { model.copy(item) }
    }
    if model.canFavorite(item) {
      Button(model.isFavorite(item) ? "取消收藏" : "加入收藏") { model.toggleFavorite(item) }
    }
    if model.isCommon(item) {
      Button("从常用中移除") { model.forget(item) }
    }
  }

  /// 一块中性高亮，按前缀和定位，在行间滑动（不用 matchedGeometryEffect：LazyVStack 回收行时会跳）
  @ViewBuilder private var highlight: some View {
    if let selected = model.selectedItem {
      let offset = Self.offset(ofRow: model.selection, in: model)
      let height = rowHeight(selected)
      let shape = RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
      shape
        .fill(Style.selectedFill)
        .overlay { shape.contrastSelectionBorder() }
        .frame(height: height)
        .offset(y: offset)
        .animation(model.selectionMotion.animation(reduced: reduceMotion), value: model.selection)
        .animation(nil, value: model.results)
      // ⌘Y 预览从选中行长出来：按同样的前缀和报它在窗口里的位置，只报列表可见区里的部分（滚出去的不当起点）；
      // 按选中项换一个新视图，一出现就报终点位置（同剪贴板的透镜）
      Color.clear
        .frame(height: height)
        .onGeometryChange(for: CGRect.self) { proxy in
          let global = proxy.frame(in: .global)
          let visible = CGRect(origin: .zero, size: proxy.size)
            .intersection(proxy.bounds(of: .scrollView) ?? .infinite)
          return visible.isEmpty ? .null : visible.offsetBy(dx: global.minX, dy: global.minY)
        } action: { rect in
          model.rowFrame = rect.isNull ? nil : (selected.id, rect)
        }
        .offset(y: offset)
        .onDisappear { if model.rowFrame?.id == selected.id { model.rowFrame = nil } }
        .id(selected.id)
    }
  }

  /// ⌘K 动作菜单：从右下角放大出来（转场在 ActionMenu 里），锚在底栏「操作 ⌘K」的上方、右缘对着 ⌘K 键帽
  /// （= 底栏的右内边距 16）。空结果用 ActionMenu 默认的「没有匹配的操作」。
  /// 要撑高面板时是瞬间长高（AppDelegate 的 resize 在菜单开着时不动画），菜单一出来就在最终位置
  private var actionMenu: some View {
    ZStack(alignment: .bottomTrailing) {
      if model.showsActions {
        ActionMenu(
          items: model.filteredActions, selection: model.actionSelection,
          maxRows: Self.visibleRows, onHover: { model.actionSelection = $0 }, onRun: model.run
        )
        .padding(.trailing, 16)
        .padding(.bottom, Self.barHeight + 4)
      }
    }
    .animation(
      Style.Motion.snap.animation(reduced: reduceMotion) ?? .easeOut(duration: Style.fadeIn),
      value: model.showsActions)
  }

  /// 底栏（N8）：左边选中项的种类（有就地提示时换成提示），右边主动作 ↩ 和「操作 ⌘K」，都能点（字用 primary；种类名是
  /// 状态，secondary：mac-whisker §3「面板里共用的几件」），两个按钮之间不画竖线（同剪贴板）。没有选中项时空着
  /// （有新版本时只剩「更新到 x」）
  private var bar: some View {
    HStack(spacing: 12) {
      if model.review != nil {
        reviewBar
      } else if let output = model.output {
        outputBar(output)
      } else {
        resultBar
      }
    }
    .animation(Style.Motion.settle.animation(reduced: reduceMotion), value: model.notice)
    .font(.system(size: 12))
    .lineLimit(1)
    .buttonStyle(.plain)
    // 左右 16 = 列表四周内缩 6 + 行内边距 10：和行图标、行右缘共用左右边线
    .padding(.horizontal, 16)
    .frame(height: Self.barHeight)
    .overlay(alignment: .top) { Hairline() }
  }

  /// 看脚本全文时的底栏：左边写这是什么，右边「运行 ↩」「返回 Esc」
  @ViewBuilder private var reviewBar: some View {
    HStack(spacing: 8) {
      KindTile(
        symbol: "exclamationmark.shield.fill", color: Color(nsColor: .systemOrange), size: 16)
      Text("从网上下载的脚本").foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
    Spacer(minLength: 8)
    // 读到之前、看不全、藏着字符时按了也不跑：画成不能点的（mac-whisker §3「状态」）
    let runnable = model.review.map { $0.isRunnable && $0.isSettled } == true
    Button(action: model.approveReview) {
      HStack(spacing: 6) {
        Text("运行")
        KeyCap("↩", primary: runnable).accessibilityHidden(true)
      }
    }
    .disabled(!runnable)
    .opacity(runnable ? 1 : Style.disabledOpacity)
    .accessibilityLabel("运行")
    Button(action: model.cancelReview) {
      HStack(spacing: 6) {
        Text("返回")
        KeyCap("Esc")
      }
    }
    .accessibilityLabel("返回")
  }

  /// 全文输出那一页的底栏：跑完是「粘贴 ↩」「复制 ⌘C」「返回 Esc」，还在跑时只有「停止 Esc」
  @ViewBuilder private func outputBar(_ output: LauncherModel.ScriptOutput) -> some View {
    HStack(spacing: 8) {
      KindTile(symbol: "terminal.fill", color: Style.Family.command, size: 16)
      Text("脚本输出").foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
    Spacer(minLength: 8)
    if output.isRunning {
      Button(action: model.closeOutput) {
        HStack(spacing: 6) {
          Text("停止")
          KeyCap("Esc")
        }
      }
      .accessibilityLabel("停止")
    } else {
      if !output.text.isEmpty {
        Button(action: model.pasteOutput) {
          HStack(spacing: 6) {
            Text("粘贴")
            KeyCap("↩", primary: true).accessibilityHidden(true)
          }
        }
        .accessibilityLabel("粘贴")
        Button(action: model.copyOutput) {
          HStack(spacing: 6) {
            Text("复制")
            KeyCap("⌘C")
          }
        }
        .accessibilityLabel("复制")
      }
      if model.canRerunOutput {
        Button(action: model.rerunOutput) {
          HStack(spacing: 6) {
            Text("重跑")
            KeyCap("⌘R")
          }
        }
        .accessibilityLabel("重跑")
      }
      Button(action: model.closeOutput) {
        HStack(spacing: 6) {
          Text("返回")
          KeyCap("Esc")
        }
      }
      .accessibilityLabel("返回")
    }
  }

  @ViewBuilder private var resultBar: some View {
    if let notice = model.notice {
      BarNoticeView(notice: notice, undo: model.undoForget)
        .transition(reduceMotion ? .opacity : AnyTransition(.blurReplace))
        .id(notice)
    }
    if let selected = model.selectedItem, model.notice == nil {
      HStack(spacing: 8) {
        KindTile(symbol: selected.familySymbol, color: selected.familyColor, size: 16)
        Text(selected.kindTitle).foregroundStyle(.secondary)
      }
      .accessibilityElement(children: .combine)
      .transition(reduceMotion ? .opacity : AnyTransition(.blurReplace))
    }
    // 有新版本：种类后面常驻「更新到 x」（没有选中项时也在）；就地提示出来时让开
    if model.notice == nil { UpdateBarHint { model.hidePanel() } }
    Spacer(minLength: 8)
    if let selected = model.selectedItem {
      let primary = model.primaryAction(for: selected).title
      // 等着再按一次确认、强制退出：字和 ↩ 键帽换危险色（mac-whisker §3「危险色」）
      let danger = model.isDangerous(selected, commandKey: false)
      // 参数没填够：↩ 只响提示音，不画成该按的主按钮（只提示键位，同 secondary 的那种）
      let inert = model.isMissingArguments(selected)
      Button {
        model.execute(selected)
      } label: {
        HStack(spacing: 6) {
          Text(primary)
            .foregroundStyle(
              danger
                ? AnyShapeStyle(Style.danger)
                : inert ? AnyShapeStyle(.secondary) : AnyShapeStyle(.foreground))
          KeyCap("↩", primary: !inert, danger: danger).accessibilityHidden(true)
        }
      }
      .accessibilityLabel(primary)
      Button(action: model.toggleActions) {
        HStack(spacing: 6) {
          Text("操作")
          KeyCap("⌘K")
        }
      }
      .accessibilityLabel("操作")
    }
  }
}

/// 脚本的一整页（启动器里原地换掉列表）：从网上下载的脚本第一次跑之前的全文（拍板 B5），全文输出的脚本的输出（B1）。
/// 标题和一行小字、可选的一句提示（橙色 / 红字）、等宽字的正文（能滚、能选，↑↓ / PageUp / PageDown 跟着模型的
/// pageScroll 滚：焦点一直在搜索框里）；正文没有时写 placeholder。输出边跑边长时（follows）正文跟着最后一行走，
/// 往上翻了就不跟、翻回底部再跟（第三轮 A1）
private struct ScriptPageView: View {
  let title: String
  let subtitle: String
  /// 跑着的：小字后面接「已 12 秒」
  var since: Date?
  let note: String?
  let noteColor: Color
  let text: String?
  /// 认了颜色的正文（输出那一页，ScriptTerminal）；有它就不用 text
  var styled: AttributedString?
  let placeholder: String
  /// 正文上面一句橙色的（没显示全、藏着字符、输出只显示了一部分）
  var warning: String?
  /// 正文的读屏名
  let label: String
  let scroll: LauncherModel.PageScroll
  /// 正文变长时，原来在底部就跟到新的底部
  var follows = false
  @State private var position = ScrollPosition(edge: .top)
  @State private var geometry: ScrollGeometry?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.system(size: 14, weight: .medium)).lineLimit(1)
        Group {
          if let since {
            // 一秒换一次的普通文字（不做数字滚动的过渡，开销很小）
            TimelineView(.periodic(from: since, by: 1)) { context in
              Text(subtitle + " " + Self.elapsed(context.date.timeIntervalSince(since)))
            }
          } else {
            Text(subtitle)
          }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
      }
      if let note {
        Text(note)
          .font(.system(size: 12))
          .foregroundStyle(noteColor)
          .fixedSize(horizontal: false, vertical: true)
      }
      // 限制（没看全、藏着字符）不是错误、也不是危险操作：同设置页的提醒用橙色（mac-whisker §3）
      if let warning {
        Text(warning)
          .font(.system(size: 12))
          .foregroundStyle(Color(nsColor: .systemOrange))
          .fixedSize(horizontal: false, vertical: true)
      }
      ScrollView {
        Group {
          if let styled { Text(styled) } else { Text(text ?? placeholder) }
        }
        .font(.system(size: 12, design: .monospaced))
        .lineSpacing(2)
        .foregroundStyle(text == nil && styled == nil ? .secondary : .primary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(10)
      }
      .scrollPosition($position)
      .onScrollGeometryChange(for: ScrollGeometry.self) {
        $0
      } action: { old, new in
        geometry = new
        // 正文长了、之前停在底部（差 4 pt 以内）：跟到新的底部
        if follows, new.contentSize.height > old.contentSize.height,
          old.contentOffset.y >= old.contentSize.height - old.containerSize.height - 4
        {
          position.scrollTo(edge: .bottom)
        }
      }
      .onChange(of: scroll) { _, scroll in move(scroll.step) }
      .background(Style.hoverFill, in: .rect(cornerRadius: Style.Radius.card, style: .continuous))
      .accessibilityLabel(text == nil && styled == nil ? placeholder : label)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  /// 「已 12 秒」「已 2 分 5 秒」
  static func elapsed(_ interval: TimeInterval) -> String {
    let seconds = max(Int(interval), 0)
    return seconds < 60 ? "已 \(seconds) 秒" : "已 \(seconds / 60) 分 \(seconds % 60) 秒"
  }

  /// ±1 一小段（三行），±2 一屏（留一行接上）
  private func move(_ step: Int) {
    guard let geometry, step != 0 else { return }
    let page = max(geometry.containerSize.height - 24, 48)
    let delta = (abs(step) == 1 ? 48 : page) * (step < 0 ? -1 : 1)
    let bottom = max(geometry.contentSize.height - geometry.containerSize.height, 0)
    let target = min(max(geometry.contentOffset.y + delta, 0), bottom)
    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { position.scrollTo(y: target) }
  }
}

/// ⌘Y 快速查看（体检 C7）：选中文件的 Quick Look 预览（和剪贴板 ⌘Y 大卡同一个单文件视图 QuickLookFile），
/// 浮层从选中行长出来、⌘Y / Esc 缩回；跟着启动器里的选中项换文件，选中的不是文件时写一句话
struct LauncherQuickLookView: View {
  let model: LauncherModel

  var body: some View {
    if model.showsQuickLookContent, let url = model.quickLookURL {
      QuickLookFile(url: url)
        .clipShape(.rect(cornerRadius: Style.Radius.card, style: .continuous))
        .padding(6)
    } else if model.showsQuickLookContent {
      Text("没有可预览的文件")
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

private struct LauncherRow: View {
  let item: LauncherItem
  let index: Int
  let showsShortcut: Bool
  let isSelected: Bool
  /// 不可撤销的系统命令等着再按一次：副标题（确认提示）用危险色（Style.danger，和 macOS 的破坏性按钮同色）
  let isArmed: Bool
  /// 按住修饰键时的替代动作说明（只有选中行有）：换掉副标题，计算结果换掉算式
  let alternate: String?
  /// 选中的内置动作当前的全局快捷键（N10，没设就是 nil）
  let hotKey: String?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// 悬停（没选中的行铺 fill.hover，0.10 s 淡入；浮层不激活本 App，SwiftUI 的 onHover 不可靠，用 HoverTracker）
  @State private var hovered = false

  var body: some View {
    HStack(spacing: 10) {
      icon
      if item.kind == .calculation {
        if let alternate {
          Text(alternate).font(.system(size: 13)).lineLimit(1)
        } else {
          Text(item.target)
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Image(systemName: "arrow.right")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.tertiary)
        // 大字按千分位分组、单位换算带单位（体检 D11）；粘贴的是不分组的 payload
        Text(item.title)
          .font(.system(size: 28, weight: .semibold, design: .rounded))
          .monospacedDigit()
          .contentTransition(.numericText())
          .lineLimit(1)
          .minimumScaleFactor(0.5)
          .animation(Style.Motion.snap.animation(reduced: reduceMotion), value: item.title)
      } else {
        // port 的标题是端口号、ip 的是地址：等宽数字，后面的副标题才成一列
        (item.isPort || item.kind == .ip ? Text(item.title).monospacedDigit() : Text(item.title))
          .font(.system(size: 14, weight: .medium))
          .lineLimit(1)
          .layoutPriority(1)
        if let subtitle = alternate ?? (item.subtitle.isEmpty ? nil : item.subtitle) {
          Text(subtitle)
            .font(.system(size: 13))
            .foregroundStyle(
              isArmed
                ? AnyShapeStyle(Style.danger)
                : alternate == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)
            )
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      Spacer(minLength: 8)
      if let hotKey, !showsShortcut {
        KeyCombo(hotKey).accessibilityLabel("快捷键 \(hotKey)")
      }
      kind
    }
    .padding(.horizontal, 10)
    .frame(maxHeight: .infinity)
    .background(
      hovered && !isSelected ? Style.hoverFill : .clear,
      in: .rect(cornerRadius: Style.Radius.card, style: .continuous)
    )
    .background {
      HoverTracker { inside in withAnimation(.easeOut(duration: 0.10)) { hovered = inside } }
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  @ViewBuilder private var icon: some View {
    if let emoji = item.presetEmoji {
      // 状态屏的状态、提醒：它的表情（静止画面）；没选的是家族色块
      StatusPresetIcon(symbol: emoji)
    } else if item.contentType?.conforms(to: .volume) == true {
      // 宗卷（eject 列出来的）：磁盘色块，不读宗卷本身取图标（按类型取是个文件夹，读宗卷可能要授权）
      KindTile(symbol: item.tileSymbol, color: item.familyColor)
    } else if let type = item.contentType {
      Image(nsImage: LauncherIcons.icon(for: type)).resizable().frame(width: 24, height: 24)
    } else if item.kind == .app || item.kind == .path,
      let image = LauncherIcons.icon(for: item.target)
    {
      Image(nsImage: image).resizable().frame(width: 24, height: 24)
    } else if let path = item.process?.app?.path, let image = LauncherIcons.icon(for: path) {
      // port 列的程序坞 App：它自己的图标（列的时候已经从 NSRunningApplication 放进缓存，不读 App 包）
      Image(nsImage: image).resizable().frame(width: 24, height: 24)
    } else if item.isSettingsPane,
      let image = LauncherIcons.icon(for: AppCatalog.systemSettingsPath)
    {
      Image(nsImage: image).resizable().frame(width: 24, height: 24)
    } else if let icon = item.scriptIcon {
      ScriptIconView(
        icon: icon, fallback: KindTile(symbol: item.tileSymbol, color: item.familyColor))
    } else if item.kind == .url || item.kind == .search, let host = SiteIcons.host(of: item.target)
    {
      SiteIcon(host: host, fallback: KindTile(symbol: item.tileSymbol, color: item.familyColor))
    } else {
      KindTile(symbol: item.tileSymbol, color: item.familyColor)
    }
  }

  /// 右侧：类型标签；按住 ⌘ 时依次换成 ⌘1–9 键帽（每行错开 15 ms）
  private var kind: some View {
    ZStack(alignment: .trailing) {
      Text(item.kindTitle)
        .font(.system(size: 12))
        .foregroundStyle(.tertiary)
        .opacity(showsShortcut ? 0 : 1)
      KeyCap("⌘\(index + 1)")
        .opacity(showsShortcut ? 1 : 0)
        .scaleEffect(showsShortcut ? 1 : 0.9)
    }
    .animation(
      reduceMotion
        ? .easeOut(duration: 0.12) : .easeOut(duration: 0.12).delay(Double(index) * 0.015),
      value: showsShortcut)
  }
}

extension LauncherItem {
  /// 系统设置的一个面板（体检 D9）：kind 是 .url，右侧写「设置」、图标是系统设置的
  fileprivate var isSettingsPane: Bool { kind == .url && AppCatalog.isSettingsPane(target) }

  /// port 列的端口行（目标是「PID:端口」；kill 的进程行目标只有 PID）
  fileprivate var isPort: Bool { kind == .process && target.contains(":") }

  /// 行里种类色块的符号：内置动作用它自己的
  fileprivate var tileSymbol: String {
    switch kind {
    case .reminder: SettingsPage.reminders.symbol
    case .prompt where target.hasPrefix("reminder-"): SettingsPage.reminders.symbol
    case .calculation: "equal"
    case .path where contentType?.conforms(to: .volume) == true: "externaldrive.fill"
    case .prompt where target == FileSearch.accessTarget: "lock.open.fill"
    case .prompt where target.hasPrefix("file-"): "doc.text.magnifyingglass"
    case .prompt where target.hasPrefix("system-"):
      SystemCommands.Verb(rawValue: String(target.dropFirst("system-".count)))?.symbol ?? "power"
    case .prompt where target == "translate-fy": SettingsPage.translate.symbol
    case .prompt where target == ExchangeRates.promptTarget: "equal"
    case .prompt where target.hasPrefix(ExchangeRates.suggestionPrefix): "banknote"
    case .search, .prompt: "magnifyingglass"
    default: symbol
    }
  }

  /// 底栏左边 16 pt 小色块的符号：只看种类，不看具体哪一项
  fileprivate var familySymbol: String {
    switch kind {
    case .app: "square.grid.2x2.fill"
    case .path where contentType?.conforms(to: .volume) == true: "externaldrive.fill"
    case .path: contentType?.conforms(to: .folder) == true ? "folder.fill" : "doc.fill"
    case .action: isStatusPreset ? HotKeyAction.statusScreen.symbol : "command"
    case .system: "power"
    case .translate: SettingsPage.translate.symbol
    case .url where isSettingsPane: "gearshape.fill"
    default: tileSymbol
    }
  }

  /// 功能家族色（mac-whisker §3）：行里的种类色块、底栏左边的小色块
  fileprivate var familyColor: Color {
    switch kind {
    // 内置动作按菜单栏的家族色（体检 A26）：对得上全局热键的用它的，其余用 MenuExtra 的（跟着菜单里所在那一节）
    case .action where isStatusPreset: Style.Family.statusScreen
    case .action where target.hasPrefix("scripts-"): Style.Family.command
    case .action:
      hotKeyAction?.color ?? MenuExtra(rawValue: target)?.color ?? Style.Family.general
    case .translate: Style.Family.translate
    case .prompt where target == "translate-fy": Style.Family.translate
    case .prompt where target == ExchangeRates.promptTarget: Style.Family.keyboard
    case .prompt where target.hasPrefix(ExchangeRates.suggestionPrefix): Style.Family.keyboard
    case .reminder: Style.Family.reminders
    case .prompt where target.hasPrefix("reminder-"): Style.Family.reminders
    case .system, .process, .ip, .script, .scriptResult: Style.Family.command
    case .prompt where target.hasPrefix("system-"): Style.Family.command
    case .url where isSettingsPane: Style.Family.general
    case .url: Style.Family.url
    // 配置 / 授权问题用橙色（Whisker §3 语义色）
    case .prompt where target == FileSearch.accessTarget: Color(nsColor: .systemOrange)
    case .prompt where target.hasPrefix("file-"): Style.Family.general
    case .search, .prompt: Style.Family.search
    case .calculation: Style.Family.keyboard
    case .clip: Style.Family.clipboard
    case .app, .path: Style.Family.general
    }
  }

  /// 行右侧的类型、底栏左边的种类名
  fileprivate var kindTitle: String {
    switch kind {
    case .app: "应用"
    case .path where contentType?.conforms(to: .volume) == true: "宗卷"
    case .path:
      contentType.map { FileSearch.kindTitle(path: target, contentType: $0.identifier) } ?? "文件"
    case .action: isStatusPreset ? HotKeyAction.statusScreen.title : "命令"
    case .system: "系统"
    case .prompt where target.hasPrefix("system-"): "系统"
    case .translate: "翻译"
    case .prompt where target == "translate-fy": "翻译"
    case .url where isSettingsPane: "设置"
    case .url: "网址"
    case .prompt where target == FileSearch.accessTarget: "授权"
    case .prompt where target == ExchangeRates.promptTarget: "汇率"
    case .prompt where target.hasPrefix(ExchangeRates.suggestionPrefix): "货币"
    case .prompt where target.hasPrefix("reminder-"): "提醒"
    case .prompt where target.hasPrefix(LauncherModel.choicePrefix): "选项"
    case .search, .prompt: "搜索"
    // 计算卡不显示副标题：汇率换算的副标题（「人民币 · 11-03 汇率」，ExchangeRates）写在这里，别的是空的
    case .calculation: subtitle.isEmpty ? "计算" : subtitle
    case .clip: "剪贴板"
    case .process: "进程"
    case .ip: "网络"
    case .reminder: "提醒"
    // 列表结果写了 url / path 的：同网址行、文件行（↩ 打开写在底栏的主动作上，第三轮 B1）
    case .scriptResult:
      switch opens {
      case .url: "网址"
      case .file: "文件"
      case nil: "脚本"
      }
    case .script: "脚本"
    }
  }
}

/// App / 文件图标（按路径缓存，面板每次重绘不重复读）
enum LauncherIcons {
  /// 不是 private：内存探针（MemoryProbeTests）要清空它，量清掉后回落多少
  static let cache = NSCache<NSString, NSImage>()

  /// 文件搜索的结果按类型取：不碰文件本身（桌面 / 文稿 / 下载里的文件读图标可能弹授权框）
  static func icon(for type: UTType) -> NSImage {
    let key = "type:" + type.identifier as NSString
    if let cached = cache.object(forKey: key) { return cached }
    let image = NSWorkspace.shared.icon(for: type)
    cache.setObject(image, forKey: key)
    return image
  }

  /// 已经拿到的图标（正在运行的 App 从 NSRunningApplication 取）：放进缓存，行里就不按路径读文件
  static func remember(_ image: NSImage, for path: String) {
    cache.setObject(image, forKey: path as NSString)
  }

  /// 重扫 App 目录时清掉 App 路径的项：升级换了图标的、卸掉的不再一直显示旧的（第三轮体检 B3）
  static func forget(_ paths: [String]) {
    for path in paths { cache.removeObject(forKey: path as NSString) }
  }

  static func icon(for path: String) -> NSImage? {
    if let cached = cache.object(forKey: path as NSString) { return cached }
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    let image = NSWorkspace.shared.icon(forFile: path)
    cache.setObject(image, forKey: path as NSString)
    return image
  }
}

/// 选中跟随滚动的触发值：选中的行号或结果列表变了
private struct RevealKey: Equatable {
  let selection: Int
  let results: [LauncherItem]
}

extension LauncherItem {
  /// 列表里的身份：计算结果行跨按键保持同一个（id 含算式，每敲一个字都会变），结果数字才能滚动变化
  fileprivate var rowID: String { kind == .calculation ? "calculation" : id }
}
