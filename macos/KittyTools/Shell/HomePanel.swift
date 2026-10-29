// 主界面（2026-10-29 拍板「全部按推荐」，拍板页 macos/build/research/home-panel-2026-10-29/decisions.html）：一眼看到全部功能、
// 点一下就用的那块面板。内容和菜单栏菜单读同一份——HotKeyAction.sections 分节、同名同序（关着的功能不出现），每节末尾接上那一节
// 的 MenuExtra（暂停记录剪贴板、复制即译、有钉图时的两项）；有关着的功能时最下面一行「N 个功能关着 · 管理…」；底栏左边有新版本
// 时是「更新到 x」（UpdateBarHint），右边「设置 ⌘,」「退出 ⌘Q」。一格 = 30 pt 家族色块 + 名字 + 一行小字快捷键，一行 5 格；
// 只有一格的节（启动台、状态屏、刘海岛）不画标题、连着的并成一行。开关是圆的，开着时填强调色，点了原地切、面板不收；别的格子
// 点了面板先收起再做（同启动器的内置动作）。「打开主界面」自己不在里面。
// 面板是一个 OverlayPanel 实例（AppDelegate.homePanel：Panel 皮肤、不激活本 App、点外面收）。键盘：←→ ↑↓ Tab 选（一块中性
// 高亮滑过去），↩ / 空格执行，Esc 收起，⌘, 设置，⌘Q 退出。按键由一块当第一响应者的 NSView 收（同选状态的面板）。
// 分节、排版、选中怎么移动、按键对应什么都是纯函数（enum Home），单测锁住。

import AppKit
import Carbon.HIToolbox
import SwiftUI

enum Home {
  /// 一行几格
  static let columns = 5
  /// 一格：最长的名字「钉住剪贴板里的图」11 pt 一行放得下
  static let tile = CGSize(width: 92, height: 76)
  /// 格子之间（横竖一样）
  static let gap: CGFloat = 2
  /// 面板左右内缩（同列表型面板的选中高亮离边 6 再加 4：格子的高亮是 card 圆角，和面板 16 同心要内缩 6 以上）
  static let inset: CGFloat = 10
  /// 格子那一块的上下内缩
  static let top: CGFloat = 4
  static let bottom: CGFloat = 6
  /// 节标题（11 semibold tertiary，贴底留 2，同启动器的分组标题）
  static let titleHeight: CGFloat = 24
  /// 没标题的那一行和上一节之间
  static let untitledGap: CGFloat = 6
  /// 「N 个功能关着 · 管理…」那一行
  static let noteHeight: CGFloat = 26
  /// 底栏（同启动器、剪贴板面板）
  static let barHeight: CGFloat = 36
  static let width = inset * 2 + CGFloat(columns) * tile.width + CGFloat(columns - 1) * gap

  struct Tile: Equatable, Identifiable {
    enum Target: Equatable {
      case action(HotKeyAction)
      case extra(MenuExtra)
    }

    let target: Target
    let title: String
    let symbol: String
    let color: Color
    /// 当前生效的快捷键（没设、没注册上的 nil）
    let key: String?
    /// 开关（暂停记录剪贴板、复制即译）开没开；不是开关的 nil
    let isOn: Bool?

    var id: String {
      switch target {
      case .action(let action): action.rawValue
      case .extra(let extra): "extra." + extra.rawValue
      }
    }
  }

  struct Section: Equatable {
    /// nil = 不画标题（只有一格的节并成的那一行）
    let title: String?
    let tiles: [Tile]
  }

