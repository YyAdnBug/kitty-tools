// 翻译浮窗根视图（Whisker，mac-whisker §6 翻译）：三层、没有分割线（内边距 12、层间距 10）——
// 顶栏（N6，对标 Bob）：两个 28 pt 语言胶囊（显示实际语言，自动时带「自动」标签）+ 圆形互换钮（转半圈，两个胶囊
// 按 glide 交换位置，体检 B26），右边只有复制即译开着时的品牌粉状态胶囊（点一下关掉）、图钉、「⋯」菜单
// （翻译历史 ⌘Y、条数、清空与导出、复制即译、设置 ⌘,）；
// 原文卡片（15 pt，↩ 就是翻译，⇧↩ / ⌘↩ 换行；只在出乎所选时写一行方向说明）+ 原文操作（收藏、划词来的可「替换原文」），
// 没有常驻「翻译」按钮（N5）：原文改过还没重译时右下角才弹出品牌粉「翻译 ↩」胶囊（pop），开始翻译就收回（settle）；
// 下方是各服务结果卡片（折叠状态记住；查单个词时最上面多一张系统词典卡）。翻译历史（N7，HistoryView）整块替换结果区，
// 开 / 关时只有这块 settle 交叉淡变、原文区不动。高度随内容伸缩（Bob 的做法：只让人拖宽度），结果卡不超过三张时
// 全放下、多于三张时至少放下前三张，第四张起才在卡片区里滚（2026-10-03 用户要求，panelHeight）；
// 字号可调（⌘+ / ⌘- / ⌘0）。状态和操作都在 TranslateCoordinator，窗口快捷键见它的 handleKeyEquivalent。

import SwiftUI

struct TranslatePanelView: View {
  @Bindable var coordinator: TranslateCoordinator
  let speaker: Speaker
  /// 内容要的高度、至少要放得下的高度（浮窗按 panelHeight 伸缩，顶边不动）
  var resize: (_ height: CGFloat, _ mustFit: CGFloat) -> Void = { _, _ in }
  /// 把第一个服务的译文粘回原 App 的选区
  var replaceOriginal: () -> Void = {}

  @AppStorage(Prefs.floatingPinned) private var pinned = false
  /// 和菜单栏的勾、设置 › 翻译读写同一个偏好
  @AppStorage(Prefs.translateCopyToTranslate) private var copyToTranslate = false
  @AppStorage(Prefs.translateFontScale) private var fontScale = 1.0
  /// 折叠着的服务 id（换行分隔）：跨重启记住
  @AppStorage(Prefs.translateCollapsedServices) private var collapsedServices = ""
  /// nil = 自动检测
  @AppStorage(Prefs.translateSource) private var source: String?
  /// nil = 自动（第一 ⇄ 第二语言）
  @AppStorage(Prefs.translateTarget) private var target: String?
  @AppStorage(Prefs.translateFirst) private var first: String?
  @AppStorage(Prefs.translateSecond) private var second: String?
  @State private var chromeHeight: CGFloat = 0
  @State private var resultsHeight: CGFloat = 0
  /// 第三张结果卡的下沿（结果区里的 y，上面有词典卡时连它一起算）：多于三张时浮窗至少放到这里
  @State private var thirdCardBottom: CGFloat = 0
  /// 互换钮转了几个半圈
  @State private var swaps = 0
  /// 原文框拿着焦点：输入框底画焦点环（和历史搜索框只有一个亮）
  @State private var sourceFocused = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(Island.self) private var island: Island?

  var body: some View {
    VStack(spacing: 10) {
      VStack(spacing: 10) {
        header
        sourceArea
      }
      .padding(.horizontal, 12)
      .padding(.top, 12)
      .onGeometryChange(for: CGFloat.self) {
        $0.size.height
      } action: {
        chromeHeight = $0
      }
      // 历史打开时整块替换结果区（材质半透明，叠在上面会透出下面的内容）；开 / 关只让这块 settle 交叉淡变
      ZStack {
        if coordinator.showsHistory {
          HistoryView(coordinator: coordinator).transition(.opacity)
        } else {
          results.transition(.opacity)
        }
      }
      .frame(maxHeight: .infinity)
      .animation(
        Style.Motion.settle.animation(reduced: reduceMotion), value: coordinator.showsHistory)
    }
    .padding(.bottom, coordinator.showsHistory ? 0 : 2)
    // 一次操作只重译一次（交换、撞同语言时两个值在同一次更新里一起改）
    .onChange(of: [source, target]) { retranslate() }
    .onChange(of: [desiredHeight, mustFitHeight], initial: true) {
      resize(desiredHeight, mustFitHeight)
    }
    // 「⋯」菜单和历史 ⌘K 的「清空历史…」共用一个确认框
    .confirmationDialog("清空翻译历史？", isPresented: $coordinator.confirmsClearHistory) {
      Button("清空", role: .destructive) { HistoryMenu.clear(coordinator.history, island: island) }
    } message: {
      Text("收藏的记录会保留")
    }
  }

