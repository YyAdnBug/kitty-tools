// 选一个状态再进（PLAN §10「状态屏」Z13a）：按状态屏的全局快捷键时先出的那块面板。每个状态一张卡片——缩小的画面
// （StatusPreview）+ 下面一行数字键帽和标题；一行最多 4 张，多了折行，放不下时在面板里滚。←→ ↑↓ Tab 选，
// 数字键 1–9、↩、单击进入；面板开着时再按一次全局快捷键 = 选中下一张（AppDelegate.pickStatus）。默认选中上次进入的那个。
// 面板本身是一个 OverlayPanel 实例（AppDelegate.statusPicker：Panel 皮肤，鼠标所在屏中央，不激活本 App），Esc、⌘W、
// 点外面关闭都走它现成的路。这时键盘鼠标还没有被拦；进不进得去仍由 StatusScreen.enter 管（没授权、正在录屏这些）。
// 面板里没有输入框：按键由一块当第一响应者的 NSView 收（keyDown 按键码，同钉图、截图遮罩），不用 SwiftUI 的 onKeyPress。
// 排版、选中怎么移动、按键对应什么、默认选中哪张都是纯函数（enum StatusPicker），单测锁住。

import AppKit
import Carbon.HIToolbox
import SwiftUI

enum StatusPicker {
  /// 卡片（缩小的画面）的大小：宽高比同 StatusPreview 的 1.6
  static let card = CGSize(width: 200, height: 125)
  /// 一行最多几张
  static let columns = 4
  /// 卡片四周留给选中那一圈的边（圈 2 pt，和卡片之间空 2 pt）
  static let ring: CGFloat = 4
  /// 卡片到下面那行字、那行字的高
  static let labelGap: CGFloat = 6
  static let labelHeight: CGFloat = 18
  /// 格子之间：横向、行间
  static let gap: CGFloat = 8
  static let rowGap: CGFloat = 12
  /// 面板四周内缩
  static let inset: CGFloat = 16
  /// 底下那行按键提示的高（同启动器的底栏）
  static let barHeight: CGFloat = 36
  /// 选中的那张放大到多少
  static let selectedScale: CGFloat = 1.04

  /// 一格 = 卡片连四周的边 + 下面那行字
  static let cell = CGSize(
    width: card.width + ring * 2, height: ring * 2 + card.height + labelGap + labelHeight)

  struct Layout: Equatable {
    let columns: Int
    let rows: Int
    /// 面板的大小
    let size: CGSize
    /// 卡片那一块比面板里放得下的高：在面板里滚
    let scrolls: Bool
  }

  /// count 个状态怎么排（纯函数）：一行最多 4 张，面板宽至少两格（底下那行按键提示放得下），高不超过 maxHeight
  /// （鼠标所在屏可见区的九成，至少露出一整行）——超了卡片那一块在面板里滚
  static func layout(count: Int, maxHeight: CGFloat) -> Layout {
    let count = max(count, 1)
    let columns = min(count, Self.columns)
    let rows = (count + Self.columns - 1) / Self.columns
    let full = inset * 2 + gridHeight(rows: rows) + barHeight
    let limit = max(maxHeight, inset * 2 + cell.height + barHeight)
    return Layout(
      columns: columns, rows: rows,
      size: CGSize(
        width: inset * 2 + gridWidth(columns: max(columns, 2)), height: min(full, limit)),
      scrolls: full > limit)
  }

  static func gridWidth(columns: Int) -> CGFloat {
    CGFloat(columns) * cell.width + CGFloat(columns - 1) * gap
  }

  static func gridHeight(rows: Int) -> CGFloat {
    CGFloat(rows) * cell.height + CGFloat(rows - 1) * rowGap
  }

  /// 第 index 张所在的那一行在滚动内容里的纵向区间（选中跟随滚动要露出来的，ListReveal）
  static func span(of index: Int) -> ClosedRange<CGFloat> {
    let top = inset + CGFloat(index / columns) * (cell.height + rowGap)
    return top...top + cell.height
  }