  /// 分节（纯函数）：和菜单栏菜单同一份（AppDelegate.buildStatusMenu），关着的功能不出现，「打开主界面」不列；
  /// 每节末尾接那一节的 MenuExtra。只有一格的节不画标题，和前面同样是一格的并成一行（菜单里这几节也不画标题）。
  /// keys：各动作当前生效的快捷键（HotKeyCenter.bindings 的 display）
  static func sections(state: LauncherItem.ActionState, keys: [HotKeyAction: String]) -> [Section] {
    let extras = MenuExtra.allCases.filter { $0.section != nil && $0.isAvailable(state) }
    var result: [Section] = []
    for section in HotKeyAction.visibleSections(enabled: state.features) {
      var tiles = section.actions.filter { $0 != .home }.map { action in
        Tile(
          target: .action(action), title: action.title(recording: state.recording == action),
          symbol: action.symbol, color: action.color, key: keys[action], isOn: nil)
      }
      for extra in extras where section.actions.contains(where: { $0 == extra.section }) {
        let isOn = extra.isOn(state)
        tiles.append(
          Tile(
            target: .extra(extra), title: extra.title(pinsHidden: state.pinsHidden == true),
            symbol: isOn == nil ? extra.symbol : toggleSymbol(extra), color: extra.color, key: nil,
            isOn: isOn))
      }
      guard !tiles.isEmpty else { continue }
      if tiles.count > 1 {
        result.append(Section(title: section.title, tiles: tiles))
      } else if let last = result.last, last.title == nil {
        result[result.count - 1] = Section(title: nil, tiles: last.tiles + tiles)
      } else {
        result.append(Section(title: nil, tiles: tiles))
      }
    }
    return result
  }

  /// 开关画在圆里：菜单用的是带圈的符号（pause.circle），圆里再画一圈就成了圈套圈
  private static func toggleSymbol(_ extra: MenuExtra) -> String {
    extra == .pauseClipboard ? "pause.fill" : "doc.on.doc.fill"
  }

  /// 关着的功能有几个（纯函数）：只算这台系统上有、而且有入口（全局动作）的——程序坞预览没有全局动作，默认关着也不提
  static func offCount(enabled: Set<Feature>, available: Set<Feature>) -> Int {
    available.subtracting(enabled).filter { feature in
      HotKeyAction.allCases.contains { $0.feature == feature }
    }.count
  }

  /// 每一行有哪几格（全部格子按顺序从 0 编号；每节自己折行）
  static func rows(_ sections: [Section]) -> [[Int]] {
    var rows: [[Int]] = []
    var next = 0
    for section in sections {
      for start in stride(from: 0, to: section.tiles.count, by: columns) {
        let count = min(columns, section.tiles.count - start)
        rows.append(Array(next + start..<next + start + count))
      }
      next += section.tiles.count
    }
    return rows
  }

  /// 面板的高（纯函数）：格子那一块 + 关着的功能那一行（有才有）+ 底栏
  static func height(_ sections: [Section], offCount: Int) -> CGFloat {
    var height = top + bottom
    for (index, section) in sections.enumerated() {
      height += section.title != nil ? titleHeight : (index == 0 ? 0 : untitledGap)
      let rows = CGFloat((section.tiles.count + columns - 1) / columns)
      height += rows * tile.height + (rows - 1) * gap
    }
    return height + (offCount > 0 ? noteHeight : 0) + barHeight
  }

  enum Move { case left, right, up, down }

  /// 选中怎么移动（纯函数）：←→ 按顺序挨个走、到头回绕（Tab / ⇧Tab 同）；↑↓ 换行，列不变，那一行短就落在它最后一格，
  /// 第一行 / 最后一行不动。还没选中时按什么都是第一格
  static func moved(_ selection: Int?, _ move: Move, rows: [[Int]]) -> Int? {
    let count = rows.reduce(0) { $0 + $1.count }
    guard count > 0 else { return nil }
    guard let selection, let row = rows.firstIndex(where: { $0.contains(selection) }),
      let column = rows[row].firstIndex(of: selection)
    else { return 0 }
    switch move {
    case .left: return (selection - 1 + count) % count
    case .right: return (selection + 1) % count
    case .up:
      guard row > 0 else { return selection }
      return rows[row - 1][min(column, rows[row - 1].count - 1)]
    case .down:
      guard row < rows.count - 1 else { return selection }
      return rows[row + 1][min(column, rows[row + 1].count - 1)]
    }
  }

