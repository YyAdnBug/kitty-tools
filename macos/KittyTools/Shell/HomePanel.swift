// 主界面（2026-10-29 拍板「全部按推荐」，拍板页 macos/build/research/home-panel-2026-10-29/decisions.html）：一眼看到全部功能、
// 点一下就用的那块面板。内容和菜单栏菜单读同一份——HotKeyAction.sections 分节、同名同序（关着的功能不出现），每节末尾接上那一节
// 的 MenuExtra 里是动作的（有钉图时的两项）；有关着的功能时最下面一行「N 个功能关着 · 管理…」；别的 App 开着安全输入、
// 只带 ⌥ 的快捷键收不到时（issue #27，HotKeyCenter.secureInputBlock）再上面一行橙字说是哪个 App；底栏左边有新版本
// 时是「更新到 x」（UpdateBarHint），右边「设置 ⌘,」「退出 ⌘Q」。一格 = 30 pt 家族色块 + 名字 + 一行小字快捷键，一行 5 格；
// 功能各一节（只剩一格的不画标题、连着的并成一行），添加了的插件全收进最后一节「插件」（同设置侧栏的分组，2026-11-13）。
// **只放点一下就做的动作**（2026-11-13 拍板，对标托盘快捷面板的通行做法：面板放动作，开关放菜单里打勾）：开关
// （暂停记录剪贴板、复制即译）不占格子，在右键菜单、启动器里；「打开主界面」自己不在里面；「钉住剪贴板内容」也不列
// （剪贴板历史面板里就能钉，Home.unlisted），菜单栏菜单、启动器、快捷键照旧有它。格子点了面板先收起再做（同启动器的内置动作）。
// 面板是一个 OverlayPanel 实例（AppDelegate.homePanel：Panel 皮肤、不激活本 App、点外面收）。键盘：←→ ↑↓ Tab 选（一块中性
// 高亮滑过去），↩ / 空格执行，Esc 收起，⌘, 设置，⌘Q 退出；直接打字（字母、数字、标点）就收起主界面、在启动器里搜它（第四轮体检 X12）。
// 按键由一块当第一响应者的 NSView 收（同选状态的面板）。
// 分节、排版、选中怎么移动、按键对应什么都是纯函数（enum Home），单测锁住。

import AppKit
import Carbon.HIToolbox
import SwiftUI

enum Home {
  /// 一行几格
  static let columns = 5
  /// 一格：最长的名字（「划词翻译并替换」这类七八个字）11 pt 一行放得下
  static let tile = CGSize(width: 92, height: 76)
  /// 名字的第二行（多语言，2026-11-15：英文的名字长，一行放不下就折成两行）：11 pt 的一行
  static let secondLine: CGFloat = 13
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
  /// 「N 个功能关着 · 管理…」那一行（安全输入挡着快捷键那一行同高）
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
    /// 新功能标记（WhatsNew）：名字前面一个强调色小圆点
    var isNew = false
    /// 格子里写的名字放不下全称时的短说法（Home.shortTitle）；悬停提示、读屏照旧用 title
    var shortTitle: String? = nil

    /// 格子里写的名字
    var label: String { shortTitle ?? title }

