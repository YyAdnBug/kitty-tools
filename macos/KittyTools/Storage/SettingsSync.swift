// 设置、全局快捷键、功能开关接进全局同步（PLAN §10「全局同步」B1–B3、C3、C4；SyncSource，规则在 Storage/SyncRecords.swift）。
// 一项一条：偏好键（编号 "pref:" + 键；哪些键、什么类型、怎么收拾和设置的导出一样——SettingsArchive.kinds / Kind.plist，
// 功能开关也在里面；发出去之前也核一遍，落不下的不发）、快捷键（"hotkey:" + 动作，清除了的也是一条）。只同步改过的（持久域
// 里有的）：一项改回默认 = 删掉这一条，别的 Mac 也回到默认（和别处同时改了值的话改了值的赢：墓碑压不住同时的改动）。
// - **留在本机的**（localKeys，B1 + 评审）：启动台整页（屏幕大小、触控板、装的 App；连它的功能开关）、录屏要不要录麦克风和
//   录音的来源、录屏显示按键（跟着这台的授权走：没授权的那台一录就写回关、把对面的也关掉）、程序坞预览的开关（打开时要这台
//   给授权，同步过去会凭空弹系统授权框）、便签放在哪块显示器、菜单栏图标显不显示（刘海屏挤不挤每台不同）、剪贴板面板和翻译
//   浮窗的图钉；导出已经不带的窗口位置、文件夹路径、授权状态这些本来就不在 kinds 里。状态屏的状态列表是用户写的东西，另走
//   一类（StatusPresetSync：一个状态一条，第一次合并在一起）。
// - **新旧版本混用**：这一版不认识的键 / 动作、留在本机的键、落不下的值（更新版本的写法、超出范围），**原样存一份「透传」**
//   （偏好里 `syncPassthrough.settings`，这台电脑自己的）、下一轮原样交回去——不落进设置、不留墓碑、这一类不停；等这台
//   更新了认得了，下一次改动时照常落。透传着的那几项交出去的是透传的那份（本机设置里还是旧值，交旧值就把新版本写的翻回去）；
//   本机自己又改了它才换成本机的、透传的扔掉。
// - **一项一项后改的赢**（C3）：每项改的时刻记在偏好里（`syncChangedAt.settings`）——监听偏好的变化（通知在主线程同步送到；
//   攒到这一轮主线程空下来再比），退出、合盖之后才合到的改动不会被记成「刚改的」翻掉别人后来改的；同步落下去的那几项清掉
//   它们的时刻。
// - **第一次合跟着已有的**（C4，adopt）：别的电脑已经有设置，整个跟着它们（本机改过、它们没有的那几项回到默认）——保留天数、
//   「不记录」的 App、功能开关也跟着换，「合在一起？」里写明；换了之后清掉了历史的，刘海岛说一声（applied 的条数）。
// - 正在录屏 / 录音、正在录快捷键、状态屏开着时这一类先不合（isBusy：对面关掉录制功能会把这台正在录的停掉）。
// - 落下去之后走设置导入同一条收尾（applied：外观、强调色、热键、启动台……，AppDelegate.settingsImported）；收到的快捷键不能
//   当全局热键用的（HotKey.isUsable）不落、透传；落完两个动作撞了同一个组合的，刘海岛说一声（后一个注册不上）。
// 账本在偏好里（SyncLedger），先写设置再存账本。

import Foundation

@MainActor final class SettingsSync: SyncSource {
  /// 留在本机、不同步的偏好键
  static let localKeys: Set<String> = [
    Prefs.launchpadColumns, Prefs.launchpadRows, Prefs.launchpadPinchGesture,
    Prefs.launchpadPinchSense, Prefs.launchpadCorner, Feature.launchpad.prefsKey,
    Prefs.screenRecordMicrophone, Prefs.audioRecordSource, Prefs.screenRecordShowsKeys,
    Feature.dockPreview.prefsKey, Prefs.notesDeckDisplay, Prefs.statusItemVisible,
    Prefs.clipboardHideOnUnfocus, Prefs.floatingPinned,
    // 另走一类（StatusPresetSync）
    Prefs.statusScreenPresets,
  ]
  private static let prefPrefix = "pref:"
  private static let hotkeyPrefix = "hotkey:"
  static let timesKey = "syncChangedAt.settings"
  static let passthroughKey = "syncPassthrough.settings"

