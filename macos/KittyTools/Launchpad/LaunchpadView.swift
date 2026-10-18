// 启动台的界面（SPEC R1–R3）：压暗的桌面上一页图标，顶上搜索框，底下页点。图标按屏幕大小排成列 × 行；
// 两指滑 / 滚轮翻页（跟手偏移由面板喂给 model）；方向键在格子间挪、到页边翻页；点图标打开 App；
// 一点空白处收起（文件夹开着时只收文件夹，batch 2）。
// 减弱动态效果：不缩放、不跟手，翻页直接换；搜索框、图标、页点照常。

import AppKit
import SwiftUI

struct LaunchpadView: View {
  @Bindable var model: LaunchpadModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var appeared = false

  var body: some View {
    GeometryReader { proxy in
      let metrics = model.metrics
      ZStack(alignment: .top) {
        // 整块屏的空白处：点一下收起（图标是 Button，点在它上面不会落到这一层）
        Color.black.opacity(0.30)
          .ignoresSafeArea()
          .contentShape(Rectangle())
          .onTapGesture { model.backgroundClicked() }
          .accessibilityLabel("启动台")
          .accessibilityAddTraits(.isButton)
          .accessibilityAction { model.backgroundClicked() }

        VStack(spacing: 0) {
          searchField
            .padding(.top, metrics.searchTop)
          Spacer(minLength: 12)
          pager(proxy.size, metrics: metrics)
          Spacer(minLength: 12)
          pageDots
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .opacity(appeared ? 1 : 0)
      .scaleEffect(appeared ? 1 : 1.06)
      .onAppear {
        withAnimation(
          reduceMotion ? .easeOut(duration: Style.fadeIn) : Style.Motion.pop.animation()
        ) {
          appeared = true
        }
      }
    }
  }

  // MARK: 顶上搜索

  private var searchField: some View {
    HStack(spacing: 7) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white.opacity(0.55))
        .accessibilityHidden(true)
      CommandTextField(
        text: $model.query, placeholder: "搜索", fontSize: 15,
        onCommand: { selector in
          switch selector {
          case #selector(NSResponder.moveLeft(_:)):
            model.navigate(.left)
            return true
          case #selector(NSResponder.moveRight(_:)):
            model.navigate(.right)
            return true
          case #selector(NSResponder.moveUp(_:)):
            model.navigate(.up)
            return true
          case #selector(NSResponder.moveDown(_:)):
            model.navigate(.down)
            return true
          case #selector(NSResponder.insertNewline(_:)):
            model.returnPressed()
            return true
          case #selector(NSResponder.cancelOperation(_:)):
            model.cancel()
            return true
          default:
            return false
          }
        }
      )
      .frame(height: 20)
    }
    .padding(.horizontal, 12)
    .frame(width: 280, height: 32)
    .background(
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .fill(.black.opacity(0.28))
    )
    .overlay {
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .stroke(.white.opacity(0.16), lineWidth: 0.5)
    }
    .accessibilityElement(children: .contain)
  }

  // MARK: 网格

