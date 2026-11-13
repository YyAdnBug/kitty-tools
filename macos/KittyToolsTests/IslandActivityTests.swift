// 刘海岛的活动（2026-11-13，刘海岛扩展 B1–B3）：耳朵上露哪一个、读数怎么写，和岛在有活动时的几种状态。
// 用摆出来的岛（Island(showing:…)）：从头到尾不建窗口。

import Foundation
import Testing

@testable import KittyTools

@MainActor
struct IslandActivityTests {
  private let notch = Island.Geometry.notch(width: 212, height: 37.5)

  private func activity(
    _ id: String, _ kind: Island.Activity.Kind, started: Date = .now,
    trailing: Island.Activity.Trailing = .none, actions: [Island.Action] = []
  ) -> Island.Activity {
    Island.Activity(
      id: id, kind: kind, title: id, symbol: "circle.fill", trailing: trailing, actions: actions,
      started: started)
  }

  /// 拍板 B2：录制 > 长任务进度 > 保持唤醒 > 提醒倒数；同一类后开始的先
  @Test func topPicksMostImportantThenLatest() {
    let early = Date(timeIntervalSince1970: 1000)
    let late = Date(timeIntervalSince1970: 2000)
    #expect(Island.Activity.top([]) == nil)
    #expect(
      Island.Activity.top([
        activity("提醒", .reminder, started: late), activity("压缩", .progress, started: early),
        activity("唤醒", .awake, started: late),
      ])?.id == "压缩")
    #expect(
      Island.Activity.top([
        activity("录屏", .record, started: early), activity("压缩", .progress, started: late),
      ])?.id == "录屏")
    #expect(
      Island.Activity.top([
        activity("早", .progress, started: early), activity("晚", .progress, started: late),
      ])?.id == "晚")
  }

  /// 右耳的字：计时同录制 HUD，倒数往上取整、到 0 停住，百分比取整、夹在 0…100
  @Test func readings() {
    let now = Date(timeIntervalSince1970: 10_000)
    let reading = { Island.Activity.reading($0, now: now) }
    #expect(reading(.elapsed(since: now.addingTimeInterval(-42))) == "0:42")
    #expect(reading(.elapsed(since: now.addingTimeInterval(-3723))) == "1:02:03")
    #expect(reading(.elapsed(since: now.addingTimeInterval(5))) == "0:00")
    #expect(reading(.countdown(to: now.addingTimeInterval(581.2))) == "9:42")
    #expect(reading(.countdown(to: now.addingTimeInterval(-3))) == "0:00")
    #expect(reading(.fraction(0.376)) == "37%")
    #expect(reading(.fraction(1.4)) == "100%")
    #expect(reading(.text("1 小时")) == "1 小时")
    #expect(reading(.none) == nil)
    #expect(activity("a", .record, trailing: .elapsed(since: now)).ticks)
    #expect(!activity("a", .progress, trailing: .fraction(0.3)).ticks)
  }

  /// 刘海屏：有活动就露耳朵，全结束就收；同一个编号再来一次原地换、开始的时刻不变
  @Test func wingsFollowActivities() {
    let island = Island(showing: nil, geometry: notch)
    #expect(!island.isShowingWings)
    let started = Date(timeIntervalSince1970: 1000)
    island.setActivity(activity("录屏", .record, started: started))
    #expect(island.isShowingWings && island.activity?.id == "录屏")
    var renamed = activity("录屏", .record)
    renamed.title = "录屏已暂停"
    island.setActivity(renamed)
    #expect(island.activities.count == 1 && island.activities[0].title == "录屏已暂停")
    #expect(island.activities[0].started == started)
    island.endActivity("录屏")
    #expect(!island.isShowingWings && island.activities.isEmpty)
  }

  /// 没有刘海的屏不挂耳朵（H1：放菜单栏）；活动照样记着，那一张里列得出来
  @Test func capsuleScreensHaveNoWings() {
    let island = Island(showing: nil, geometry: .capsule(menuBar: 24))
    island.setActivity(activity("压缩", .progress, trailing: .fraction(0.4)))
    #expect(!island.isShowingWings && island.activities.count == 1)
  }

  /// 点耳朵展开成卡片（带活动的按钮）；收起后回到耳朵；它更新时卡片原地换，结束时收起
  @Test func tapExpandsTheActivityCard() {
    var stopped = false
    let stop = Island.Action("停止") { stopped = true }
    let island = Island(
      showing: nil, geometry: notch,
      activities: [activity("录屏", .record, actions: [stop])])
    #expect(island.isShowingWings)
    island.tapped()
    #expect(island.content?.title == "录屏" && island.isExpanded && island.isOpen)
    #expect(island.actions.map(\.title) == ["停止"])
    var paused = activity("录屏", .record, actions: [stop])
    paused.title = "录屏已暂停"
    island.setActivity(paused)
    #expect(island.content?.title == "录屏已暂停")
    island.dismiss()
    #expect(island.content == nil && island.isShowingWings)
    // 再展开、活动结束：卡片收起、耳朵也收
    island.tapped()
    #expect(island.content != nil)
    island.endActivity("录屏")
    #expect(island.content == nil && !island.isShowingWings)
    #expect(!stopped)
  }

  /// 提示照旧从刘海长出来（盖住耳朵），收起后还是耳朵；那一张同样
  @Test func noticesAndBoardReturnToWings() {
    let island = Island(showing: nil, geometry: notch, activities: [activity("压缩", .progress)])
    island.show("已复制")
    #expect(island.content?.title == "已复制" && island.isShowingWings)
    island.dismiss()
    #expect(island.content == nil && island.isShowingWings)
    island.toggleBoard()
    #expect(island.isBoardOpen)
    island.toggleBoard()
    #expect(!island.isBoardOpen && island.isShowingWings)
  }
}
