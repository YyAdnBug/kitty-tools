// 新功能标记（Shell/WhatsNew.swift，2026-11-05 拍板）：清单的规矩（每版最多 3 个、有地方标、版本对得上）、新装不标、跳着升级
// 中间几版一起标、30 天 / 碰过 / 功能关着就不标、换页时看着的那页不闪掉、账只在有变化时写（临时偏好域，不碰用户的）。

import Foundation
import Testing

@testable import KittyTools

struct WhatsNewTests {
  private typealias Entry = WhatsNew.Entry
  private let day: TimeInterval = 24 * 60 * 60
  private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
  private let all = Set(Feature.allCases)

  /// 三版各一个：0.7.0 的动作、0.8.0 的设置页一节、0.9.0 的一族
  private let sample: [Entry] = [
    Entry(id: "a", version: "0.7.0", feature: .clipboard, actions: [.pinClipboard]),
    Entry(id: "b", version: "0.8.0", feature: nil, page: .general, section: "功能"),
    Entry(
      id: "c", version: "0.9.0", feature: .notes, actions: [.noteCapture], page: .notes),
  ]

  /// 清单本身：id 不重复、每版不超过 3 个、每个都有地方标（动作或设置页）、写了节就得写页、动作归它说的那个功能；
  /// 版本要么在更新日志里，要么比现在这一版新（还没发布）
  @Test func entriesAreWellFormed() {
    let entries = WhatsNew.entries
    #expect(Set(entries.map(\.id)).count == entries.count)
    for version in Set(entries.map(\.version)) {
      #expect(entries.filter { $0.version == version }.count <= WhatsNew.perVersion, "\(version)")
    }
    let released = Set(AboutTab.releases.map(\.version))
    for entry in entries {
      #expect(!entry.actions.isEmpty || entry.page != nil, "\(entry.id)")
      #expect(entry.section == nil || entry.page != nil, "\(entry.id)")
      if let feature = entry.feature {
        #expect(entry.actions.allSatisfy { $0.feature == feature }, "\(entry.id)")
      }
      #expect(
        released.contains(entry.version)
          || Updater.isNewer(entry.version, than: AboutTab.version), "\(entry.id)")
    }
  }

  /// 新装（没有上次的版本）什么都不记；从 0.6.0 跳到 0.8.0：0.7.0、0.8.0 都从现在起算，0.9.0 不算；记过的不再动
  @Test func upgradeStartsTheVersionsInBetween() {
    let empty = WhatsNew.Ledger()
    #expect(WhatsNew.adopting(empty, from: nil, to: "0.8.0", now: t0, entries: sample) == empty)
    let upgraded = WhatsNew.adopting(empty, from: "0.6.0", to: "0.8.0", now: t0, entries: sample)
    #expect(upgraded.started == ["0.7.0": t0, "0.8.0": t0])
    let later = t0.addingTimeInterval(5 * day)
    let again = WhatsNew.adopting(upgraded, from: "0.8.0", to: "0.9.0", now: later, entries: sample)
    // 升到下一版：上一版和更早的记成很久以前（不再标，2026-11-06），这一版从现在起算
    #expect(again.started == ["0.7.0": .distantPast, "0.8.0": .distantPast, "0.9.0": later])
    // 退回 0.7.0 再升回来：时刻不重新算
    #expect(
      WhatsNew.adopting(again, from: "0.7.0", to: "0.9.0", now: later + day, entries: sample)
        == again)
  }

  /// 要标的：开始标了、30 天以内、没碰过、功能开着；不归功能的一直算开着；钟往回拨了照标
  @Test func freshFollowsTheRules() {
    let ledger = WhatsNew.Ledger(started: ["0.7.0": t0, "0.8.0": t0])
    func ids(_ ledger: WhatsNew.Ledger, _ enabled: Set<Feature>, _ now: Date) -> [String] {
      WhatsNew.fresh(ledger, enabled: enabled, now: now, entries: sample).map(\.id)
    }
    #expect(ids(ledger, all, t0) == ["a", "b"])
    #expect(ids(ledger, all, t0 - day) == ["a", "b"])
    #expect(ids(ledger, all, t0 + WhatsNew.lifetime - 1) == ["a", "b"])
    #expect(ids(ledger, all, t0 + WhatsNew.lifetime).isEmpty)
    #expect(ids(ledger, all.subtracting([.clipboard]), t0) == ["b"])
    #expect(ids(ledger, [], t0) == ["b"])
    var touched = ledger
    touched.touched = ["a"]
    #expect(ids(touched, all, t0) == ["b"])
  }

  /// 碰过：只记已经开始标的，记过的原样（调用方据此不写偏好）
  @Test func touchingOnlyRecordsStartedEntries() {
    let ledger = WhatsNew.Ledger(started: ["0.7.0": t0])
    let touched = WhatsNew.touching(ledger, entries: sample) { $0.actions.contains(.pinClipboard) }
    #expect(touched.touched == ["a"])
    #expect(WhatsNew.touching(touched, entries: sample) { $0.id == "a" } == touched)
    // 0.9.0 还没开始标：碰它的动作不记
    #expect(
      WhatsNew.touching(ledger, entries: sample) { $0.actions.contains(.noteCapture) } == ledger)
  }

  /// 设置里只有它才有入口的（没有动作、有页）：菜单「设置…」、主界面「设置」跟着标
  @Test func settingsOnlyEntries() {
    #expect(!WhatsNew.inSettingsOnly([sample[0]]))
    #expect(WhatsNew.inSettingsOnly([sample[1]]))
    #expect(!WhatsNew.inSettingsOnly([sample[2]]))
    #expect(!WhatsNew.inSettingsOnly([]))
  }

  /// 升到下一版：上次那一版（和更早）的不再标；同一版重开、退回旧版本不动
  @Test func nextVersionClearsOlderMarks() {
    let sample = [
      WhatsNew.Entry(id: "old", version: "0.7.2", feature: nil, page: .launcher, section: "x"),
      WhatsNew.Entry(id: "new", version: "0.8.0", feature: nil, actions: [.noteCapture]),
    ]
    let on072 = WhatsNew.adopting(.init(), from: "0.7.1", to: "0.7.2", now: t0, entries: sample)
    #expect(on072.started == ["0.7.2": t0])
    // 同一版重开：照旧
    #expect(WhatsNew.adopting(on072, from: "0.7.2", to: "0.7.2", now: t0, entries: sample) == on072)
    // 0.7.2 → 0.8.0：0.7.2 的没了，0.8.0 的开始标
    let on080 = WhatsNew.adopting(on072, from: "0.7.2", to: "0.8.0", now: t0, entries: sample)
    #expect(on080.started == ["0.7.2": .distantPast, "0.8.0": t0])
    #expect(WhatsNew.fresh(on080, enabled: [], now: t0, entries: sample).map(\.id) == ["new"])
    // 从 0.7.1 直接跳到 0.8.0：两版的都标
    let skipped = WhatsNew.adopting(.init(), from: "0.7.1", to: "0.8.0", now: t0, entries: sample)
    #expect(skipped.started == ["0.7.2": t0, "0.8.0": t0])
  }

  /// 换页：这一页原来标着的看着时留着，换到别的页才没；侧栏和页里那一节按这一份标
  @Test func visitedPageKeepsItsMarksUntilLeft() {
    let overlay = WhatsNew.entries.first { $0.id == "screenshot-overlay" }!
    let frequent = WhatsNew.entries.first { $0.id == "launcher-frequent" }!
    // 打开设置时停在翻译页：两个都标（翻译页这时已经碰过，但看着的时候不闪掉）
    let first = WhatsNew.shown(visiting: .translate, fresh: [overlay, frequent], showing: [])
    #expect(first == ["screenshot-overlay", "launcher-frequent"])
    #expect(WhatsNew.marks(.translate, in: first))
    // 换到启动器页：翻译碰过了、不再标；启动器页标着
    let second = WhatsNew.shown(visiting: .launcher, fresh: [frequent], showing: first)
    #expect(second == ["launcher-frequent"])
    #expect(!WhatsNew.marks(.translate, in: second))
    #expect(WhatsNew.marks(.launcher, in: second))
    // 再换到关于：启动器也碰过了，什么都不标
    #expect(WhatsNew.shown(visiting: .about, fresh: [], showing: second).isEmpty)
  }

  /// 账写在偏好里：新装不写；升级记下开始的时刻；碰过写一次，再碰不重写
  @Test func ledgerPersistsOnlyChanges() throws {
    let suite = "kitty-whatsnew-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    WhatsNew.adopt(upgradingFrom: nil, to: "0.7.2", defaults: defaults, now: t0)
    #expect(defaults.object(forKey: Prefs.whatsNewStarted) == nil)
    WhatsNew.adopt(upgradingFrom: "0.7.1", to: "0.7.2", defaults: defaults, now: t0)
    #expect(WhatsNew.ledger(defaults).started == ["0.7.2": t0])
    WhatsNew.touch(action: .pinClipboard, defaults: defaults)
    #expect(WhatsNew.ledger(defaults).touched == ["pin-text"])
    WhatsNew.touch(section: "空搜索框里列出常用", of: .launcher, defaults: defaults)
    #expect(WhatsNew.ledger(defaults).touched == ["pin-text", "launcher-frequent"])
    // 没变化不写：把存的值换成一个记号，再碰一次同样的，记号还在
    defaults.set(["pin-text", "launcher-frequent", "marker"], forKey: Prefs.whatsNewTouched)
    WhatsNew.touch(action: .pinClipboard, defaults: defaults)
    #expect(defaults.stringArray(forKey: Prefs.whatsNewTouched)?.contains("marker") == true)
  }
}
