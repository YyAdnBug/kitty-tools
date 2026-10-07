// 空闲回收的计时（Memory.IdleTimer，常驻内存 2026-10-07）：最后一次 schedule 之后过了时限、闲着才做一次；
// 到点时还忙着就再等一轮；放手之后不再做。真正回收了多少在内存探针里量（MemoryProbeTests），这里只锁计时的逻辑

import Testing

@testable import KittyTools

struct MemoryTests {
  /// 连着 schedule 只算最后一次；头两轮还忙着不做，第三轮闲下来做一次，之后不再每轮都做。
  /// 不靠墙上时钟判断「做了」：全量并行跑时主线程被别的测试占着，等多久说不准，所以等 work 自己发信号
  @MainActor @Test(.timeLimit(.minutes(1))) func idleTimerWaitsUntilIdle() async {
    var busyRounds = 2
    var runs = 0
    let (done, signal) = AsyncStream<Void>.makeStream()
    let timer = Memory.IdleTimer(
      after: .milliseconds(20),
      isIdle: {
        guard busyRounds == 0 else {
          busyRounds -= 1
          return false
        }
        return true
      },
      work: {
        runs += 1
        signal.yield()
      })
    timer.schedule()
    timer.schedule()
    timer.schedule()
    for await _ in done { break }
    #expect(runs == 1 && busyRounds == 0)
    try? await Task.sleep(for: .milliseconds(150))
    #expect(runs == 1)
  }

  /// 没人拿着它了就不做（等着的那一轮醒来发现自己没了）
  @MainActor @Test func idleTimerStopsWhenReleased() async {
    var runs = 0
    var timer: Memory.IdleTimer? = Memory.IdleTimer(
      after: .milliseconds(20), isIdle: { true }, work: { runs += 1 })
    timer?.schedule()
    timer = nil
    try? await Task.sleep(for: .milliseconds(150))
    #expect(runs == 0)
  }
}