  enum Key: Equatable {
    case move(Move)
    /// ↩、空格：执行选中的那一格
    case run
    case cancel
  }

  /// 面板里的按键（纯函数）；nil = 不认识，交还给系统。带 ⌘⌃⌥ 的不管（⌘, ⌘Q 走 command，⌘W 在 OverlayPanel 里）
  static func key(code: Int, modifiers: NSEvent.ModifierFlags) -> Key? {
    guard modifiers.isDisjoint(with: [.command, .control, .option]) else { return nil }
    switch code {
    case kVK_LeftArrow: return .move(.left)
    case kVK_RightArrow: return .move(.right)
    case kVK_UpArrow: return .move(.up)
    case kVK_DownArrow: return .move(.down)
    case kVK_Tab: return .move(modifiers.contains(.shift) ? .left : .right)
    case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space: return .run
    case kVK_Escape: return .cancel
    default: return nil
    }
  }

  /// 面板里的 ⌘ 组合（纯函数）：⌘, 设置、⌘Q 退出（同菜单栏菜单的键）。按键码认，不看输入法和键盘布局；
  /// 修饰键只比 ⌘⌃⌥⇧、不看大写锁定（同 OverlayPanel 的 ⌘W）
  static func command(code: Int, modifiers: NSEvent.ModifierFlags) -> MenuExtra? {
    guard modifiers.intersection([.command, .control, .option, .shift]) == .command else {
      return nil
    }
    switch code {
    case kVK_ANSI_Comma: return .settings
    case kVK_ANSI_Q: return .quit
    default: return nil
    }
  }
}

@Observable final class HomeModel {
  private(set) var sections: [Home.Section]
  private(set) var offCount: Int
  /// 键盘选中的那一格；没按过方向键时没有（打开时不画高亮）
  private(set) var selection: Int?
  /// 鼠标停在哪一格上（没选中的那格铺 fill.hover）
  var hovered: Int?
  /// 选中换了走哪条曲线：键盘 snap，按住连发不动画
  private(set) var motion = Style.Motion.instant

  /// 做一件事（AppDelegate 接上：动作走 run(action)，菜单栏那几项走 run(extra)；开关做完再 refresh）
  @ObservationIgnored var perform: (Home.Tile.Target) -> Void = { _ in }
  /// 「管理…」：设置 › 通用（「功能」那一节在里面）
  @ObservationIgnored var openFeatures: () -> Void = {}
  /// 收起面板（不放淡出：接下来要做的事要面板已经不在屏幕上）
  @ObservationIgnored var hidePanel: () -> Void = {}

  /// 截图自检直接摆出某个样子；正常使用建一个空的，每次呼出前 update
  init(
    sections: [Home.Section] = [], offCount: Int = 0, selection: Int? = nil, hovered: Int? = nil
  ) {
    self.sections = sections
    self.offCount = offCount
    self.selection = selection
    self.hovered = hovered
  }

  var tiles: [Home.Tile] { sections.flatMap(\.tiles) }
  var size: CGSize { CGSize(width: Home.width, height: Home.height(sections, offCount: offCount)) }

  /// 换成现在的样子。appearing：新呼出（选中、悬停清掉）；开关切完原地刷新时选中留着
  func update(_ sections: [Home.Section], offCount: Int, appearing: Bool) {
    self.sections = sections
    self.offCount = offCount
    if appearing {
      selection = nil
      hovered = nil
      motion = .instant
    } else if let selection, selection >= tiles.count {
      self.selection = tiles.isEmpty ? nil : tiles.count - 1
    }
  }

  func handle(_ key: Home.Key) {
    switch key {
    case .move(let move):
      motion = Style.isKeyRepeat ? .instant : .snap
      selection = Home.moved(selection, move, rows: Home.rows(sections))
    case .run:
      if let selection { activate(selection) }
    case .cancel: break
    }
  }

  /// 点了 / 按了第 index 格：开关原地切（面板不收）；别的先收起面板再做
  func activate(_ index: Int) {
    guard tiles.indices.contains(index) else { return }
    let tile = tiles[index]
    if tile.isOn == nil { hidePanel() }
    perform(tile.target)
  }

