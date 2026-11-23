// 剪贴板列表的一行（Lens Bar，mac-whisker §6 剪贴板）：40 pt，24 pt 图标块（色块 > 缩略图 > 来源 App 图标 + 代码角标
// > 网站图标 / 种类图标），标题 13 regular 单行（代码 / JSON 用 SF Mono 12；有搜索词时从第一个命中处摘录、命中词黄底），
// 右侧 11 pt「来源 · 多久前」（有备注时换成备注），再右是收藏夹 / 带格式 / 片段 / 收藏标记；
// 标题已经把整条文本原样显示全的（showsWholeText），透镜不再画第二遍、有搜索词也不摘录；
// ⌘1–9 键帽只在按住 ⌘ 时出现。选中是列表背后一块滑动的中性高亮（透镜的底），行本身不填色、文字不反白；
// 多选时最左边多一个品牌粉勾选圆，勾中的行品牌粉 0.14 底。选中行在它下面展开透镜（LensView）。
// 图片行（设置「列表里直接显示图片」，默认开，2026-11-20）：64 高，图标块换成来源 App，标题那一格是一张 48 高的图（RowPicture，
// 从顶上裁）+ 宽×高；选中时这张图在原地长到 108 高、整张放在棋盘格上（透镜只剩元信息行，同一张图不画两遍）。
// 行内用到的摘要文字、图标与取色缓存、缩略图也放在这里。

import AppKit
import SwiftUI

struct ClipRowView: View {
  let item: ClipItem
  let form: ContentForm?
  /// 搜索词：标题从命中处摘录、命中词高亮
  var query = ""
  /// 0...8：显示 ⌘1…⌘9
  let shortcutIndex: Int?
  /// 按住 ⌘：把 ⌘数字键帽亮出来
  let showsShortcut: Bool
  /// nil = 不在多选状态
  let isChecked: Bool?
  /// 所在收藏夹的名字：只在收藏夹筛选为「全部」时传
  let groupName: String?
  let images: ImageStore
  /// 图片行：标题那一格画图（只对图片条目、设置开着时传 true）
  var picture = false
  /// 图片行选中展开：图长到 108 高，各格顶对齐
  var expanded = false
  /// 面板这次呼出的时刻：只当刷新的由头（行按值比较，不传的话条目没变时「多久前」一直是上次画的）
  var shownAt = Date.distantPast
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  static let height: CGFloat = 40
  /// 图片行：64 高，图 48 高、上下各留 8；展开时图 108 高（同原来透镜里的图），行头只剩上面 8
  static let pictureRowHeight: CGFloat = 64
  static let pictureHeight: CGFloat = 48
  static let expandedPictureHeight: CGFloat = 108
  static let picturePadding: CGFloat = 8

  /// 一行没展开时的高：图片行 64，其余 40（ListLayout、窗口高度都按它累加）
  static func height(of item: ClipItem, imageRows: Bool) -> CGFloat {
    imageRows && item.kind == .image ? pictureRowHeight : height
  }

