// 「动画表情」弹窗（2026-11-05 用户：系统表情和动画版要两个入口；又说「动画版的选择面板和系统的保持一致」）：图标格子里「动画
// 表情」那一格点开的气泡，照系统表情面板的样子排：顶上搜索框（一打开就能打字；中文名、CLDR 中文关键词、英文、表情字本身都能搜），
// 中间 6 列大格子从头滚到尾（「常用」= 最近挑过的，再是表情与人物、动物与自然、食物、活动、旅行与地点、物品、旗帜，段之间空一点、
// 不写标题），底下一排分类图标（点了跳过去，滚到哪一段哪个亮）。格子是包里带的缩略图（和挑到的是同一个样子）；鼠标停在一格
// 0.4 s，那一格就下好动画、原地动起来（系统面板没有这一手，用户要看得出动画是什么）；名字在悬停提示里。点一格就选上、气泡
// 收起：自带的 28 个之一存自带的 id，别的存「pack:编号」，第一次用到时下载（EmojiPack）。状态和提醒的详情页共用。

import SwiftUI

struct AnimatedEmojiPicker: View {
  /// 现在选着的图标值（亮那一格）
  let selection: String
  let pick: (String) -> Void
  /// 搜的词（截图自检可以直接给）
  @State var query = ""
  /// 滚到了哪一段（底下那排亮哪个；点了跳过去）。打开时是选着的那个所在的那一段
  @State var section: String?
  @State private var hovered: String?
  @AppStorage(Prefs.emojiPackRecent) private var recentData = ""
  @FocusState private var searching: Bool

  /// 分类：编号、名字（旁白、悬停提示）、底下那排的符号（同系统表情面板）
  static let categories: [(id: String, title: String, symbol: String)] = [
    ("recent", "常用", "clock"), ("people", "表情与人物", "face.smiling"),
    ("nature", "动物与自然", "pawprint"), ("food", "食物", "carrot"), ("activities", "活动", "soccerball"),
    ("travel", "旅行与地点", "car"), ("objects", "物品", "lightbulb"), ("flags", "旗帜", "flag"),
  ]
  static let columns = 6
  static let cell: CGFloat = 48
  static let size = CGSize(width: 332, height: 440)
  /// 「常用」最多几个（三行）
  static let recentLimit = 18

  struct Section: Identifiable, Equatable {
    let id: String
    let entries: [EmojiPack.Entry]
  }

  /// 不搜时的几段（纯函数）：「常用」（最近挑过的、对照表里还有的）在前，再照分类的先后；空的段不画
  static func sections(_ all: [EmojiPack.Entry], recent: [String]) -> [Section] {
    let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let recentEntries = recent.compactMap { byID[$0] }
    return
      ([Section(id: "recent", entries: recentEntries)]
      + categories.dropFirst().map { category in
        Section(id: category.id, entries: all.filter { $0.group == category.id })
      })
      .filter { !$0.entries.isEmpty }
  }

  /// 挑了一个之后的「常用」（纯函数）：挪到最前、不重复、最多 recentLimit 个
  static func recent(after picked: String, in list: [String]) -> [String] {
    Array(([picked] + list.filter { $0 != picked }).prefix(recentLimit))
  }

  private var recent: [String] { recentData.split(separator: ",").map(String.init) }

  var body: some View {
    let all = EmojiPack.catalog?.emoji ?? []
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    let sections = Self.sections(all, recent: recent)
    VStack(spacing: 0) {
      searchField.padding(12)
      ScrollView {
        if trimmed.isEmpty {
          LazyVStack(spacing: 14) {
            ForEach(sections) { section in grid(section.entries).id(section.id) }
          }
          .scrollTargetLayout()
          .padding(.horizontal, 12)
          .padding(.bottom, 8)
        } else {
          let found = EmojiPack.search(trimmed, in: all)
          if found.isEmpty {
            Text("没有对上的动画表情").font(.callout).foregroundStyle(.secondary).padding(.top, 40)
          }
          grid(found).padding(.horizontal, 12).padding(.bottom, 8)
        }
      }
      .scrollPosition(id: $section, anchor: .top)
      Divider()
      categoryBar(sections.map(\.id))
        .opacity(trimmed.isEmpty ? 1 : 0.4)
        .disabled(!trimmed.isEmpty)
    }
    .frame(width: Self.size.width, height: Self.size.height)
    .onAppear { searching = true }
  }

