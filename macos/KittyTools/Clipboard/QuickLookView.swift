// ⌘Y 放大预览 = 完整检查器（mac-whisker §6 剪贴板）：剪贴板选中条目的大卡片（PreviewView），窗口从透镜的位置
// （透镜关掉时是选中行）长出来（OverlayPanel.zoom）。来源 App 彩色页眉只在这里；图片按原尺寸铺开（屏幕放不下时
// 等比缩小，窗口跟着图片的比例）并带识别文字，
// 单个文件用 Quick Look 预览、多个文件是缩略图网格，文字放大且可选中。
// 不用系统 QLPreviewPanel：它没有 nonactivatingPanel，当 key 会把键盘从原 App 抢走、点它会激活本 App（PLAN D3）。
// 预览浮层不抢键盘：↑↓ 仍在剪贴板面板里换条目，这里跟着换并按条目重算尺寸；⌘Y / Esc 缩回卡片。

import QuickLookUI
import SwiftUI

struct QuickLookView: View {
  @Bindable var model: ClipboardPanelModel
  /// 换了条目：按新条目的理想尺寸改窗口（保持中心，AppDelegate 算尺寸、夹进屏幕）
  let resize: (ClipItem) -> Void

  var body: some View {
    Group {
      if model.showsQuickLookContent, let item = model.selectedItem {
        PreviewView(item: item, model: model)
      } else if model.showsQuickLookContent {
        Text("没有可预览的条目").font(.system(size: 13)).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    // 放在 if 外面：中间经过「没有条目」再回来时也要按新条目改尺寸
    .onChange(of: model.selectedItem?.id) {
      guard model.showsQuickLookContent, let item = model.selectedItem else { return }
      resize(item)
    }
  }

  /// 图片下面识别文字区的最高高度
  static let ocrHeight: CGFloat = 140

  /// 按内容定的窗口尺寸（调用方再夹到屏幕可见区的 90%，limit 就是那个上限）：图片按原尺寸（像素 / 屏幕倍率）
  /// 加卡片的页眉页脚（有识别文字再加文字区），放不下时等比缩小；文字按估出来的行数，文件、链接、颜色各给一个
  /// 比剪贴板面板大的固定尺寸
  static func idealSize(
    for item: ClipItem, form: ContentForm?,
    within limit: NSSize = NSSize(width: CGFloat.infinity, height: CGFloat.infinity),
    scale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2
  ) -> NSSize {
    switch item.kind {
    case .image:
      let width = CGFloat(item.image?.width ?? 1600) / scale
      let height = CGFloat(item.image?.height ?? 1000) / scale
      // 卡片内缩 6、图片区内边距 10 + 8；页眉 40、页脚 42；识别文字：标题 + 间距约 30 + 文字区
      let ocr = (item.ocrText ?? "").isEmpty ? 0 : ocrHeight + 30
      let chrome = NSSize(width: 48, height: 130 + ocr)
      // 屏幕放不下原尺寸时图片等比缩小，窗口跟着图片的比例走：宽高各夹各的话，图片区比图片宽（或高）出一大截
      let fit = max(
        0, min(1, (limit.width - chrome.width) / width, (limit.height - chrome.height) / height))
      return NSSize(
        width: max(width * fit + chrome.width, 560), height: max(height * fit + chrome.height, 420))
    case .file:
      // 多个文件是缩略图网格，用不着 Quick Look 那么大
      return (item.filePaths?.count ?? 0) > 1
        ? NSSize(width: 720, height: 520) : NSSize(width: 900, height: 680)
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