  /// 图片行里那张图的框（点）。平时高 48、宽按比例夹在 0.75–5 倍高（手机截图、长截图不至于成一条缝，从顶上裁；
  /// 超宽的横幅不占满整行）；展开时高 108、宽 60–360（同原来透镜里的图，整张放进去、两边垫棋盘格）
  static func pictureSize(_ image: ClipItem.ImageInfo?, expanded: Bool) -> CGSize {
    let ratio = image.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) } ?? 1.5
    if expanded {
      return CGSize(
        width: min(max(expandedPictureHeight * ratio, 60), 360), height: expandedPictureHeight)
    }
    return CGSize(
      width: min(max(pictureHeight * ratio, pictureHeight * 0.75), pictureHeight * 5),
      height: pictureHeight)
  }
  /// 行内间距、左右内边距、右侧文字最宽：布局和 showsWholeText 的宽度预算共用
  private static let spacing: CGFloat = 10
  private static let padding: CGFloat = 10
  private static let trailingMax: CGFloat = 220

  var body: some View {
    // 每一格都放在 40 高的一条里：普通行就是这一行；图片行平时居中（在 64 的正中），展开时顶对齐——图标块、右侧文字、
    // 键帽留在最上面这一条里，图往下长（位置变化跟着选中那次 transaction 动画）
    HStack(alignment: expanded ? .top : .center, spacing: Self.spacing) {
      if let isChecked {
        Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 15))
          .foregroundStyle(isChecked ? Style.brand : .secondary)
          .contentTransition(.symbolEffect(.replace))
          .frame(height: Self.height)
      }
      IconTile(item: item, form: form, images: images, showsThumbnail: !picture)
        .frame(height: Self.height)
      if picture {
        RowPicture(item: item, images: images, expanded: expanded)
          .padding(.top, Self.picturePadding)
          .padding(.bottom, expanded ? 0 : Self.picturePadding)
        // 宽×高（靠识别文字搜到的接命中那段）；展开后宽×高在元信息行里有、不画第二遍，
        // 但搜到图中文字的照样留着（看得出为什么命中：搜索时第一条就是选中展开的）
        Text(title)
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(height: Self.height)
          .opacity(expanded && !matchesText ? 0 : 1)
          .accessibilityLabel(item.title)
      } else {
        Text(title)
          .font(
            form == .code || form == .json
              ? .system(size: 12, design: .monospaced) : .system(size: 13)
          )
          .lineLimit(1)
          .truncationMode(.tail)
      }
      Spacer(minLength: 8)
      // 右侧文字、标记、星标是一组，星标自己带它前面的间距：没收藏时星标宽 0、间距也是 0（直接放在外层 HStack 里的话，
      // 宽 0 的星标仍占一个间距，没收藏的行右侧文字比分组横线、键帽往里缩 10 pt）
      HStack(spacing: 0) {
        HStack(spacing: Self.spacing) {
          trailing
            .font(.system(size: 11))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: Self.trailingMax, alignment: .trailing)
            .layoutPriority(1)
          if let groupName {
            Text(groupName)
              .font(.system(size: 10, weight: .medium))
              .lineLimit(1)
              .padding(.horizontal, 6)
              .frame(height: 16)
              .background(
                Style.controlFill, in: .rect(cornerRadius: Style.Radius.control, style: .continuous)
              )
          }
          if item.richType != nil {
            // 带格式（RTF / HTML）。textformat 在中文系统上画成「格式」两个字；B I U 不跟系统语言换字形
            Image(systemName: "bold.italic.underline").imageScale(.small).foregroundStyle(.tertiary)
              .help("带格式")
          }
          if item.isSnippet {
            Image(systemName: "text.badge.star").imageScale(.small).foregroundStyle(.secondary)
              .help("片段")
          }
        }
        Image(systemName: "star.fill")
          .font(.system(size: 11))
          .foregroundStyle(Color(nsColor: .systemYellow))
          .opacity(item.favorite ? 1 : 0)
          .scaleEffect(item.favorite || reduceMotion ? 1 : 0.4)
          .symbolEffect(.bounce, value: item.favorite)
          // 宽度和前面的间距都在动画里：收藏时星星挤开旁边的标记，而不是跳
          .frame(width: item.favorite ? nil : 0)
          .padding(.leading, item.favorite ? Self.spacing : 0)
          .animation(Style.Motion.pop.animation(reduced: reduceMotion), value: item.favorite)
          .accessibilityLabel(item.favorite ? "已收藏" : "")
      }
      .frame(height: Self.height)
      // 和原来右侧文字那一格一样先分到宽度（里面那一格最宽 220），剩下的才是标题的
      .layoutPriority(1)
      // 没按 ⌘ 时不在布局里（占着宽度和间距的话，前九行的标题比别的行早截断）
      if isChecked == nil, let shortcutIndex, showsShortcut {
        KeyCap("⌘\(shortcutIndex + 1)")
          .frame(height: Self.height)
          .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9)))
      }
    }
    .animation(
      reduceMotion
        ? .easeOut(duration: 0.12)
        : .easeOut(duration: 0.12).delay(Double(shortcutIndex ?? 0) * 0.015), value: showsShortcut
    )
    .padding(.horizontal, Self.padding)
    .frame(
      height: !picture
        ? Self.height
        : expanded ? Self.picturePadding + Self.expandedPictureHeight : Self.pictureRowHeight,
      alignment: .top
    )
    .background(
      isChecked == true ? Style.brand.opacity(0.14) : .clear,
      in: .rect(cornerRadius: Style.Radius.card, style: .continuous)
    )
  }

  /// 图片是靠识别文字搜到的（标题后面接着命中那段）
  private var matchesText: Bool {
    guard !query.isEmpty, let ocr = item.ocrText else { return false }
    return Search.firstHit(in: ocr, query: query) != nil
  }

  /// 标题：有搜索词且命中不在开头时从命中处摘录（前 12 字 + 「…」），命中词黄底。
  /// 图片靠识别文字搜到的，「图片 宽×高」后面接上命中的那段识别文字（图片行里图已经在前面，只写「宽×高」）
  private var title: AttributedString {
    // 宽高按原样的数字插（同 ClipItem.title：插 Int 会按语言加千分位）
    let full =
      picture
      ? item.image.map { "\(String($0.width))×\(String($0.height))" } ?? item.title
      : Self.title(of: item)
    guard !query.isEmpty else { return AttributedString(full) }
    var shown = full
    switch item.kind {
    case .text:
      // 标题本来就显示得全的不摘录：这时透镜没有正文区，摘录会把开头藏起来。
      // 多选时行首多一个勾选圆、标题列变窄（透镜也收着），照旧摘录
      if isChecked != nil || !Self.showsWholeText(item) {
        let text = String((item.text ?? "").prefix(20_000))
        shown = Search.excerpt(of: text, query: query, before: 12, after: 160) ?? full
      }
    case .image:
      if let ocr = item.ocrText, Search.firstHit(in: ocr, query: query) != nil {
        shown =
          full + " · "
          + (Search.excerpt(of: ocr, query: query, before: 12, after: 160)
            ?? String(ocr.prefix(200)))
      }
    case .file:
      shown = Search.excerpt(of: full, query: query, before: 12, after: 160) ?? full
    }
    var attributed = AttributedString(shown.collapsingWhitespace())
    attributed.highlight(query)
    return attributed
  }

  /// 标题已经把整条文本原样显示出来了：去掉首尾空白后和标题一字不差（一行，没有被压成一个空格的连续空白），
  /// 而且标题列最窄时也放得下。这时透镜不再把同一句话画第二遍（Lens.bodyHeight 给 0，只剩元信息行），
  /// 有搜索词时标题也不摘录。透镜的高度进前缀和，所以只看条目自己的数据（纯函数，不读时间、修饰键、系统设置）：
  /// ⌘数字键帽和常显的滚动条都当它在——真的标题列只会比这里算的宽（352 – 406 pt 减去标记；
  /// ClipboardPanelTests.wholeTitleIsNotTruncated 把行画出来对过）。
  /// ponytail: 收藏夹筛选为「全部」时行尾多一个收藏夹胶囊，没算进来：收藏夹名超过三个字、标题又贴着上限时
  /// 会被截掉几个字（⌘Y 看全文）；真碰到再把收藏夹名的宽度传进来
  static func showsWholeText(_ item: ClipItem) -> Bool {
    // 标题列再宽也放不下 400 字节（最窄的字母也有 3 pt 多）；长文本不在这里整段去空白
    guard item.kind == .text, let text = item.text, text.utf8.count <= 400 else { return false }
    let key = WholeTextKey(
      text: text, rich: item.richType != nil, snippet: item.isSnippet, favorite: item.favorite)
    if let cached = wholeTexts[item.id], cached.key == key { return cached.shows }
    let shows = measureWholeText(item, text: text)
    wholeTexts[item.id] = (key, shows)
    return shows
  }

  /// 判定用到的条目数据：缓存连它一起记、取的时候比（正文没变时两边是同一块存储，比较当场返回）
  private struct WholeTextKey: Equatable {
    let text: String
    let rich: Bool
    let snippet: Bool
    let favorite: Bool
  }

  /// showsWholeText、行标题按条目缓存（美化与提速 P3）：有搜索词时每一行的标题都要问一次、透镜高度也要，
  /// 量一次字宽、去一次空白（正则）各要几十微秒，打一个字就是几十行。收起面板时裁掉删了的（prune）
  private static var wholeTexts: [UUID: (key: WholeTextKey, shows: Bool)] = [:]
  private static var titles: [UUID: (text: String, title: String)] = [:]

  /// 文本条目的行标题（ClipItem.title，按条目缓存）；别的种类现算（不贵）
  static func title(of item: ClipItem) -> String {
    guard item.kind == .text, let text = item.text else { return item.title }
    if let cached = titles[item.id], cached.text == text { return cached.title }
    let title = item.title
    titles[item.id] = (text, title)
    return title
  }

  /// 收起面板时（ClipboardPanelModel.reset）：删掉的条目不留在两张缓存里
  static func prune(keeping live: Set<UUID>) {
    wholeTexts = wholeTexts.filter { live.contains($0.key) }
    titles = titles.filter { live.contains($0.key) }
  }

  private static func measureWholeText(_ item: ClipItem, text: String) -> Bool {
    let title = title(of: item)
    guard title == text.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
    // 标题列最窄时：行宽 − 常显的滚动条 16 − 左右内边距 − 图标块 − 三处固定间距（图标后、Spacer 两边）
    // − Spacer 最窄 8 − 右侧文字那一格（带 maxWidth 的 frame 有多少占多少，字再短也占满 220）
    // − ⌘数字键帽（⌘9 约 27.4）连它前面的间距
    var room =
      ClipboardPanelView.width - 2 * ClipboardPanelView.inset - 16 - 2 * padding - IconTile.side
      - 3 * spacing - 8 - trailingMax - (spacing + 28)
    // 标记各连它前面的间距（星标没收藏时连间距都不占）；宽度是 SF Symbols 实测后取整：带格式 23、片段 14、星标 15
    if item.richType != nil { room -= spacing + 24 }
    if item.isSnippet { room -= spacing + 16 }
    if item.favorite { room -= spacing + 16 }
    let width = (title as NSString).size(
      withAttributes: [.font: NSFont.systemFont(ofSize: 13)]
    ).width
    return ceil(width) <= room
  }

  /// 右侧：有备注时是备注（Style.noteText，所有条目都能写，体检 A3），否则「来源 · 多久前」（Style.metaText）
  @ViewBuilder private var trailing: some View {
    if let note = item.note, !note.isEmpty {
      Text(note).foregroundStyle(Style.noteText)
    } else {
      // 跟着界面语言（Locale.current）：「31秒钟前」/「31 seconds ago」
      let ago = item.copiedAt.formatted(.relative(presentation: .named))
      Text([item.sourceTitle, ago].compactMap { $0 }.joined(separator: " · "))
        .foregroundStyle(Style.metaText)
    }
  }
}