  private let defaults: UserDefaults
  private let domainName: String?
  private let applied: () -> Void
  /// 这一轮先不合（AppDelegate 给：录屏 / 录音、录快捷键、状态屏）
  var isBusy: () -> Bool = { false }
  /// 落完快捷键撞了时说一声（AppDelegate 给刘海岛）
  var conflicted: (String) -> Void = { _ in }
  /// 上次看到的本机设置里的各项（编号 → 内容，不含透传）：比出本机改了哪几项、记改的时刻
  private var known: [String: String] = [:]
  private var pending = false
  private var applying = false

  /// domainName：持久域的名字（只同步改过的：持久域里有的）；applied：落下去之后让运行中的东西跟上
  init(
    defaults: UserDefaults = .standard, domainName: String? = Bundle.main.bundleIdentifier,
    applied: @escaping () -> Void = {}
  ) {
    self.defaults = defaults
    self.domainName = domainName
    self.applied = applied
    known = ownValues()
    // ponytail: 观察者不摘（这个对象跟 App 一样长；单测里的弱引用着，自己失效）
    NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.noteChanges() }
    }
  }

  var syncKind: SyncRecords.Kind { .settings }
  var syncJoin: SyncRecords.Join { .adopt }
  var syncBusy: Bool { isBusy() }

  /// 本机设置里的各项，透传着的那几项换成透传的那份
  func syncValues() -> [String: String] {
    ownValues().merging(passthrough()) { _, passed in passed }
  }

  /// 本机设置里的各项（不含透传）
  private func ownValues() -> [String: String] {
    let domain = domainName.flatMap(defaults.persistentDomain(forName:)) ?? [:]
    var values: [String: String] = [:]
    for (key, kind) in SettingsArchive.kinds where !Self.localKeys.contains(key) {
      // 发之前也核一遍：对面落不下的不发（不然对面这一类就落成透传、本机的改不过去）
      guard let value = kind.value(of: domain[key]), kind.plist(value) != nil,
        let text = Self.encoded(value)
      else { continue }
      values[Self.prefPrefix + key] = text
    }
    for action in HotKeyAction.allCases {
      guard let data = domain[action.prefsKey] as? Data else { continue }
      // 解不出来的当清除了（同 HotKeyAction.resolve）
      let hotKey = try? JSONDecoder().decode(HotKey.self, from: data)
      values[Self.hotkeyPrefix + action.rawValue] = Self.encoded(hotKey)
    }
    return values
  }

  private static func encoded(_ value: some Encodable) -> String? {
    (try? SyncRecords.encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) }
  }

  private func passthrough() -> [String: String] {
    (defaults.dictionary(forKey: Self.passthroughKey) ?? [:]).compactMapValues { $0 as? String }
  }

  // MARK: 改的时刻

  /// 偏好变了：攒到这一轮主线程空下来再比（一次改好几项只比一回）
  private func noteChanges() {
    guard !applying, !pending else { return }
    pending = true
    Task { @MainActor [weak self] in self?.recordChanges() }
  }

  /// 和上次看到的本机设置比，变了的那几项记成现在改的（透传着的扔掉：本机的作数）
  func recordChanges() {
    pending = false
    let own = ownValues()
    let changed = Set(own.keys).union(known.keys).filter { own[$0] != known[$0] }
    known = own
    guard !changed.isEmpty else { return }
    let passed = passthrough()
    if !changed.isDisjoint(with: passed.keys) {
      let kept = passed.filter { !changed.contains($0.key) }
      defaults.set(kept.isEmpty ? nil : kept, forKey: Self.passthroughKey)
    }
    let stamp = Note.milliseconds(.now)
    var times = changeTimes()
    for id in changed { times[id] = stamp }
    let now = syncValues()
    saveTimes(times.filter { now[$0.key] != nil })
  }

  private func changeTimes() -> [String: Int64] {
    (defaults.dictionary(forKey: Self.timesKey) ?? [:]).compactMapValues {
      ($0 as? NSNumber)?.int64Value
    }
  }

  private func saveTimes(_ times: [String: Int64]) {
    defaults.set(times.mapValues { NSNumber(value: $0) }, forKey: Self.timesKey)
  }

  func syncChanged() -> [String: Int64] {
    recordChanges()
    return changeTimes()
  }

  // MARK: 账本、落下去

  func syncLedger(library: String) throws -> SyncRecords.Ledger? {
    try SyncLedger.load(.settings, library: library, in: defaults)
  }

  /// 先算好要写的（落不下的进透传），再写设置、存账本，最后让运行中的东西跟上。只有存账本没成才返回 false
  func applySync(_ changes: [String: String?], ledger: SyncRecords.Ledger, library: String) -> Bool
  {
    var writes: [(key: String, value: Any?)] = []
    var passed = passthrough()
    var hotkeysChanged = false
    for (id, value) in changes {
      // 认得、落得下的写进设置（同时清掉这一项的透传）；别的原样存进透传
      if let write = Self.write(for: id, value) {
        writes.append(write)
        passed[id] = nil
        hotkeysChanged = hotkeysChanged || id.hasPrefix(Self.hotkeyPrefix)
      } else {
        passed[id] = value
      }
    }
    applying = true
    defer { applying = false }
    for (key, value) in writes {
      if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
    if passed != passthrough() {
      defaults.set(passed.isEmpty ? nil : passed, forKey: Self.passthroughKey)
    }
    known = ownValues()
    do {
      try SyncLedger.save(ledger, kind: .settings, library: library, in: defaults)
    } catch {
      return false
    }
    // 落下去的那几项不再算本机改的：清掉它们记着的时刻
    let times = changeTimes()
    if !Set(times.keys).isDisjoint(with: changes.keys) {
      saveTimes(times.filter { changes[$0.key] == nil })
    }
    if !writes.isEmpty { applied() }
    if hotkeysChanged, let clash = clashingHotKeys() { conflicted(clash) }
    return true
  }

  /// 一项要写进偏好的什么（nil 值 = 删掉这个键）；这一版不认识、留在本机、落不下的给 nil（透传）
  private static func write(for id: String, _ value: String?) -> (key: String, value: Any?)? {
    if id.hasPrefix(prefPrefix) {
      let key = String(id.dropFirst(prefPrefix.count))
      guard let kind = SettingsArchive.kinds[key], !localKeys.contains(key) else { return nil }
      guard let value else { return (key, nil) }
      guard let decoded = SyncRecords.decodeExact(SettingsArchive.Value.self, from: value),
        let plist = kind.plist(decoded)
      else { return nil }
      return (key, plist)
    }
    if id.hasPrefix(hotkeyPrefix) {
      guard let action = HotKeyAction(rawValue: String(id.dropFirst(hotkeyPrefix.count))) else {
        return nil
      }
      guard let value else { return (action.prefsKey, nil) }
      // 文件夹是信任边界：不能当全局热键用的组合（会吞掉正常输入）不落
      guard let hotKey = SyncRecords.decodeExact(HotKey?.self, from: value),
        hotKey?.isUsable != false
      else { return nil }
      return (action.prefsKey, HotKeyAction.stored(hotKey))
    }
    return nil
  }

  /// 存着的快捷键里两个动作用了同一个组合：说哪两个（只说第一对）
  private func clashingHotKeys() -> String? {
    var owners: [HotKey: HotKeyAction] = [:]
    for action in HotKeyAction.allCases {
      guard let data = defaults.data(forKey: action.prefsKey),
        let hotKey = try? JSONDecoder().decode(HotKey.self, from: data)
      else { continue }
      if let first = owners[hotKey] { return "「\(first.title)」和「\(action.title)」" }
      owners[hotKey] = action
    }
    return nil
  }
}
