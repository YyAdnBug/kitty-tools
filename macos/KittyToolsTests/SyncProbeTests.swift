// 全局同步的主线程耗时探针（第三轮体检第 6 批 P1，2026-10-27；按需开，默认跳过）：`TEST_RUNNER_KITTY_SYNC_PROBE=1` 才跑，
// grep「sync-probe」看。临时目录里一个同步文件夹 + 三台（本机 a、别的 Mac b / c：各自真的便签库、剪贴板库（临时文件，
// WAL 同 App）、临时偏好域），便签 1000 / 5000 条（正文 1–5 KB）、片段和收藏 3000 条、设置一整份（每个键都存着 + 全部
// 快捷键 + 一块 100 KB 的无关偏好）：
//   (a) 什么都没变的一轮：a 的 round() 前后主线程的 CPU 时间（CLOCK_THREAD_CPUTIME_ID；读写文件夹在主线程外，不算），
//       连着 6 轮取中位和最长；另把便签 / 每一类拆开单独量（同一份读到的文件夹，纯函数各跑一遍）；
//   (b) 第一次合：新的一台 d（自己有 2 万条普通历史、500 条收藏（一半和 a 的正文一样）、100 条便签）加入，第一轮的主线程
//       CPU 和墙上时间；另单量剪贴板那一类落下去（ClipboardStore.applySync）要多久；
//   (c) SettingsSync：开着同步时改一个和同步无关的偏好（窗口位置这类）、改一个同步的偏好（拖滑块的一格），没开同步时改
//       无关的偏好——从写偏好到它引起的主线程活都做完，各要多久（20 次的中位）。
// 两种构建各跑一遍（Debug 是 -Onone；-O 用 Debug 配置加 SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule：
// Release 配置关了可测性，@testable 进不来）：
//   TEST_RUNNER_KITTY_SYNC_PROBE=1 xcodebuild -project macos/KittyTools.xcodeproj -scheme KittyTools \
//     test -only-testing:'KittyToolsTests/SyncProbeTests/measure()' [SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule]
// 量到的数（M3 Air 无风扇，macOS 27，2026-10-27 / 28；单位 ms，主线程 CPU；改前 = 27304ba7，改后两次的数写成「a–b」）：
//                                              改前 Debug   改前 -O   改后 Debug   改后 -O
//   (a) 没变的一轮，1000 条便签（6 轮中位）         913        783       22–27      5.5–5.8
//   (a) 没变的一轮，5000 条便签                    2600       1035      32–64      13–19
//   (b) 新的一台加入的第一轮，1000 条               33713      5963      472–519    262–446
//   (b) 同上，5000 条                             34848      6403      675–728    429–493
//   (b) 其中剪贴板落下去（3503 条改动 × 2 万条）     38368      6195      209–224    166–266
//   (c) 开着同步改一个无关的偏好（扣掉写偏好本身）    0.2        0.2       0.1        0.1
//   (c) 开着同步拖滑块的一格                        0.7        0.6       0.1        0.1
//   (c) 没开同步改一个无关的 / 同步的偏好            0.3 / 0.7  0.2 / 0.6  0.0 / 0.0  0.0 / 0.0
// 没变的一轮改后每一部分都跳过（输出里 skipped 那一列）；改前的大头是哈希的十六进制（String(format:) 一个字节一回）、片段那一类
// 每条的 Foundation contains 和 JSON 编码、账本每轮重解；第一次合的大头是剪贴板落下去时逐条线性找。改后 5000 条那一轮剩下的
// 随文件数涨（比上万个文件属性、放掉上一轮读到的那份，没再细拆）。拆开的各项（同一份文件夹、纯函数各跑一遍，约等于「有东西
// 变了」那一轮的开销）看输出里的 part 行，-O 1000 条：便签合 61 → 12、写出去要做什么 56 → 5、片段那一类合 444 → 51。
// 数字受机器发热影响能差一两成（无风扇，连着跑几分钟会降频）；改了同步的一轮后前后各跑一遍对比（同一种构建）。

import Foundation
import Testing

@testable import KittyTools

@MainActor
struct SyncProbeTests {
  nonisolated private static var isEnabled: Bool {
    ProcessInfo.processInfo.environment["KITTY_SYNC_PROBE"] == "1"
  }

  private let root = FileManager.default.temporaryDirectory.appending(
    path: "kitty-sync-probe-\(UUID().uuidString)", directoryHint: .isDirectory)
  private var shared: URL { root.appending(path: "同步", directoryHint: .isDirectory) }