/// 行首 24 pt 图标块（圆角 tile(24)）：颜色 = 色块（透明时垫棋盘格）；图片 = 缩略图；文本 = 来源 App 图标，
/// JSON / 代码 / 链接在右下角加 11 pt 角标（链接取过预览后是网站图标）；都没有时是网站图标或种类图标。
/// 新条目插进来时 0.85→1（pop，只播一次，见 IconPop）。拖动预览（ClipDrag）也用它
struct IconTile: View {
  let item: ClipItem
  let form: ContentForm?
  let images: ImageStore
  /// 图片画缩略图；图片行里图另有一格，这里是来源 App（没有就是种类图标）
  var showsThumbnail = true
  @AppStorage(Prefs.clipboardLinkPreview) private var showsLinkPreview = true
  @Environment(\.clipRowArriving) private var arriving

  static let side: CGFloat = 24
  static let badge: CGFloat = 11

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Style.Radius.tile(Self.side), style: .continuous)
    // 角标也按色块公式取圆角（边长 × 0.225），和它贴着的图标块一个比例
    let badgeShape = RoundedRectangle(
      cornerRadius: Style.Radius.tile(Self.badge), style: .continuous)
    Group {
      if form == .color, let color = ContentForm.color(in: item.text ?? "") {
        shape.fill(Color(color))
          .background(Checkerboard(cell: 4).clipShape(shape))
          .overlay(shape.strokeBorder(Style.swatchRim, lineWidth: 1))
      } else if item.kind == .image, showsThumbnail {
        // 先定框再裁：fill 的图比框宽（长截图 5:1），只裁自己的边界会溢出盖住标题
        ThumbnailView(id: item.id, images: images, maxPixel: ThumbnailView.iconPixel)
          .frame(width: Self.side, height: Self.side)
          .clipShape(shape)
          .overlay(shape.hairlineBorder())
      } else if let icon = AppIcons.icon(for: item.sourceBundleID) {
        Image(nsImage: icon).resizable().scaledToFit()
          .overlay(alignment: .bottomTrailing) {
            if let form, form != .color {
              Group {
                // 链接取过预览后，角标换成网站图标
                if let favicon {
                  Image(nsImage: favicon).resizable().interpolation(.high).padding(1)
                } else {
                  Image(systemName: form.symbol).font(.system(size: 6, weight: .bold))
                }
              }
              .frame(width: Self.badge, height: Self.badge)
              .background(.regularMaterial, in: badgeShape)
              .overlay(badgeShape.hairlineBorder())
              .offset(x: 2, y: 2)
            }
          }
      } else if let favicon {
        Image(nsImage: favicon).resizable().interpolation(.high)
          .clipShape(shape)
          .overlay(shape.hairlineBorder())
      } else {
        Image(systemName: form?.symbol ?? item.kind.symbol)
          .font(.system(size: 11, weight: .medium))
          .symbolRenderingMode(.hierarchical)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Style.controlFill, in: shape)
      }
    }
    .frame(width: Self.side, height: Self.side)
    .scaleEffect(arriving ? 0.85 : 1)
    .animation(Style.Motion.pop.animation(), value: arriving)
    .accessibilityHidden(true)
  }

  private var favicon: NSImage? {
    form == .link && showsLinkPreview ? LinkPreview.shared.favicon(forLink: item.text ?? "") : nil
  }
}

