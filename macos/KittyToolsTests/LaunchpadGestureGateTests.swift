// 只喂系统手势元数据，不安装拦截、不读真实输入或用户偏好。
import Testing

@testable import KittyTools

struct LaunchpadGestureGateTests {
  private func feed(
    _ state: inout LaunchpadGestureGate.Ownership, _ phase: Int64, open: Bool,
    type: UInt32 = 30, hid: Int64 = 23, motion: Int64 = 3
  ) -> Bool {
    state.swallow(type: type, hid: hid, motion: motion, phase: phase, isOpen: open)
  }

  @Test func openPanelOwnsWholeGestureEvenAfterClosing() {
    var state = LaunchpadGestureGate.Ownership()
    #expect(feed(&state, 1, open: true))
    #expect(feed(&state, 2, open: false))
    #expect(feed(&state, 4, open: false))
    #expect(state.owner == nil)
    #expect(!feed(&state, 1, open: false))
  }

  @Test func systemKeepsOwnershipWhenPanelOpensMidGesture() {
    var state = LaunchpadGestureGate.Ownership()
    #expect(!feed(&state, 1, open: false))
    #expect(!feed(&state, 2, open: true))
    #expect(!feed(&state, 4, open: true))
    #expect(state.owner == nil)
  }

  @Test func repeatedBeganDoesNotRelatchPanelState() {
    for initial in [false, true] {
      var state = LaunchpadGestureGate.Ownership()
      #expect(feed(&state, 1, open: initial) == initial)
      #expect(feed(&state, 1, open: !initial) == initial)
      #expect(feed(&state, 4, open: !initial) == initial)
    }
  }

  @Test func terminalBitsAndMotionLowBitsMatchDock() {
    for terminal: Int64 in [4, 8, 12, 20] {
      var state = LaunchpadGestureGate.Ownership()
      #expect(feed(&state, 1, open: true, motion: 0x10003))
      #expect(feed(&state, terminal, open: false, motion: 0x10003))
      #expect(state.owner == nil)
    }
  }

  @Test func missingBeganAndUnknownPhasePassThrough() {
    var state = LaunchpadGestureGate.Ownership()
    #expect(!feed(&state, 2, open: true))
    #expect(!feed(&state, 4, open: true))
    #expect(feed(&state, 1, open: true))
    #expect(!feed(&state, 128, open: true))
    #expect(state.owner == nil)
    #expect(!feed(&state, 2, open: true))
  }

  @Test func otherAxesTypesAndSubtypesAlwaysPass() {
    var state = LaunchpadGestureGate.Ownership()
    #expect(feed(&state, 1, open: true))
    for motion: Int64 in [0, 1, 2, 4, 6, 7] {
      #expect(!feed(&state, 2, open: true, motion: motion))
    }
    #expect(!feed(&state, 2, open: true, type: 10))
    #expect(!feed(&state, 2, open: true, hid: 8))
    #expect(feed(&state, 4, open: false))
  }

  @Test func onlyOwnedCancellationEnvelopeIsSwallowed() {
    var state = LaunchpadGestureGate.Ownership()
    #expect(!feed(&state, 0, open: true, type: 29, hid: 60))
    #expect(feed(&state, 1, open: true))
    for hid: Int64 in [0, 5, 8, 22, 23] {
      #expect(!feed(&state, 0, open: true, type: 29, hid: hid))
    }
    #expect(feed(&state, 0, open: false, type: 29, hid: 60))
    #expect(state.owner == nil)
    #expect(!feed(&state, 2, open: true))
    #expect(!feed(&state, 4, open: true))
  }

  @Test func resetAfterTapLossDoesNotTakeOverContinuation() {
    var state = LaunchpadGestureGate.Ownership()
    #expect(feed(&state, 1, open: true))
    state.reset()
    #expect(!feed(&state, 2, open: true))
    #expect(!feed(&state, 8, open: true))
    #expect(feed(&state, 1, open: true))
  }

  @Test func systemCancellationEnvelopeEndsItsOwnership() {
    var state = LaunchpadGestureGate.Ownership()
    #expect(!feed(&state, 1, open: false))
    #expect(!feed(&state, 0, open: true, type: 29, hid: 60))
    #expect(state.owner == nil)
    #expect(feed(&state, 1, open: true))
    #expect(feed(&state, 4, open: false))
  }
}
