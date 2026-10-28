// 同步的执行层（便签未来计划 A1–A5，2026-10-22；2026-10-23 起全局同步也在这：规矩在 mac-native §2「便签同步」）：什么时候
// 合一轮、一轮怎么走。便签的文件夹写法和一轮该做什么在 NoteSyncFolder（纯函数），合并规则在 NoteSync；别的几类（片段和收藏、
// 生词本……，SyncSource）的合并规则在 SyncRecords；读写文件夹在 NoteSyncDisk（主线程外）。
// - **几部分**：便签（「notes」）和每一类 SyncSource；每部分一个勾（这台电脑自己的偏好 syncSkipped，默认都勾上）、跟着
//   各自的功能开关（featureOn：便签跟便签、片段跟剪贴板、生词本和翻译服务跟翻译、搜索和启动器收藏跟启动器、状态跟状态屏）
//   ——关着的那部分这一轮不合；设置那部分不跟功能，同步一开着就一直在合。一类先便签后别的：便签那部分停下来（文件夹不对、
//   刹车）整轮都停；别的哪一类出了问题只跳过那一类。
// - **开关**（A2 默认关）：设置里选了文件夹才开（enable：新的文件夹写标记、已经有库的接着用——标记还没下载完、读不出来，
//   或者没标记却有别的电脑的子文件夹，都不开：新写一个会把别的电脑全挡在外面；没标记的还得是空的，不往放着别的东西的
//   文件夹里撒子文件夹；文件夹和库编号记在这台电脑自己的偏好里，
//   不注册默认值、不跟着导出走；开了之后由调用方 start）；关掉（disable）只是不再同步，文件夹里的东西留着、本机的便签不动。
//   stop 之后 syncNow、刹车的「继续」都不再起一轮。
// - **从只同步便签的版本升上来的**（第三轮体检 R1，isUpgrade）：开着同步、设置没合过、勾从没存过——便签之外的几类在第一轮
//   之前先不勾（存下来），刘海岛（并进「已更新到」那座；岛上挂着警告时不弹）和设置页各说一声；设置页勾上还没合过的一类时
//   先问「合在一起？」（joins）。
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
// - **跳过**（第三轮体检第 6 批）：一部分上一轮整轮走完、什么都没落也没写，这一轮的输入又一模一样——读到的文件属性
//   （NoteSyncDisk.Snapshot.stamps：路径、文件号、改动时间、大小，同读缓存认「没变」的那几样）、本机那份（便签：库的代数、
//   电脑编号、库里记的第几轮、两边的图片文件名；一类：交出来的值、账本）——就不合也不写这一部分（合出来的会和上一轮一样）。
//   有文件没下载完、读不出来、刚改过（不到 2 秒）的部分不跳过；哪一步停了，下一轮全都照常合。量到的数在 SyncProbeTests 文件头。
//   ponytail: 上一轮的输入只记在内存里，重启后第一轮全合；没变的一轮还是要把每个文件看一遍属性、比一遍，随文件数线性涨
//   （5000 条便签 -O 13–19 ms，1000 条约 6 ms）——要再省就换 FSEvents 只看变了的；有一个永远读不出来的文件（哪台不用了的
//   Mac 留下的坏文件）时，那一部分每轮都不跳过，回到原来每轮全合的样子。
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
    /// 文件夹或某一类里有更新版本的 Kitty Tools 写的东西
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
  /// 便签之外接进同步的几类（AppDelegate 给：剪贴板、翻译历史……）
  @ObservationIgnored var sources: [SyncSource] = []
  /// 一部分（"notes" / 类别名）的功能开着没有（AppDelegate 给；单测里都开着）
  @ObservationIgnored var featureOn: (String) -> Bool = { _ in true }
  /// 这台电脑上不同步的几部分（设置页的勾）
  private(set) var skipped: Set<String>
  /// 设置页「同步」那一节说一句「现在也能同步别的几类，勾上要同步的」（upgraded 那次存下；勾上哪一类、看过那一节离开时
  /// 清掉，停止同步不清——再开时那几类照旧没勾）
  private(set) var newKindsHint: Bool
  /// 这次启动认出是从只同步便签的版本升上来的（AppDelegate 在刘海岛说一声）
  @ObservationIgnored private(set) var upgraded = false
  /// 这台电脑叫什么（device.json）；单测换成固定的
  @ObservationIgnored var computerName: () async -> String = { await NoteSyncDisk.computerName() }
  @ObservationIgnored private var cache = NoteSyncDisk.Cache()
  @ObservationIgnored private var timer: Timer?
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var again = false
  /// 用户在刹车那里点了继续：当时每一部分各是几条（每部分只用自己的额度，不超过它的放行一次）
  @ObservationIgnored private var confirmed: [String: Int] = [:]
  /// 正在等确认的那一轮，每一部分要删几条（点「继续」时记成 confirmed）
  @ObservationIgnored private var pending: [String: Int] = [:]
  /// 刹车上一次弹刘海岛时是几条（一样的不再弹）
  @ObservationIgnored private var braked: Int?
  /// 上一轮整轮走完时什么都没做（没落什么、没写什么）的那几部分，当时的输入：这一轮一模一样就跳过这一部分（文件头「跳过」）
  @ObservationIgnored private var settled: [String: Inputs] = [:]
  /// 上一轮跳过了哪几部分（单测看）
  @ObservationIgnored private(set) var skippedParts: Set<String> = []

  /// 一部分这一轮的输入里会变的那几样：读到的文件的属性（NoteSyncDisk.Stamp）+ 本机那份。一样就合出来、写出去的都一样
  private enum Inputs: Equatable {
    /// 便签：库的代数（改一条、合进来、清到期的都 +1）、电脑编号、库里记的第几轮、本机图片目录和文件夹 images/ 里的文件名
    case notes(
      stamps: [NoteSyncDisk.Stamp], generation: Int, device: String, epoch: Int,
      images: Set<String>, folderImages: Set<String>)
    /// 一类：电脑编号（换了编号要写出新的子文件夹）、本机那份、账本（账本被退回去了也认得出来）
    case records(
      stamps: [NoteSyncDisk.Stamp], device: String, values: Values, ledger: SyncRecords.Ledger?)
  }

  /// 一类交出来的值，按字节比（同 SyncRecords：只换了写法的改动也要发出去，不能当成没变跳过）
  private struct Values: Equatable {
    var values: [String: String]

    static func == (a: Values, b: Values) -> Bool {
      a.values.count == b.values.count
        && a.values.allSatisfy { key, value in
          b.values[key].map { SyncRecords.sameBytes($0, value) } ?? false
        }
    }
  }

  init(store: NoteStore, defaults: UserDefaults = .standard) {
    self.store = store
    self.defaults = defaults
    folder = defaults.string(forKey: Prefs.notesSyncFolder).map {
      URL(filePath: $0, directoryHint: .isDirectory)
    }
    library = defaults.string(forKey: Prefs.notesSyncLibrary)
    // 升级上来的：便签之外的几类先不勾、存下来（必须在第一轮之前：设置第一次合是整个跟着别的 Mac）
    let upgraded = Self.isUpgrade(defaults)
    if upgraded {
      defaults.set(SyncRecords.Kind.allCases.map(\.rawValue).sorted(), forKey: Prefs.syncSkipped)
      defaults.set(true, forKey: Prefs.syncNewKindsHint)
    }
    skipped = Set(defaults.stringArray(forKey: Prefs.syncSkipped) ?? [])
    newKindsHint = defaults.bool(forKey: Prefs.syncNewKindsHint)
    self.upgraded = upgraded
  }

  /// 从只同步便签的版本（0.6.0）升上来、开着同步的这台：文件夹有、设置这一类没合过（没账本）、「同步的内容」的勾从没存过
  /// （0.7.0 起开同步时 enable 会存一份）。新加的几类要是默认都勾上，第一轮就把这台的设置、快捷键、功能开关整个换成别的
  /// Mac 的（adopt），再按对面的保留天数清历史，谁也没问过——所以先不勾，到设置页勾上时再问合不合在一起（joins）
  static func isUpgrade(_ defaults: UserDefaults) -> Bool {
    defaults.string(forKey: Prefs.notesSyncFolder) != nil
      && defaults.object(forKey: SyncLedger.key(.settings)) == nil
      && defaults.object(forKey: Prefs.syncSkipped) == nil
  }

  /// 便签那部分的名字（和类别名放在同一组勾里）
  static let notesPart = NoteSyncFolder.notesPart

  /// 这一部分同不同步（设置页的勾）
  func syncs(_ part: String) -> Bool { !skipped.contains(part) }

  /// 勾上 / 取消一部分：取消只是不再合它，账本和文件夹里的都留着（再勾上接着合，关着时本机改的照样算本机改的）
  func setSyncs(_ part: String, _ on: Bool) {
    if on { skipped.remove(part) } else { skipped.insert(part) }
    defaults.set(skipped.sorted(), forKey: Prefs.syncSkipped)
    if on {
      dismissHint()
      syncNow()
    }
  }

  /// 勾上这一类会是它第一次合（还没有这个库的账本），而文件夹里有（或者还不知道有没有）别的 Mac：设置页先问合不合在一起
  /// ——设置第一次合整个跟着别的 Mac，片段、搜索、翻译服务这些同样内容的只留文件夹那条。便签那部分不问（它没有账本，
  /// 合的时候两版都留下）
  func joins(_ part: String) -> Bool {
    guard let library, lastSync == nil || !peers.isEmpty,
      let source = sources.first(where: { $0.syncKind.rawValue == part })
    else { return false }
    // 读不出来也问（这一轮反正不合）
    return (try? source.syncLedger(library: library)) == nil
  }

  /// 不再说那句「现在也能同步别的几类」（勾上了哪一类、设置页那一节看过了）
  func dismissHint() {
    guard newKindsHint else { return }
    newKindsHint = false
    defaults.removeObject(forKey: Prefs.syncNewKindsHint)
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
    // 这一版里开的同步（合不合在一起已经问过）：勾存一份，下次启动不当成升级上来的（isUpgrade）
    defaults.set(skipped.sorted(), forKey: Prefs.syncSkipped)
    self.folder = folder
    self.library = library
    cache = NoteSyncDisk.Cache()
    settled = [:]
    return nil
  }

  /// 不同步了：文件夹里的东西留着，本机的便签不动；为同步留着的几份缓存放掉
  func disable() {
    stop()
    SyncLedger.forget()
    for source in sources { source.syncStopped() }
    defaults.removeObject(forKey: Prefs.notesSyncFolder)
    defaults.removeObject(forKey: Prefs.notesSyncLibrary)
    folder = nil
    library = nil
    cache = NoteSyncDisk.Cache()
    settled = [:]
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
    // 晚几秒没关系（同步盘本来就是几秒到几分钟的延迟）：让系统把这次唤醒和别的计时器并在一起
    timer.tolerance = Self.interval / 4
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
    syncNow()
  }

  /// 停（便签这个功能关了、不同步了）：在走的那一轮走完就不再有下一轮
  func stop() {
    timer?.invalidate()
    timer = nil
    again = false
    confirmed = [:]
    pending = [:]
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
    if case .waiting = status { confirmed = pending }
  }

  // MARK: 一轮

  /// 合一轮、写出去（单测直接 await 它）
  func round() async {
    guard let folder, let library else { return }
    status = .syncing
    // 刹车的「继续」：每部分只用自己的额度，走到刹车那一步（这一轮定了停不停）才用掉
    let allowance = confirmed
    let notesOn = syncs(Self.notesPart) && featureOn(Self.notesPart)
    let sources = self.sources.filter {
      syncs($0.syncKind.rawValue) && featureOn($0.syncKind.rawValue)
    }
    if notesOn { store.flush() }
    // 这一轮没整轮走完（停在哪一步）的话下一轮都照常合
    let previous = settled
    settled = [:]
    var settling: [String: Inputs] = [:]
    var skipping: Set<String> = []
    let snapshot = await NoteSyncDisk.read(
      folder: folder, cache: cache, kinds: sources.map(\.syncKind), device: store.deviceID)
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
    let epoch: Int
    do {
      epoch = try store.meta(Self.epochKey).flatMap { Int($0) } ?? 0
    } catch {
      return halt(.failed(error.localizedDescription))
    }
    peers = snapshot.peers.filter { $0.id != store.deviceID }.sorted {
      ($0.name ?? $0.id).localizedStandardCompare($1.name ?? $1.id) == .orderedAscending
    }

    var plan = NoteSyncFolder.Publish()
    let localImages = notesOn ? store.images?.fileNames() ?? [] : []
    let noteInputs = Inputs.notes(
      stamps: snapshot.stamps[Self.notesPart] ?? [], generation: store.generation,
      device: store.deviceID, epoch: epoch, images: localImages,
      folderImages: snapshot.folder.images)
    let notesSettled = !snapshot.unsettled.contains(Self.notesPart)
    if notesOn, notesSettled, previous[Self.notesPart] == noteInputs {
      settling[Self.notesPart] = noteInputs
      skipping.insert(Self.notesPart)
    } else if notesOn {
      // 库被退回去了吗（文件头注释）：① 钟；② 第几轮——恢复之后又打了字、计数追上了也认得出来（光看钟认不出：同一台
      // 电脑同一个计数的两回改动，钟分不出来）。认出来就换编号，和自己文件夹里那一版不一样的都记一笔新编号的改动（走另存
      // 那条路，两版都留下）
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
      var held: Set<String> = []
      var merged = false
      switch NoteSyncFolder.round(
        local: store.notes, erased: store.erased, folder: snapshot.folder, library: library,
        now: clock())
      {
      case .failure(let reason):
        return halt(problem(for: reason, in: snapshot))
      case .success(let round):
        if round.brakes, round.trashing > allowance[Self.notesPart] ?? 0 {
          return wait(
            [Self.notesPart: round.trashing], title: "便签同步先停下了",
            detail: "这一轮要把 \(round.trashing) 条便签放进「最近删除」")
        }
        merged = !round.merges.isEmpty
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
            symbol: "arrow.triangle.2.circlepath.circle.fill")
        }
      }
      plan = NoteSyncFolder.publish(
        local: store.notes, erased: store.erased, own: snapshot.folder.devices[store.deviceID],
        localImages: localImages, folderImages: snapshot.folder.images)
      // 没换进来的那几条也先不写出去（还是没合的样子：别的电脑会把它当成和自己各改各的、另存一条）
      plan.writes.removeAll { held.contains($0.id) }
      // 什么都没换、什么都不用写（也没换编号）：输入不变的话下一轮也一样
      if notesSettled, !merged, plan.isEmpty, regressed.isEmpty, !rolledBack {
        settling[Self.notesPart] = noteInputs
      }
    }

    // 别的几类：一类一类合，落进各自的库（账本同一个事务），要写的文件交给 write；哪一类停了只跳过它
    var kindFiles: [SyncRecords.Kind: Data] = [:]
    var waiting: [String: Int] = [:]
    var trouble: Problem?
    for source in sources {
      let part = source.syncKind.rawValue
      switch merge(
        source, snapshot: snapshot, library: library, allowance: allowance[part] ?? 0,
        previous: previous[part])
      {
      case .done(let data, let inputs):
        if let data { kindFiles[source.syncKind] = data }
        settling[part] = inputs
      case .unchanged(let inputs):
        settling[part] = inputs
        skipping.insert(part)
      case .skipped: break
      case .braked(let count): waiting[part] = count
      case .problem(let problem): trouble = trouble ?? problem
      }
    }

    // 便签、墓碑要动：先在库里记「第几轮」+1，device.json 最后写（NoteSyncDisk.write）——文件夹里的比库里的大就是库被
    // 退回去了；没写成的话文件夹里的小，不会认错。这一轮没合便签：照文件夹里已经写着的写（不往小里写——库被退回去了的话，
    // 等便签再勾上时还认得出来）
    var next = notesOn ? epoch : max(epoch, snapshot.folder.devices[store.deviceID]?.epoch ?? 0)
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
      images: store.images?.directory, kinds: kindFiles)
    // 拿下来的图已经在本机的图片目录里了（别处出了错、换了文件夹也一样）：按「没图」建的墙卡片、编辑器里的占位框换上它们
    store.imagesArrived(Set(written.downloaded.map(\.id)))
    guard self.folder == folder else { return }
    if let problem = written.problem { return halt(.failed(problem)) }
    settled = settling
    skippedParts = skipping
    lastSync = clock()
    if !waiting.isEmpty {
      let count = waiting.values.reduce(0, +)
      let titles = sources.filter { waiting[$0.syncKind.rawValue] != nil }.map(\.syncKind.title)
      return wait(
        waiting, title: "同步先停下了",
        detail: "这一轮要删掉 \(count) 条\(titles.joined(separator: "、"))里的东西")
    }
    confirmed = [:]
    braked = nil
    if let trouble { return halt(trouble) }
    status = .idle
  }

  /// 一类合到哪了
  private enum KindStep {
    /// 合完了（要重写的自己那份；nil = 不用写）；什么都没落、没写的话带着这一轮的输入
    case done(Data?, settled: Inputs?)
    /// 输入和上一轮什么都没做的那一轮一样：跳过
    case unchanged(Inputs)
    /// 这一轮先不合（剪贴板面板里有还能撤销的改动）
    case skipped
    /// 刹车：这一轮要删这么多条
    case braked(Int)
    case problem(Problem)
  }

  /// 合一类：读到的各台那份 + 本机的 + 账本 → SyncRecords.round → 落下去（和账本一个事务）。别人的那份读不出来（还在下载）
  /// 这一类先不合（不知道它删了什么）；自己那份读不出来照常合（引擎接着见过的最大往上数）
  private func merge(
    _ source: SyncSource, snapshot: NoteSyncDisk.Snapshot, library: String, allowance: Int,
    previous: Inputs?
  ) -> KindStep {
    guard !source.syncBusy else { return .skipped }
    let part = source.syncKind.rawValue
    let me = store.deviceID
    var own: SyncRecords.File?
    var others: [SyncRecords.File] = []
    for (device, read) in snapshot.kinds[source.syncKind] ?? [:] {
      switch read {
      case .read(let file): if device == me { own = file } else { others.append(file) }
      case .newer: return .problem(.newerFormat)
      case .unreadable:
        guard device == me else {
          return .problem(.unreadable(snapshot.peers.first { $0.id == device }?.name))
        }
      }
    }
    let ledger: SyncRecords.Ledger?
    do {
      ledger = try source.syncLedger(library: library)
    } catch {
      return .problem(.failed("\(source.syncKind.title)的同步记录读不出来"))
    }
    let local = source.syncValues()
    let inputs =
      snapshot.unsettled.contains(part)
      ? nil
      : Inputs.records(
        stamps: snapshot.stamps[part] ?? [], device: me, values: Values(values: local),
        ledger: ledger)
    if let inputs, inputs == previous { return .unchanged(inputs) }
    let outcome = SyncRecords.round(
      local: local, changed: source.syncChanged(), ledger: ledger, own: own, others: others,
      me: me, now: Note.milliseconds(clock()), join: source.syncJoin)
    // 刹车：别处要删掉本机的、本机自己一下删掉的，加起来按删之前有几条算（设置不算：删一项 = 改回默认，没丢东西）
    let deleting = outcome.trashing + outcome.erasing
    if source.syncKind != .settings,
      NoteSyncFolder.brakes(trashing: deleting, alive: outcome.alive + outcome.erasing),
      deleting > allowance
    {
      return .braked(deleting)
    }
    // 编出来的自己那份太大（同步盘、别的电脑读不进来）：这一类不合、不写，说清楚（不每轮重写一份读不了的文件）
    let data = SyncRecords.data(of: outcome.own, kind: source.syncKind)
    guard data.count <= NoteSyncDisk.maxErasedBytes else {
      return .problem(
        .failed("\(source.syncKind.title)超过 \(NoteSyncDisk.maxErasedBytes >> 20) MB，同步不了"))
    }
    if !outcome.changes.isEmpty || outcome.ledger != ledger {
      switch source.applySync(outcome.changes, ledger: outcome.ledger, library: library) {
      case .saved: break
      // 有一条是更新版本写的（多了这一版不认识的字段）：整类没落，等这台更新
      case .newer: return .problem(.newerFormat)
      case .failed: return .problem(.failed("\(source.syncKind.title)没存上"))
      }
    }
    // 和读到的自己那份按字节比（String 的相等按 Unicode 等价，只换了写法的改动会漏写）
    let unchanged = own != nil && snapshot.ownBytes[source.syncKind] == data
    let idle = unchanged && outcome.changes.isEmpty && outcome.ledger == ledger
    return .done(unchanged ? nil : data, settled: idle ? inputs : nil)
  }

  /// 刹车：停在这一轮，等用户说继续（条数变了才再弹刘海岛）。parts：每一部分要删几条（点继续时各自记下额度）
  private func wait(_ parts: [String: Int], title: String, detail: String) {
    pending = parts
    confirmed = [:]
    let count = parts.values.reduce(0, +)
    status = .waiting(trashing: count)
    if braked != count {
      island?.show(
        title, detail: detail, tone: .warning,
        actions: [.init("继续") { [weak self] in self?.confirmTrashing() }])
    }
    braked = count
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
