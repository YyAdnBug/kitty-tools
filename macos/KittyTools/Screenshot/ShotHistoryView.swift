// 截图历史窗口的界面（历史第 2 批，拍板 C1）：左边按日期分组的缩略图网格（顶上搜索和筛选），
// 选中一条右边是大预览、信息和一排操作。模型和窗口在 ShotHistoryWindow.swift。
// 文件末尾的 ShotThumbnail（缩略图在主线程外读、读好再画）是这里和晾衣绳的卡片共用的。
// Whisker：系统皮肤的窗口（同设置窗、全部便签窗口），卡片圆角 card，选中那张画 2 pt 强调色描边
// （强调色只标「现在该操作的东西」，核心 §1.2），空状态用 EmptyState。

import SwiftUI

struct ShotHistoryView: View {
  @Bindable var model: ShotHistoryModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// 光标在不在搜索框里：在的话方向键和 ⌘C 让给它（见 shortcuts）
  @FocusState private var searching: Bool

  /// 网格里一张卡多宽（高按 3:2 留，图按自己的比例缩在里面）
  static let cardWidth: CGFloat = 168
  static let cardHeight: CGFloat = 112

  var body: some View {
    HStack(spacing: 0) {
      grid
      let chosen = model.chosen
      if chosen.count > 1 {
        Divider()
        many(chosen).frame(width: 280)
      } else if let item = model.selected {
        Divider()
        detail(item).frame(width: 280)
      }
      shortcuts
    }
    .toolbar {
      ToolbarItem(placement: .principal) {
        Picker("筛选", selection: $model.filter) {
          ForEach(ShotHistoryModel.Filter.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(width: 280)
      }
    }
    .searchable(text: $model.search, prompt: "搜来源或种类")
    .searchFocused($searching)
    .onKeyPress(.delete) {
      guard !model.picked.isEmpty else { return .ignored }
      model.deleteSelection()
      return .handled
    }
    .confirmationDialog(
      "删掉 \(model.deleting.count) 条？",
      isPresented: Binding {
        !model.deleting.isEmpty
      } set: {
        if !$0 { model.deleting = [] }
      }
    ) {
      Button("删除", role: .destructive) {
        model.delete(model.deleting)
        model.deleting = []
      }
    } message: {
      Text("历史里这几条连同留着的原图一起删掉，不能撤销；已经存到文件夹里的文件不动。")
    }
    .symbolEffectsRemoved(reduceMotion)
    .appAccent()
  }

  // MARK: 快捷键

  /// 窗口里的键。挂在看不见的按钮上（同全部便签窗口）：挂在工具栏项上的话，窗口一窄工具栏收进「»」，
  /// 键就跟着不灵了。⌫ 删除还是 onKeyPress（SwiftUI 的 .keyboardShortcut(.delete) 认的不是 ⌫ 键，
  /// 见 NotesWindowView.shortcuts）。
  /// 方向键和 ⌘C 在搜索框里打字时让开：performKeyEquivalent 比输入框先看到键，不让开就没法在搜索框里
  /// 挪光标、拷贝选中的字。
  /// ⇧⌘S 另存为、⇧ + 方向键连选不在这里：同一个键上挂带 ⇧ 和不带 ⇧ 的两颗，不带 ⇧ 的那颗会被抢走
  /// （实测，⌘S 三次里错一两次；⇧← 一挂上，光按 ← 就变成连选了），都由窗口自己认
  /// （ShotHistoryWindow.handlesKeyDown，同 NotesWindow 的 ⇧⌘Z）
  @ViewBuilder private var shortcuts: some View {
    let chosen = model.chosen
    let item = model.selected
    let isImage = item.map { $0.filePath == nil } ?? false
    Group {
      Group {
        Button("上一张") { model.move(by: -1) }.keyboardShortcut(.leftArrow, modifiers: [])
        Button("下一张") { model.move(by: 1) }.keyboardShortcut(.rightArrow, modifiers: [])
        Button("上一行") { model.move(by: -model.columnsPerRow) }
          .keyboardShortcut(.upArrow, modifiers: [])
        Button("下一行") { model.move(by: model.columnsPerRow) }
          .keyboardShortcut(.downArrow, modifiers: [])
        Button("全选") { model.pickAll() }.keyboardShortcut("a")
        Button("拷贝") { model.copySelection() }
          .keyboardShortcut("c").disabled(!model.canCopy)
      }
      .disabled(searching)
      Button("改标注") { if let item { edit(item) } }
        .keyboardShortcut(.return, modifiers: []).disabled(item == nil)
      Button("存储到…") { model.saveSelection() }
        .keyboardShortcut("s").disabled(!model.canSave)
      Button("钉到屏幕") { if let item { model.actions.pin(item) } }
        .keyboardShortcut("p").disabled(!isImage)
      Button("识字并拷贝") { if let item { model.actions.recognize(item) } }
        .keyboardShortcut("o").disabled(!isImage)
      Button("在访达中显示") { model.revealSelection() }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(chosen.isEmpty || (chosen.count == 1 && !model.hasFile(chosen[0])))
      Button("搜索") { searching = true }.keyboardShortcut("f")
      // ⌘1…⌘4：换筛选（同顶上那排）
      ForEach(Array(ShotHistoryModel.Filter.allCases.enumerated()), id: \.element) {
        index, filter in
        Button(filter.title) { model.filter = filter }
          .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
      }
    }
    .opacity(0)
    .frame(width: 0, height: 0)
    .accessibilityHidden(true)
  }

  // MARK: 左边的网格

  private var grid: some View {
    let groups = model.groups
    return ScrollViewReader { proxy in
      ScrollView {
        if groups.isEmpty {
          EmptyState(symbol: "clock.arrow.circlepath", title: "还没有截图") {
            Text(
              model.search.isEmpty
                ? "截图、长截图、录屏录音都会留在这里，默认保留 30 天。" : "换个词试试。")
          }
          .padding(.top, 80)
        }
        LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
          ForEach(groups) { group in
            Section {
              LazyVGrid(
                columns: [GridItem(.adaptive(minimum: Self.cardWidth), spacing: 12)], spacing: 12
              ) {
                ForEach(group.items) { item in
                  ShotCard(
                    item: item, chosen: model.picked.contains(item.id), history: model.history,
                    generation: model.redraws,
                    select: { model.click(item.id) }, edit: { edit(item) },
                    drag: { model.beginDrag(item) }
                  )
                  .contextMenu { menu(item) }
                }
              }
            } header: {
              Text(group.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.leading, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)  // 吸顶时盖住下面滚过去的卡片（深浅自适应）
            }
          }
        }
        .padding(16)
      }
      .frame(minWidth: 420)
      // 量出一行几张：方向键的 ↑↓ 跳一行
      .onGeometryChange(for: CGFloat.self) {
        $0.size.width
      } action: { width in
        model.columnsPerRow = ShotHistoryModel.columns(
          width: width, card: Self.cardWidth, spacing: 12, padding: 16)
      }
      // 换选中时把那张滚进视野（2026-10-27 用户手测：方向键挑到看不见的那一行，内容区不跟着滚）。
      // anchor 给 nil 是「滚最少的距离、够看见就行」：已经看得见的（点一下、同一行里左右挪）一动不动
      .onChange(of: model.anchor) { _, now in
        guard let now else { return }
        proxy.scrollTo(now, anchor: nil)
      }
    }
  }

  static func symbol(_ kind: ShotHistory.Kind) -> String {
    switch kind {
    case .shot: "photo"
    case .scroll: "rectangle.expand.vertical"
    case .video: "video"
    case .audio: "waveform"
    case .gif: "photo.stack"
    }
  }

  // MARK: 右边的预览

  private func detail(_ item: ShotHistory.Item) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      ZStack {
        RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
          .fill(.quaternary.opacity(0.4))
        ShotThumbnail(item: item, history: model.history, generation: model.redraws) { image in
          if let image {
            Image(nsImage: image)
              .resizable()
              .aspectRatio(contentMode: .fit)
              .padding(4)
          } else {
            Image(systemName: Self.symbol(item.kind)).font(.system(size: 28)).foregroundStyle(
              .secondary)
          }
        }
      }
      .frame(height: 180)
      .onDrag { model.dragProvider(for: item) }
      Text(ShotHistoryModel.caption(item)).font(.system(size: 12))
      let details = ShotHistoryModel.details(item)
      if !details.isEmpty {
        Text(details).font(.system(size: 11)).foregroundStyle(.secondary)
      }
      Divider()
      actions(item)
      Spacer()
    }
    .padding(16)
    .frame(maxHeight: .infinity, alignment: .top)
  }

  /// 多选时右边这一栏：已选几张、各几个多大，底下是能一起做的那几件
  private func many(_ items: [ShotHistory.Item]) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      ZStack {
        RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
          .fill(.quaternary.opacity(0.4))
        VStack(spacing: 8) {
          Image(systemName: "square.on.square").font(.system(size: 26)).foregroundStyle(.secondary)
          Text("已选 \(items.count) 项").font(.system(size: 13, weight: .medium))
        }
      }
      .frame(height: 180)
      Text(ShotHistoryModel.summary(items)).font(.system(size: 12)).foregroundStyle(.secondary)
      Divider()
      VStack(alignment: .leading, spacing: 8) {
        row("拷贝", "doc.on.doc", key: "⌘C") { model.copySelection() }
        row("存储到…", "square.and.arrow.down", key: "⌘S") { model.saveSelection() }
        row("在访达中显示", "folder", key: "⇧⌘R") { model.revealSelection() }
        row("删除", "trash", key: "⌫", danger: true) { model.deleteSelection() }
      }
      Spacer()
    }
    .padding(16)
    .frame(maxHeight: .infinity, alignment: .top)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("已选 \(items.count) 项")
  }

  @ViewBuilder private func actions(_ item: ShotHistory.Item) -> some View {
    let isImage = item.filePath == nil
    VStack(alignment: .leading, spacing: 8) {
      if isImage {
        row("改标注", "pencil.tip.crop.circle", key: "↩") { edit(item) }
        row("拷贝", "doc.on.doc", key: "⌘C") { model.actions.copy(item) }
        row("存储到…", "square.and.arrow.down", key: "⌘S") { model.actions.save(item) }
        row("另存为…", "square.and.arrow.down.on.square", key: "⇧⌘S") { model.actions.saveAs(item) }
        row("钉到屏幕", "pin", key: "⌘P") { model.actions.pin(item) }
        row("识字并拷贝", "text.viewfinder", key: "⌘O") { model.actions.recognize(item) }
      } else {
        row("打开", "play.rectangle", key: "↩") { model.open(item) }
      }
      row("在访达中显示", "folder", key: "⇧⌘R") { model.reveal(item) }
        .disabled(!model.hasFile(item))
      row("删除", "trash", key: "⌫", danger: true) { model.deleting = [item.id] }
    }
  }

  /// 一行操作：右边写着键位（同菜单里的写法，用户不用去速查表翻）
  private func row(
    _ title: String, _ symbol: String, key: String, danger: Bool = false,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Label(title, systemImage: symbol)
          .foregroundStyle(danger ? AnyShapeStyle(Style.danger) : AnyShapeStyle(.primary))
        Spacer(minLength: 8)
        Text(key).foregroundStyle(.tertiary).monospacedDigit()
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .font(.system(size: 13))
    .accessibilityLabel(title)
  }

  @ViewBuilder private func menu(_ item: ShotHistory.Item) -> some View {
    let chosen = model.chosen
    if chosen.count > 1, chosen.contains(where: { $0.id == item.id }) {
      // 右键点的就是多选里的一张：整批做（点在选区外面的那张只管它自己，不动选中）
      Button("拷贝 \(chosen.count) 项") { model.actions.copyMany(chosen) }
      Button("存储 \(chosen.count) 项…") { model.actions.saveMany(chosen) }
      Button("在访达中显示") { model.reveal(chosen) }
      Divider()
      Button("删除 \(chosen.count) 项", role: .destructive) {
        model.deleting = chosen.map(\.id)
      }
    } else if item.filePath == nil {
      Button("改标注") { edit(item) }
      Button("拷贝") { model.actions.copy(item) }
      Button("存储到…") { model.actions.save(item) }
      Button("另存为…") { model.actions.saveAs(item) }
      Button("钉到屏幕") { model.actions.pin(item) }
      Button("识字并拷贝") { model.actions.recognize(item) }
    } else {
      Button("打开") { model.open(item) }
    }
    Button("在访达中显示") { model.reveal(item) }
      .disabled(!model.hasFile(item))
    Divider()
    Button("删除", role: .destructive) { model.deleting = [item.id] }
  }

  /// 双击 / 「改标注」：录制的那几条双击是用默认 App 打开（拍板 C3）
  private func edit(_ item: ShotHistory.Item) {
    model.pick(item.id)
    if item.filePath == nil { model.actions.edit(item) } else { model.open(item) }
  }
}