  /// 结果区画的是卡片（和 results 的分支一致）
  private var showsCards: Bool {
    !coordinator.showsHistory && coordinator.notice == nil
      && !coordinator.services.enabled.isEmpty && !coordinator.cards.isEmpty
  }

  /// 顶栏 + 原文区 + 结果（卡片按实际高度；历史、提示、没有服务、空态给固定的高度，和 results 的分支一致）
  private var desiredHeight: CGFloat {
    let body: CGFloat = coordinator.showsHistory ? 420 : showsCards ? resultsHeight : 200
    return ceil(chromeHeight + 10 + body + 2)
  }

  /// 至少要放得下的高度：结果卡不超过三张是全部内容，多于三张到第三张的下沿（加结果区底下的 10）
  private var mustFitHeight: CGFloat {
    guard showsCards, coordinator.cards.count > 3 else { return desiredHeight }
    return ceil(chromeHeight + 10 + thirdCardBottom + 10 + 2)
  }

  /// 浮窗的高：随内容，最矮 220；最高平时是屏幕可见区的 85%，再多就在卡片区里滚，但 mustFit 要放得下
  /// （三张写满 8 行的卡约 850 pt，85% 的上限会差一点、多出外层滚动条），这时最高到可见区减上下各 12。
  /// ponytail: 可见区比 mustFit 还矮（小屏、调大了字号）时照样在卡片区里滚；要保证三张都露全得按可见区压低卡片的 8 行上限
  static func panelHeight(_ height: CGFloat, mustFit: CGFloat, visible: CGFloat) -> CGFloat {
    min(max(height, 220), min(max(visible * 0.85, mustFit), visible - 24))
  }

  // MARK: 顶栏

  /// 窄时（复制即译胶囊占了顶栏、浮窗拖窄）两个胶囊一起收掉「自动」标签（只收一个会让它看着像固定语言），
  /// 还不够才截断语言名
  private var header: some View {
    HStack(spacing: 8) {
      ViewThatFits(in: .horizontal) {
        languages(showsAutoTags: true)
        languages(showsAutoTags: false)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if copyToTranslate {
        CopyToTranslateBadge { copyToTranslate = false }
          .transition(reduceMotion ? .opacity : .scale(scale: 0.85).combined(with: .opacity))
      }
      HStack(spacing: 2) {
        // 开关类按钮：开着时品牌粉（mac-whisker §1.2）
        Button {
          pinned.toggle()
        } label: {
          Image(systemName: pinned ? "pin.fill" : "pin")
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 24, height: 24)
            .contentShape(.rect)
        }
        .foregroundStyle(pinned ? Style.brand : .secondary)
        .help(pinned ? "已固定：点别处不收起（⌘P）" : "固定浮窗（⌘P）")
        .accessibilityLabel("固定浮窗")
        .accessibilityValue(pinned ? "已固定" : "未固定")
        MoreMenu(coordinator: coordinator)
      }
      .font(.system(size: 13, weight: .medium))
      .symbolRenderingMode(.hierarchical)
      .fixedSize()
    }
    .buttonStyle(.plain)
    .frame(height: 28)
    .animation(
      (copyToTranslate ? Style.Motion.pop : .settle).animation(reduced: reduceMotion),
      value: copyToTranslate)
  }

  /// 顶栏语言区的三格：按语言值标 id（两边都自动时各用自己的），互换时 SwiftUI 把同一个语言的胶囊滑到另一边
  private struct LanguageSlot: Identifiable {
    enum Kind { case source, swap, target }
    let id: String
    let kind: Kind
  }

