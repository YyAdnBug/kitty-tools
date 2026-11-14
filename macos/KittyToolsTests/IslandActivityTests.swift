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

  /// 刘海岛插件没添加（2026-11-13 插件化 P1b）：活动不收、耳朵不露；移除时挂着的活动全收掉，进行中的提示不缩进耳朵
  @Test func extrasFollowPlugin() {
    let island = Island(showing: nil, geometry: notch)
    island.setActivity(activity("录屏", .record))
    #expect(island.isShowingWings)
    island.hasExtras = false
    #expect(island.activities.isEmpty && !island.isShowingWings)
    island.setActivity(activity("倒数", .reminder))
    #expect(island.activities.isEmpty && !island.isShowingWings)
    island.hasExtras = true
    island.setActivity(activity("倒数", .reminder))
    #expect(island.activities.count == 1)
  }

  /// 移除刘海岛插件时，缩进耳朵的进行中换回挂着的提示，之后的进度照常改它（评审 4：不然一直到结果出来都看不见、停不了）
  @Test func removingPluginBringsProgressBack() throws {
    let island = Island(showing: nil, geometry: notch)
    island.show("正在压缩", detail: "1%", tone: .progress)
    let shown = try #require(island.content)
    island.collapseProgress(shown)
    #expect(island.activities.count == 1)
    island.hasExtras = false
    #expect(island.activities.isEmpty)
    #expect(island.content?.title == "正在压缩" && island.content?.tone == .progress)
    island.progress("正在压缩", detail: "50%", fraction: 0.5)
    #expect(island.content?.detail == "50%" && island.content?.fraction == 0.5)
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

  /// 慢的长任务（刘海岛扩展 C4）：进行中的提示缩进耳朵后跟着进度走（按钮跟过去）；结果来了、做完自己收（dismiss(ifShowing:)）都收掉
  @Test func progressCollapsesIntoWings() throws {
    let island = Island(showing: nil, geometry: notch)
    island.show(
      "正在压缩", detail: "12%", tone: .progress, fraction: 0.12, actions: [Island.Action("停止") {}])
    let shown = try #require(island.content)
    island.collapseProgress(shown)
    #expect(island.content == nil && island.isShowingWings)
    #expect(island.activity?.id == Island.progressID("正在压缩"))
    #expect(island.activity?.actions.map(\.title) == ["停止"])
    island.progress("正在压缩", detail: "40%", fraction: 0.4)
    #expect(island.activity?.trailing == .fraction(0.4) && island.activity?.detail == "40%")
    island.show("已压缩")
    #expect(island.activities.isEmpty && island.content?.title == "已压缩")
    // 做完没有结果岛、调用方自己收的
    island.dismiss()
    island.show("正在导出", tone: .progress)
    island.collapseProgress(try #require(island.content))
    #expect(island.activity?.trailing == Island.Activity.Trailing.none)
    island.dismiss(ifShowing: "正在导出")
    #expect(island.activities.isEmpty && !island.isShowingWings)
  }

  /// 没有刘海屏：进行中的照旧挂着（菜单栏那一项是下一批）
  @Test func progressStaysWithoutNotch() throws {
    let island = Island(showing: nil, geometry: .capsule(menuBar: 24))
    island.show("正在压缩", tone: .progress)
    island.collapseProgress(try #require(island.content))
    #expect(island.content?.title == "正在压缩" && island.activities.isEmpty)
  }

  /// 没有刘海屏时菜单栏里挂哪个（H1）：挂得了耳朵时不挂；最要紧的是录制时不挂（它有自己的停止项）
  @Test func menuItemPicksNonRecordingTop() {
    let record = activity("录屏", .record)
    let countdown = activity("喝水", .reminder, trailing: .countdown(to: .now))
    #expect(IslandMenuItem.pick([countdown], wings: true) == nil)
    #expect(IslandMenuItem.pick([countdown], wings: false)?.id == "喝水")
    #expect(IslandMenuItem.pick([record, countdown], wings: false) == nil)
    #expect(IslandMenuItem.pick([], wings: false) == nil)
  }

  /// 两指往下滑 = 点刘海（G1）；「点刘海叫出那一张」关着（G2）时不响应，快捷键照样开
  @Test func swipeDownFollowsNotchSetting() {
    let island = Island(showing: nil, geometry: notch)
    island.respondsToNotch = false
    island.swipeDown()
    #expect(!island.isBoardOpen)
    island.toggleBoard()
    #expect(island.isBoardOpen)
    island.toggleBoard()
    island.respondsToNotch = true
    island.swipeDown()
    #expect(island.isBoardOpen)
    // 开着提示时不抢
    island.toggleBoard()
    island.show("已复制")
    island.swipeDown()
    #expect(!island.isBoardOpen)
  }

  /// 一个刘海只有一张面（2026-11-14）：有活动时点刘海 / 往下滑开的是最要紧那个活动的卡片，再往下滑轮到下一个活动、
  /// 最后是那一张，那一张上再往下滑回到第一个；没有活动时直接是那一张。别的提示开着时不轮
  @Test func openingAndRotating() {
    let record = activity("录屏", .record)
    let timer = activity("喝水", .reminder)
    let island = Island(showing: nil, geometry: notch, activities: [timer, record])
    island.swipeDown()
    #expect(island.cardActivity?.id == "录屏" && island.content != nil && !island.isBoardOpen)
    island.swipeDown()
    #expect(island.cardActivity?.id == "喝水" && !island.isBoardOpen)
    island.swipeDown()
    #expect(island.isBoardOpen && island.cardActivity == nil && island.content == nil)
    island.swipeDown()
    #expect(island.cardActivity?.id == "录屏" && !island.isBoardOpen)
    // 活动中途结束了：从剩下的接着轮
    island.endActivity("录屏")
    #expect(island.content == nil)
    island.openTop()
    #expect(island.cardActivity?.id == "喝水")
    island.rotate()
    #expect(island.isBoardOpen)
    island.toggleBoard()
    // 别的提示开着：不轮、不开
    island.show("已复制")
    island.swipeDown()
    island.rotate()
    #expect(island.content?.title == "已复制" && !island.isBoardOpen)
    // 没有活动：打开就是那一张；那一张上再往下滑不动
    let idle = Island(showing: nil, geometry: notch)
    idle.openTop()
    #expect(idle.isBoardOpen)
    idle.swipeDown()
    #expect(idle.isBoardOpen)
    // 卡片开着时用快捷键叫出那一张：卡片的标记清掉；卡片开着、有排着的提示时活动结束：换上排着的那条
    let keyed = Island(showing: nil, geometry: notch, activities: [record])
    keyed.tapped()
    keyed.toggleBoard(byKeyboard: false)
    #expect(keyed.isBoardOpen && keyed.cardActivity == nil)
    // 只有暂停了一阵的正在播放（不上耳朵）：打开是那一张，从那一张往下滑轮得到它
    var paused = activity("音乐", .media)
    paused.onWings = false
    let quiet = Island(showing: nil, geometry: notch, activities: [paused])
    quiet.openTop()
    #expect(quiet.isBoardOpen)
    quiet.swipeDown()
    #expect(quiet.cardActivity?.id == "音乐")
    // 设置里关了「点刘海打开」：往下滑不开、也不轮
    let off = Island(showing: nil, geometry: notch, activities: [record])
    off.respondsToNotch = false
    off.swipeDown()
    #expect(off.content == nil)
    off.tapped()
    off.swipeDown()
    #expect(off.cardActivity?.id == "录屏" && !off.isBoardOpen)
    // 刚换过面的 0.8 秒里不轮（悬停刚把卡片展开，那一下点击才到）
    let start = ContinuousClock.now
    #expect(Island.canTurn(since: nil, now: start))
    #expect(!Island.canTurn(since: start, now: start + .milliseconds(300)))
    #expect(Island.canTurn(since: start, now: start + .milliseconds(800)))
    // 点在刘海上该做什么
    #expect(Island.notchClick(hasContent: false, boardOpen: false, cardOpen: false) == .open)
    #expect(Island.notchClick(hasContent: false, boardOpen: true, cardOpen: false) == .closeBoard)
    #expect(Island.notchClick(hasContent: true, boardOpen: false, cardOpen: true) == .rotate)
    #expect(Island.notchClick(hasContent: true, boardOpen: false, cardOpen: false) == .ignore)
  }

  /// 提示照旧从刘海长出来（盖住耳朵），收起后还是耳朵；那一张同样
  @Test func noticesAndBoardReturnToWings() {
    let island = Island(showing: nil, geometry: notch, activities: [activity("录屏", .record)])
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
