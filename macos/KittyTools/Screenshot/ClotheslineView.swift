// 晾衣绳面板的内容（第十族第 1 批，2026-10-26 拍板 D1；长相见 mac-whisker-capture.mdc「晾衣绳」）：
// 一根绳子横在屏幕顶上、中间断开给刘海岛让位，挂着的截图一张张从两边往中间挂，每张上面一枚品牌粉的小夹子。
// 卡片就是常驻缩略图那一张（圆角 10、white 0.25 发丝线描边 + black 0.28 / r16 / y6 阴影，Style.shotCard），
// 图是截图历史里那条的缩略图（ShotThumbnails，和历史窗口共用一份缓存）。
// 排法、绳子的下垂都由 ClotheslineLayout 算好（面板内坐标，原点左上）；这里只管画。
// 面板是整块透明的（没有毛玻璃底）：透明的地方系统自己点穿，只有卡片接鼠标（Clothesline.makePanel）。

import AppKit
import SwiftUI

struct ClotheslineView: View {
  let model: ClotheslineModel

  var body: some View {
    ZStack(alignment: .topLeading) {
      // 绳子：底下压一道深的、上面一道浅的（HUD 的内外描边那一套）——面板整块透明，桌面深浅都看得见
      RopeShape(ropes: model.plan.ropes)
        .stroke(Color(nsColor: Style.HUD.outerStroke), lineWidth: ClotheslineLayout.ropeWidth + 1.5)
        .overlay {
          RopeShape(ropes: model.plan.ropes)
            .stroke(
              Color(nsColor: Style.HUD.secondaryText), lineWidth: ClotheslineLayout.ropeWidth)
        }
        .allowsHitTesting(false)
      ForEach(Array(zip(model.items, model.plan.cards)), id: \.0.id) { item, rect in
        ClotheslineCard(item: item, history: model.history)
          .frame(width: rect.width, height: rect.height)
          .position(x: rect.midX, y: rect.midY)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

/// 绳子：两端固定在屏幕两边、中间自然下垂的二次贝塞尔，正中间断开一段给刘海岛（拍板 C2）。
/// nonisolated：path(in:) 可能在 SwiftUI 的渲染线程上调（mac-native §3），只读传进来的几何
nonisolated private struct RopeShape: Shape {
  let ropes: [ClotheslineLayout.Rope]

  func path(in rect: CGRect) -> Path {
    var path = Path()
    for rope in ropes {
      path.move(to: rope.from)
      path.addQuadCurve(to: rope.to, control: rope.control)
    }
    return path
  }
}

/// 挂在绳子上的一张：缩略图 + 顶上那枚夹子
private struct ClotheslineCard: View {
  let item: ShotHistory.Item
  let history: ShotHistory?

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
    // 图放在 overlay 里铺满：比例和卡片不一样时也不会把卡片撑大（同常驻缩略图）
    Color.clear
      .overlay {
        if let image = history.flatMap({ ShotThumbnails.shared.image(for: item, in: $0) }) {
          Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
          Color(nsColor: Style.HUD.solidFill)
        }
      }
      .shotCard(shape)
      // 夹子压在卡片顶边、往上伸到绳子上
      .overlay(alignment: .top) { Clip().offset(y: -ClotheslineLayout.clipHeight) }
  }
}

/// 夹子：品牌粉的小圆角条，中间一道浅色的缝
private struct Clip: View {
  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
    shape
      .fill(Color(nsColor: Style.Shot.accent))
      .frame(width: 13, height: ClotheslineLayout.clipHeight + 7)
      .overlay {
        Color(nsColor: Style.Shot.onAccent).opacity(0.45)
          .frame(width: 1)
          .padding(.vertical, 3)
      }
      .overlay { shape.strokeBorder(Style.Shot.cardStroke, lineWidth: Style.HUD.strokeWidth) }
      .shadow(color: Style.Shot.cardShadow, radius: 4, y: 2)
      .accessibilityHidden(true)
  }
}
