// 截图历史窗口的界面（历史第 2 批，拍板 C1）：左边按日期分组的缩略图网格（顶上搜索和筛选），
// 选中一条右边是大预览、信息和一排操作。模型和窗口在 ShotHistoryWindow.swift。
// Whisker：系统皮肤的窗口（同设置窗、全部便签窗口），卡片圆角 card，选中那张画 2 pt 强调色描边
// （强调色只标「现在该操作的东西」，核心 §1.2），空状态用 EmptyState。

import SwiftUI

struct ShotHistoryView: View {
  @Bindable var model: ShotHistoryModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// 网格里一张卡多宽（高按 3:2 留，图按自己的比例缩在里面）
  static let cardWidth: CGFloat = 168
  static let cardHeight: CGFloat = 112

  var body: some View {
    HStack(spacing: 0) {
      grid
      if let item = model.selected {
        Divider()
        detail(item).frame(width: 280)
      }
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
    .onKeyPress(.delete) {
      guard let item = model.selected else { return .ignored }
      model.deleting = [item.id]
      return .handled
    }
    .onKeyPress(.return) {
      guard let item = model.selected else { return .ignored }
      edit(item)
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

  // MARK: 左边的网格

  private var grid: some View {
    ScrollView {
      if model.groups.isEmpty {
        EmptyState(symbol: "clock.arrow.circlepath", title: "还没有截图") {
          Text(
            model.search.isEmpty
              ? "截图、长截图、录屏录音都会留在这里，默认保留 30 天。" : "换个词试试。")
        }
        .padding(.top, 80)
      }
      LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
        ForEach(model.groups) { group in
          Section {
            LazyVGrid(
              columns: [GridItem(.adaptive(minimum: Self.cardWidth), spacing: 12)], spacing: 12
            ) {
              ForEach(group.items) { item in
                ShotCard(
                  item: item, chosen: model.selection == item.id,
                  thumbnail: ShotThumbnails.shared.image(for: item, in: model.history),
                  generation: model.redraws,
                  select: { model.selection = item.id }, edit: { edit(item) }
                )
                .onDrag { model.dragProvider(for: item) }
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
        if let image = ShotThumbnails.shared.image(for: item, in: model.history) {
          Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .padding(4)
        } else {
          Image(systemName: Self.symbol(item.kind)).font(.system(size: 28)).foregroundStyle(
            .secondary)
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

  @ViewBuilder private func actions(_ item: ShotHistory.Item) -> some View {
    let isImage = item.filePath == nil
    VStack(alignment: .leading, spacing: 8) {
      if isImage {
        row("改标注", "pencil.tip.crop.circle") { edit(item) }
        row("拷贝", "doc.on.doc") { model.actions.copy(item) }
        row("存储到…", "square.and.arrow.down") { model.actions.save(item) }
        row("另存为…", "square.and.arrow.down.on.square") { model.actions.saveAs(item) }
        row("钉到屏幕", "pin") { model.actions.pin(item) }
        row("识字并拷贝", "text.viewfinder") { model.actions.recognize(item) }
      } else {
        row("打开", "play.rectangle") { model.open(item) }
      }
      row("在访达中显示", "folder") { model.reveal(item) }
        .disabled(!model.hasFile(item))
      row("删除", "trash", danger: true) { model.deleting = [item.id] }
    }
  }

  private func row(
    _ title: String, _ symbol: String, danger: Bool = false, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Label(title, systemImage: symbol)
        .foregroundStyle(danger ? AnyShapeStyle(Style.danger) : AnyShapeStyle(.primary))
    }
    .buttonStyle(.plain)
    .font(.system(size: 13))
  }

  @ViewBuilder private func menu(_ item: ShotHistory.Item) -> some View {
    if item.filePath == nil {
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
    model.selection = item.id
    if item.filePath == nil { model.actions.edit(item) } else { model.open(item) }
  }
}

/// 网格里的一张卡：单独一个视图，换选中时只有受影响的那两张重画（整片网格重画会卡，
/// 2026-10-26 用户手测报的）。单击和双击都用 simultaneousGesture：
/// 叠着两个 onTapGesture 的话，单击要等双击判定超时才落地，看着就是「点了半天才高亮」
private struct ShotCard: View {
  let item: ShotHistory.Item
  let chosen: Bool
  let thumbnail: NSImage?
  /// 缩略图重做了第几回（ShotThumbnails 不是 @Observable）：改完标注这一条本身没变，
  /// 不把代数摆进卡片的值里，LazyVGrid 就认为这一格没变、不重画
  /// （2026-10-26 用户手测：右边的预览变了、左边的列表没变）
  let generation: Int
  let select: () -> Void
  let edit: () -> Void

  var body: some View {
    VStack(spacing: 6) {
      ZStack {
        RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
          .fill(.quaternary.opacity(0.4))
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
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(item.kind.title)，\(ShotHistoryModel.caption(item))")
    .accessibilityAddTraits(chosen ? [.isSelected, .isButton] : .isButton)
  }
}
