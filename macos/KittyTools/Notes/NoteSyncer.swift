// 便签同步的执行层（便签未来计划 A1–A5，2026-10-22；规矩在 mac-native §2「便签同步」）：什么时候合一轮、一轮怎么走。
// 文件夹的写法和一轮该做什么在 NoteSyncFolder（纯函数），读写文件夹在 NoteSyncDisk（主线程外），合并规则在 NoteSync。
// - **开关**（A2 默认关）：设置里选了文件夹才开（enable：新的文件夹写标记、已经有库的接着用——标记还没下载完、读不出来，
//   或者没标记却有别的电脑的子文件夹，都不开：新写一个会把别的电脑全挡在外面；没标记的还得是空的，不往放着别的东西的
//   文件夹里撒子文件夹；文件夹和库编号记在这台电脑自己的偏好里，
//   不注册默认值、不跟着导出走；开了之后由调用方 start）；关掉（disable）只是不再同步，文件夹里的东西留着、本机的便签不动。
//   便签这个功能关着（Feature.notes）时也停（算「后台活」：stop 之后 syncNow、刹车的「继续」都不再起一轮），库照开。
// - **什么时候合**：开的时候一轮，之后每 20 秒一轮（ponytail: 轮询；同步盘本来就是几秒到几分钟的延迟，没变的文件只看属性
//   不读，几百个文件一轮几毫秒——真嫌慢再换 FSEvents），醒来时一轮，设置里「立即同步」一轮；一轮没完时再要的排在它后面。
// - **一轮**：先落盘（flush：写进文件夹的东西必须是落下去了的）→ 主线程外读文件夹 → 先认是不是那个文件夹（标记、格式；
//   读不出来、自己的 device.json 读不出来也停：这时认不出库被退回去了）→ 认出库被退回去了就先换编号（NoteStore.switchDevice，
//   要在写出去之前）→ 合（NoteSyncFolder.round）→ 刹车（A5：要放进最近删除的太多就停下来问，刘海岛上一个「继续」（条数变了
//   才再弹），设置页也有；「继续」只放行不超过当时那么多条的）→ **正在编辑的那几条先不换、也先不写出去**（key 窗口里拿着
//   焦点的、还挂着没确认的组字的：换进去之后编辑器会拿旧底 + 新打的字整段写回、钟又 +1，把同步来的盖掉；写出去的话别的
//   电脑每轮多一条另存的半截；等焦点离开再合）→ 落下去（applySync；没落下去就停，不写文件）→ 冲突另存了就在刘海岛说一句
//   （A3）→ 主线程外写出去（NoteSyncDisk.write）。
// - **认出库被退回去了**（时间机器把数据目录恢复成旧的）：① 文件夹里哪一版本机那一格的钟比库里的大；② 写出去的是第几轮
//   （epoch，只增不减）：便签文件、墓碑文件要动的那一轮先在库里 +1、device.json 最后写——自己子文件夹里记的比库里的大，
//   就是库退回去了（写到一半停了、换过文件夹、文件夹被恢复成旧的，都是文件夹里的小，不会认错）。
// - **状态**（设置页的状态行）：关着 / 正在同步 / 好了（上次同步的时刻）/ 停了（为什么：文件夹不在、不是那个文件夹、
//   更新版本写的、哪台的东西读不出来、读写出错）/ 等你确认（刹车）。别的电脑：名字和最后一次看到它的文件变的时刻。
// 拿下来的图片：编辑器里正开着的那条下次打开时才画出来（附件的尺寸在建的时候读）。
// ponytail: 退出时不再赶一轮（落盘照常，下次打开那一轮写出去）

import AppKit
import Observation

@Observable final class NoteSyncer {
  /// 现在怎样
  enum Status: Equatable {
    case off
    case syncing
    case idle
    case stopped(Problem)
    /// 刹车：这一轮要放进最近删除（或真删）这么多条，等用户说继续
    case waiting(trashing: Int)
  }

