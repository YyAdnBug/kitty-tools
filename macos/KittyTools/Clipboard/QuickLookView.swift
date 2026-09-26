// ⌘Y 放大预览（Whisker D）：剪贴板选中条目的大卡片，从检查器卡片的位置放大出来（OverlayPanel.zoom）。
// 和检查器是同一张卡（PreviewView 的 enlarged 版）：图片按原尺寸铺开，文件用 Quick Look 预览，文字放大。
// 不用系统 QLPreviewPanel：它没有 nonactivatingPanel，当 key 会把键盘从原 App 抢走、点它会激活本 App（PLAN D3）。
// 预览浮层不抢键盘：↑↓ 仍在剪贴板面板里换条目，这里跟着换并按条目重算尺寸；⌘Y / Esc 缩回卡片。

import QuickLookUI
import SwiftUI

struct QuickLookView: View {
  @Bindable var model: ClipboardPanelModel
  /// 换了条目：按新条目的理想尺寸改窗口（保持中心，AppDelegate 夹进屏幕）
  let resize: (NSSize) -> Void

  var body: some View {
    Group {
      if model.showsQuickLookContent, let item = model.selectedItem {
        PreviewView(item: item, model: model, enlarged: true)
      } else if model.showsQuickLookContent {
        Text("没有可预览的条目").font(.system(size: 13)).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    // 放在 if 外面：中间经过「没有条目」再回来时也要按新条目改尺寸
    .onChange(of: model.selectedItem?.id) {
      guard model.showsQuickLookContent, let item = model.selectedItem else { return }
      resize(Self.idealSize(for: item, form: model.contentForm(of: item)))
    }
  }

  /// 按内容定的窗口尺寸（调用方再夹到屏幕可见区的 90%）：图片按原尺寸（像素 / 屏幕倍率）加卡片的页眉页脚，
  /// 文字按估出来的行数，文件、链接、颜色各给一个比剪贴板面板大的固定尺寸
  static func idealSize(for item: ClipItem, form: ContentForm?) -> NSSize {
    switch item.kind {
    case .image:
      let scale = NSScreen.main?.backingScaleFactor ?? 2
      let width = CGFloat(item.image?.width ?? 1600) / scale
      let height = CGFloat(item.image?.height ?? 1000) / scale
      // 卡片内缩 6、图片区内边距 10 + 8；页眉 40、页脚 42
      return NSSize(width: max(width + 48, 560), height: max(height + 130, 420))
    case .file:
      return NSSize(width: 900, height: 680)
    case .text:
      switch form {
      case .color: return NSSize(width: 520, height: 600)
      case .link: return NSSize(width: 760, height: 620)
      default:
        // 高度按估出来的行数（放大后一行约 21 pt、一个字约 9 pt 宽，正文区约 760 pt 宽）：短文本不留一大片空白
        let lines = (item.text ?? "").prefix(20_000).split(
          separator: "\n", omittingEmptySubsequences: false
        )
        .reduce(0) { $0 + max(1, Int((CGFloat($1.count) * 9 / 760).rounded(.up))) }
        return NSSize(width: 820, height: min(max(CGFloat(lines) * 21 + 130, 420), 720))
      }
    }
  }
}

/// 文件的 Quick Look 预览（PDF、视频、文稿、图片…），不激活本 App
struct QuickLookFile: NSViewRepresentable {
  let url: URL

  func makeNSView(context: Context) -> QLPreviewView {
    let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
    view.shouldCloseWithWindow = false
    return view
  }

  func updateNSView(_ view: QLPreviewView, context: Context) {
    if (view.previewItem as? URL) != url { view.previewItem = url as NSURL }
  }

  static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}