/// 图片行里的那张图（ClipRowView.picture）：平时填满 48 高的框、从顶上裁（长截图看得到开头），用按框算的那一档缩略图
/// （ThumbnailView.rowPixel）；选中展开时框长到 108 高，换成透镜那一档、整张放在 8 pt 棋盘格上（同原来透镜里的图）。
/// 两层交叉淡入淡出，框的大小跟着选中那次 transaction 走
private struct RowPicture: View {
  let item: ClipItem
  let images: ImageStore
  let expanded: Bool

  var body: some View {
    let size = ClipRowView.pictureSize(item.image, expanded: expanded)
    let shape = RoundedRectangle(cornerRadius: Style.Radius.control, style: .continuous)
    ZStack {
      Checkerboard(cell: 8).opacity(expanded ? 1 : 0)
      // 先定框再裁：fill 的图比框大，靠 frame 的 .top 让多出来的落在下面被裁掉
      ThumbnailView(id: item.id, images: images, maxPixel: ThumbnailView.rowPixel(for: item.image))
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipped()
        .opacity(expanded ? 0 : 1)
      if expanded {
        ThumbnailView(
          id: item.id, images: images, maxPixel: ThumbnailView.lensPixel, contentMode: .fit
        )
        .clipShape(shape)
        .transition(.opacity)
      }
    }
    .frame(width: size.width, height: size.height)
    .clipShape(shape)
    .overlay(shape.hairlineBorder())
    .accessibilityHidden(true)
  }
}