  private var slots: [LanguageSlot] {
    let bothAuto = source == nil && target == nil
    return [
      LanguageSlot(id: source ?? (bothAuto ? "auto-src" : "auto"), kind: .source),
      LanguageSlot(id: "swap", kind: .swap),
      LanguageSlot(id: target ?? (bothAuto ? "auto-dst" : "auto"), kind: .target),
    ]
  }

  /// 源语言胶囊 + 互换钮 + 目标语言胶囊。两个胶囊是同一种视图（languageMenu），互换后同一个语言的元素身份不变，
  /// SwiftUI 才会把它滑到另一边；分成两种视图（或 switch 三个分支）时换边 = 换分支，只会原地交叉淡变
  private func languages(showsAutoTags: Bool) -> some View {
    HStack(spacing: 6) {
      ForEach(slots) { slot in
        if slot.kind == .swap {
          swapButton
        } else {
          languageMenu(isSource: slot.kind == .source, showsAutoTags: showsAutoTags)
        }
      }
    }
  }

  private func languageMenu(isSource: Bool, showsAutoTags: Bool) -> some View {
    let title = isSource ? sourceTitle : targetTitle
    let isAuto = (isSource ? source : target) == nil
    let label = isSource ? "源语言" : "目标语言"
    return Menu {
      Picker(
        label,
        selection: isSource ? choose(\.source, other: \.target) : choose(\.target, other: \.source)
      ) {
        if isSource {
          Text("自动检测").tag(String?.none)
        } else {
          let pair = Lang.pair(first: first, second: second)
          Text("自动（\(pair.first.title) ⇄ \(pair.second.title)）").tag(String?.none)
        }
        Divider()
        ForEach(Lang.allCases, id: \.self) { Text($0.title).tag(String?.some($0.rawValue)) }
      }
      .pickerStyle(.inline)
    } label: {
      LanguageCapsule(
        title: title,
        showsAutoTag: showsAutoTags && isAuto && title != (isSource ? "自动检测" : "自动"))
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .help(label)
    .accessibilityLabel(label)
    .accessibilityValue(title)
  }

  /// 原样互换，「自动」也照换（Bob 的做法）；两边都自动时本来就是双向的，不用换。
  /// 箭头转半圈、两个胶囊交换位置，都是 glide（指针驱动的位移；减弱动态效果时瞬时）
  private var swapButton: some View {
    Button {
      withAnimation(Style.Motion.glide.animation(reduced: reduceMotion)) {
        swaps += 1
        (source, target) = (target, source)
      }
    } label: {
      Image(systemName: "arrow.left.arrow.right")
        .font(.system(size: 11, weight: .semibold))
        .rotationEffect(.degrees(Double(swaps) * 180))
        .frame(width: 24, height: 24)
        .background(Style.controlFill, in: .circle)
        .contentShape(.circle)
    }
    .buttonStyle(PressScale())
    .disabled(source == nil && target == nil)
    .opacity(source == nil && target == nil ? 0.35 : 1)
    .help("交换语言")
    .accessibilityLabel("交换语言")
  }

  /// 源语言胶囊：自动时显示检测到的语言（还没翻译时写「自动检测」）
  private var sourceTitle: String {
    if let source, let lang = Lang(rawValue: source) { return lang.title }
    return (coordinator.fixedSource ?? coordinator.detected)?.title ?? "自动检测"
  }

  /// 目标语言胶囊：自动时显示这次实际译成的语言（还没翻译时写「自动」，菜单里有「自动（A ⇄ B）」）
  private var targetTitle: String {
    if let target, let lang = Lang(rawValue: target) { return lang.title }
    return coordinator.target?.title ?? "自动"
  }

  /// 选成和另一边相同的固定语言时，另一边换成这边原来的值（像交换一样），不会出现「英 → 英」
  private func choose(
    _ side: ReferenceWritableKeyPath<Self, String?>, other: ReferenceWritableKeyPath<Self, String?>
  ) -> Binding<String?> {
    Binding {
      self[keyPath: side]
    } set: { new in
      if new != nil, new == self[keyPath: other] { self[keyPath: other] = self[keyPath: side] }
      self[keyPath: side] = new
    }
  }

  private func retranslate() {
    if !coordinator.sourceText.isEmpty { coordinator.start() }
  }

  // MARK: 原文区

  private var sourceArea: some View {
    VStack(alignment: .leading, spacing: 6) {
      // 历史开着时焦点在原文框里按 Esc：先关历史（不然会直接关掉浮窗）
      // 左右不加内边距（文字缩进 10 + 2 在 horizontalInset 里）：滚动条贴原文框右边
      SourceTextView(
        text: $coordinator.sourceText, fontSize: 15 * fontScale, horizontalInset: 12,
        onCancel: coordinator.showsHistory ? { coordinator.showsHistory = false } : nil
      ) {
        coordinator.start()
      } onFocusChange: {
        sourceFocused = $0
      }
      .frame(height: 76)
      .overlay(alignment: .topLeading) {
        // 划词没取到文字时换一句说明（体检 A16，同一句也播报给 VoiceOver），开始输入就换回平时的
        if coordinator.sourceText.isEmpty {
          Text(coordinator.missedSelection ? "没取到选中的文字，可以直接输入或粘贴" : "输入或粘贴文字，↩ 翻译，⇧↩ 换行")
            .font(.system(size: 15 * fontScale))
            .foregroundStyle(.tertiary)
            .padding(.leading, 15)
            .padding(.top, 1)
            .allowsHitTesting(false)
        }
      }
      if let note = directionNote {
        Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
          .padding(.horizontal, 10)
      }
      HStack(spacing: 12) {
        Group {
          Button(
            "朗读原文",
            systemImage: speaker.speaking == coordinator.sourceText
              ? "speaker.wave.2.fill" : "speaker.wave.2"
          ) {
            speaker.toggle(
              coordinator.sourceText,
              language: coordinator.fixedSource ?? coordinator.detected)
          }
          .symbolEffect(
            .variableColor.iterative.reversing,
            isActive: speaker.speaking == coordinator.sourceText && !coordinator.sourceText.isEmpty)
          Button("复制原文", systemImage: "doc.on.doc") {
            Paster.write(string: coordinator.sourceText, record: true)
            island?.show("已复制原文", detail: Island.excerpt(coordinator.sourceText))
          }
          Button("清空", systemImage: "xmark.circle") { coordinator.beginInput() }
        }
        .foregroundStyle(.secondary)
        .disabled(coordinator.sourceText.isEmpty)
        Spacer()
        Button(
          coordinator.isFavorite ? "取消收藏" : "收藏",
          systemImage: coordinator.isFavorite ? "star.fill" : "star"
        ) {
          coordinator.toggleFavorite()
        }
        .foregroundStyle(coordinator.isFavorite ? Color(nsColor: .systemYellow) : .secondary)
        .contentTransition(.symbolEffect(.replace))
        .symbolEffect(.bounce, value: coordinator.isFavorite)
        .disabled(coordinator.primaryResult == nil)
        .help("收藏这次翻译（⌘D），在历史里可以只看收藏")
        // 查单个词时结果是一段释义，不能拿去替换
        if coordinator.replaceSource != nil, !coordinator.isWordLookup {
          Button("替换原文", systemImage: "arrow.uturn.backward", action: replaceOriginal)
            .labelStyle(.titleAndIcon)
            .disabled(coordinator.primaryResult == nil)
            .help("用第一个服务的译文替换原 App 里选中的文字")
        }
        // 没有常驻「翻译」按钮（N5）：↩ 就是翻译，原文改过、还没重译时才从右下角弹出来
        if coordinator.needsTranslate {
          TranslateCapsule { coordinator.start() }
            .transition(
              reduceMotion
                ? .opacity : .scale(scale: 0.6, anchor: .trailing).combined(with: .opacity))
        }
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
      .font(.system(size: 13, weight: .medium))
      // 定高：胶囊弹出、收回时原文框不跟着变高
      .frame(height: 24)
      .animation(
        (coordinator.needsTranslate ? Style.Motion.pop : .settle).animation(reduced: reduceMotion),
        value: coordinator.needsTranslate
      )
      .padding(.horizontal, 10)
    }
    .padding(.top, 8)
    .padding(.bottom, 8)
    .modifier(InputBox(isFocused: sourceFocused))
  }

  /// 只在出乎所选时写一行：固定目标正好是原文语言而改译了另一端；固定源和检测结果对不上（照所选发出，只提示）
  private var directionNote: String? {
    if let abandoned = coordinator.abandonedTarget, let to = coordinator.target {
      return "原文已是\(abandoned.title)，改译成\(to.title)"
    }
    if let fixedSource = coordinator.fixedSource, let detected = coordinator.detected,
      !detected.isSameLanguage(as: fixedSource)
    {
      return "检测到\(detected.title)，仍按\(fixedSource.title)翻译"
    }
    return nil
  }

  // MARK: 结果

  @ViewBuilder private var results: some View {
    if let notice = coordinator.notice {
      EmptyStateView(symbol: "exclamationmark.bubble", title: notice) {
        // 只有授权类提示才给按钮（以前任何提示都挂「打开辅助功能设置」）
        if let permission = coordinator.noticePermission {
          Button(permission.settingsTitle, action: permission.openSettings)
        }
      }
    } else if coordinator.services.enabled.isEmpty {
      EmptyStateView(symbol: "character.bubble", title: "没有启用的翻译服务") {
        Button("打开翻译设置") { coordinator.openSettings(nil) }
      }
    } else if coordinator.cards.isEmpty {
      EmptyStateView(symbol: "character.bubble", title: "划词、截图或输入后开始翻译") {
        VStack(spacing: 6) {
          ForEach(
            [HotKeyAction.selectionTranslate, .screenshotTranslate, .inputTranslate], id: \.self
          ) {
            action in
            HStack {
              Text(action.title).foregroundStyle(.secondary)
              Spacer()
              if let hotKey = action.hotKey {
                KeyCap(hotKey.display)
              } else {
                Text("未设置").foregroundStyle(.tertiary)
              }
            }
            .font(.system(size: 12))
            .frame(width: 200)
          }
        }
      }
    } else {
      ScrollView {
        VStack(spacing: 10) {
          if let entry = coordinator.dictionary {
            DictionaryCardView(
              entry: entry, language: coordinator.detected, speaker: speaker, fontScale: fontScale
            )
            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
          }
          ForEach(Array(coordinator.cards.enumerated()), id: \.element.id) { index, card in
            ProviderCardView(
              card: card, index: index, language: coordinator.target, speaker: speaker,
              fontScale: fontScale, isCollapsed: collapsed.contains(card.id),
              copyTick: coordinator.copiedCard == card.id ? coordinator.copyTick : 0
            ) {
              coordinator.retry(card.id)
            } onCopy: {
              coordinator.copyCard(card.id)
            } onToggleCollapse: {
              toggleCollapse(card.id)
            } onOpenSettings: {
              // 直达这个服务的详情页（体检 C5）
              coordinator.openSettings(card.id)
            }
            .onGeometryChange(for: CGFloat.self) {
              $0.frame(in: .named(Self.resultsSpace)).maxY
            } action: {
              if index == 2 { thirdCardBottom = $0 }
            }
          }
        }
        .coordinateSpace(.named(Self.resultsSpace))
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .animation(
          Style.Motion.settle.animation(reduced: reduceMotion), value: coordinator.dictionary
        )
        .onGeometryChange(for: CGFloat.self) {
          $0.size.height
        } action: {
          resultsHeight = $0
        }
      }
    }
  }

  /// 结果区卡片堆的坐标系（量第三张卡的下沿；在滚动内容里，滚动不影响）
  private static let resultsSpace = "translateResults"

  private var collapsed: Set<String> {
    Set(collapsedServices.split(separator: "\n").map(String.init))
  }

  private func toggleCollapse(_ id: String) {
    var set = collapsed
    if set.remove(id) == nil { set.insert(id) }
    collapsedServices = set.sorted().joined(separator: "\n")
  }
}

/// 28 pt 语言胶囊：语言名 +（自动且已知实际语言时）「自动」标签 + 9 pt 下拉箭头；窄时语言名截断
private struct LanguageCapsule: View {
  let title: String
  let showsAutoTag: Bool

  var body: some View {
    HStack(spacing: 5) {
      // 窄的时候只让语言名截断，「自动」标签和箭头不挤
      Text(title)
        .font(.system(size: 13, weight: .medium))
        .lineLimit(1)
        .truncationMode(.middle)
        .contentTransition(.interpolate)
        .layoutPriority(-1)
      if showsAutoTag {
        Text("自动")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(Style.brandInk)
          .padding(.horizontal, 5)
          .padding(.vertical, 1)
          .background(Style.brand.opacity(0.14), in: .capsule)
          .fixedSize()
      }
      Image(systemName: "chevron.down")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.secondary)
        .fixedSize()
    }
    .padding(.leading, 12)
    .padding(.trailing, 10)
    .frame(height: 28)
    .background(Style.controlFill, in: .capsule)
    .contentShape(.capsule)
  }
}

/// 顶栏「⋯」菜单（N6）：翻译历史 ⌘Y、清空历史、导出（体检 C6，和设置 › 翻译、历史 ⌘K 同一个 HistoryMenu.export）
/// 与条数、复制即译开关、设置 ⌘,。菜单项的键位和 TranslateCoordinator.handleKeyEquivalent 一致（那边先处理，这里只是显示）；
/// 浮窗快捷键不再塞进按钮 help。清空的确认框挂在根视图上（历史 ⌘K 也开它）
private struct MoreMenu: View {
  @Bindable var coordinator: TranslateCoordinator
  @AppStorage(Prefs.translateCopyToTranslate) private var copyToTranslate = false
  @Environment(Island.self) private var island: Island?