  private var searchField: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
      TextField("搜索", text: $query)
        .textFieldStyle(.plain)
        .focused($searching)
    }
    .padding(.horizontal, 10)
    .frame(height: 32)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(Color.accentColor.opacity(searching ? 0.8 : 0), lineWidth: 3)
    }
  }

  private func grid(_ entries: [EmojiPack.Entry]) -> some View {
    let current = StatusEmoji.canonical(selection)
    return LazyVGrid(
      columns: Array(repeating: GridItem(.fixed(Self.cell), spacing: 4), count: Self.columns),
      spacing: 4
    ) {
      ForEach(entries, id: \.id) { entry in
        let symbol = StatusEmoji.symbol(forPack: entry.id)
        PickerCell(
          entry: entry, symbol: symbol, hovered: hovered == symbol, selected: symbol == current
        ) {
          recentData = Self.recent(after: entry.id, in: recent).joined(separator: ",")
          pick(symbol)
        }
        .onHover { inside in
          if inside {
            hovered = symbol
          } else if hovered == symbol {
            hovered = nil
          }
        }
      }
    }
  }

  /// 底下那排分类：点了滚到那一段，滚到哪一段哪个亮（同系统表情面板）
  private func categoryBar(_ shown: [String]) -> some View {
    HStack(spacing: 0) {
      ForEach(Self.categories.filter { shown.contains($0.id) }, id: \.id) { category in
        let active = (section ?? shown.first) == category.id
        Button {
          withAnimation(.easeOut(duration: 0.2)) { section = category.id }
        } label: {
          Image(systemName: category.symbol)
            .font(.system(size: 15))
            .foregroundStyle(active ? .primary : .secondary)
            .frame(width: 30, height: 30)
            .background(active ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: Circle())
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(category.title)
        .accessibilityLabel(category.title)
        .accessibilityAddTraits(active ? .isSelected : [])
      }
    }
    .padding(.horizontal, 8)
    .frame(height: 44)
  }
}

/// 气泡里的一格：缩略图（主线程外解，EmojiPack.loadThumbnail）；鼠标停 0.4 s 就下好动画、原地动起来（减弱动态效果时不动）；
/// 选着的一圈强调色、悬停一块中性底（同系统面板的悬停）
private struct PickerCell: View {
  let entry: EmojiPack.Entry
  let symbol: String
  let hovered: Bool
  let selected: Bool
  let pick: () -> Void
  @State private var thumbnail: CGImage?
  @State private var frames: StatusEmoji.Frames?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(
    entry: EmojiPack.Entry, symbol: String, hovered: Bool, selected: Bool,
    pick: @escaping () -> Void
  ) {
    self.entry = entry
    self.symbol = symbol
    self.hovered = hovered
    self.selected = selected
    self.pick = pick
    _thumbnail = State(initialValue: EmojiPack.cachedThumbnail(entry.id))
  }

  var body: some View {
    Button(action: pick) {
      ZStack {
        if let frames {
          StatusEmojiView(id: symbol, frames: frames, fetches: false)
        } else if let thumbnail {
          Image(decorative: thumbnail, scale: 1).resizable().interpolation(.high)
        }
      }
      .frame(width: AnimatedEmojiPicker.cell - 10, height: AnimatedEmojiPicker.cell - 10)
      .frame(width: AnimatedEmojiPicker.cell, height: AnimatedEmojiPicker.cell)
      .background(
        hovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
      )
      .overlay {
        if selected {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Style.brand, lineWidth: 2)
        }
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .task(id: entry.id) { thumbnail = await EmojiPack.loadThumbnail(entry.id) }
    .task(id: hovered) {
      frames = nil
      guard hovered, !reduceMotion else { return }
      try? await Task.sleep(for: .milliseconds(400))
      guard !Task.isCancelled, let decoded = await StatusEmoji.load(symbol), !Task.isCancelled
      else { return }
      frames = decoded
    }
    .help(entry.name)
    .accessibilityLabel(entry.name)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}