  /// 为什么停了
  enum Problem: Equatable {
    /// 文件夹不在（没登录 iCloud、移动硬盘没插、被删了）
    case missingFolder
    /// 不是那个文件夹（标记没了 / 换了）
    case notTheFolder
    /// 文件夹是更新版本的 Kitty Tools 写的
    case newerFormat
    /// 哪台电脑的墓碑读不出来（多半是还没下载完；它的名字，没写名字是 nil）
    case unreadable(String?)
    /// 标记、本机自己的 device.json 读不出来（多半是还没下载完；ponytail: 真写坏了会一直停在这，要删掉那个文件）
    case downloading
    /// 读写出错（原因）
    case failed(String)
  }

  /// 一轮隔多久
  static let interval: TimeInterval = 20
  /// 库里记「写出去的是第几轮」的那一项（note_meta）
  static let epochKey = "sync-epoch"

  // 下面四样只由一轮改（截图自检直接设）
  var status: Status = .off
  var lastSync: Date?
  /// 别的电脑（名字、最后一次看到它的文件变的时刻），按名字排
  var peers: [NoteSyncDisk.Peer] = []
  /// 这一轮还在等同步盘下载的文件有几个
  var downloading = 0
  /// 同步的文件夹、它的库编号（没开 = nil）：偏好里那两项的样子（设置页要跟着变，放在这里）
  private(set) var folder: URL?
  private(set) var library: String?

  @ObservationIgnored let store: NoteStore
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored var island: Island?
  /// 正在编辑的便签（这一轮先不换它们）；单测换成自己给的
  @ObservationIgnored var editing: () -> Set<String> = { NoteSyncer.editingNotes() }
  @ObservationIgnored var clock: () -> Date = { .now }
  /// 这台电脑叫什么（device.json）；单测换成固定的
  @ObservationIgnored var computerName: () async -> String = { await NoteSyncDisk.computerName() }
  @ObservationIgnored private var cache = NoteSyncDisk.Cache()
  @ObservationIgnored private var timer: Timer?
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var again = false
  /// 用户在刹车那里点了继续：当时是几条（不超过它的放行一次）
  @ObservationIgnored private var confirmed: Int?
  /// 刹车上一次弹刘海岛时是几条（一样的不再弹）
  @ObservationIgnored private var braked: Int?

  init(store: NoteStore, defaults: UserDefaults = .standard) {
    self.store = store
    self.defaults = defaults
    folder = defaults.string(forKey: Prefs.notesSyncFolder).map {
      URL(filePath: $0, directoryHint: .isDirectory)
    }
    library = defaults.string(forKey: Prefs.notesSyncLibrary)
  }

  var isEnabled: Bool { folder != nil && library != nil }

  // MARK: 开关

  /// 用这个文件夹同步：没有标记的写一个（新的库），有标记的接着用那个库。返回没开成的原因（nil = 开了，调用方接着
  /// start）。文件夹里已经有别的电脑的便签时合不合在一起，由调用方先问（NoteSyncDisk.inspect）
  func enable(folder: URL) async -> String? {
    let inspection = await NoteSyncDisk.inspect(folder: folder, device: store.deviceID)
    guard inspection.exists else { return "这个文件夹不在了" }
    guard !inspection.markerUnreadable else {
      return "这个文件夹里的同步记录还没下载完（或者读不出来），稍后再试"
    }
    var library = inspection.marker?.library
    if let marker = inspection.marker, marker.format > NoteSyncFolder.format {
      return "这个文件夹是更新版本的 Kitty Tools 用的，先更新再同步"
    }
    if library == nil, inspection.devices > 0 {
      return "这个文件夹里有别的 Mac 同步过的便签，却找不到同步记录（可能还没下载完），稍后再试"
    }
    // 没同步过的文件夹要是空的：不往「文稿」这种放着别的东西的文件夹里撒子文件夹
    if library == nil, !inspection.empty {
      return "这个文件夹里已经有别的东西了，新建一个空文件夹来同步"
    }
    if library == nil {
      let fresh = UUID().uuidString
      if let problem = await NoteSyncDisk.createMarker(in: folder, library: fresh) {
        return problem
      }
      library = fresh
    }
    defaults.set(folder.path, forKey: Prefs.notesSyncFolder)
    defaults.set(library, forKey: Prefs.notesSyncLibrary)
    self.folder = folder
    self.library = library
    cache = NoteSyncDisk.Cache()
    return nil
  }