  var body: some View {
    let history = coordinator.history
    let _ = history.revision  // 增删、收藏后刷新条数
    let counts = history.counts
    Menu {
      Toggle("翻译历史", isOn: $coordinator.showsHistory)
        .keyboardShortcut("y")
      Button("清空历史…") { coordinator.confirmsClearHistory = true }
        .disabled(counts.total == counts.favorites)
      Menu("导出") { HistoryExportItems(history: history, island: island) }
        .disabled(counts.total == 0)
      Text("共 \(counts.total) 条 · 收藏 \(counts.favorites)")
      Divider()
      Toggle("复制即译", isOn: $copyToTranslate)
      Divider()
      Button("设置…") { coordinator.openSettings(nil) }
        .keyboardShortcut(",")
    } label: {
      Image(systemName: "ellipsis")
        .frame(width: 24, height: 24)
        .contentShape(.rect)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .foregroundStyle(.secondary)
    .help("更多：翻译历史、导出、复制即译、设置")
    .accessibilityLabel("更多")
  }
}

/// 复制即译开着时顶栏的品牌粉状态胶囊（N6）：点一下关掉。只放字（22 高、12 medium、左右 10）：
/// 默认 420 宽、两边都自动时顶栏正好放得下两个「自动」标签和它
private struct CopyToTranslateBadge: View {
  let turnOff: () -> Void