extension EnvironmentValues {
  /// 这一行正随插入过渡出现（IconPop）
  @Entry var clipRowArriving = false
}

/// 行插入过渡里带上它：把「正在插入」写进环境，IconTile 自己按 pop 从 0.85 长到 1。
/// 所以只在列表真的插入一行时播（新复制进来、撤销删除）：搜索 / 筛选换列表那一帧不动画、
/// 滚动时新进可见区附近的行不算插入（不在动画里改，见 ClipboardPanelView.list），都不播；减弱动态效果时行只淡入，不带它
struct IconPop: Transition {
  func body(content: Content, phase: TransitionPhase) -> some View {
    content.environment(\.clipRowArriving, phase == .willAppear)
  }
}

/// 棋盘格底（透明色、透明图片下面）
struct Checkerboard: View {
  var cell: CGFloat = 8

  var body: some View {
    Canvas { context, size in
      let columns = Int(ceil(size.width / cell))
      let rows = Int(ceil(size.height / cell))
      context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.primary.opacity(0.04)))
      for row in 0..<rows {
        for column in 0..<columns where (row + column) % 2 == 0 {
          context.fill(
            Path(
              CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)),
            with: .color(.primary.opacity(0.08)))
        }
      }
    }
  }
}

extension ClipItem.Kind {
  var symbol: String {
    switch self {
    case .text: "text.alignleft"
    case .image: "photo"
    case .file: "doc"
    }
  }