  /// 刚呼出时滚到哪（纯函数）：选中的那一行看不全就滚到露出它，看得见就在顶上
  static func initialScroll(selection: Int, layout: Layout) -> CGFloat {
    guard layout.scrolls else { return 0 }
    let span = span(of: selection)
    let visible = CGRect(
      x: 0, y: 0, width: layout.size.width, height: layout.size.height - barHeight)
    return ListReveal.target(
      top: span.lowerBound, bottom: span.upperBound, visible: visible, coveredTop: inset,
      inset: inset) ?? 0
  }

  enum Move { case left, right, up, down }

  /// 选中怎么移动（纯函数）：←→ 挨个走、到头回绕（Tab / ⇧Tab、面板开着时再按全局快捷键同 → ←）；↑↓ 换行、列不变，
  /// 到了第一行 / 最后一行就不动；下一行不满、正下方没有卡片时落在最后一张
  static func moved(_ selection: Int, _ move: Move, count: Int) -> Int {
    guard count > 0 else { return 0 }
    switch move {
    case .left: return (selection - 1 + count) % count
    case .right: return (selection + 1) % count
    case .up: return selection >= columns ? selection - columns : selection
    case .down:
      if selection + columns < count { return selection + columns }
      return selection / columns < (count - 1) / columns ? count - 1 : selection
    }
  }

  /// 默认选中哪张（纯函数）：上次进入的那个状态；没有记录、它已经被删了就是第一张
  static func selection(last: String?, in presets: [StatusPreset]) -> Int {
    presets.firstIndex { $0.id == last } ?? 0
  }

  enum Key: Equatable {
    case move(Move)
    /// 数字键：第几张（从 0 数）
    case pick(Int)
    case enter
    case cancel
  }

  /// 按键对应什么（纯函数）；nil = 不认识，交还给系统。带 ⌘⌃⌥ 的不管（⌘W 在 OverlayPanel 里）；⇧ 只对 Tab 有意义。
  /// 数字按键码认（主键盘上面那一排和小键盘的 1–9，同启动器、剪贴板的 ⌘1–9）：不看输入法和键盘布局
  static func key(code: Int, modifiers: NSEvent.ModifierFlags) -> Key? {
    guard modifiers.isDisjoint(with: [.command, .control, .option]) else { return nil }
    if let digit = digitKeys.firstIndex(of: code) { return .pick(digit % 9) }
    switch code {
    case kVK_LeftArrow: return .move(.left)
    case kVK_RightArrow: return .move(.right)
    case kVK_UpArrow: return .move(.up)
    case kVK_DownArrow: return .move(.down)
    case kVK_Tab: return .move(modifiers.contains(.shift) ? .left : .right)
    case kVK_Return, kVK_ANSI_KeypadEnter: return .enter
    case kVK_Escape: return .cancel
    default: return nil
    }
  }

  /// 前 9 个是主键盘的 1–9，后 9 个是小键盘的
  private static let digitKeys = [
    kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8,
    kVK_ANSI_9, kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4,
    kVK_ANSI_Keypad5, kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9,
  ]

  /// 底栏「直接进入」后面的键帽：有几张写到几（最多 9）
  static func digitsCap(count: Int) -> String {
    count > 1 ? "1–\(min(count, 9))" : "1"
  }
}

@Observable final class StatusPickerModel {
  private(set) var presets: [StatusPreset]
  private(set) var selection: Int
  private(set) var layout: StatusPicker.Layout
  /// 鼠标停在哪张上（没选中的那张铺 fill.hover）
  var hovered: Int?
  /// 每呼出一次加一：卡片那一块按它重建（滚动位置重新摆、悬停清掉）
  private(set) var shows = 0
  /// 选中换了走哪条曲线：键盘 snap，按住连发、刚呼出不动画
  private(set) var motion = Style.Motion.instant

  /// 各卡片此刻在面板里的位置（SwiftUI 坐标，画面报上来；滚出可见区的没有）：进入时画面从它长到整屏
  @ObservationIgnored var cardFrames: [Int: CGRect] = [:]
  /// 进入一个状态（AppDelegate 接上：收起面板、StatusScreen.enter）；第二个参数是那张卡片在面板里的位置
  @ObservationIgnored var onEnter: (StatusPreset, CGRect?) -> Void = { _, _ in }

