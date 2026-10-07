// 把内存还给系统（第二轮体检 M4；空闲回收是 2026-10-07 查常驻内存后加的，PLAN §10「常驻内存」）。
// relieve：让分配器把用完的空页还回去。malloc 放掉的内存平时留在进程里等着再用，活动监视器里的数不降；刚丢掉一大块
// 东西之后调一次，空下来的页当场还。实测（内存探针）：⌘Y 大卡看过一张整屏截图、丢掉它的缩略图后，解码用的那 14 MB
// 不调就一直留着，调了当场还；调用本身 0.3–4 ms。
// 只在两种时候调：① 刚丢掉一大块、界面已经收走（剪贴板 ⌘Y 大卡放掉之后，AppDelegate.quickLookPanel）；
// ② 空闲回收（AppDelegate.idleReclaim：面板都收起 idleDelay 之后，连透镜缓存一起清）。
// 截图、转 GIF 之后不调（实测它们自己还得干净，调了也还不出东西）；别在动画中间、每次收面板时调。

import Foundation

enum Memory {
  /// 所有 zone、能还多少还多少
  static func relieve() {
    _ = malloc_zone_pressure_relief(nil, 0)
  }

  /// 空闲回收等多久：最后一块面板收起后这么久没再呼出才做。两分钟：来回切着用的时候不白清（透镜缓存清了再看到要
  /// 重做，一张 14–97 ms），停下来之后活动监视器里的数也不用等太久
  static let idleDelay: Duration = .seconds(120)

  /// 空闲回收的计时：每次 schedule 重新计时；到点了闲着（isIdle）才做一次 work，还忙着就再等一轮。
  /// 放手（没人拿着它）之后不再做
  final class IdleTimer {
    private let delay: Duration
    private let isIdle: () -> Bool
    private let work: () -> Void
    private var pending: Task<Void, Never>?

    init(after delay: Duration, isIdle: @escaping () -> Bool, work: @escaping () -> Void) {
      self.delay = delay
      self.isIdle = isIdle
      self.work = work
    }

    func schedule() {
      pending?.cancel()
      pending = Task { [weak self, delay] in
        while true {
          try? await Task.sleep(for: delay)
          guard !Task.isCancelled, let self else { return }
          if isIdle() {
            work()
            return
          }
        }
      }
    }
  }
}