  var titleResource: LocalizedStringResource {
    switch self {
    case .text: "文本"
    case .image: "图片"
    case .file: "文件"
    }
  }

  var title: String { String(localized: titleResource) }
}

extension ContentForm {
  var symbol: String {
    switch self {
    case .color: "paintpalette"
    case .json: "curlybraces"
    case .link: "link"
    case .code: "chevron.left.forwardslash.chevron.right"
    }
  }
}

extension ClipItem {
  /// 列表里的一行摘要
  var title: String {
    switch kind {
    case .text:
      return String((text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        .collapsingWhitespace()
    case .image:
      guard let image else { return String(localized: "图片") }
      // 宽高按原样的数字插（插 Int 会按语言加千分位：1,200×240）
      return String(localized: "图片 \(String(image.width))×\(String(image.height))")
    case .file:
      let names = (filePaths ?? []).map { URL(filePath: $0).lastPathComponent }
      return names.count == 1 ? names[0] : names.joinedAsList()
    }
  }
}

extension String {
  /// 连续的空白（含换行）压成一个空格：同 `replacing(/\s+/, with: " ")`（\s 按字符就是 Character.isWhitespace），
  /// 不建正则——行标题每画一次都要，正则一次几十微秒（光建正则就占一半），搜索时几十行一起来（美化与提速 P3）
  nonisolated func collapsingWhitespace() -> String {
    var result = ""
    result.reserveCapacity(utf8.count)
    var inSpace = false
    for character in self {
      if character.isWhitespace {
        if !inSpace { result.append(" ") }
        inSpace = true
      } else {
        result.append(character)
        inSpace = false
      }
    }
    return result
  }
}

extension Color {
  init(_ rgba: ContentForm.RGBA) {
    self.init(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
  }
}

/// 来源 App 图标与取色（按 bundle ID 缓存；App 被卸载时为 nil）
enum AppIcons {
  private static var cache: [String: NSImage?] = [:]
  private static var colors: [String: NSColor] = [:]

  /// ⌘Y 放大卡的页眉色：图标 12×12 采样，跳过透明和过亮 / 过暗的像素求平均，饱和度 ×1.25 + 0.08、亮度 ×0.85
  /// 夹在 0.35–0.75（白字才读得清）。取不到时用系统蓝
  static func accentColor(for bundleID: String?) -> NSColor {
    guard let bundleID else { return .systemBlue }
    if let cached = colors[bundleID] { return cached }
    let color = icon(for: bundleID).flatMap(Self.average) ?? .systemBlue
    colors[bundleID] = color
    return color
  }

  /// 图标主色（也给链接预览的网站图标用）
  static func average(of image: NSImage) -> NSColor? {
    let side = 12
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
          bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
        let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
      else { return false }
      context.interpolationQuality = .medium
      context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
      return true
    }
    guard drawn else { return nil }
    var sum = (r: 0.0, g: 0.0, b: 0.0, n: 0.0)
    for index in stride(from: 0, to: pixels.count, by: 4) {
      let alpha = Double(pixels[index + 3]) / 255
      guard alpha > 0.5 else { continue }
      let r = Double(pixels[index]) / 255 / alpha
      let g = Double(pixels[index + 1]) / 255 / alpha
      let b = Double(pixels[index + 2]) / 255 / alpha
      let luminance = 0.299 * r + 0.587 * g + 0.114 * b
      guard luminance > 0.08, luminance < 0.92 else { continue }
      sum = (sum.r + r, sum.g + g, sum.b + b, sum.n + 1)
    }
    guard sum.n > 0 else { return nil }
    let color = NSColor(
      srgbRed: sum.r / sum.n, green: sum.g / sum.n, blue: sum.b / sum.n, alpha: 1)
    var hue: CGFloat = 0
    var saturation: CGFloat = 0
    var brightness: CGFloat = 0
    color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
    return NSColor(
      hue: hue, saturation: min(saturation * 1.25 + 0.08, 1),
      brightness: min(max(brightness * 0.85, 0.35), 0.75), alpha: 1)
  }

  static func icon(for bundleID: String?) -> NSImage? {
    guard let bundleID else { return nil }
    if let cached = cache[bundleID] { return cached }
    let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map {
      NSWorkspace.shared.icon(forFile: $0.path)
    }
    cache[bundleID] = icon
    return icon
  }

  /// App 在访达里的名字（按 bundle ID 找到 App 包；找不到是 nil）：来源标记、排除 App 列表用
  static func name(for bundleID: String) -> String? {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map {
      AppCatalog.systemName(path: $0.path)
    }
  }
}

/// 图片条目的缩略图：后台按需生成，NSCache 复用。缓存里有的在建视图时就直接用（滚回来、透镜展开不闪一下占位）。
/// 缓存有上限（第二轮体检 M1）：画过的缩略图每张在内存里留两份「宽 × 高 × 4」（CG raster data、CoreAnimation 各一份，
/// 内存探针实测），窗口关了也不还，缓存放手才还。行里的图（行图标、图片行的图）单独一个缓存（icons），透镜和 ⌘Y 大卡
/// 共用一个（previews）；
/// 大卡那一档在大卡放掉时整档丢掉（dropCards），面板都收起两分钟后 previews 整个清掉（dropPreviews，空闲回收）。
/// 正在显示的那张不怕被淘汰：视图自己的 @State 还拿着它
struct ThumbnailView: View {
  let id: UUID
  let images: ImageStore
  let maxPixel: Int
  var contentMode = ContentMode.fill
  @State private var image: NSImage?

  /// 三档的长边（像素）：行图标、透镜、⌘Y 大卡。图片行的图另按框算（rowPixel），都比透镜这一档小
  static let iconPixel = 72
  static let lensPixel = 720
  static let cardPixel = 2400
  /// 图片行的图最长取这么多：比例极端的长截图（1:20 以上）按框算要上千像素，只看得到顶上一截，不值
  static let rowPixelCap = 640

  /// 行里的图最多留这么多张、这么多字节（按 cost），单独一个缓存：不让大图把它们挤掉（重做一张要把原图整张解码）。
  /// 行图标一张最大 72 × 72，画过后实测留 25–31 KB，300 张 7–10 MB；图片行的图一张常见 70–370 KB（整屏截图约 115 KB，
  /// 2026-11-20 独立探针：100 张常见比例的画过一遍比行图标多约 9 MB），16 MB 约 140 张 = 连着翻过二十来屏都是图的列表
  static let iconCount = 300
  static let iconBytes = 16 * 1_048_576
  /// 透镜 + 大卡最多留这么多（按 cost）：约 18 张整屏截图的透镜，或一张大卡（整屏截图约 29 MB）+ 7 张透镜。
  /// 最大的一张大卡（2400 × 2400，44 MB）加同一张图的透镜（720 × 720，4 MB）也放得下：正在看的这两张不会把对方挤掉
  static let previewBytes = 48 * 1_048_576

  /// 不是 private：内存探针（MemoryProbeTests）要清空它们，量清掉后回落多少
  static let icons = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = iconCount
    cache.totalCostLimit = iconBytes
    return cache
  }()
  static let previews = {
    let cache = NSCache<NSString, NSImage>()
    cache.totalCostLimit = previewBytes
    return cache
  }()
  /// 进过缓存的大卡档的 key：NSCache 列不出自己有什么，dropCards 照着这份丢。不是 private：单测要查
  /// 「丢的是不是只有大卡这一档」（系统的 NSCache 随时可能自己清掉，不能拿「还在缓存里」当断言）
  private(set) static var cardKeys: Set<String> = []

  init(id: UUID, images: ImageStore, maxPixel: Int, contentMode: ContentMode = .fill) {
    self.id = id
    self.images = images
    self.maxPixel = maxPixel
    self.contentMode = contentMode
    _image = State(
      initialValue: Self.cache(for: maxPixel).object(forKey: Self.key(id, maxPixel) as NSString))
  }

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode)
      } else {
        Style.controlFill
      }
    }
    // 不自己裁：调用方按自己的圆角裁 ThumbnailView 本身（行图标 tile、透镜和 ⌘Y 大卡 control），
    // .fit 时图片比容器小，只裁外面的容器图片会是直角
    .task(id: id) {
      image = await Self.load(id, images: images, maxPixel: maxPixel)
    }
  }

  /// 缓存里有就直接给，没有就在后台生成再缓存（截图自检也先用它把缓存填好：屏外渲染时 .task 来不及跑）
  static func load(_ id: UUID, images: ImageStore, maxPixel: Int) async -> NSImage? {
    let key = key(id, maxPixel)
    let cache = cache(for: maxPixel)
    if let cached = cache.object(forKey: key as NSString) { return cached }
    guard let cgImage = await images.thumbnail(for: id, maxPixel: maxPixel) else { return nil }
    let loaded = NSImage(cgImage: cgImage, size: .zero)
    // 尺寸取 CGImage 自己的：NSImage 的 rep 报的是另一个数
    cache.setObject(
      loaded, forKey: key as NSString, cost: cost(width: cgImage.width, height: cgImage.height))
    if maxPixel >= cardPixel { cardKeys.insert(key) }
    return loaded
  }

  /// 一张缩略图画过之后占的内存：宽 × 高 × 4 字节，两份
  static func cost(width: Int, height: Int) -> Int { width * height * 4 * 2 }

  /// 这一档进哪个缓存：行里的图（行图标、图片行的图，都比透镜小）进 icons，透镜、大卡进 previews
  static func cache(for maxPixel: Int) -> NSCache<NSString, NSImage> {
    maxPixel < lensPixel ? icons : previews
  }

  /// 图片行的图要的长边（像素）：按 2x 屏正好盖住它的框（ClipRowView.pictureSize，填满裁切），最多 rowPixelCap。
  /// 不知道尺寸的按行图标那一档。纯函数（单测）
  static func rowPixel(for image: ClipItem.ImageInfo?) -> Int {
    guard let image, image.width > 0, image.height > 0 else { return iconPixel }
    let box = ClipRowView.pictureSize(image, expanded: false)
    let (width, height) = (CGFloat(image.width), CGFloat(image.height))
    let scale = max(box.width * 2 / width, box.height * 2 / height)
    return min(Int((max(width, height) * scale).rounded(.up)), rowPixelCap)
  }

  /// ⌘Y 大卡放掉了：大卡档的缩略图都丢掉（一张整屏截图约 29 MB，留着会把透镜档挤出去）
  static func dropCards() {
    for key in cardKeys { previews.removeObject(forKey: key as NSString) }
    cardKeys = []
  }

  /// 空闲回收（AppDelegate.idleReclaim，面板都收起两分钟后）：透镜和大卡两档全丢。装满时两份加起来约 50 MB，
  /// 闲着白占；再看到时重新生成（整屏截图一张 40–100 ms，这期间是占位色块）。行图标不丢：重做一张同样要把原图
  /// 整张解码，一屏十来张一起重做太贵，留满也才 7–10 MB
  static func dropPreviews() {
    previews.removeAllObjects()
    cardKeys = []
  }

  static func key(_ id: UUID, _ maxPixel: Int) -> String {
    "\(id.uuidString)-\(maxPixel)"
  }
}