    var id: String {
      switch target {
      case .action(let action): action.rawValue
      case .extra(let extra): "extra." + extra.rawValue
      }
    }
  }

  struct Section: Equatable {
    /// nil = 不画标题（只剩一格的功能并成的那一行）
    let title: String?
    let tiles: [Tile]
  }

  /// 主界面里不列的动作：「打开主界面」自己；「钉住剪贴板内容」（剪贴板历史面板里就能钉，这里不再摆一格）
  static let unlisted: Set<HotKeyAction> = [.home, .pinClipboard]

  /// 插件那一节的标题（同设置侧栏那一组的名字）
  static var pluginsTitle: String { String(localized: "插件") }

  /// 分节（纯函数）：和菜单栏菜单同一份（AppDelegate.buildStatusMenu），关着的功能不出现，unlisted 的不列；
  /// 每节末尾接那一节的 MenuExtra 里是动作的（开关不列：isOn 不是 nil 的）。功能只剩一格的节不画标题，和前面同样是一格的
  /// 并成一行；插件的格子不分节，按原来的先后全收进最后一节「插件」（只添加了一个也带标题，不会掉出孤零零的一格）。
  /// keys：各动作当前生效的快捷键（HotKeyCenter.bindings 的 display）；fresh：这一版新加、还没碰过的动作（WhatsNew），格子标小圆点
  static func sections(
    state: LauncherItem.ActionState, keys: [HotKeyAction: String], fresh: Set<HotKeyAction> = []
  ) -> [Section] {
    let extras = MenuExtra.allCases.filter {
      $0.section != nil && $0.isAvailable(state) && $0.isOn(state) == nil
    }
    var result: [Section] = []
    var plugins: [Tile] = []
    for section in HotKeyAction.visibleSections(enabled: state.features) {
      var tiles = section.actions.filter { !unlisted.contains($0) && state.lists($0) }.map {
        action in
        Tile(
          target: .action(action), title: action.title(recording: state.isRunning(action)),
          symbol: action.symbol, color: action.color, key: keys[action],
          isNew: fresh.contains(action), shortTitle: shortTitle(action))
      }
      for extra in extras where section.actions.contains(where: { $0 == extra.section }) {
        tiles.append(
          Tile(
            target: .extra(extra), title: extra.title(pinsHidden: state.pinsHidden == true),
            symbol: extra.symbol, color: extra.color, key: nil))
      }
      guard !tiles.isEmpty else { continue }
      if section.actions.first?.feature?.isPlugin == true {
        plugins += tiles
      } else if tiles.count > 1 {
        result.append(Section(title: section.title, tiles: tiles))
      } else if let last = result.last, last.title == nil {
        result[result.count - 1] = Section(title: nil, tiles: last.tiles + tiles)
      } else {
        result.append(Section(title: nil, tiles: tiles))
      }
    }
    if !plugins.isEmpty { result.append(Section(title: pluginsTitle, tiles: plugins)) }
    return result
  }

  /// 关着的功能有几个（纯函数）：只算这台系统上有、而且有入口（全局动作）的——程序坞预览没有全局动作，默认关着也不提；
  /// 没添加的插件不算（插件默认就不添加，不是「关着」）
  static func offCount(enabled: Set<Feature>, available: Set<Feature>) -> Int {
    available.subtracting(enabled).filter { feature in
      !feature.isPlugin && HotKeyAction.allCases.contains { $0.feature == feature }
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

  /// 格子里用短说法的动作（TRANSLATION.md 五）：「划词翻译并替换」英文全称折两行也放不下（会缩字），格子里写 Translate & Replace。
  /// 中文和全称一样
  static func shortTitle(_ action: HotKeyAction) -> String? {
    guard action == .translateReplace else { return nil }
    return String(
      localized: "home.translateReplace", defaultValue: "划词翻译并替换",
      comment: "短说法：主界面格子里「划词翻译并替换」的名字（英文全称两行也放不下）")
  }

  /// 名字一行放得下（格子宽减左右各 3；带「新」的小圆点再让出圆点 6 + 间距 3）
  static func fitsOneLine(_ tile: Tile) -> Bool {
    Style.fitsOneLine(tile.label, size: 11, width: Self.tile.width - 6 - (tile.isNew ? 9 : 0))
  }

  /// 格子的高（纯函数）：有一格的名字一行放不下（英文），整块面板的格子都高一行，排得齐；都放得下（中文）就是 tile.height
  static func tileHeight(_ sections: [Section]) -> CGFloat {
    let wraps = sections.contains { $0.tiles.contains { !fitsOneLine($0) } }
    return tile.height + (wraps ? secondLine : 0)
  }

  /// 面板的高（纯函数）：格子那一块 + 安全输入那一行、关着的功能那一行（有才有）+ 底栏
  static func height(_ sections: [Section], offCount: Int, secureInput: Bool = false) -> CGFloat {
    var height = top + bottom
    let tileHeight = tileHeight(sections)
    for (index, section) in sections.enumerated() {
      height += section.title != nil ? titleHeight : (index == 0 ? 0 : untitledGap)
      let rows = CGFloat((section.tiles.count + columns - 1) / columns)
      height += rows * tileHeight + (rows - 1) * gap
    }
    return height + (offCount > 0 ? noteHeight : 0) + (secureInput ? noteHeight : 0) + barHeight
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

  /// 打字转到启动器（第四轮体检 X12）：不带 ⌘⌃⌥、打出来的是能显示的字（字母、数字、标点、符号；空格是执行选中的那格，
  /// 不算）就给这段字，别的 nil（纯函数）
  static func typed(_ characters: String?, modifiers: NSEvent.ModifierFlags) -> String? {
    guard modifiers.isDisjoint(with: [.command, .control, .option]), let characters,
      !characters.isEmpty,
      characters.unicodeScalars.allSatisfy({ scalar in
        !scalar.properties.isWhitespace && scalar.value >= 0x20 && scalar.value != 0x7F
          && !(0xF700...0xF8FF).contains(scalar.value)  // 方向键、功能键这类私用区
      })
    else { return nil }
    return characters
  }

  /// 面板里的 ⌘ 组合（纯函数）：⌘, 设置、⌘Q 退出（同菜单栏菜单的键）。code 是 NSEvent.typedKeyCode（按打出来的字认，E2）；
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
  /// 安全输入挡着只带 ⌥ 的快捷键（打开时看的那一眼）；没挡着 nil
  private(set) var secureInput: HotKeyCenter.SecureInputBlock?
  /// 设置里有只在那里才有入口的新功能（WhatsNew.inSettingsOnly）：底栏「设置」前面一个小圆点
  private(set) var settingsIsNew: Bool
  /// 同步（AppDelegate 每次呼出前接上）：底栏「设置」的橙点直接读它的 needsAttention——那是被观察的，主界面开着时状态
  /// 变了也跟着变（第五轮体检 U1）
  @ObservationIgnored weak var syncer: NoteSyncer?
  /// 截图自检直接摆的（没接同步时用它）
  private let pinnedTrouble: Bool
  /// 同步停了、该让人知道了：底栏「设置」前面一个橙色小圆点（盖过「新」的那个）
  var syncTrouble: Bool { syncer?.needsAttention ?? pinnedTrouble }
  /// 键盘选中的那一格；没按过方向键时没有（打开时不画高亮）
  private(set) var selection: Int?
  /// 鼠标停在哪一格上（没选中的那格铺 fill.hover）
  var hovered: Int?
  /// 选中换了走哪条曲线：键盘 snap，按住连发不动画
  private(set) var motion = Style.Motion.instant

  /// 做一件事（AppDelegate 接上：动作走 run(action)，菜单栏那几项走 run(extra)）
  @ObservationIgnored var perform: (Home.Tile.Target) -> Void = { _ in }
  /// 「管理…」：设置 › 通用 ›「功能」
  @ObservationIgnored var openFeatures: () -> Void = {}
  /// 收起面板（不放淡出：接下来要做的事要面板已经不在屏幕上）
  @ObservationIgnored var hidePanel: () -> Void = {}
  /// 打了字（X12）：收起主界面、打开启动器、把这一下按键原样交给它的输入框（AppDelegate 接；启动器关着时响一声）。
  /// 交的是按键不是字：开着拼音时这一下要进输入法组字，直接填字会把第一个字母拆出去（同 issue #30）
  @ObservationIgnored var typeToLauncher: (NSEvent) -> Void = { _ in }

  /// 截图自检直接摆出某个样子；正常使用建一个空的，每次呼出前 update
  init(
    sections: [Home.Section] = [], offCount: Int = 0,
    secureInput: HotKeyCenter.SecureInputBlock? = nil, settingsIsNew: Bool = false,
    syncTrouble: Bool = false, selection: Int? = nil, hovered: Int? = nil
  ) {
    self.sections = sections
    self.offCount = offCount
    self.secureInput = secureInput
    self.settingsIsNew = settingsIsNew
    pinnedTrouble = syncTrouble
    self.selection = selection
    self.hovered = hovered
  }

  var tiles: [Home.Tile] { sections.flatMap(\.tiles) }
  var tileHeight: CGFloat { Home.tileHeight(sections) }
  var size: CGSize {
    CGSize(
      width: Home.width,
      height: Home.height(sections, offCount: offCount, secureInput: secureInput != nil))
  }

  /// 换成现在的样子。appearing：新呼出（选中、悬停清掉）；开着时再排一遍选中留着
  func update(
    _ sections: [Home.Section], offCount: Int, secureInput: HotKeyCenter.SecureInputBlock? = nil,
    settingsIsNew: Bool = false, appearing: Bool
  ) {
    self.sections = sections
    self.offCount = offCount
    self.secureInput = secureInput
    self.settingsIsNew = settingsIsNew
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

  /// 点了 / 按了第 index 格：先收起面板再做
  func activate(_ index: Int) {
    guard tiles.indices.contains(index) else { return }
    hidePanel()
    perform(tiles[index].target)
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
      if let block = model.secureInput { secureInputNote(block) }
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
    let tileHeight = model.tileHeight
    return VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(model.sections.enumerated()), id: \.offset) { index, section in
        if let title = section.title {
          Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Style.metaText)
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
                  height: tileHeight, namespace: selection)
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
        .accessibilityHint("打开 设置 › 通用 › 功能，打开或关掉功能")
    }
    .font(.system(size: 11))
    .padding(.leading, Home.inset + 10)
    .frame(maxWidth: .infinity, minHeight: Home.noteHeight, alignment: .leading)
  }

  /// 「「Google Chrome」开着安全输入，⌥ 快捷键暂时不响应」：橙字（同快捷键页注册失败的那行），悬停说为什么、按开着它的 App
  /// 怎么关、哪些不受影响（SecureInputBlock.explanation）。只是告诉人为什么没反应，不给按钮——能做的是让那个 App 把安全输入关掉，
  /// 或者把快捷键换成带 ⌘ / ⌃ 的、连按两下
  private func secureInputNote(_ block: HotKeyCenter.SecureInputBlock) -> some View {
    // App 名原样显示（Text(String) 不按 Markdown 解析）
    Text(block.summary)
      .foregroundStyle(Color(nsColor: .systemOrange))
      .font(.system(size: 11))
      .lineLimit(1)
      .truncationMode(.middle)
      .help(block.explanation)
      .padding(.leading, Home.inset + 10)
      .padding(.trailing, Home.inset)
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

  private func barButton(
    _ title: LocalizedStringResource, key: String, _ extra: MenuExtra
  ) -> some View {
    Button {
      model.run(extra)
    } label: {
      HStack(spacing: 6) {
        // 同步停了（U1）：橙色小圆点，好了自己没；不然设置里有新的（只在那里才有入口的）：强调色小圆点（拍板 A4）
        if isTroubled(extra) {
          Circle()
            .fill(Color(nsColor: .systemOrange))
            .frame(width: 6, height: 6)
        } else if isNew(extra) {
          NewDot()
        }
        Text(title)
        KeyCap(key).accessibilityHidden(true)
      }
      .contentShape(.rect)
    }
    .help(isTroubled(extra) ? Text("同步停了：到 设置 › 通用 › 同步 里看为什么") : Text(verbatim: ""))
    .accessibilityLabel(
      extra == .quit
        ? String(localized: "退出 Kitty Tools")
        : String(localized: "设置")
          + (isTroubled(extra) ? Island.comma + String(localized: "同步停了") : "")
          + (isNew(extra) ? Island.comma + WhatsNew.spoken : ""))
  }

  private func isNew(_ extra: MenuExtra) -> Bool {
    extra == .settings && model.settingsIsNew
  }

  private func isTroubled(_ extra: MenuExtra) -> Bool {
    extra == .settings && model.syncTrouble
  }
}

/// 一格：色块 + 名字 + 快捷键。键盘选中的那格垫一块中性高亮（matchedGeometryEffect
/// 在格子间滑过去：格子是固定的、不会被回收，不同于长列表的 offset 写法）；没选中的悬停铺 fill.hover
private struct HomeTile: View {
  let model: HomeModel
  let tile: Home.Tile
  let index: Int
  /// Home.tileHeight：一块面板里的格子一样高
  let height: CGFloat
  let namespace: Namespace.ID
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let selected = model.selection == index
    let wraps = height > Home.tile.height
    let shape = RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
    Button {
      model.activate(index)
    } label: {
      VStack(spacing: 0) {
        KindTile(symbol: tile.symbol, color: tile.color, size: 30).padding(.top, 9)
        // 新功能：名字前面一个小圆点（iOS 主屏新装 App 的那种，拍板 A1）
        // 英文的名字长：一行放不下时整块面板的格子高一行（Home.tileHeight），名字折成两行、居中；这时每格的名字都占两行高、
        // 顶对齐，一行的和两行的格子里快捷键在同一高度（第五轮体检 U3②：原来两行的那格快捷键往下掉一行）。
        // 不折的时候（中文）照旧一行，和以前一个像素都不差
        ZStack(alignment: .top) {
          if wraps {
            Text(verbatim: "A\nA").font(.system(size: 11)).lineLimit(2).hidden()
              .accessibilityHidden(true)
          }
          HStack(spacing: 3) {
            if tile.isNew { NewDot() }
            Text(tile.label)
              .font(.system(size: 11))
              .lineLimit(wraps ? 2 : 1)
              .multilineTextAlignment(wraps ? .center : .leading)
              .minimumScaleFactor(0.85)
          }
        }
        .padding(.horizontal, 3)
        .padding(.top, 6)
        Text(tile.key ?? "")
          .font(.system(size: 10, weight: .medium, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(.tertiary)
          .lineLimit(1)
          .frame(height: 13)
          .padding(.top, 1)
        Spacer(minLength: 0)
      }
      .frame(width: Home.tile.width, height: height)
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
    .accessibilityLabel(tile.isNew ? tile.title + Island.comma + WhatsNew.spoken : tile.title)
    .accessibilityValue(tile.key.map { String(localized: "快捷键 \($0)") } ?? "")
    .accessibilityAddTraits(selected ? .isSelected : [])
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
      case nil:
        // 打字转到启动器搜索（X12）：按字母大概率是想搜东西
        if Home.typed(event.characters, modifiers: event.modifierFlags) != nil {
          model?.typeToLauncher(event)
        } else {
          super.keyDown(with: event)
        }
      }
    }
  }
}
