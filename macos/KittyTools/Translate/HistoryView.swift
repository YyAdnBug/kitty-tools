// 翻译历史（覆盖在浮窗结果区上）：搜索原文 / 译文、可只看收藏（生词本），点一条把原文放回去重新翻译；
// 收藏、复制译文、删除；底部「共 N 条 · 收藏 M」与清空（只清非收藏，先确认）。导出在设置 › 翻译。

import SwiftUI

struct HistoryView: View {
  let history: HistoryStore
  let onApply: (HistoryStore.Entry) -> Void
  let onClose: () -> Void
  @State private var query = ""
  @State private var favoritesOnly = false
  @State private var confirmClear = false

  var body: some View {
    let _ = history.revision  // 改动后刷新查询
    let entries = history.search(query, favoritesOnly: favoritesOnly)
    let counts = history.counts
    VStack(spacing: 0) {
      HStack {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("搜索翻译历史", text: $query).textFieldStyle(.plain)
        Toggle(isOn: $favoritesOnly) {
          Image(systemName: favoritesOnly ? "star.fill" : "star")
        }
        .toggleStyle(.button)
        .foregroundStyle(favoritesOnly ? AnyShapeStyle(.yellow) : AnyShapeStyle(.secondary))
        .help(favoritesOnly ? "显示全部" : "只看收藏")
        Button("关闭", systemImage: "xmark", action: onClose)
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
      }
      .padding(10)
      Divider()
      if entries.isEmpty {
        ContentUnavailableView(
          query.isEmpty ? (favoritesOnly ? "还没有收藏（⌘S 收藏当前翻译）" : "还没有翻译历史") : "没有匹配的记录",
          systemImage: favoritesOnly ? "star" : "clock"
        )
        .frame(maxHeight: .infinity)
      } else {
        List(entries) { entry in
          Button {
            onApply(entry)
          } label: {
            row(entry)
          }
          .buttonStyle(.plain)
          .contextMenu {
            Button("复制译文") { Paster.write(string: entry.result) }
            Button(entry.favorite ? "取消收藏" : "收藏") {
              history.setFavorite(entry.id, !entry.favorite)
            }
            Divider()
            Button("删除", role: .destructive) { history.delete(entry.id) }
          }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
      }
      Divider()
      HStack {
        Text("共 \(counts.total) 条 · 收藏 \(counts.favorites)").foregroundStyle(.secondary)
        Spacer()
        Button("清空历史…") { confirmClear = true }.disabled(counts.total == counts.favorites)
      }
      .font(.caption)
      .buttonStyle(.borderless)
      .padding(.horizontal, 10)
      .frame(height: 30)
    }
    .confirmationDialog("清空翻译历史？", isPresented: $confirmClear) {
      Button("清空", role: .destructive) { history.clearNonFavorites() }
    } message: {
      Text("收藏的记录会保留")
    }
  }

  private func row(_ entry: HistoryStore.Entry) -> some View {
    HStack(alignment: .top, spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(entry.source).lineLimit(1).truncationMode(.tail)
        Text(entry.result).font(.callout).foregroundStyle(.secondary).lineLimit(1)
          .truncationMode(.tail)
      }
      Spacer(minLength: 4)
      VStack(alignment: .trailing, spacing: 2) {
        Text(Self.time(entry.createdAt)).font(.caption2).foregroundStyle(.tertiary)
        Button(entry.favorite ? "取消收藏" : "收藏", systemImage: entry.favorite ? "star.fill" : "star") {
          history.setFavorite(entry.id, !entry.favorite)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .foregroundStyle(entry.favorite ? .yellow : .secondary)
      }
    }
    .contentShape(.rect)
  }

  /// 今天 HH:mm / 昨天 HH:mm / 今年 M月d日 / 跨年 yyyy年M月d日
  private static func time(_ date: Date) -> String {
    let calendar = Calendar.current
    let chinese = Locale(identifier: "zh-Hans")
    let clock = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().locale(chinese))
    if calendar.isDateInToday(date) { return clock }
    if calendar.isDateInYesterday(date) { return "昨天 \(clock)" }
    return calendar.isDate(date, equalTo: .now, toGranularity: .year)
      ? date.formatted(.dateTime.month().day().locale(chinese))
      : date.formatted(.dateTime.year().month().day().locale(chinese))
  }
}