/// 网格里的一张卡：单独一个视图，换选中时只有受影响的那两张重画（整片网格重画会卡，
/// 2026-10-26 用户手测报的）。单击和双击都用 simultaneousGesture：
/// 叠着两个 onTapGesture 的话，单击要等双击判定超时才落地，看着就是「点了半天才高亮」
private struct ShotCard: View {
  let item: ShotHistory.Item
  let chosen: Bool
  let history: ShotHistory
  /// 缩略图重做了第几回（ShotThumbnails 不是 @Observable）：改完标注这一条本身没变，
  /// 不把代数摆进卡片的值里，LazyVGrid 就认为这一格没变、不重画
  /// （2026-10-26 用户手测：右边的预览变了、左边的列表没变）
  let generation: Int
  let select: () -> Void
  let edit: () -> Void
  /// 拖开 6 pt 时调一次：起 AppKit 拖放会话（选中的几张一起拖，ShotHistoryModel.beginDrag），之后的鼠标事件归它
  let drag: () -> Void
  @GestureState private var dragging = false

  var body: some View {
    VStack(spacing: 6) {
      ZStack {
        RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
          .fill(.quaternary.opacity(0.4))
        ShotThumbnail(item: item, history: history, generation: generation) { thumbnail in
          if let thumbnail {
            Image(nsImage: thumbnail)
              .resizable()
              .aspectRatio(contentMode: .fit)
              .clipShape(RoundedRectangle(cornerRadius: Style.Radius.card - 2, style: .continuous))
              .padding(2)
          } else {
            Image(systemName: ShotHistoryView.symbol(item.kind))
              .font(.system(size: 22))
              .foregroundStyle(.secondary)
          }
        }
        if item.kind != .shot {
          Text(item.kind.title)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.black.opacity(0.55), in: Capsule())
            .foregroundStyle(.white)
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
      }
      .frame(width: ShotHistoryView.cardWidth, height: ShotHistoryView.cardHeight)
      .overlay {
        RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
          .strokeBorder(chosen ? Style.brand : .clear, lineWidth: 2)
      }
      Text(item.createdAt.formatted(date: .omitted, time: .shortened))
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
    .contentShape(.rect)
    .simultaneousGesture(TapGesture(count: 2).onEnded { edit() })
    .simultaneousGesture(TapGesture().onEnded { select() })
    .simultaneousGesture(
      DragGesture(minimumDistance: 6).updating($dragging) { _, started, _ in
        guard !started else { return }
        started = true
        drag()
      }
    )
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(item.kind.title)，\(ShotHistoryModel.caption(item))")
    .accessibilityAddTraits(chosen ? [.isSelected, .isButton] : .isButton)
  }
}

/// 一条的缩略图（历史窗口的网格和预览、晾衣绳的卡片共用）：缓存里有就当场画，没有就在主线程外读盘、读好再画
/// （P2：原来在 body 里同步读盘）。generation 变了（改完标注、缩略图重做好了）重读一次。
/// 读回来的那张按编号记着：同一个位置换了一条（预览换了选中）时不会先露出上一条的图
struct ShotThumbnail<Content: View>: View {
  let item: ShotHistory.Item
  let history: ShotHistory?
  var generation = 0
  @ViewBuilder let content: (NSImage?) -> Content
  @State private var loaded: (id: UUID, image: NSImage?)?

  /// 缓存里的（别处刚读好的新图也在这儿）优先，其次是自己读回来的那张（缓存满了被挤掉也还在）
  private var image: NSImage? {
    if let cached = ShotThumbnails.shared.cached(item.id) { return cached }
    guard let loaded, loaded.id == item.id else { return nil }
    return loaded.image
  }

  var body: some View {
    content(image)
      .task(id: Load(id: item.id, generation: generation)) {
        guard let history else { return }
        let image = await ShotThumbnails.shared.image(for: item, in: history)
        loaded = (item.id, image)
      }
  }

  private struct Load: Equatable {
    let id: UUID
    let generation: Int
  }
}