  /// 一台电脑：便签库、剪贴板库（同库的生词本、启动器收藏）、偏好域里的几类、同步
  private final class Mac {
    let host: String
    let store: NoteStore
    let syncer: NoteSyncer
    let suite: String
    let defaults: UserDefaults
    let clipboard: ClipboardStore
    let settings: SettingsSync

    init(host: String, root: URL) throws {
      self.host = host
      let notes = try Database(path: root.appending(path: "\(host)-notes.sqlite3").path)
      store = try NoteStore(db: notes, wait: { _ in }, host: host)
      store.images = NoteImageStore(directory: root.appending(path: "images-\(host)"))
      suite = "kitty-sync-probe-\(UUID().uuidString)"
      defaults = UserDefaults(suiteName: suite)!
      SyncProbeTests.fillSettings(defaults)
      syncer = NoteSyncer(store: store, defaults: defaults)
      let kitty = try Database(path: root.appending(path: "\(host)-kitty.sqlite3").path)
      clipboard = try ClipboardStore(
        db: kitty, images: ImageStore(directory: root.appending(path: "clips-\(host)")))
      let history = try HistoryStore(db: kitty)
      history.defaults = defaults
      settings = SettingsSync(defaults: defaults, domainName: suite)
      syncer.sources = [
        clipboard, history, WebSearchSync(defaults: defaults),
        TranslateServiceSync(store: TranslateServiceStore(services: [.zhipu]), defaults: defaults),
        try LauncherUsage(db: kitty), StatusPresetSync(defaults: defaults), settings,
      ]
      syncer.computerName = { host }
      syncer.editing = { [] }
    }

    deinit { UserDefaults().removePersistentDomain(forName: suite) }
  }

  /// 设置一整份：每个同步的键都存着（默认值也算存过）、每个快捷键、再加一块和同步无关的大偏好（启动台布局、窗口位置这类）
  private static func fillSettings(_ defaults: UserDefaults) {
    for (key, _) in SettingsArchive.kinds {
      if let value = Prefs.defaults[key] { defaults.set(value, forKey: key) }
    }
    for action in HotKeyAction.allCases {
      defaults.set(HotKeyAction.stored(action.defaultHotKey), forKey: action.prefsKey)
    }
    defaults.set(Data(repeating: 7, count: 100 << 10), forKey: "probe.unrelatedBlob")
  }

  /// 第 index 条便签的正文：1–5 KB
  private static func body(_ index: Int) -> String {
    let line = "普通的一行文字，中英混排 mixed text with some words，第 \(index) 条。\n"
    let target = 1024 * (1 + index % 5)
    var body = "第 \(index) 条便签\n"
    while body.utf8.count < target { body += line }
    return body
  }

  /// 片段和收藏：count 条，正文 100–300 字；snippet 每 4 条一个；新的在前
  private static func clips(_ count: Int, prefix: String, favorite: Bool, from start: Int = 0)
    -> [SettingsArchive.Clip]
  {
    (0..<count).map { offset in
      let index = start + offset
      return SettingsArchive.Clip(
        text: "\(prefix) \(index)：" + String(repeating: "片段的正文 text ", count: 8 + index % 16),
        note: index % 7 == 0 ? "备注 \(index)" : nil, favorite: favorite,
        snippet: favorite && index % 4 == 0,
        group: favorite && index % 10 == 0 ? "组 \(index % 5)" : nil,
        copiedAt: Date(timeIntervalSinceNow: -Double(offset)))
    }
  }