  private func pager(_ size: CGSize, metrics: LaunchpadMetrics) -> some View {
    let pages = model.displayPages
    return HStack(spacing: 0) {
      ForEach(pages.indices, id: \.self) { index in
        pageGrid(pages[index], metrics: metrics)
          .frame(width: size.width, height: metrics.gridHeight, alignment: .top)
      }
    }
    .frame(width: size.width * CGFloat(max(pages.count, 1)), alignment: .leading)
    .offset(x: -CGFloat(model.page) * size.width + model.pageOffset)
    .frame(width: size.width, alignment: .leading)
    .clipped()
    .animation(
      reduceMotion ? nil : Style.Motion.glide.animation(), value: model.page
    )
    .animation(
      reduceMotion ? nil : Style.Motion.instant.animation(), value: model.pageOffset
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel(model.isSearching ? "搜索结果" : "第 \(model.page + 1) 页")
  }

  private func pageGrid(_ tiles: [LaunchpadTile], metrics: LaunchpadMetrics) -> some View {
    VStack(spacing: 0) {
      ForEach(0..<model.rows, id: \.self) { row in
        HStack(spacing: 0) {
          ForEach(0..<model.columns, id: \.self) { column in
            let index = row * model.columns + column
            if let tile = tiles[safe: index] {
              tileCell(tile, index: index, metrics: metrics)
            } else {
              Color.clear.frame(width: metrics.cellWidth, height: metrics.cellHeight)
            }
          }
        }
      }
    }
    .frame(width: metrics.gridWidth, height: metrics.gridHeight)
  }

  private func tileCell(_ tile: LaunchpadTile, index: Int, metrics: LaunchpadMetrics) -> some View {
    let selected = model.selected == index
    return Button {
      model.open(at: index)
    } label: {
      VStack(spacing: 7) {
        ZStack {
          RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(.white.opacity(selected ? 0.16 : 0.001))
            .frame(width: metrics.icon * 1.22, height: metrics.icon * 1.22)
          icon(for: tile, size: metrics.icon)
        }
        Text(model.title(of: tile))
          .font(.system(size: 12, weight: .regular))
          .foregroundStyle(.white.opacity(0.96))
          .lineLimit(1)
          .truncationMode(.middle)
          .frame(width: metrics.labelWidth)
          .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
      }
      .frame(width: metrics.cellWidth, height: metrics.cellHeight)
      .contentShape(Rectangle())
    }
    .buttonStyle(LaunchpadIconButtonStyle())
    .help(model.title(of: tile))
    .accessibilityLabel(model.title(of: tile))
    .accessibilityHint(tile.folder == nil ? "打开" : "打开文件夹")
  }

  @ViewBuilder
  private func icon(for tile: LaunchpadTile, size: CGFloat) -> some View {
    switch tile {
    case .app(let ref):
      if let app = model.app(ref) {
        Image(nsImage: model.icons.icon(for: app, size: size))
          .resizable()
          .interpolation(.high)
          .frame(width: size, height: size)
          .accessibilityHidden(true)
      } else {
        placeholderIcon(size: size)
      }
    case .folder(let folder):
      FolderGlyph(folder: folder, model: model, size: size)
    }
  }

  private func placeholderIcon(size: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
      .fill(.white.opacity(0.12))
      .frame(width: size, height: size)
      .overlay {
        Image(systemName: "questionmark.app.dashed")
          .font(.system(size: size * 0.4))
          .foregroundStyle(.white.opacity(0.5))
      }
      .accessibilityHidden(true)
  }

  // MARK: 页点

  private var pageDots: some View {
    HStack(spacing: 9) {
      ForEach(0..<model.pageCount, id: \.self) { index in
        Circle()
          .fill(.white.opacity(index == model.page ? 0.92 : 0.35))
          .frame(width: 7, height: 7)
          .contentShape(Rectangle().inset(by: -6))
          .onTapGesture { model.go(to: index) }
          .accessibilityLabel("第 \(index + 1) 页")
          .accessibilityAddTraits(index == model.page ? [.isSelected, .isButton] : .isButton)
          .accessibilityAction { model.go(to: index) }
      }
    }
    .opacity(model.pageCount > 1 ? 1 : 0)
    .padding(.bottom, 16)
    .accessibilityElement(children: .contain)
  }
}

/// 图标按钮按下去微微缩一点（Whisker 先瞬时）；减弱动态效果不缩，只压暗。
private struct LaunchpadIconButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
      .opacity(configuration.isPressed ? 0.82 : 1)
      .animation(.easeOut(duration: Style.fadeIn), value: configuration.isPressed)
  }
}

/// 文件夹图标（batch 2 打开文件夹、batch 3 导入都会用到）：一块半透明圆角底，里面按 3 × 3 画前 9 个 App 的小图标。
/// 文件夹里一个都没有时画一个系统的文件夹符号（导入的脏数据兜底）。
private struct FolderGlyph: View {
  let folder: LaunchpadFolder
  let model: LaunchpadModel
  let size: CGFloat

  var body: some View {
    let mini = size * 0.255
    let apps = folder.apps.prefix(9).compactMap { model.app($0) }
    RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
      .fill(.white.opacity(0.14))
      .overlay {
        if apps.isEmpty {
          Image(systemName: "folder.fill")
            .font(.system(size: size * 0.44))
            .foregroundStyle(.white.opacity(0.55))
        } else {
          VStack(spacing: size * 0.055) {
            ForEach(0..<3, id: \.self) { row in
              HStack(spacing: size * 0.055) {
                ForEach(0..<3, id: \.self) { column in
                  let index = row * 3 + column
                  if index < apps.count {
                    Image(nsImage: model.icons.icon(for: apps[index], size: mini))
                      .resizable()
                      .interpolation(.high)
                      .frame(width: mini, height: mini)
                  } else {
                    Color.clear.frame(width: mini, height: mini)
                  }
                }
              }
            }
          }
        }
      }
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }
}