  /// 截图自检直接摆出某个样子；正常使用建一个空的，每次呼出前 prepare
  init(
    presets: [StatusPreset] = [], selection: Int = 0, hovered: Int? = nil,
    maxHeight: CGFloat = .infinity
  ) {
    self.presets = presets
    self.selection = selection
    self.hovered = hovered
    layout = StatusPicker.layout(count: presets.count, maxHeight: maxHeight)
  }

  /// 呼出前：换成现在的状态列表，选中上次进入的那个，按屏幕能给的高度排版
  func prepare(_ presets: [StatusPreset], last: String?, maxHeight: CGFloat) {
    self.presets = presets
    selection = StatusPicker.selection(last: last, in: presets)
    layout = StatusPicker.layout(count: presets.count, maxHeight: maxHeight)
    hovered = nil
    cardFrames = [:]
    motion = .instant
    shows += 1
  }

  func move(_ move: StatusPicker.Move) {
    motion = Style.isKeyRepeat ? .instant : .snap
    selection = StatusPicker.moved(selection, move, count: presets.count)
  }

  /// 面板里的按键（Esc 不到这里：按键视图直接交给面板的 cancelOperation）
  func handle(_ key: StatusPicker.Key) {
    switch key {
    case .move(let move): self.move(move)
    case .pick(let index): enter(index)
    case .enter: enter(selection)
    case .cancel: break
    }
  }

  /// 进入第 index 张（数字键、↩、单击）；没有这一张就不做
  func enter(_ index: Int) {
    guard presets.indices.contains(index) else { return }
    onEnter(presets[index], cardFrames[index])
  }
}

struct StatusPickerView: View {
  let model: StatusPickerModel

  var body: some View {
    VStack(spacing: 0) {
      // 每次呼出重建：滚动位置、悬停都从头来
      PickerGrid(model: model).id(model.shows)
      bar
    }
    .background { PickerKeys(model: model) }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("选择状态")
  }

  /// 底栏：左边三条按键提示，右边主动作「进入 ↩」（能点）。样子同启动器的底栏
  private var bar: some View {
    HStack(spacing: 14) {
      hint("选择", "←→")
      hint("直接进入", StatusPicker.digitsCap(count: model.presets.count))
      hint("取消", "Esc")
      Spacer(minLength: 8)
      Button {
        model.enter(model.selection)
      } label: {
        HStack(spacing: 6) {
          Text("进入")
          KeyCap("↩", primary: true).accessibilityHidden(true)
        }
      }
      .accessibilityLabel("进入选中的状态")
    }
    .font(.system(size: 12))
    .lineLimit(1)
    .buttonStyle(.plain)
    .padding(.horizontal, 14)
    .frame(height: StatusPicker.barHeight)
    .overlay(alignment: .top) { Hairline() }
  }

  private func hint(_ text: String, _ key: String) -> some View {
    HStack(spacing: 6) {
      Text(text).foregroundStyle(.secondary)
      KeyCap(key)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(text)：\(key)")
  }
}

/// 卡片那一块：一行最多 4 张、行内靠左、整块在面板里居中；放不下时滚，选中的那一行跟着露出来
private struct PickerGrid: View {
  let model: StatusPickerModel
  @State private var position: ScrollPosition

  init(model: StatusPickerModel) {
    self.model = model
    var position = ScrollPosition()
    let y = StatusPicker.initialScroll(selection: model.selection, layout: model.layout)
    if y > 0 { position.scrollTo(y: y) }
    _position = State(initialValue: position)
  }

  var body: some View {
    if model.layout.scrolls {
      ScrollView { grid }
        .modifier(
          RevealsSelection(
            position: $position, key: model.selection, motion: model.motion,
            coveredTop: StatusPicker.inset, inset: StatusPicker.inset
          ) { StatusPicker.span(of: model.selection) })
    } else {
      grid
    }
  }