  /// 底栏的「设置」「退出」
  func run(_ extra: MenuExtra) {
    hidePanel()
    perform(.extra(extra))
  }
}

struct HomeView: View {
  let model: HomeModel
  @Namespace private var selection

  var body: some View {
    VStack(spacing: 0) {
      grid
      if model.offCount > 0 { offNote }
      bar
    }
    .background { HomeKeys(model: model) }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("主界面")
  }

  private var grid: some View {
    let starts = model.sections.indices.map { index in
      model.sections[..<index].reduce(0) { $0 + $1.tiles.count }
    }
    return VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(model.sections.enumerated()), id: \.offset) { index, section in
        if let title = section.title {
          Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.leading, 10)
            .padding(.bottom, 2)
            .frame(height: Home.titleHeight, alignment: .bottomLeading)
            .accessibilityAddTraits(.isHeader)
        } else if index > 0 {
          Color.clear.frame(height: Home.untitledGap)
        }
        VStack(alignment: .leading, spacing: Home.gap) {
          ForEach(Array(stride(from: 0, to: section.tiles.count, by: Home.columns)), id: \.self) {
            start in
            HStack(spacing: Home.gap) {
              ForEach(start..<min(start + Home.columns, section.tiles.count), id: \.self) {
                offset in
                HomeTile(
                  model: model, tile: section.tiles[offset], index: starts[index] + offset,
                  namespace: selection)
              }
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, Home.inset)
    .padding(.top, Home.top)
    .padding(.bottom, Home.bottom)
  }

  /// 「2 个功能关着 · 管理…」：字 secondary，「管理…」是强调色文字按钮（同底栏的「撤销」）
  private var offNote: some View {
    HStack(spacing: 4) {
      Text("\(model.offCount) 个功能关着 ·").foregroundStyle(.secondary)
      Button("管理…") { model.openFeatures() }
        .buttonStyle(.plain)
        .foregroundStyle(Style.brandInk)
        .pointerStyle(.link)
        .accessibilityLabel("管理功能")
        .accessibilityHint("打开 设置 › 通用，打开或关掉功能")
    }
    .font(.system(size: 11))
    .padding(.leading, Home.inset + 10)
    .frame(maxWidth: .infinity, minHeight: Home.noteHeight, alignment: .leading)
  }

  /// 底栏（同启动器的底栏，mac-whisker §3「面板里共用的几件」）：左边有新版本时「更新到 x」，右边两个能点的动作
  /// 「设置 ⌘,」「退出 ⌘Q」（primary）；左右 16 = 内缩 10 + 6，对齐格子的高亮里面那条线
  private var bar: some View {
    HStack(spacing: 12) {
      UpdateBarHint { model.hidePanel() }
      Spacer(minLength: 8)
      barButton("设置", key: "⌘,", .settings)
      barButton("退出", key: "⌘Q", .quit)
    }
    .font(.system(size: 12))
    .lineLimit(1)
    .buttonStyle(.plain)
    .padding(.horizontal, 16)
    .frame(height: Home.barHeight)
    .overlay(alignment: .top) { Hairline() }
  }

  private func barButton(_ title: String, key: String, _ extra: MenuExtra) -> some View {
    Button {
      model.run(extra)
    } label: {
      HStack(spacing: 6) {
        Text(title)
        KeyCap(key).accessibilityHidden(true)
      }
      .contentShape(.rect)
    }
    .accessibilityLabel(extra == .quit ? "退出 Kitty Tools" : "设置")
  }
}

/// 一格：色块（开关是圆）+ 名字 + 快捷键（开关这一行写「已暂停」「已开启」）。键盘选中的那格垫一块中性高亮（matchedGeometryEffect
/// 在格子间滑过去：格子是固定的、不会被回收，不同于长列表的 offset 写法）；没选中的悬停铺 fill.hover
private struct HomeTile: View {
  let model: HomeModel
  let tile: Home.Tile
  let index: Int
  let namespace: Namespace.ID
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let selected = model.selection == index
    let shape = RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
    Button {
      model.activate(index)
    } label: {
      VStack(spacing: 0) {
        icon.padding(.top, 9)
        Text(tile.title)
          .font(.system(size: 11))
          .lineLimit(1)
          .minimumScaleFactor(0.85)
          .padding(.horizontal, 3)
          .padding(.top, 6)
        Text(detail)
          .font(.system(size: 10, weight: .medium, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(
            tile.isOn == true ? AnyShapeStyle(Style.brandInk) : AnyShapeStyle(.tertiary)
          )
          .lineLimit(1)
          .frame(height: 13)
          .padding(.top, 1)
        Spacer(minLength: 0)
      }
      .frame(width: Home.tile.width, height: Home.tile.height)
      .background {
        if selected {
          shape.fill(Style.selectedFill)
            .overlay(shape.contrastSelectionBorder())
            .matchedGeometryEffect(id: "selection", in: namespace)
        } else if model.hovered == index {
          shape.fill(Style.hoverFill)
        }
      }
      .contentShape(shape)
    }
    .buttonStyle(PressStyle())
    .animation(model.motion.animation(reduced: reduceMotion), value: model.selection)
    .background {
      // 浮层不激活本 App，SwiftUI 的 onHover 不可靠（同启动器的行、选状态的卡片）
      HoverTracker { inside in
        withAnimation(.easeOut(duration: 0.10)) {
          if inside { model.hovered = index } else if model.hovered == index { model.hovered = nil }
        }
      }
    }
    .help(tile.key.map { "\(tile.title)  \($0)" } ?? tile.title)
    .accessibilityLabel(tile.title)
    .accessibilityValue(accessibilityValue)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityAddTraits(tile.isOn != nil ? .isToggle : [])
  }

  @ViewBuilder private var icon: some View {
    if let isOn = tile.isOn {
      // 开关：圆，关着中性底，开着强调色（同控制中心）
      Image(systemName: tile.symbol)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(isOn ? AnyShapeStyle(Style.onBrand) : AnyShapeStyle(.primary))
        .frame(width: 30, height: 30)
        .background(
          isOn ? AnyShapeStyle(Style.brand) : AnyShapeStyle(Style.controlFill), in: .circle
        )
        .contentTransition(.symbolEffect(.replace))
    } else {
      KindTile(symbol: tile.symbol, color: tile.color, size: 30)
    }
  }

  /// 名字下面那一行：快捷键；开关开着时写开着是什么样（同启动器里这两项的副标题）
  private var detail: String {
    switch tile.target {
    case .extra(.pauseClipboard): tile.isOn == true ? "已暂停" : ""
    case .extra: tile.isOn == true ? "已开启" : ""
    case .action: tile.key ?? ""
    }
  }

  private var accessibilityValue: String {
    if let isOn = tile.isOn { return isOn ? "开" : "关" }
    return tile.key.map { "快捷键 \($0)" } ?? ""
  }
}

/// 按下缩到 0.97（Whisker §3 状态）
private struct PressStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
      .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
  }
}

/// 收按键的那块视图（同选状态的面板的 PickerKeys）：挂进窗口时把自己设成 initialFirstResponder 并当场拿焦点；不接点击
private struct HomeKeys: NSViewRepresentable {
  let model: HomeModel

  func makeNSView(context: Context) -> KeyView { KeyView() }
  func updateNSView(_ view: KeyView, context: Context) { view.model = model }

  final class KeyView: NSView {
    var model: HomeModel?

    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      window?.initialFirstResponder = self
      window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
      switch Home.key(code: Int(event.keyCode), modifiers: event.modifierFlags) {
      // Esc 走面板现成的路（OverlayPanel.cancelOperation → dismiss）
      case .cancel?: window?.cancelOperation(nil)
      case let key?: model?.handle(key)
      case nil: super.keyDown(with: event)
      }
    }
  }
}
