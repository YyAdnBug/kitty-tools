import Testing

@testable import KittyTools

struct LaunchpadDesktopStateTests {
  @Test func startsUnknown() {
    #expect(!LaunchpadDesktopState.State.unknown.isShowingDesktop)
  }

  @Test func desktopNotificationYieldsPinch() {
    var state = LaunchpadDesktopState.State.unknown
    state.receive("AXExposeShowDesktop")
    #expect(state.isShowingDesktop)
    state.receive("AXExposeExit")
    #expect(!state.isShowingDesktop)
  }

  @Test func otherOverviewNotificationsDoNotMeanDesktop() {
    for name in ["AXExposeShowAllWindows", "AXExposeShowFrontWindows"] {
      var state = LaunchpadDesktopState.State.desktop
      state.receive(name)
      #expect(state == .other)
    }
  }

  @Test func unrelatedNotificationsDoNotChangeKnownState() {
    var state = LaunchpadDesktopState.State.desktop
    state.receive("AXFocusedWindowChanged")
    #expect(state.isShowingDesktop)
    state = .unknown
    #expect(!state.isShowingDesktop)
  }
}
