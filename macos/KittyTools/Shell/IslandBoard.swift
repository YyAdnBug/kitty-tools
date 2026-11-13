// 刘海岛的「那一张」（2026-10-26，用户要能主动叫出来：点刘海、或者快捷键「打开刘海岛」）：上面一排快捷动作（截图、录屏、
// 录音、识字、截图翻译、快速记一条，关着的功能不出；开哪几个、什么先后在 设置 › 刘海岛），下面是本次启动以来最近 10 条提示，
// 新的在前（设置里能不列：那时只有快捷动作，都关了就一句话）。还能点的打开类按钮
// （在访达中显示、打开系统设置、打开设置）照样能点，点一行等于点它的按钮；撤销、取消这类过后再点会出事，不留。
// 用快捷键叫出时 ←→ 选中的快捷动作圆底换成强调色的焦点圈（第四轮体检 U9），↩ 执行它。
// 宽 420，画在岛的黑底上（同 Island 的深色、字号刻度），不另开窗口。

import SwiftUI

struct IslandBoard: View {
  let island: Island

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // 正在进行的活动（刘海岛扩展 B3）：最要紧的在上面，各带自己的按钮
      if !island.activities.isEmpty {
        VStack(spacing: 0) {
          ForEach(island.activities.sorted { ($0.kind, $0.started) > ($1.kind, $1.started) }) {
            ActivityRow(activity: $0) { island.perform($0) }
          }
        }
        .padding(.vertical, 6)
        Rectangle().fill(.white.opacity(0.12)).frame(height: 0.5)
      }
      if !island.quickActions.isEmpty {
        HStack(spacing: 6) {
          ForEach(Array(island.quickActions.enumerated()), id: \.offset) { index, action in
            QuickAction(action: action, selected: island.boardSelection == index) {
              island.perform(action)
            }
          }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
        .padding(.bottom, island.showsHistory ? 12 : 8)
        if island.showsHistory { Rectangle().fill(.white.opacity(0.12)).frame(height: 0.5) }
      }
      if !island.showsHistory {
        if island.quickActions.isEmpty { placeholder("快捷动作和最近的提示都关着") }
      } else if island.history.isEmpty {
        placeholder("还没有提示")
      } else {
        VStack(spacing: 0) {
          // 窗口一次定高（Island.boardHeight）：活动占了几行，列表就少列几条
          ForEach(island.history.prefix(max(Island.historyLimit - island.activities.count, 0))) {
            record in
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

  private func placeholder(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 12))
      .foregroundStyle(.white.opacity(0.45))
      .frame(maxWidth: .infinity)
      .padding(.vertical, 16)
  }
}

/// 一个快捷动作：36 pt 的圆底符号 + 11 pt 的名字，宽 60。键盘选中时圆底亮一档、外面一圈强调色（焦点环，Whisker §1）
private struct QuickAction: View {
  let action: Island.Action
  var selected = false
  let run: () -> Void

  var body: some View {
    Button(action: run) {
      VStack(spacing: 5) {
        Image(symbol: action.symbol ?? "circle")
          .font(.system(size: 15, weight: .medium))
          .foregroundStyle(.white.opacity(0.92))
          .frame(width: 36, height: 36)
          .background(Circle().fill(.white.opacity(selected ? 0.24 : 0.12)))
          .overlay {
            if selected { Circle().strokeBorder(Style.brand, lineWidth: 2).padding(-3) }
          }
        Text(action.title)
          .font(.system(size: 11))
          .foregroundStyle(.white.opacity(selected ? 0.95 : 0.75))
          .lineLimit(1)
      }
      .frame(width: 60)
      .contentShape(Rectangle())
    }
    .buttonStyle(IslandButtonStyle())
    .accessibilityLabel(action.title)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

/// 正在进行的一个活动（高 34）：耳朵上那两样（图标 / 一圈进度 + 读数）+ 标题 + 它的按钮（第一个是主按钮）
private struct ActivityRow: View {
  let activity: Island.Activity
  let perform: (Island.Action) -> Void

  var body: some View {
    if let media = activity.media {
      // 正在播放：封面、歌名 / 艺人、小一号的播放控制（IslandMedia.swift）
      IslandMediaRow(media: media, perform: perform)
    } else {
      row
    }
  }

  private var row: some View {
    HStack(spacing: 10) {
      IslandActivityMark(activity: activity, size: 16).frame(width: 22, height: 22)
      Text(activity.title)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white.opacity(0.92))
        .lineLimit(1)
      IslandActivityReading(activity: activity)
      Spacer(minLength: 8)
      ForEach(Array(activity.actions.enumerated().reversed()), id: \.offset) { index, action in
        IslandButton(title: action.title, prominent: index == 0) { perform(action) }
      }
    }
    .frame(height: 34)
    .accessibilityElement(children: .combine)
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
