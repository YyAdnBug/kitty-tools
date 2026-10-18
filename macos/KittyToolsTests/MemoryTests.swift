// 空闲回收的计时（Memory.IdleTimer，常驻内存 2026-10-07）：最后一次 schedule 之后过了时限、闲着才做一次；
// 到点时还忙着就再等一轮；放手之后不再做。真正回收了多少在内存探针里量（MemoryProbeTests），这里只锁计时的逻辑
// 和「算不算闲」（AppDelegate.isIdle，调优 T2：便签的窗口也算进来）

import AppKit
import SwiftUI
import Testing

@testable import KittyTools

struct MemoryTests {
  /// 连着 schedule 只算最后一次；头两轮还忙着不做，第三轮闲下来做一次，之后不再每轮都做。
  /// 不靠墙上时钟判断「做了」：全量并行跑时主线程被别的测试占着，等多久说不准，所以等 work 自己发信号
  @MainActor @Test(.timeLimit(.minutes(3))) func idleTimerWaitsUntilIdle() async {
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

  /// 算不算闲（AppDelegate.isIdle）：浮层（三块主面板）、全部便签窗口、展开着的那叠开着不算；一直展开时静置的那一列、
  /// 浮动便签、关着的窗口不拦；正在框选不算。窗口都摆在屏外、不当 key
  @MainActor @Test func idleIgnoresOnlyTheFloatingNote() throws {
    let far = NSRect(x: -20000, y: -20000, width: 300, height: 300)
    let store = try NoteStore(db: Database(path: ":memory:"))
    let note = store.create(body: "甲")
    let overlay = OverlayPanel(
      size: far.size, autoHide: .clickOutside, isPinned: { true }, content: Text("面板"))
    let notes = NSWindow(
      contentRect: far, styleMask: [.borderless], backing: .buffered, defer: true)
    notes.identifier = NotesWindow.identifier
    let deckModel = NoteDeckModel(store: store)
    deckModel.panelSize = CGSize(width: 538, height: 875)
    deckModel.pillCenter = 437
    let deck = NoteDeckPanel(frame: far, model: deckModel) {}
    let float = NoteFloatPanel(frame: far, model: NoteFloatModel(store: store))
    let windows: [NSWindow] = [overlay, notes, deck, float]
    defer {
      for window in windows { window.orderOut(nil) }
    }
    func idle(_ shown: [NSWindow], capturing: Bool = false) -> Bool {
      for window in windows where !shown.contains(where: { $0 === window }) { window.orderOut(nil) }
      for window in shown {
        window.setFrameOrigin(far.origin)
        window.orderFrontRegardless()
      }
      #expect(shown.allSatisfy { $0.isVisible && $0.screen == nil })  // 真的开着、没被挪进屏幕里
      return AppDelegate.isIdle(windows: windows, isCapturing: capturing)
    }
    #expect(idle([]))
    #expect(!idle([], capturing: true))
    #expect(!idle([overlay]))
    #expect(!idle([notes]))
    #expect(idle([float]), "浮动便签可以一直浮着：不拦")
    #expect(idle([deck]), "那叠收着（面板还没放掉）")
    deckModel.send(.pillEntered(optionDown: false, allowed: true))
    #expect(!idle([deck, float]), "扇着")
    deckModel.options.alwaysFanned = true
    #expect(idle([deck]), "一直展开时静置的那一列常驻屏幕上，不算展开")
    deckModel.tapTab(note.id)
    #expect(deckModel.state.openID == note.id)
    #expect(!idle([deck]), "打开着便签")
    // 真的全部便签窗口带着这个标识（不上屏、不记位置）
    let real = NotesWindow(model: NotesWindowModel(store: store), frameName: nil)
    #expect(real.window.identifier == NotesWindow.identifier)
  }
}