  private static func cpu() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }

  private static func ms(_ nanoseconds: UInt64) -> String {
    String(format: "%.1f", Double(nanoseconds) / 1_000_000)
  }

  private static func log(_ line: String) { print("sync-probe \(line)") }

  /// 量一段主线程上的同步代码
  private static func time(_ label: String, _ work: () -> Void) {
    let start = cpu()
    work()
    log("\(label) \(ms(cpu() - start)) ms")
  }

  @Test(.enabled(if: SyncProbeTests.isEnabled)) func measure() async throws {
    // assert 的条件只在 -Onone 里求值
    var optimized = true
    assert(
      {
        optimized = false
        return true
      }())
    Self.log("build \(optimized ? "-O" : "-Onone")")
    for count in [1000, 5000] { try await scale(notes: count) }
  }

  private func scale(notes count: Int) async throws {
    try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let a = try Mac(host: "a", root: root)
    let b = try Mac(host: "b", root: root)
    let c = try Mac(host: "c", root: root)
    for index in 0..<count { a.store.create(body: Self.body(index)) }
    a.clipboard.adopt(Self.clips(3000, prefix: "片段", favorite: true), groups: [])
    // 不 start（计时器会另起一轮，和下面手动的撞在一起）：round() 只要开着
    for mac in [a, b, c] { #expect(await mac.syncer.enable(folder: shared) == nil) }
    for _ in 0..<2 {
      for mac in [a, b, c] { await mac.syncer.round() }
    }
    #expect(c.store.notes.count == count && b.clipboard.items.count == 3000)
    #expect(a.syncer.status == .idle && b.syncer.status == .idle && c.syncer.status == .idle)
    // 刚写的文件不进读缓存（改动时刻离读的时候不到 2 秒）：等它们旧一点
    try await Task.sleep(for: .seconds(2.5))
    await a.syncer.round()

    // (a) 什么都没变的一轮
    var samples: [UInt64] = []
    var walls: [Double] = []
    for _ in 0..<6 {
      let start = Self.cpu()
      let wall = Date()
      await a.syncer.round()
      samples.append(Self.cpu() - start)
      walls.append(Date().timeIntervalSince(wall) * 1000)
    }
    #expect(a.syncer.status == .idle)
    samples.sort()
    Self.log(
      "notes=\(count) (a) idle round main-cpu median \(Self.ms(samples[samples.count / 2])) ms max \(Self.ms(samples.last ?? 0)) ms wall median \(String(format: "%.1f", walls.sorted()[walls.count / 2])) ms skipped \(a.syncer.skippedParts.sorted())"
    )
    try await breakdown(a, notes: count)

    // (b) 第一次合：新的一台加入
    let d = try Mac(host: "d", root: root)
    for index in 0..<100 { d.store.create(body: "d 自己的第 \(index) 条") }
    d.clipboard.adopt(
      Self.clips(250, prefix: "片段", favorite: true)
        + Self.clips(250, prefix: "d 的收藏", favorite: true, from: 5000)
        + Self.clips(20_000, prefix: "历史", favorite: false, from: 10_000), groups: [])
    #expect(await d.syncer.enable(folder: shared) == nil)
    let start = Self.cpu()
    let wall = Date()
    await d.syncer.round()
    Self.log(
      "notes=\(count) (b) first round (d joins) main-cpu \(Self.ms(Self.cpu() - start)) ms wall \(String(format: "%.0f", Date().timeIntervalSince(wall) * 1000)) ms status \(d.syncer.status)"
    )
    #expect(d.store.notes.count == count + 100)
    try await firstClipMerge(notes: count)
  }

  /// 没变的一轮拆开：同一份读到的文件夹，便签那几步、每一类那几步各多久
  private func breakdown(_ mac: Mac, notes count: Int) async throws {
    let kinds = mac.syncer.sources.map(\.syncKind)
    let me = mac.store.deviceID
    let snapshot = await NoteSyncDisk.read(
      folder: shared, cache: NoteSyncDisk.Cache(), kinds: kinds, device: me)
    let library = try #require(mac.syncer.library)
    let prefix = "notes=\(count) (a) part"
    Self.time("\(prefix) notes.regressed") {
      _ = NoteSyncFolder.regressed(local: mac.store.notes, folder: snapshot.folder, device: me)
    }
    Self.time("\(prefix) notes.round") {
      _ = NoteSyncFolder.round(
        local: mac.store.notes, erased: mac.store.erased, folder: snapshot.folder,
        library: library, now: .now)
    }
    Self.time("\(prefix) notes.publish") {
      _ = NoteSyncFolder.publish(
        local: mac.store.notes, erased: mac.store.erased, own: snapshot.folder.devices[me],
        localImages: mac.store.images?.fileNames() ?? [], folderImages: snapshot.folder.images)
    }
    Self.time("\(prefix) notes.contentHash x\(mac.store.notes.count)") {
      for note in mac.store.notes { _ = NoteSync.contentHash(note) }
    }
    for source in mac.syncer.sources {
      let kind = source.syncKind
      var own: SyncRecords.File?
      var others: [SyncRecords.File] = []
      for (device, read) in snapshot.kinds[kind] ?? [:] {
        guard case .read(let file) = read else { continue }
        if device == me { own = file } else { others.append(file) }
      }
      var local: [String: String] = [:]
      var changed: [String: Int64] = [:]
      var ledger: SyncRecords.Ledger?
      var outcome = SyncRecords.Outcome()
      Self.time("\(prefix) \(kind.rawValue).values(\(own?.records.count ?? 0))") {
        local = source.syncValues()
        changed = source.syncChanged()
      }
      Self.time("\(prefix) \(kind.rawValue).ledger") {
        ledger = try? source.syncLedger(library: library)
      }
      Self.time("\(prefix) \(kind.rawValue).round") {
        outcome = SyncRecords.round(
          local: local, changed: changed, ledger: ledger, own: own, others: others, me: me,
          now: Note.milliseconds(.now), join: source.syncJoin)
      }
      // 改前编两遍（合出来的、读到的自己那份）；改后编一遍、和读到的原样字节比
      Self.time("\(prefix) \(kind.rawValue).encode+compare") {
        _ = SyncRecords.data(of: outcome.own, kind: kind) == snapshot.ownBytes[kind]
      }
    }
  }

  /// 第一次合里剪贴板那一类单量：一台有 2 万条普通历史 + 500 条收藏的加入，文件夹里 3000 条片段和收藏 → 落下去多久
  private func firstClipMerge(notes count: Int) async throws {
    let e = try Mac(host: "e", root: root)
    e.clipboard.adopt(
      Self.clips(250, prefix: "片段", favorite: true)
        + Self.clips(250, prefix: "e 的收藏", favorite: true, from: 5000)
        + Self.clips(20_000, prefix: "历史", favorite: false, from: 10_000), groups: [])
    let snapshot = await NoteSyncDisk.read(
      folder: shared, cache: NoteSyncDisk.Cache(), kinds: [.clips])
    let others = (snapshot.kinds[.clips] ?? [:]).values.compactMap { read -> SyncRecords.File? in
      if case .read(let file) = read { return file }
      return nil
    }
    let outcome = SyncRecords.round(
      local: e.clipboard.syncValues(), ledger: nil, own: nil, others: others,
      me: e.store.deviceID, now: Note.milliseconds(.now), join: e.clipboard.syncJoin)
    var applied = SyncApplied.failed
    Self.time(
      "notes=\(count) (b) clips.applySync changes=\(outcome.changes.count) items=\(e.clipboard.items.count)"
    ) {
      applied = e.clipboard.applySync(outcome.changes, ledger: outcome.ledger, library: "probe")
    }
    #expect(applied == .saved)
  }

  // MARK: (c) SettingsSync

  /// (c) 单独开：TEST_RUNNER_KITTY_SYNC_PROBE=1 … -only-testing:'KittyToolsTests/SyncProbeTests/settingsChanges()'，几秒
  @Test(.enabled(if: SyncProbeTests.isEnabled)) func settingsChanges() async throws {
    try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let on = try Mac(host: "on", root: root)
    on.defaults.set(shared.path, forKey: Prefs.notesSyncFolder)
    on.defaults.set("probe", forKey: Prefs.notesSyncLibrary)
    let off = try Mac(host: "off", root: root)
    // 对照：同样一整份偏好、没有 SettingsSync 看着的域——写偏好本身的开销
    let plainSuite = "kitty-sync-probe-plain-\(UUID().uuidString)"
    let plain = try #require(UserDefaults(suiteName: plainSuite))
    defer { UserDefaults().removePersistentDomain(forName: plainSuite) }
    Self.fillSettings(plain)
    await Task.yield()
    func measure(_ label: String, _ write: (Int) -> Void) async {
      var samples: [UInt64] = []
      for index in 0..<20 {
        let start = Self.cpu()
        write(index)
        // 偏好变了的通知同步送到，记改动的那次排在主线程下一拍：让出几拍，让它（和它写改动时刻又引起的那一次）做完
        for _ in 0..<4 { await Task.yield() }
        samples.append(Self.cpu() - start)
      }
      samples.sort()
      Self.log(
        "(c) settings \(label) median \(Self.ms(samples[samples.count / 2])) ms max \(Self.ms(samples.last ?? 0)) ms"
      )
    }
    let frame = "NSWindow Frame probe"
    await measure("baseline(no SettingsSync) pref write") {
      plain.set("{{\($0), 0}, {800, 600}}", forKey: frame)
    }
    await measure("sync-on unrelated-pref") {
      on.defaults.set("{{\($0), 0}, {800, 600}}", forKey: frame)
    }
    await measure("sync-on synced-pref(slider tick)") {
      on.defaults.set(30 + $0, forKey: Prefs.clipboardRetentionDays)
    }
    await measure("sync-off unrelated-pref") {
      off.defaults.set("{{\($0), 0}, {800, 600}}", forKey: frame)
    }
    await measure("sync-off synced-pref(slider tick)") {
      off.defaults.set(30 + $0, forKey: Prefs.clipboardRetentionDays)
    }
    // 记改的时刻那次真的跑了（不然量的只是写偏好）
    let times = on.defaults.dictionary(forKey: SettingsSync.timesKey) ?? [:]
    #expect(times["pref:" + Prefs.clipboardRetentionDays] != nil)
    Self.time("(c) settings syncValues()") { _ = on.settings.syncValues() }
  }
}