  var body: some View {
    Button(action: turnOff) {
      Text("复制即译")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Style.brandInk)
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(Style.brand.opacity(0.16), in: .capsule)
        .contentShape(.capsule)
    }
    .buttonStyle(PressScale())
    .fixedSize()
    .help("复制即译已开启：复制文字后自动翻译。点一下关闭")
    .accessibilityLabel("复制即译已开启")
    .accessibilityHint("关闭复制即译")
  }
}

/// 原文框右下角的「翻译 ↩」（N5）：品牌粉实心胶囊（主按钮），只在原文改过、还没重译时出现
private struct TranslateCapsule: View {
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 5) {
        Text("翻译")
        Text("↩").opacity(0.75)
      }
      .font(.system(size: 12, weight: .semibold))
      .foregroundStyle(Style.onBrand)
      .padding(.horizontal, 12)
      .frame(height: 24)
      .background(Style.brand, in: .capsule)
      .contentShape(.capsule)
    }
    .buttonStyle(PressScale())
    .help("翻译改过的原文（↩）")
    .accessibilityLabel("翻译")
    .accessibilityHint("原文改过了，按回车键也可以翻译")
  }
}

/// 空状态 / 提示：28 pt 图标 + 14 semibold 标题 + 下方内容（按钮、快捷键）；翻译历史的空态也用它
struct EmptyStateView<Actions: View>: View {
  let symbol: String
  let title: String
  @ViewBuilder var actions: Actions

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: symbol)
        .font(.system(size: 28, weight: .regular))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(.tertiary)
      Text(title)
        .font(.system(size: 14, weight: .semibold))
        .multilineTextAlignment(.center)
      actions
    }
    .padding(20)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