  /// 不同步了：文件夹里的东西留着，本机的便签不动
  func disable() {
    stop()
    defaults.removeObject(forKey: Prefs.notesSyncFolder)
    defaults.removeObject(forKey: Prefs.notesSyncLibrary)
    folder = nil
    library = nil
    cache = NoteSyncDisk.Cache()
    peers = []
    lastSync = nil
    downloading = 0
  }

  /// 开始（开着同步时）：马上一轮，之后每 interval 秒一轮
  func start() {
    guard isEnabled else { return }
    timer?.invalidate()
    let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.syncNow() }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
    syncNow()
  }

  /// 停（便签这个功能关了、不同步了）：在走的那一轮走完就不再有下一轮
  func stop() {
    timer?.invalidate()
    timer = nil
    again = false
    confirmed = nil
    braked = nil
    status = .off
  }

  /// 马上合一轮（设置里「立即同步」、醒来时、刹车的「继续」）；一轮没完就排在它后面。停着（stop 之后）不起
  func syncNow() {
    guard isEnabled, timer != nil else { return }
    guard task == nil else {
      again = true
      return
    }
    task = Task { [weak self] in
      await self?.round()
      guard let self else { return }
      task = nil
      // 走这一轮时被停了：状态回到关着
      guard timer != nil else {
        status = .off
        return
      }
      if again {
        again = false
        syncNow()
      }
    }
  }

  /// 刹车那里点了「继续」
  func confirmTrashing() {
    allowTrashing()
    syncNow()
  }

  /// 下一轮不刹，只要要放进最近删除的不比现在等着的多（单测直接调它再 await round）
  func allowTrashing() {
    if case .waiting(let trashing) = status { confirmed = trashing }
  }

  // MARK: 一轮

  /// 合一轮、写出去（单测直接 await 它）
  func round() async {
    guard let folder, let library else { return }
    status = .syncing
    store.flush()
    let snapshot = await NoteSyncDisk.read(folder: folder, cache: cache)
    // 读的时候被关了、换了文件夹：这一轮作废
    guard self.folder == folder, self.library == library else { return }
    cache = snapshot.cache
    downloading = snapshot.downloading
    if snapshot.missing { return halt(.missingFolder) }
    // 文件夹里的东西信得过之前什么都不动（换编号也不）
    if snapshot.markerUnreadable { return halt(.downloading) }
    if let stop = NoteSyncFolder.check(snapshot.folder.marker, library: library) {
      return halt(problem(for: stop, in: snapshot))
    }
    if snapshot.unreadableInfo.contains(store.deviceID) { return halt(.downloading) }
    // 库被退回去了吗（文件头注释）：① 钟；② 第几轮——恢复之后又打了字、计数追上了也认得出来（光看钟认不出：同一台
    // 电脑同一个计数的两回改动，钟分不出来）。认出来就换编号，和自己文件夹里那一版不一样的都记一笔新编号的改动（走另存
    // 那条路，两版都留下）
    let epoch: Int
    do {
      epoch = try store.meta(Self.epochKey).flatMap { Int($0) } ?? 0
    } catch {
      return halt(.failed(error.localizedDescription))
    }
    var regressed = NoteSyncFolder.regressed(
      local: store.notes, folder: snapshot.folder, device: store.deviceID)
    let own = snapshot.folder.devices[store.deviceID]
    let rolledBack = (own?.epoch ?? 0) > epoch
    if rolledBack, let own {
      regressed.formUnion(store.notes.filter { own.notes[$0.id] != $0 }.map(\.id))
    }
    if !regressed.isEmpty || rolledBack {
      do {
        guard try store.switchDevice(bumping: regressed) else {
          return halt(.failed(store.saveProblem ?? "便签没存上"))
        }
      } catch {
        return halt(.failed(error.localizedDescription))
      }
    }
    peers = snapshot.peers.filter { $0.id != store.deviceID }.sorted {
      ($0.name ?? $0.id).localizedStandardCompare($1.name ?? $1.id) == .orderedAscending
    }
    var held: Set<String> = []
    switch NoteSyncFolder.round(
      local: store.notes, erased: store.erased, folder: snapshot.folder, library: library,
      now: clock())
    {
    case .failure(let reason):
      return halt(problem(for: reason, in: snapshot))
    case .success(let round):
      if round.brakes, round.trashing > confirmed ?? 0 {
        confirmed = nil
        status = .waiting(trashing: round.trashing)
        if braked != round.trashing {
          island?.show(
            "便签同步先停下了", detail: "这一轮要把 \(round.trashing) 条放进「最近删除」", tone: .warning,
            action: ("继续", { [weak self] in self?.confirmTrashing() }))
        }
        braked = round.trashing
        return
      }
      confirmed = nil
      braked = nil
      held = editing().intersection(round.merges.keys)
      let merges = round.merges.filter { !held.contains($0.key) }
      let before = Set(store.notes.map(\.id))
      guard store.applySync(merges, tombstones: round.tombstones) else {
        return halt(.failed(store.saveProblem ?? "便签没存上"))
      }
      let copied = merges.values.flatMap(\.copies).contains {
        !before.contains($0.id) && store.note($0.id) != nil
      }
      if copied {
        island?.show(
          "两台电脑改了同一条便签", detail: "另一版放进了「最近删除」", tone: .info,
          symbol: "arrow.triangle.2.circlepath")
      }
    }
    var plan = NoteSyncFolder.publish(
      local: store.notes, erased: store.erased, own: snapshot.folder.devices[store.deviceID],
      localImages: store.images?.fileNames() ?? [], folderImages: snapshot.folder.images)
    // 没换进来的那几条也先不写出去（还是没合的样子：别的电脑会把它当成和自己各改各的、另存一条）
    plan.writes.removeAll { held.contains($0.id) }
    // 便签、墓碑要动：先在库里记「第几轮」+1，device.json 最后写（NoteSyncDisk.write）——文件夹里的比库里的大就是库被
    // 退回去了；没写成的话文件夹里的小，不会认错
    var next = epoch
    if plan.touchesNotes {
      next += 1
      do {
        try store.setMeta(Self.epochKey, String(next))
      } catch {
        return halt(.failed(error.localizedDescription))
      }
    }
    let name = await computerName()
    let written = await NoteSyncDisk.write(
      plan, folder: folder, device: store.deviceID, name: name, epoch: next,
      images: store.images?.directory)
    guard self.folder == folder else { return }
    if let problem = written.problem { return halt(.failed(problem)) }
    lastSync = clock()
    status = .idle
  }

  /// 停在这一轮（下一轮照常来，问题没了就好了）
  private func halt(_ problem: Problem) {
    status = .stopped(problem)
  }

  private func problem(for stop: NoteSyncFolder.Stop, in snapshot: NoteSyncDisk.Snapshot)
    -> Problem
  {
    switch stop {
    case .notTheFolder: .notTheFolder
    case .newerFormat: .newerFormat
    case .unreadableTombstones(let device):
      .unreadable(snapshot.peers.first { $0.id == device }?.name)
    }
  }

  /// 正在编辑的便签：key 窗口里有输入框拿着焦点时，那扇窗口里的便签（正文框按编号认；标题框拿着焦点也算——它和正文在
  /// 同一扇窗口里）；别的窗口里还挂着没确认的组字的正文框。不是 key 的窗口打不了字，外面换了正文它照常换（NoteTextView.setText）
  static func editingNotes() -> Set<String> {
    var ids: Set<String> = []
    for window in NSApp.windows {
      let typing = window.isKeyWindow && window.firstResponder is NSTextView
      for editor in editors(in: window.contentView) where typing || editor.hasMarkedText() {
        if let id = editor.identifier?.rawValue { ids.insert(id) }
      }
    }
    return ids
  }

  private static func editors(in view: NSView?) -> [NoteTextView] {
    guard let view else { return [] }
    if let editor = view as? NoteTextView { return [editor] }
    return view.subviews.flatMap(editors(in:))
  }
}
