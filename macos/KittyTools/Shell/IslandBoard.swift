// 刘海岛的「那一张」（2026-10-26，用户要能主动叫出来：点刘海、或者快捷键「打开刘海岛」）：上面一排快捷动作（截图、录屏、
// 录音、识字、截图翻译、快速记一条，关着的功能不出），下面是本次启动以来最近 10 条提示，新的在前。还能点的打开类按钮
// （在访达中显示、打开系统设置、打开设置）照样能点，点一行等于点它的按钮；撤销、取消这类过后再点会出事，不留。
// 宽 420，画在岛的黑底上（同 Island 的深色、字号刻度），不另开窗口。

import SwiftUI

struct IslandBoard: View {
  let island: Island

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if !island.quickActions.isEmpty {
        HStack(spacing: 6) {
          ForEach(Array(island.quickActions.enumerated()), id: \.offset) { _, action in
            QuickAction(action: action) { island.perform(action) }
          }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
        .padding(.bottom, 12)
        Rectangle().fill(.white.opacity(0.12)).frame(height: 0.5)
      }
      if island.history.isEmpty {
        Text("还没有提示")
          .font(.system(size: 12))
          .foregroundStyle(.white.opacity(0.45))
          .frame(maxWidth: .infinity)
          .padding(.vertical, 16)
      } else {
        VStack(spacing: 0) {
          ForEach(island.history) { record in
            Row(record: record) { island.perform($0) }
          }
        }
        .padding(.vertical, 6)
      }
    }
    .padding(.horizontal, 14)
    .padding(.bottom, 4)
    .frame(width: Island.boardWidth)
  }
}

/// 一个快捷动作：36 pt 的圆底符号 + 11 pt 的名字，宽 60
private struct QuickAction: View {
  let action: Island.Action
  let run: () -> Void

  var body: some View {
    Button(action: run) {
      VStack(spacing: 5) {
        Image(symbol: action.symbol ?? "circle")
          .font(.system(size: 15, weight: .medium))
          .foregroundStyle(.white.opacity(0.92))
          .frame(width: 36, height: 36)
          .background(Circle().fill(.white.opacity(0.12)))
        Text(action.title)
          .font(.system(size: 11))
          .foregroundStyle(.white.opacity(0.75))
          .lineLimit(1)
      }
      .frame(width: 60)
      .contentShape(Rectangle())
    }
    .buttonStyle(IslandButtonStyle())
    .accessibilityLabel(action.title)
  }
}

/// 列表里的一行（高 34）：前导 + 标题 / 详情 + 多久以前 + 打开类的按钮；有按钮时点整行等于点它
private struct Row: View {
  let record: Island.Record
  let perform: (Island.Action) -> Void

  var body: some View {
    let first = record.actions.first
    HStack(spacing: 10) {
      IslandLeading(content: record.content)
      VStack(alignment: .leading, spacing: 1) {
        Text(record.content.title)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.white.opacity(0.92))
          .lineLimit(1)
        if let detail = record.content.detail {
          Text(detail)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.5))
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      Spacer(minLength: 8)
      Text(record.at, format: .relative(presentation: .named))
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(.white.opacity(0.4))
        .lineLimit(1)
        .fixedSize()
      if let first {
        IslandButton(title: first.title, prominent: false) { perform(first) }
      }
    }
    .frame(height: 34)
    .contentShape(Rectangle())
    .onTapGesture { if let first { perform(first) } }
    .accessibilityElement(children: .combine)
  }
}
