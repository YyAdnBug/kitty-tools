// 没有刘海屏时，刘海岛的活动放在菜单栏里（2026-11-13，刘海岛扩展 H1）：没刘海的 Mac、合盖只用外接屏、新 MacBook Pro
// （系统灵动岛，那一块让给系统）上没有耳朵，最要紧的那个活动挂在菜单栏右边另起的一项上——同录屏的停止项「■ 0:42」：
// 12 pt 等宽数字，左边是活动的符号（模板图，跟着菜单栏深浅）。点它 = 同点耳朵，展开成卡片（菜单栏下方正中，同那里的提示）。
// 录制自己有停止项（ScreenRecorder.makeStopItem），最要紧的是录制时这里不再挂一个（菜单栏里不重复，拍板 H1）。
// 每秒在变的读数（提醒倒数）只在这一项挂着时每秒换一次字（菜单开着时也走：.common）。

import AppKit

@MainActor final class IslandMenuItem: NSObject {
  /// 点了这一项（Island 接：展开那个活动的卡片）
  var onClick: (String) -> Void = { _ in }
  private var item: NSStatusItem?
  private var shown: Island.Activity?
  private var timer: Timer?

  /// 菜单栏里挂哪一个（纯函数，单测锁住）：挂得了耳朵时不挂；最要紧的是录制时也不挂（它有自己的停止项）
  static func pick(_ activities: [Island.Activity], wings: Bool) -> Island.Activity? {
    guard !wings, let top = Island.Activity.top(activities), top.kind != .record else { return nil }
    return top
  }

  func show(_ activity: Island.Activity?) {
    guard let activity else { return hide() }
    shown = activity
    let item = self.item ?? makeItem()
    self.item = item
    if let button = item.button {
      let image = NSImage(systemSymbolName: activity.symbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
      image?.isTemplate = true
      button.image = image
      button.setAccessibilityLabel(activity.title)
    }
    refresh()
    if activity.ticks, timer == nil {
      let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.refresh() }
      }
      RunLoop.main.add(timer, forMode: .common)
      self.timer = timer
    } else if !activity.ticks {
      timer?.invalidate()
      timer = nil
    }
  }

  func hide() {
    timer?.invalidate()
    timer = nil
    shown = nil
    if let item { NSStatusBar.system.removeStatusItem(item) }
    item = nil
  }

  private func refresh() {
    guard let shown, let button = item?.button else { return }
    let reading = Island.Activity.reading(shown.trailing, now: .now) ?? ""
    button.title = reading.isEmpty ? "" : " " + reading
    button.setAccessibilityValue(reading)
  }

  private func makeItem() -> NSStatusItem {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = item.button {
      button.imagePosition = .imageLeading
      button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
      button.target = self
      button.action = #selector(clicked)
    }
    return item
  }

  @objc private func clicked() {
    if let shown { onClick(shown.id) }
  }
}
