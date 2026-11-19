// 刘海岛的活动（刘海岛扩展 B1–B3、C4；第五轮体检 H1 从 Island.swift 拆出）：开始 / 结束一个活动、展开成卡片、耳朵露不露，慢的进行中提示缩进耳朵。

import AppKit
import SwiftUI

extension Island {
  // MARK: 活动

  /// 耳朵上露的那一个（拍板 B2）
  var activity: Activity? { Activity.top(activities) }

  /// 卡片展开着的那个活动
  var cardActivity: Activity? { activities.first { $0.id == expandedActivity } }

  /// 开始 / 更新一个活动（同一个 id 再来一次 = 原地换，开始的时刻不变）。刘海屏上收起时挂到耳朵上；
  /// 它的卡片正展开着就原地换内容和按钮
  func setActivity(_ activity: Activity) {
    guard hasExtras else { return }
    var next = activity
    if let index = activities.firstIndex(where: { $0.id == activity.id }) {
      next.started = activities[index].started
      activities[index] = next
    } else {
      activities.append(next)
    }
    if expandedActivity == next.id, content != nil {
      content = next.content
      actions = next.actions
      buttonsChanged()
    }
    refreshWings()
  }

  /// 活动结束：它的卡片正展开着就收起；没有活动了耳朵缩回刘海
  func endActivity(_ id: String) {
    guard activities.contains(where: { $0.id == id }) else { return }
    // 它的卡片（或者它的一瞥）正出着：先收（内容清掉），再把活动拿走——反过来有一拍「内容还在、活动没了」，会闪出
    // 一条普通样式的行；一瞥留着的话指针移上去会展开成普通卡片
    if expandedActivity == id || glancing == id, content != nil { dismiss() }
    activities.removeAll { $0.id == id }
    if expandedActivity == id { expandedActivity = nil }
    refreshWings()
  }

  /// 点耳朵：最要紧的那个活动展开成卡片（同悬停展开的样子），收起后回到耳朵
  func expandActivity() {
    if let activity { expand(activity.id) }
  }

  /// 某个活动展开成卡片（耳朵、菜单栏那一项都走这里）
  func expand(_ id: String) {
    guard let activity = activities.first(where: { $0.id == id }) else { return }
    hoverExpand?.cancel()
    hoverExpand = nil
    haptic()
    isPeeking = false
    turnedAt = .now
    // 「是它的卡片」和内容在同一个事务里换（apply 的说明）
    apply(activity.content, actions: activity.actions, quiet: true, card: activity.id)
    withAnimation(Self.resize) { isExpanded = true }
  }

  /// 耳朵该不该露：有活动、有刘海屏（摆出来的岛看给的几何）。没开着别的时当场长出 / 缩回；开着提示、那一张时只改标记，
  /// 它们收起时（dismiss）照这个缩回耳朵
  func refreshWings() {
    let wanted = activity != nil && canShowWings
    if !isStaged { menuItem.show(IslandMenuItem.pick(activities, wings: canShowWings)) }
    guard wanted != isShowingWings else { return }
    if wanted, !isOpen, !isStaged { showWindow(on: Self.notchScreen) }
    withAnimation((wanted ? Style.Motion.island : Style.Motion.retract).animation()) {
      isShowingWings = wanted
    }
    guard !wanted, !isOpen, !isStaged else { return }
    Task { [weak self] in
      try? await Task.sleep(for: Self.retractTime)
      guard let self, !self.isOpen, !self.isPeeking, !self.isShowingWings else { return }
      self.window?.orderOut(nil)
    }
  }

  /// 有刘海的那块屏（耳朵挂在它上面）；没有是 nil
  static var notchScreen: NSScreen? {
    NSScreen.screens.first { notchRect(of: $0) != nil }
  }

  /// 挂得了耳朵：有刘海屏（摆出来的岛看给的几何）
  private var canShowWings: Bool {
    if isStaged {
      if case .notch = geometry { true } else { false }
    } else {
      Self.notchScreen != nil
    }
  }

  // MARK: 慢的长任务缩进耳朵（刘海岛扩展 C4）

  /// 进行中的提示挂满这么久还没做完，缩回耳朵
  static let progressCollapse = Duration.seconds(3)
  /// 缩进耳朵的进行中多久没有新进度就收掉（同原来进行中提示的 60 s 兜底）
  static let progressExpiry = Duration.seconds(60)

  /// 缩进耳朵的进行中那个活动的编号：key 分开不同的句子（译文可能撞），取出来的字分开同一句插了不同的值
  static func progressID(_ title: LocalizedStringResource) -> String {
    "progress:" + title.key + "\u{1F}" + String(localized: title)
  }

  /// 进行中的提示出来了：挂满 3 秒还是它（指针不在上面）就缩进耳朵；指针在上面就等它离开
  func collapseLater(_ title: LocalizedStringResource) {
    collapseTask?.cancel()
    guard hasExtras else { return }
    collapseTask = Task { [weak self] in
      try? await Task.sleep(for: Self.progressCollapse)
      while !Task.isCancelled {
        guard let self, let content = self.content, content.tone == .progress,
          content.source == title
        else { return }
        if !self.isHovered, !self.isBoardOpen, !self.holdsKeyboard {
          return self.collapseProgress(content)
        }
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  /// 把正显示着的进行中提示换成耳朵上的活动（左一圈进度、右百分比；说不出做到哪的只有记号），按钮（停止）跟过去，
  /// 提示收起、缩回耳朵。没有刘海屏时照旧挂着（菜单栏那一项是第 1-3 批）
  func collapseProgress(_ content: Content) {
    guard hasExtras, canShowWings, self.content == content else { return }
    setActivity(
      Activity(
        id: Self.progressID(content.source), kind: .progress, title: content.title,
        detail: content.detail, symbol: content.symbol,
        trailing: content.fraction.map { .fraction($0) } ?? .none, actions: actions,
        source: content.source))
    expireProgressLater()
    dismiss()
  }

  /// 缩进耳朵的进行中都收掉（结果来了）
  func endProgress() {
    for activity in activities where activity.kind == .progress { endActivity(activity.id) }
    expiryTask?.cancel()
  }

  func expireProgressLater() {
    expiryTask?.cancel()
    expiryTask = Task { [weak self] in
      try? await Task.sleep(for: Self.progressExpiry)
      if !Task.isCancelled { self?.endProgress() }
    }
  }
}
