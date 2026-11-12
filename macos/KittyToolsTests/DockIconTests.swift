// macOS 26 上程序坞图标常驻（PR #1，2026-11-12）：只在 26 上、默认开、关掉就照原来的样子；别的系统版本不受影响

import AppKit
import Testing

@testable import KittyTools

@MainActor
struct DockIconTests {
  @Test func onlyTahoeKeepsTheDockIconByDefault() throws {
    let suite = "dock-icon-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    // 没存过（启动入口在注册默认值之前就读）：26 上常驻
    #expect(NSApplication.keepsDockIcon(osMajor: 26, defaults: defaults))
    #expect(!NSApplication.keepsDockIcon(osMajor: 15, defaults: defaults))
    #expect(!NSApplication.keepsDockIcon(osMajor: 27, defaults: defaults))
    defaults.set(false, forKey: Prefs.dockIconOnTahoe)
    #expect(!NSApplication.keepsDockIcon(osMajor: 26, defaults: defaults))
    defaults.set(true, forKey: Prefs.dockIconOnTahoe)
    #expect(!NSApplication.keepsDockIcon(osMajor: 27, defaults: defaults))
    #expect(Prefs.defaults[Prefs.dockIconOnTahoe] as? Bool == true)
  }
}
