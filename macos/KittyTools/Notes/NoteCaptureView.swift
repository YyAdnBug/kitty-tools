// 快速记一条的面板（Panel 皮肤，mac-whisker-notes.mdc「快速记一条」；状态和规则在 NoteCapture.swift）：
// 顶上一行「记到 新便签」+ 右边一排目的地（新便签 + 最近的 8 条，各是它的纸色圆点，选中的外面一圈强调色）；
// 中间是多行输入框（SourceTextView：↩ 记下、⇧↩ 换行，输入法组字时不误提交），3 行起、最多 8 行；
// 底栏左边是键位（只提示、不能点，secondary），存不了时换成原因；右边「记下 ↩」。

import SwiftUI

struct NoteCaptureView: View {
  @Bindable var model: NoteCaptureModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private typealias Layout = NoteCaptureModel.Layout

  var body: some View {
    VStack(spacing: 0) {
      header.frame(height: Layout.headerHeight)
      Hairline()
      editor
      Hairline()
      bar
    }
  }

  // MARK: 记到哪

  /// 线头和左右内边距用搜索线的（和启动器、剪贴板顶上那一行同一条左边线）
  private var header: some View {
    let shown = model.hovered ?? model.selectedIndex
    return SearchLine(symbol: "square.and.pencil") {
      Text("记到").foregroundStyle(.secondary)
      // 鼠标停在别的目的地上时先写它的名字（secondary：还没选）
      Text(model.title(of: shown))
        .foregroundStyle(shown == model.selectedIndex ? .primary : .secondary)
        .lineLimit(1)
        .truncationMode(.tail)
        .accessibilityHidden(true)
      Spacer(minLength: 12)
      HStack(spacing: 8) {
        ForEach(0...model.destinations.count, id: \.self) { destination($0) }
      }
      // 每个圆点外面留了 4 pt 给选中圈：往右让 4，最后一个圆点自己的右边和底栏「记下 ↩」同一条右边线
      .padding(.trailing, -4)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("记到哪")
    }
    .font(.system(size: 13))
  }

  /// 一个目的地：新便签是带加号的圆，已有的是它的纸色圆点；选中的外面隔 2 pt 一圈强调色（生效的范围）
  private func destination(_ index: Int) -> some View {
    let selected = model.selectedIndex == index
    let notes = model.destinations
    return Button {
      model.select(index)
    } label: {
      Group {
        if index == 0 {
          Image(systemName: "plus")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 18, height: 18)
            .background(Style.controlFill, in: .circle)
            .overlay(Circle().hairlineBorder())
        } else {
          NoteDot(paper: .of(notes[index - 1]), size: 18)
        }
      }
      .padding(4)
      .overlay {
        if selected { Circle().strokeBorder(Style.brand, lineWidth: 2).transition(.opacity) }
      }
      .contentShape(.circle)
    }
    .buttonStyle(.plain)
    .animation(Style.Motion.snap.animation(reduced: reduceMotion), value: selected)
    .background {
      // 浮层不激活本 App，SwiftUI 的 onHover 不可靠（同启动器的行）
      HoverTracker { inside in
        if inside { model.hovered = index } else if model.hovered == index { model.hovered = nil }
      }
    }
    .accessibilityLabel(index == 0 ? "新便签" : "记到「\(model.title(of: index))」")
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  // MARK: 输入框

  /// 滚动区铺满面板宽、文字缩进放在 horizontalInset 里（13 + NSTextView 自己的 5 = 18，和上下两行同一条左边线）：
  /// 滚动条贴面板右边
  private var editor: some View {
    SourceTextView(
      text: $model.draft, fontSize: Layout.fontSize, horizontalInset: Layout.margin - 5,
      onCancel: model.cancel
    ) {
      model.save()
    }
    .accessibilityLabel("便签内容")
    .frame(height: NoteCaptureModel.textHeight(for: model.draft) + 2 * Layout.textInset)
    .overlay(alignment: .topLeading) {
      if model.draft.isEmpty {
        Text("记点什么…")
          .font(.system(size: Layout.fontSize))
          .foregroundStyle(.tertiary)
          .padding(.leading, Layout.margin)
          .padding(.top, Layout.textInset)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
    }
    .padding(.vertical, Layout.textPadding)
  }

  // MARK: 底栏

  private var bar: some View {
    let count = model.destinations.count
    return HStack(spacing: 12) {
      if let notice = model.notice {
        BarNoticeView(notice: notice, undo: {})
          .transition(reduceMotion ? .opacity : AnyTransition(.blurReplace))
      } else {
        hint("换行", "⇧↩")
        hint("新便签", "⌘1")
        if count > 0 { hint("记到已有的", count == 1 ? "⌘2" : "⌘2–\(count + 1)") }
        hint("取消", "Esc")
      }
      Spacer(minLength: 8)
      Button {
        model.save()
      } label: {
        HStack(spacing: 6) {
          Text("记下")
          KeyCap("↩", primary: true).accessibilityHidden(true)
        }
        .opacity(model.canSave ? 1 : Style.disabledOpacity)
      }
      .disabled(!model.canSave)
      .accessibilityLabel("记下")
    }
    .animation(Style.Motion.settle.animation(reduced: reduceMotion), value: model.notice)
    .font(.system(size: 12))
    .lineLimit(1)
    .buttonStyle(.plain)
    .padding(.horizontal, Layout.margin)
    .frame(height: Layout.barHeight)
  }

  /// 只提示键位、不能点：secondary（mac-whisker §3「面板里共用的几件」）
  private func hint(_ text: String, _ key: String) -> some View {
    HStack(spacing: 6) {
      Text(text).foregroundStyle(.secondary)
      KeyCap(key)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(text)：\(key)")
  }
}
