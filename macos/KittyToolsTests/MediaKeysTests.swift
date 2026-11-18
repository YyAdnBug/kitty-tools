// 音量 / 亮度键换成刘海岛上的提示（2026-11-14）：按键怎么解、一格怎么走、岛上那一行什么时候出什么时候换。
// 另有一个按需的实机自检 liveSwallowsVolumeKey（TEST_RUNNER_KITTY_LIVE_MEDIA_KEYS=1，要测试宿主有「辅助功能」授权）：
// 真的建拦截，发一个**合成**的「音量+」媒体键，看它被吞掉（音量只走了我们自己的一格）、岛上出了那一行；测完音量恢复。
// 不出声；系统音量会临时变一格。平时的单测不建拦截、不碰音量和亮度。
// **自检里只发会被吞掉的键**：发一个不吞的（带 ⌥ 的），系统会真的照做（打开系统设置）。

import AppKit
import Foundation
import Testing

@testable import KittyTools

@MainActor
struct MediaKeysTests {
  /// 系统定义事件的 data1：高 16 位是键，0xA00 按下、0xB00 抬起，最低位连发（探针实测的写法）
  @Test func decodesMediaKeys() throws {
    let up = try #require(MediaKeys.decode(data1: 0x0000_0A00))
    #expect(up.key == .volumeUp && up.down && !up.isRepeat)
    let held = try #require(MediaKeys.decode(data1: 0x0001_0A01))
    #expect(held.key == .volumeDown && held.down && held.isRepeat)
    let released = try #require(MediaKeys.decode(data1: 0x0002_0B00))
    #expect(released.key == .brightnessUp && !released.down)
    #expect(MediaKeys.decode(data1: 0x0003_0A00)?.key == .brightnessDown)
    #expect(MediaKeys.decode(data1: 0x0007_0A00)?.key == .mute)
    // 别的媒体键（播放 16、键盘背光 21 / 22）、不是按下也不是抬起的：不认
    #expect(MediaKeys.decode(data1: 0x0010_0A00) == nil)
    #expect(MediaKeys.decode(data1: 0x0015_0A00) == nil)
    #expect(MediaKeys.decode(data1: 0x0000_0000) == nil)
  }

