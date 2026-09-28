// 剪贴板的行拖到别的 App（体检 D3，对标 Paste）：SwiftUI 的 onDrag 一次只给得出一个 NSItemProvider，拖不了多个勾选项、
// 一条里的多个文件，所以在行的拖动手势里起一个 AppKit 拖放会话，拖的东西是 ClipboardPanelModel.dragItems 给的剪贴板条目
// （和粘贴写进去的同一份）。只给「拷贝」：拖出去不动历史（不算粘贴、不置顶、不改选中）。
// 拖放期间点外关闭自然不会触发：会话从面板里的按下开始，拖着的时候没有新的按下事件（OverlayPanel 只看按下）；
// 真放下了（对方收了）才照常收起面板（onDrop，固定着不收），拖回来 / 没放成不收。
// 预览是这一行的样子（图标块 + 标题），多项时 AppKit 自己叠在下面并标个数。

import AppKit
import SwiftUI

enum ClipDrag {
  /// 在行的拖动手势里调：那时 NSApp.currentEvent 是面板里的 leftMouseDragged，会话从它开始
  static func begin(
    _ items: [NSPasteboardItem], preview: NSImage?, onDrop: @escaping () -> Void
  ) {
    guard !items.isEmpty, let event = NSApp.currentEvent, event.type == .leftMouseDragged,
      let view = event.window?.contentView
    else { return }
    let point = view.convert(event.locationInWindow, from: nil)
    let image = preview ?? NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
    let size = image?.size ?? CGSize(width: 24, height: 24)
    // 预览以指针为中心；后面几项叠在同一处、不另画（AppKit 标个数）
    let frame = CGRect(
      x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width,
      height: size.height)
    let dragging = items.enumerated().map { index, item in
      let draggingItem = NSDraggingItem(pasteboardWriter: item)
      draggingItem.setDraggingFrame(frame, contents: index == 0 ? image : nil)
      return draggingItem
    }
    source.onDrop = onDrop
    view.beginDraggingSession(with: dragging, event: event, source: source)
  }

  /// 拖动预览：行首的 24 pt 图标块 + 标题（最宽 320，单行截断），画在窗口底色的圆角卡上。
  /// ImageRenderer 画不了材质和 AppKit 控件，图标块和标题都是 SwiftUI 的图和字，画得出来。
  /// ImageRenderer 不跟 App 外观走（默认浅色），深浅要自己给：默认取 App 当前的
  static func preview(
    _ item: ClipItem, form: ContentForm?, images: ImageStore, colorScheme: ColorScheme? = nil
  ) -> NSImage? {
    let scheme =
      colorScheme
      ?? (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? .dark : .light)
    let shape = RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
    let renderer = ImageRenderer(
      content: HStack(spacing: 10) {
        IconTile(item: item, form: form, images: images)
        Text(item.title)
          .font(
            form == .code || form == .json
              ? .system(size: 12, design: .monospaced) : .system(size: 13)
          )
          .lineLimit(1)
          .truncationMode(.tail)
      }
      .padding(.horizontal, 10)
      .frame(maxWidth: 320, alignment: .leading)
      .frame(height: ClipRowView.height)
      .background(Color(nsColor: .windowBackgroundColor).opacity(0.92), in: shape)
      .overlay(shape.hairlineBorder())
      .environment(\.colorScheme, scheme))
    renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
    return renderer.nsImage
  }

  private static let source = Source()

  private final class Source: NSObject, NSDraggingSource {
    /// 这次拖放放成了之后做什么（每次 begin 覆盖）
    var onDrop: () -> Void = {}

    func draggingSession(
      _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
      if operation != [] { onDrop() }
      onDrop = {}
    }

    func draggingSession(
      _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
      .copy
    }
  }
}