  private var grid: some View {
    let (count, columns) = (model.presets.count, StatusPicker.columns)
    return VStack(alignment: .leading, spacing: StatusPicker.rowGap) {
      ForEach(0..<model.layout.rows, id: \.self) { row in
        HStack(spacing: StatusPicker.gap) {
          ForEach(row * columns..<min(count, (row + 1) * columns), id: \.self) { index in
            PickerCard(model: model, index: index)
          }
        }
      }
    }
    .frame(width: StatusPicker.gridWidth(columns: model.layout.columns), alignment: .leading)
    .frame(maxWidth: .infinity)
    .padding(StatusPicker.inset)
  }
}

/// 一张卡片：缩小的画面（熄屏样式是纯黑，靠下面的标题认）+ 数字键帽（前 9 张）和标题。选中的外面一圈强调色、略微放大
/// （同通用页外观缩略图的选中画法）；没选中的悬停时整格铺 fill.hover；单击进入
private struct PickerCard: View {
  let model: StatusPickerModel
  let index: Int
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let preset = model.presets[index]
    let selected = model.selection == index
    let outer = RoundedRectangle(
      cornerRadius: Style.Radius.card + StatusPicker.ring, style: .continuous)
    Button {
      model.enter(index)
    } label: {
      VStack(spacing: StatusPicker.labelGap) {
        StatusPreview(preset: preset)
          .frame(width: StatusPicker.card.width, height: StatusPicker.card.height)
          // 进入时画面从这张卡片长到整屏：报它在面板里的位置（放大之后的）；滚出可见区的不报
          .onGeometryChange(for: CGRect.self) { proxy in
            let visible = proxy.bounds(of: .scrollView) ?? .infinite
            return CGRect(origin: .zero, size: proxy.size).intersects(visible)
              ? proxy.frame(in: .global) : .null
          } action: { frame in
            model.cardFrames[index] = frame.isNull ? nil : frame
          }
          .padding(StatusPicker.ring)
          .overlay {
            if selected { outer.strokeBorder(Style.brand, lineWidth: 2).transition(.opacity) }
          }
          // 只放大卡片：下面那行字不跟着动，各张的标题还在一条线上
          .scaleEffect(selected ? StatusPicker.selectedScale : 1)
        HStack(spacing: 6) {
          if index < 9 { KeyCap("\(index + 1)") }
          Text(preset.title)
            .font(.system(size: 13))
            .foregroundStyle(selected ? .primary : .secondary)
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .frame(width: StatusPicker.card.width, height: StatusPicker.labelHeight)
      }
      .background(model.hovered == index && !selected ? Style.hoverFill : .clear, in: outer)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .animation(model.motion.animation(reduced: reduceMotion), value: selected)
    .background {
      // 浮层不激活本 App，SwiftUI 的 onHover 不可靠（同启动器的行）
      HoverTracker { inside in
        withAnimation(.easeOut(duration: 0.10)) {
          if inside { model.hovered = index } else if model.hovered == index { model.hovered = nil }
        }
      }
    }
    .accessibilityLabel(preset.title)
    .accessibilityHint("进入这个状态")
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

/// 收按键的那块视图：挂进窗口时把自己设成 initialFirstResponder（OverlayPanel.present 会把焦点给它）并当场拿焦点
/// （面板里只有它要键盘：present 那一下它还没建出来也不怕）。不接点击；点面板别处焦点也不会走——鼠标点到的都是
/// SwiftUI 的宿主视图，它不接第一响应者（单测锁住）
private struct PickerKeys: NSViewRepresentable {
  let model: StatusPickerModel

  func makeNSView(context: Context) -> KeyView { KeyView() }
  func updateNSView(_ view: KeyView, context: Context) { view.model = model }

  final class KeyView: NSView {
    var model: StatusPickerModel?

    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      window?.initialFirstResponder = self
      window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
      switch StatusPicker.key(code: Int(event.keyCode), modifiers: event.modifierFlags) {
      // Esc 走面板现成的路（OverlayPanel.cancelOperation → dismiss）
      case .cancel?: window?.cancelOperation(nil)
      case let key?: model?.handle(key)
      case nil: super.keyDown(with: event)
      }
    }
  }
}
