// 系统应用程序捏合的版本差异：只读写临时偏好域，不接触系统的 Dock / 触控板偏好。

import Foundation
import Testing

@testable import KittyTools

struct TrackpadSystemGestureTests {
  private func withDefaults(_ body: (UserDefaults, [UserDefaults]) -> Void) throws {
    let names = (0..<3).map { "launchpad.system-gesture.test.\(UUID().uuidString).\($0)" }
    let values = try names.map { name in try #require(UserDefaults(suiteName: name)) }
    defer {
      for (name, defaults) in zip(names, values) { defaults.removePersistentDomain(forName: name) }
    }
    body(values[0], Array(values.dropFirst()))
  }

  @Test func tahoeDefaultsToAppsPinchOn() throws {
    try withDefaults { dock, trackpads in
      #expect(
        TrackpadSystemGesture.systemPinchIsOn(majorVersion: 26, dock: dock, trackpads: trackpads))
    }
    #expect(TrackpadSystemGesture.systemPinchIsOn(majorVersion: 26, dock: nil, trackpads: []))
  }

  @Test func tahoeUsesTheIndependentDockSwitch() throws {
    try withDefaults { dock, trackpads in
      for enabled in [false, true] {
        dock.set(enabled, forKey: TrackpadSystemGesture.spotlightKey)
        #expect(
          TrackpadSystemGesture.systemPinchIsOn(majorVersion: 26, dock: dock, trackpads: trackpads)
            == enabled)
      }
    }
  }

  @Test func tahoeIgnoresShowDesktopAndLegacyPinchKeys() throws {
    try withDefaults { dock, trackpads in
      for desktop in [false, true] {
        dock.set(desktop, forKey: "showDesktopGestureEnabled")
        for legacy in [0, 2] {
          for defaults in trackpads {
            defaults.set(legacy, forKey: TrackpadSystemGesture.fourFingerKey)
            defaults.set(legacy, forKey: TrackpadSystemGesture.fiveFingerKey)
          }
          // 没有独立开关时默认开；显式关时，桌面和旧键都不能把应用程序捏合重新打开。
          dock.removeObject(forKey: TrackpadSystemGesture.spotlightKey)
          #expect(
            TrackpadSystemGesture.systemPinchIsOn(
              majorVersion: 26, dock: dock, trackpads: trackpads))
          dock.set(false, forKey: TrackpadSystemGesture.spotlightKey)
          #expect(
            !TrackpadSystemGesture.systemPinchIsOn(
              majorVersion: 26, dock: dock, trackpads: trackpads))
        }
      }
    }
  }

  @Test func laterVersionsKeepTheCombinedTrackpadRules() throws {
    try withDefaults { dock, trackpads in
      dock.set(false, forKey: TrackpadSystemGesture.spotlightKey)
      dock.set(false, forKey: "showDesktopGestureEnabled")
      #expect(
        TrackpadSystemGesture.systemPinchIsOn(majorVersion: 27, dock: dock, trackpads: trackpads))
      trackpads[0].set(0, forKey: TrackpadSystemGesture.fourFingerKey)
      #expect(
        !TrackpadSystemGesture.systemPinchIsOn(majorVersion: 27, dock: dock, trackpads: trackpads))
      trackpads[1].set(2, forKey: TrackpadSystemGesture.fiveFingerKey)
      #expect(
        TrackpadSystemGesture.systemPinchIsOn(majorVersion: 27, dock: dock, trackpads: trackpads))
      trackpads[1].set(0, forKey: TrackpadSystemGesture.fiveFingerKey)
      dock.set(true, forKey: TrackpadSystemGesture.spotlightKey)
      dock.set(true, forKey: "showDesktopGestureEnabled")
      #expect(
        !TrackpadSystemGesture.systemPinchIsOn(majorVersion: 27, dock: dock, trackpads: trackpads))
    }
  }

  @Test func earlierVersionsKeepTheTrackpadKeys() throws {
    try withDefaults { dock, trackpads in
      dock.set(true, forKey: TrackpadSystemGesture.spotlightKey)
      trackpads[0].set(0, forKey: TrackpadSystemGesture.fourFingerKey)
      #expect(
        !TrackpadSystemGesture.systemPinchIsOn(majorVersion: 15, dock: dock, trackpads: trackpads))
      trackpads[0].set(2, forKey: TrackpadSystemGesture.fourFingerKey)
      #expect(
        TrackpadSystemGesture.systemPinchIsOn(majorVersion: 15, dock: dock, trackpads: trackpads))
    }
  }
}