  /// 真正的拦截在后台线程：用 AppKit 在主线程造事件，序列化后在后台走生产的读取入口。不发系统事件，
  /// 不建拦截、不切输入法、不动音量。非媒体子类型（包括输入法切换）必须在读 compound data 前放行
  /// （6、9 读 data1 会让 SkyLight 断言退出：先读 data1 的写法这里直接崩）。
  @Test func decodesSystemEventsOffMainThread() async throws {
    // 开拦截前的现场核对在这台系统上要过（过不了，设置里开了也不接这几个键）
    #expect(MediaKeys.fieldsReadable)
    for subtype: Int16 in [0, 6, 7, 8, 9, 11, 12] {
      for (code, key) in [
        (0, MediaKeys.Key.volumeUp), (1, .volumeDown), (2, .brightnessUp),
        (3, .brightnessDown), (7, .mute), (4, nil), (16, nil), (21, nil),
      ] as [(Int, MediaKeys.Key?)] {
        for state in [0xA00, 0xA01, 0xB00, 0] {
          let system = try #require(
            NSEvent.otherEvent(
              with: .systemDefined, location: .zero, modifierFlags: [], timestamp: 0,
              windowNumber: 0, context: nil, subtype: subtype, data1: (code << 16) | state,
              data2: -1))
          let data = try #require(system.cgEvent?.data) as Data
          let press = try await Self.decodeOffMain(data)
          if subtype == 8, let key, state != 0 {
            #expect(press?.key == key)
            #expect(press?.down == (state != 0xB00))
            #expect(press?.isRepeat == (state == 0xA01))
          } else {
            #expect(press == nil)
          }
        }
      }
    }
    // Caps Lock 的普通修饰键事件也不能当媒体键（只构造、不发送）。
    let caps = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 57, keyDown: false))
    caps.type = .flagsChanged
    #expect(try await Self.decodeOffMain(#require(caps.data) as Data) == nil)
  }

  @concurrent nonisolated private static func decodeOffMain(_ data: Data) async throws
    -> (key: MediaKeys.Key, down: Bool, isRepeat: Bool)?
  {
    #expect(pthread_main_np() == 0)
    let event = try #require(CGEvent(withDataAllocator: nil, data: data as CFData))
    return MediaKeys.decode(event: event)
  }

  /// 哪些时候接这个键：平时接；按着 ⌥（打开设置）、⇧（反转提示音）、⌃（调外接屏）任一个、锁屏着（岛看不见）交回系统
  @Test func leavesModifiersAndLockScreenToSystem() {
    #expect(MediaKeys.takes(flags: [], locked: false))
    // 探针里实体键带的那一位（0x100）、⌘、fn 不算
    #expect(MediaKeys.takes(flags: CGEventFlags(rawValue: 0x100), locked: false))
    #expect(MediaKeys.takes(flags: [.maskCommand, .maskSecondaryFn], locked: false))
    #expect(!MediaKeys.takes(flags: [.maskAlternate], locked: false))
    #expect(!MediaKeys.takes(flags: [.maskShift], locked: false))
    #expect(!MediaKeys.takes(flags: [.maskControl], locked: false))
    #expect(!MediaKeys.takes(flags: [.maskAlternate, .maskShift], locked: false))
    #expect(!MediaKeys.takes(flags: [], locked: true))
  }

  /// 按下和抬起成对：第一下看接不接；连发和抬起跟第一下走——按住中途按 / 松修饰键、锁屏都不改主意，
  /// 不把半截交给系统、也不吞掉系统那一半的抬起
  @Test func pressAndReleaseStayPaired() {
    // 第一下
    #expect(MediaKeys.verdict(down: true, isRepeat: false, held: false, takes: true) == .act)
    #expect(MediaKeys.verdict(down: true, isRepeat: false, held: false, takes: false) == .pass)
    // 上一次的抬起丢过（held 还留着）：这一次放行的第一下照样放行
    #expect(MediaKeys.verdict(down: true, isRepeat: false, held: true, takes: false) == .pass)
    // 连发：第一下吞了的接着调（哪怕中途按上了 ⌥），第一下放行的接着放行（哪怕中途松了 ⌥）
    #expect(MediaKeys.verdict(down: true, isRepeat: true, held: true, takes: false) == .act)
    #expect(MediaKeys.verdict(down: true, isRepeat: true, held: false, takes: true) == .pass)
    // 抬起：吞了按下的才吞
    #expect(MediaKeys.verdict(down: false, isRepeat: false, held: true, takes: false) == .swallow)
    #expect(MediaKeys.verdict(down: false, isRepeat: false, held: false, takes: true) == .pass)
  }

  /// 写完读回来：往该去的方向动了才算（档比 1/16 粗的设备会量化回原档，那就交回系统）；本来就在那一头的照样算
  @Test func checksTheWriteLanded() {
    #expect(MediaKeys.moved(from: 0.25, to: 0.3125, up: true))
    #expect(!MediaKeys.moved(from: 0.25, to: 0.25, up: true))
    #expect(!MediaKeys.moved(from: 0.25, to: 0.2, up: true))
    #expect(MediaKeys.moved(from: 1, to: 1, up: true))
    #expect(MediaKeys.moved(from: 0.25, to: 0.1875, up: false))
    #expect(!MediaKeys.moved(from: 0.25, to: 0.25, up: false))
    #expect(MediaKeys.moved(from: 0, to: 0, up: false))
  }

  /// 到头了再按（第五轮体检 U13）：100% 再按 +、0 再按 − 算到头；岛上每来一次「到头了」就多弹一下（levelBumps），平常的不算
  @Test func bumpsAtTheEnds() {
    #expect(MediaKeys.atEnd(1, up: true) && MediaKeys.atEnd(0.9995, up: true))
    #expect(!MediaKeys.atEnd(0.9375, up: true) && !MediaKeys.atEnd(1, up: false))
    #expect(MediaKeys.atEnd(0, up: false) && !MediaKeys.atEnd(0.0625, up: false))
    let island = Island(showing: nil, geometry: .notch(width: 212, height: 37.5))
    island.showLevel(Island.Level(kind: .volume, fraction: 0.9375))
    #expect(island.levelBumps == 0)
    island.showLevel(Island.Level(kind: .volume, fraction: 1, pushed: true))
    island.showLevel(Island.Level(kind: .volume, fraction: 1, pushed: true))
    #expect(island.levelBumps == 2 && island.level?.fraction == 1)
    island.showLevel(Island.Level(kind: .brightness, fraction: 0, pushed: true))
    #expect(island.levelBumps == 3)
  }

  /// 设置页说为什么接不住（第五轮体检 U6）：先看开没开，再看授权、字段核对、建没建起来过；只有核对没过、建不起来时有橙字
  /// （没授权那一行另有按钮）
  @Test func reportsWhyKeysAreNotTaken() {
    #expect(MediaKeys.status(on: false, trusted: false, readable: false, gaveUp: true) == .off)
    #expect(
      MediaKeys.status(on: true, trusted: false, readable: false, gaveUp: false) == .needsPermission
    )
    #expect(MediaKeys.status(on: true, trusted: true, readable: false, gaveUp: true) == .unreadable)
    #expect(MediaKeys.status(on: true, trusted: true, readable: true, gaveUp: true) == .failed)
    #expect(MediaKeys.status(on: true, trusted: true, readable: true, gaveUp: false) == .running)
    #expect(IslandTab.keyWarning(.unreadable) != nil && IslandTab.keyWarning(.failed) != nil)
    for status in [MediaKeys.Status.off, .needsPermission, .running] {
      #expect(IslandTab.keyWarning(status) == nil)
    }
    #expect(IslandTab.keyWarning(nil) == nil)
  }

  /// 一格是 1/16：先吸到最近的格上再走，到头不出界
  @Test func stepsBySixteenths() {
    #expect(MediaKeys.stepped(0.25, up: true) == 0.3125)
    #expect(MediaKeys.stepped(0.25, up: false) == 0.1875)
    // 不在格上的（拖过滑杆、环境光漂过）：吸到最近的格再走
    #expect(MediaKeys.stepped(0.26, up: true) == 0.3125)
    #expect(MediaKeys.stepped(0.493, up: false) == 0.4375)
    #expect(MediaKeys.stepped(1, up: true) == 1)
    #expect(MediaKeys.stepped(0, up: false) == 0)
    #expect(MediaKeys.stepped(0.99, up: true) == 1)
    #expect(MediaKeys.stepped(-3, up: false) == 0)
  }

  /// 那一行的图标和读数：静音、0 是划掉的喇叭，音量分三档；静音时条和百分比是 0
  @Test func levelLooks() {
    func volume(_ fraction: Double, muted: Bool = false) -> Island.Level {
      Island.Level(kind: .volume, fraction: fraction, muted: muted)
    }
    #expect(volume(0).symbol == "speaker.slash.fill")
    #expect(volume(0.2).symbol == "speaker.wave.1.fill")
    #expect(volume(0.5).symbol == "speaker.wave.2.fill")
    #expect(volume(0.9).symbol == "speaker.wave.3.fill")
    #expect(volume(0.9, muted: true).symbol == "speaker.slash.fill")
    #expect(volume(0.9, muted: true).shown == 0 && volume(0.9, muted: true).title == "静音")
    #expect(volume(0.5).shown == 0.5 && volume(0.5).title == "音量")
    let sun = Island.Level(kind: .brightness, fraction: 0.4)
    #expect(sun.symbol == "sun.max.fill" && sun.title == "亮度")
  }

  /// 刘海两边的东西贴着形体的边走：形体每侧还差多少没长到位，它们就往中间挪多少；形体比它们宽不挪；最多一个 wing
  @Test func wingsRideTheEdge() {
    let notch: CGFloat = 212
    // 每侧 108 的东西：长到位不挪；形体捏到每侧只多 8 时挪 100；长到一半挪一半
    #expect(Island.ride(wing: 108, notch: notch, shape: notch + 216) == 0)
    #expect(Island.ride(wing: 108, notch: notch, shape: notch + 16) == 100)
    #expect(Island.ride(wing: 108, notch: notch, shape: notch + 116) == 50)
    // 耳朵（每侧 36）：鼓起、展开成卡片时形体更宽，不往外挪；缩进刘海里面时最多挪一个 wing
    #expect(Island.ride(wing: 36, notch: notch, shape: notch + 72 + 16) == 0)
    #expect(Island.ride(wing: 36, notch: notch, shape: 384) == 0)
    #expect(Island.ride(wing: 36, notch: notch, shape: notch + 16) == 28)
    #expect(Island.ride(wing: 36, notch: notch, shape: notch - 40) == 36)
  }

  /// 岛上：没出着就长出来（顶掉别的提示），出着就原地换数；不进最近的提示；收起后清掉；有活动时收回耳朵
  @Test func islandShowsLevelInPlace() {
    let notch = Island.Geometry.notch(width: 212, height: 37.5)
    let island = Island(showing: nil, geometry: notch)
    island.showLevel(Island.Level(kind: .volume, fraction: 0.5))
    #expect(island.level?.fraction == 0.5 && island.content?.title == "音量")
    #expect(island.isShowingLevel && island.levelShaped)
    // 出之前要不要先捏回刘海：从耳朵过来、换了种类（音量 → 亮度）时捏；岛上空着、摆出来的岛、减弱动态效果不捏
    func squeezes(
      swaps: Bool, wings: Bool, notch: Bool = true, staged: Bool = false, reduced: Bool = false
    ) -> Bool {
      Island.squeezes(
        swapsKind: swaps, wings: wings, notch: notch, staged: staged, reduceMotion: reduced)
    }
    #expect(squeezes(swaps: false, wings: true) && squeezes(swaps: true, wings: false))
    #expect(!squeezes(swaps: false, wings: false))
    // 没有刘海的屏上是一行、形体不认「捏着」：不捏
    #expect(!squeezes(swaps: true, wings: true, notch: false))
    #expect(!squeezes(swaps: true, wings: true, staged: true))
    #expect(!squeezes(swaps: true, wings: true, reduced: true))
    #expect(!island.pinched)
    island.showLevel(Island.Level(kind: .volume, fraction: 0.5625))
    #expect(island.level?.fraction == 0.5625 && island.history.isEmpty)
    // 换成亮度：还是那一行，原地换
    island.showLevel(Island.Level(kind: .brightness, fraction: 0.3))
    #expect(island.level?.kind == .brightness)
    island.dismiss()
    #expect(island.level == nil && island.content == nil && !island.isShowingLevel)
    // 岛上正有提示：顶掉它
    let busy = Island(
      showing: .init(
        title: "已复制", detail: nil, tone: .success, symbol: "checkmark", leading: .tone),
      geometry: notch)
    busy.showLevel(Island.Level(kind: .volume, fraction: 0.25))
    #expect(busy.level != nil && busy.content?.title == "音量")
    // 来了新提示：那一行让开
    busy.show("已保存")
    #expect(busy.level == nil && !busy.levelShaped)
    // 那一张开着：换成这一行
    let board = Island(showing: nil, geometry: notch, board: [])
    board.showLevel(Island.Level(kind: .volume, fraction: 0.25))
    #expect(board.level != nil && !board.isBoardOpen)
    // 进行中的提示出着：先排着，这一行收起后换回来（它的进度、按钮不能丢）
    let working = Island(
      showing: .init(
        title: "正在压缩", detail: "40%", tone: .progress, symbol: "ellipsis.circle.fill",
        leading: .tone),
      geometry: notch)
    working.showLevel(Island.Level(kind: .volume, fraction: 0.25))
    #expect(working.level != nil)
    working.dismiss()
    #expect(working.level == nil && working.content?.title == "正在压缩")
    // 有活动挂着：这一行收起后耳朵还在；活动的卡片开着时按键 → 卡片收掉、换成这一行
    let recording = Island.Activity(
      id: "rec", kind: .record, title: "录屏中", symbol: "record.circle.fill")
    let winged = Island(showing: nil, geometry: notch, activities: [recording])
    winged.tapped()
    #expect(winged.cardActivity != nil)
    winged.showLevel(Island.Level(kind: .brightness, fraction: 0.5))
    #expect(winged.level != nil && winged.cardActivity == nil)
    winged.setActivity(recording)
    #expect(winged.level != nil && winged.content?.title == "亮度")
    winged.dismiss()
    #expect(winged.level == nil && winged.isShowingWings)
  }

  // MARK: 实机自检（按需）

  @Test(.enabled(if: ProcessInfo.processInfo.environment["KITTY_LIVE_MEDIA_KEYS"] == "1"))
  func liveSwallowsVolumeKey() async throws {
    try #require(Permissions.isAccessibilityTrusted, "测试宿主没有「辅助功能」授权")
    let before = try #require(OutputVolume.read(), "这个输出设备读不到音量")
    try #require(OutputVolume.isSettable)
    // 静音着不测：「音量+」会解除静音，哪怕马上恢复也会响一下
    try #require(OutputVolume.isMuted != true, "系统静音着，先取消静音再跑")
    try #require(before < 0.95, "音量已经到头，调低一点再跑")
    defer { OutputVolume.set(before) }
    let suite = "media-keys-live-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: Feature.island.prefsKey)
    defaults.set(true, forKey: Prefs.islandKeyLevels)
    let island = Island(showing: nil, geometry: .notch(width: 212, height: 37.5))
    let keys = MediaKeys(island: island, defaults: defaults)
    keys.apply()
    // 不管下面哪一步失败都把拦截停掉
    defer {
      defaults.set(false, forKey: Prefs.islandKeyLevels)
      keys.apply()
    }
    try await Task.sleep(for: .milliseconds(300))
    // 没建起来就不发键（发了系统会真的加一格）
    try #require(keys.isRunning, "拦截没建起来")

    // 合成的「音量+」按下 + 抬起
    for state in [0xA, 0xB] {
      let media = NSEvent.otherEvent(
        with: .systemDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, subtype: 8, data1: (0 << 16) | (state << 8), data2: -1)
      media?.cgEvent?.post(tap: .cghidEventTap)
    }
    for _ in 0..<20 where island.level == nil { try await Task.sleep(for: .milliseconds(50)) }
    // 被吞掉了：只走了我们自己的一格（没吞掉的话系统还会再走一格）
    let expected = MediaKeys.stepped(before, up: true)
    #expect(abs((OutputVolume.read() ?? -1) - expected) < 0.005)
    #expect(island.level?.kind == .volume)
    #expect(abs((island.level?.fraction ?? -1) - expected) < 0.005)

    // 「按着 ⌥ 不吞」只在纯函数里测（takes）：真发一个带 ⌥ 的音量键，系统会照它原来的行为打开「系统设置」的声音页

    // 关掉：线程退出
    defaults.set(false, forKey: Prefs.islandKeyLevels)
    keys.apply()
    try await Task.sleep(for: .milliseconds(300))
    #expect(!keys.isRunning)
  }
}
