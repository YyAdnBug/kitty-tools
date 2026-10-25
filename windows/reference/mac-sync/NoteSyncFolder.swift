// 便签的同步文件夹（便签未来计划 A1 / A5，2026-10-22；合并规则在 NoteSync，读写文件夹、什么时候合一轮在执行层）：
// 文件夹里放什么、一个文件怎么写怎么读、一轮扫描下来该做什么——全是纯函数，配单测和随机测试。
//
// 文件夹（用户选的，默认建议 iCloud 云盘里的一个；**每台电脑只写自己的子文件夹**，iCloud 层面不会有两台写同一个文件）：
//   kitty-notes-sync.json                  标记：这个库的编号和格式。读到、编号对得上才算「是那个文件夹、列出来的是真的」
//   devices/<电脑编号>/device.json           这台电脑叫什么（设置里列出来）
//   devices/<电脑编号>/notes/<便签编号>.md     这台电脑眼里每条便签的样子（含「最近删除」里的）
//   devices/<电脑编号>/erased.json           这台电脑知道的墓碑（永久删除过的，NoteSync.Tombstone）
//   images/<图片编号>.<扩展名>                 正文里的图片：存了就不改，同名就是同一张
// 便签文件：开头是和导出一样的文件头键（kitty-note、title、color、tint、created、modified、revision、archived、pinned、order），
// 后面加同步要的几样：时间都是整数毫秒（导出用的 ISO 写法到毫秒不保准）、删除时刻、版本钟、**内容哈希**；文件头之后**正文
// 原样**（存的形式，不换成 Markdown：往返要一个字不差，不然每一轮都像改过）。文件名用编号不用标题（不跟着改名、不撞名；
// 人要读看导出）。**读的时候从严**（文件夹是信任边界：别的电脑、别的 App、用户在访达里都能改）：先看大小，写了却解不出来的
// 键、内容和哈希对不上（被编辑器补了个换行、读到一半）都当「读不出来」——不然这一版会以同一个钟去和真的那版比，一半
// 概率赢、把真的挤进最近删除。设置里「导入…」认出这种文件就跳过（它读不全删除时刻，会把删了的当没删的导回来）。
// 一轮（round）：本机的便签 + 本机的墓碑 + **所有子文件夹（含自己的）**里的便签和墓碑 → 每条合一遍（NoteSync.merge）。
// 自己的也合：本机没有、自己文件夹里有、又没墓碑的（0.5.0 的到期清理不留墓碑）合回来——宁可多一条。
// - **读不出来的那一版这一轮不算**（只扔这一版，不整条不合：哪台不用了的电脑留下一个坏文件，整条就永远合不了）；
//   **哪台的墓碑读不出来**：整轮不合（不知道哪些该压住）；标记或墓碑文件是更新的格式：整轮不合、说先更新。
// - **刹车**（A5，brakes）：一轮要把本机没删的放进「最近删除」（或真删掉）的超过 20 条、或者（至少 5 条时）超过三成，就停下来
//   问。「至少 5 条」是替用户定的：便签只有三四条时删一条就是三成，每次都问太吵。每轮单独算：对面一次删了几十条、文件
//   分几轮才到的话可以每轮都不到线——都进最近删除，找得回来。
// 写出去（publish，合完、落盘之后）：自己子文件夹里那一版和本机的不一样（或者读不出来、没有）就重写；本机已经没有（永久删了）
// 的文件删掉；墓碑变了重写 erased.json；正文里引用的图片，文件夹里没有就传上去、本机没有就拿下来。
// 认出「库被退回去了」（regressed：时间机器从旧备份恢复了整个数据目录）：哪一版（自己的、别人的）里本机那一格的钟比库里
// 那条的大——接着用这个编号会和以前发出去的撞上。执行层换一个新编号、给这几条各记一笔新编号的改动（变成和那几版
// 「各改各的」，恢复后打的字走另存那条路，不被当成被盖过），旧的子文件夹当成别人的照常合；**要在写出去之前做**。

import Foundation

nonisolated enum NoteSyncFolder {
  static let markerName = "kitty-notes-sync.json"
  static let devicesName = "devices"
  static let notesName = "notes"
  static let erasedName = "erased.json"
  static let deviceInfoName = "device.json"
  static let imagesName = "images"
  /// 文件夹格式的版本（标记、墓碑文件里写着）：以后改了写法 +1，读到更大的整轮不合、说先更新
  static let format = 1
  /// 一轮放进「最近删除」多少条要停下来问（A5）
  static let brakeCount = 20
  static let brakeFloor = 5
  /// 一个便签文件最大多少（正文上限 + 64 KB 的头）；钟最多几格、那一行最长多少
  static let maxNoteFileBytes = Note.maxBodyBytes + 64 * 1024
  static let maxClockCells = 1024
  static let maxClockText = 64 * 1024
  /// 读进来的时刻夹在这个范围里（毫秒；离谱的值换算回去会变成 0，内存和库对不上）
  static let maxMilliseconds: Int64 = 1 << 53

  // MARK: 标记、墓碑、电脑信息

  struct Marker: Codable, Equatable, Sendable {
    var kind = "kitty-notes-sync"
    var format = NoteSyncFolder.format
    var library: String
  }

  struct DeviceInfo: Codable, Equatable, Sendable {
    var format = NoteSyncFolder.format
    var name: String
    /// 写出去的是第几轮（只增不减，同时记在库里；文件夹里的比库里的大 = 库被退回去了，NoteSyncer）
    var epoch: Int?
  }

  /// erased.json：编号 → 被删那一版的钟和状态时刻（整数毫秒）
  private struct ErasedFile: Codable {
    struct Entry: Codable {
      var clock: String
      var state: Int64
    }
    var format = NoteSyncFolder.format
    var erased: [String: Entry]
  }

  static func data(of tombstones: [String: NoteSync.Tombstone]) -> Data {
    let file = ErasedFile(
      erased: tombstones.mapValues {
        ErasedFile.Entry(clock: NoteSync.text(of: $0.clock), state: Note.milliseconds($0.state))
      })
    return (try? encoder.encode(file)) ?? Data()
  }

  /// 读 erased.json 的结果
  enum Tombstones: Equatable, Sendable {
    case read([String: NoteSync.Tombstone])
    /// 读不出来（没下载完、写坏了）
    case unreadable
    /// 更新的格式
    case newer
  }

  /// 读 erased.json：编号不是 UUID 的条目、钟太长的条目跳过；同一个编号写了几份（大小写不同）并起来
  static func tombstones(from data: Data) -> Tombstones {
    guard let file = try? JSONDecoder().decode(ErasedFile.self, from: data) else {
      return .unreadable
    }
    guard file.format <= format else { return .newer }
    var result: [String: NoteSync.Tombstone] = [:]
    for (raw, entry) in file.erased {
      guard let id = UUID(uuidString: raw)?.uuidString, entry.clock.utf8.count <= maxClockText
      else { continue }
      let tombstone = NoteSync.Tombstone(
        clock: NoteSync.clock(text: entry.clock), state: date(entry.state))
      result[id] = result[id].map { $0.merged(with: tombstone) } ?? tombstone
    }
    return .read(result)
  }

  static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }()

  private static func date(_ milliseconds: Int64) -> Date {
    Note.date(milliseconds: min(max(milliseconds, -maxMilliseconds), maxMilliseconds))
  }

  // MARK: 便签文件

  /// 一条便签在文件夹里的文件名
  static func fileName(of id: String) -> String { "\(id).md" }

  /// 文件名 → 便签编号（不是 `<UUID>.md` 的给 nil）
  static func noteID(ofFileNamed name: String) -> String? {
    guard name.hasSuffix(".md") else { return nil }
    return UUID(uuidString: String(name.dropLast(3)))?.uuidString
  }

  /// 是不是同步文件（设置里「导入…」认出来就跳过）
  static func isSyncFile(_ text: String) -> Bool {
    text.hasPrefix("---\n") && text.prefix(4096).contains("\nsync-clock:")
  }

  /// 一条便签的文件：导出同样的键 + 同步的几样，文件头之后正文原样
  static func text(of note: Note) -> String {
    var lines = ["---", "kitty-note: \(note.id)"]
    if !note.title.isEmpty { lines.append("title: \(NoteMarkdownFiles.jsonString(note.title))") }
    lines.append("color: \(Note.storedPreset(of: note.color))")
    if let rgb = Note.customRGB(of: note.color) {
      lines.append("tint: \(NoteMarkdownFiles.jsonString(Note.hex(rgb: rgb)))")
    }
    lines += [
      "created: \(NoteMarkdownFiles.iso(note.createdAt))",
      "modified: \(NoteMarkdownFiles.iso(note.modifiedAt))",
      "revision: \(min(max(note.revision, 0), Note.maxRevision))",
      "archived: \(note.isArchived)",
      "pinned: \(note.isPinned)",
      "order: \(note.order)",
      "sync-created: \(Note.milliseconds(note.createdAt))",
      "sync-modified: \(Note.milliseconds(note.modifiedAt))",
      "sync-state: \(Note.milliseconds(note.stateTime))",
      "sync-order: \(Note.milliseconds(note.orderTime))",
    ]
    if let deleted = note.deletedAt { lines.append("sync-deleted: \(Note.milliseconds(deleted))") }
    lines.append("sync-clock: \(NoteSync.text(of: note.clock))")
    lines.append("sync-hash: \(NoteSync.contentHash(note))")
    lines.append("---")
    return lines.joined(separator: "\n") + "\n" + note.body
  }

  /// 读回来：要是自家的同步文件（第一行 `---`、头里有合法的 kitty-note、sync-clock、sync-hash，文件名对得上编号），
  /// 写了的键都要解得出来，内容和哈希对得上；文字过一遍收拾（同导入）。认不出给 nil（这一版这一轮不算）
  static func note(from text: String, fileID: String) -> Note? {
    guard text.utf8.count <= maxNoteFileBytes, text.hasPrefix("---\n") else { return nil }
    var values: [String: String] = [:]
    var cursor = text.index(text.startIndex, offsetBy: 4)
    var closed = false
    for _ in 0..<40 {
      guard let end = text[cursor...].firstIndex(of: "\n") else { break }
      let line = text[cursor..<end]
      cursor = text.index(after: end)
      if line == "---" {
        closed = true
        break
      }
      guard let colon = line.firstIndex(of: ":") else { return nil }
      let key = line[..<colon].trimmingCharacters(in: .whitespaces)
      guard values[key] == nil else { return nil }
      values[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    guard closed, let id = values["kitty-note"].flatMap({ UUID(uuidString: $0)?.uuidString }),
      id == fileID, let clockText = values["sync-clock"], clockText.utf8.count <= maxClockText,
      let hash = values["sync-hash"],
      let created = values["sync-created"].flatMap(Int64.init),
      let modified = values["sync-modified"].flatMap(Int64.init),
      let state = values["sync-state"].flatMap(Int64.init),
      let ordered = values["sync-order"].flatMap(Int64.init),
      let preset = values["color"].flatMap(Int.init), (0..<Note.colorCount).contains(preset),
      let order = values["order"].flatMap(Double.init), order.isFinite,
      let revision = values["revision"].flatMap(Int.init),
      let archived = values["archived"].flatMap(Bool.init),
      let pinned = values["pinned"].flatMap(Bool.init)
    else { return nil }
    // 选填的：写了就要解得出来
    var title = ""
    if let raw = values["title"] {
      guard let decoded = NoteMarkdownFiles.jsonDecode(raw) else { return nil }
      title = decoded
    }
    var tint: Int?
    if let raw = values["tint"] {
      guard let decoded = NoteMarkdownFiles.jsonDecode(raw).flatMap(Note.rgb(hex:)) else {
        return nil
      }
      tint = decoded
    }
    var deleted: Date?
    if let raw = values["sync-deleted"] {
      guard let value = Int64(raw) else { return nil }
      deleted = date(value)
    }
    let clock = NoteSync.clock(text: clockText)
    guard clock.count <= maxClockCells else { return nil }
    let body = Note.sanitized(text: String(text[cursor...]))
    guard body.utf8.count <= Note.maxBodyBytes else { return nil }
    let note = Note(
      id: id, title: Note.sanitized(title: title), body: body,
      color: Note.color(preset: preset, tint: tint), createdAt: date(created),
      modifiedAt: date(modified), revision: min(max(revision, 0), Note.maxRevision),
      isArchived: archived, isPinned: pinned, order: order, deletedAt: deleted,
      stateChangedAt: date(state), orderChangedAt: date(ordered), clock: clock)
    return NoteSync.contentHash(note) == hash ? note : nil
  }

  // MARK: 一轮

  /// 读到的一台电脑的子文件夹
  struct Device: Equatable, Sendable {
    var name: String?
    /// device.json 里记的「写出去的是第几轮」（见 DeviceInfo.epoch）
    var epoch: Int?
    /// 读出来的便签
    var notes: [String: Note] = [:]
    /// 有文件、但读不出来的（没下载完、写坏了、格式认不出）
    var unreadable: Set<String> = []
    /// 墓碑文件
    var erased: Tombstones = .read([:])
  }

  /// 读到的整个文件夹
  struct Folder: Equatable, Sendable {
    /// 标记（没有、读不出来 = nil）
    var marker: Marker?
    /// 电脑编号 → 它的子文件夹（含本机自己的）
    var devices: [String: Device] = [:]
    /// images/ 里的文件名
    var images: Set<String> = []
  }

  /// 这一轮合不合、为什么不合
  enum Stop: Error, Equatable, Sendable {
    /// 没有标记、或者标记里的编号不是这个库的（换了文件夹、文件夹被清空了）
    case notTheFolder
    /// 这台电脑的墓碑读不出来（多半是还没下载完）
    case unreadableTombstones(device: String)
    /// 文件夹是更新版本的 Kitty Tools 写的
    case newerFormat
  }

  /// 合一轮的结果
  struct Round: Equatable, Sendable {
    /// 要落下去的（NoteStore.applySync）：只有和本机不一样的、或者带着要另存的
    var merges: [String: NoteSync.Merge] = [:]
    /// 这一轮的墓碑（本机的和各台的并起来）
    var tombstones: [String: NoteSync.Tombstone] = [:]
    /// 本机没删的、这一轮要放进「最近删除」或真删掉的有几条；本机一共有几条没删的
    var trashing = 0
    var alive = 0
    /// 这一轮读不出来、没算进去的那几版（编号）
    var skipped: Set<String> = []
    /// 要不要先停下来问（A5）
    var brakes: Bool { NoteSyncFolder.brakes(trashing: trashing, alive: alive) }
  }

  /// 刹车（A5）：超过 20 条；或者至少 5 条、超过三成
  static func brakes(trashing: Int, alive: Int) -> Bool {
    trashing > brakeCount || (trashing >= brakeFloor && trashing * 10 > alive * 3)
  }

  /// 是不是那个文件夹：有标记、格式不比这一版新、库编号对得上（文件夹里的东西信得过之前什么都不做，NoteSyncer 先看它）
  static func check(_ marker: Marker?, library: String) -> Stop? {
    guard let marker else { return .notTheFolder }
    guard marker.format <= format else { return .newerFormat }
    guard marker.library == library else { return .notTheFolder }
    return nil
  }

  /// 合一轮：local / erased 是本机的便签和墓碑，folder 是读到的文件夹，library 是本机记着的库编号
  static func round(
    local: [Note], erased: [String: NoteSync.Tombstone], folder: Folder, library: String,
    now: Date
  ) -> Result<Round, Stop> {
    if let stop = check(folder.marker, library: library) { return .failure(stop) }
    var tombstones = erased
    for (device, other) in folder.devices.sorted(by: { $0.key < $1.key }) {
      switch other.erased {
      case .newer: return .failure(.newerFormat)
      case .unreadable: return .failure(.unreadableTombstones(device: device))
      case .read(let theirs):
        for (id, tombstone) in theirs {
          tombstones[id] = tombstones[id].map { $0.merged(with: tombstone) } ?? tombstone
        }
      }
    }
    var round = Round(tombstones: tombstones)
    var remotes: [String: [Note]] = [:]
    for other in folder.devices.values {
      round.skipped.formUnion(other.unreadable)
      for (id, note) in other.notes { remotes[id, default: []].append(note) }
    }
    let mine = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
    round.alive = local.count { $0.deletedAt == nil }
    for id in Set(mine.keys).union(remotes.keys) {
      let merge = NoteSync.merge(
        local: mine[id], remotes: remotes[id] ?? [], tombstone: tombstones[id], now: now)
      let fresh = merge.copies.contains { mine[$0.id] == nil && tombstones[$0.id] == nil }
      guard merge.note != mine[id] || fresh else { continue }
      round.merges[id] = merge
      if let old = mine[id], old.deletedAt == nil, merge.note == nil || merge.note?.deletedAt != nil
      {
        round.trashing += 1
      }
    }
    return .success(round)
  }

  /// 写出去的：merges 落下去之后，本机的便签和墓碑 → 自己子文件夹里要重写 / 删的、erased.json 要不要重写、图片传上去 / 拿下来
  struct Publish: Equatable, Sendable {
    /// 要（重）写的便签
    var writes: [Note] = []
    /// 要删的便签文件（本机已经没有了、有墓碑的）
    var deletes: [String] = []
    /// erased.json 要重写成这样（nil = 不用动）
    var erased: [String: NoteSync.Tombstone]?
    /// 文件夹里没有、要传上去的图片；本机没有、要拿下来的图片
    var uploads: [NoteImages.Image] = []
    var downloads: [NoteImages.Image] = []
    /// 什么都不用做
    var isEmpty: Bool { !touchesNotes && uploads.isEmpty && downloads.isEmpty }
    /// 便签文件、墓碑文件要动（这才算写出去新的一轮：图片两头补齐不算，NoteSyncer 的 epoch）
    var touchesNotes: Bool { !writes.isEmpty || !deletes.isEmpty || erased != nil }
  }

  /// own：读到的自己的子文件夹（还没有 = nil）；localImages：本机图片目录里的文件名
  static func publish(
    local: [Note], erased: [String: NoteSync.Tombstone], own: Device?, localImages: Set<String>,
    folderImages: Set<String>
  ) -> Publish {
    var plan = Publish()
    // 自己文件夹里那一版和本机的不一样（读不出来、没有都算不一样）就重写
    plan.writes = local.filter { own?.notes[$0.id] != $0 }
    let ids = Set(local.map(\.id))
    let onDisk = Set(own.map { Array($0.notes.keys) } ?? []).union(own?.unreadable ?? [])
    // 只删永久删过的（有墓碑）：本机没有、又没墓碑的，读得出来的这一轮已经合回来了；读不出来的（还在下载、库被退回去了）
    // 可能是唯一的一份，留着
    plan.deletes = onDisk.subtracting(ids).filter { erased[$0] != nil }.sorted()
    if own?.erased != .read(erased) { plan.erased = erased }
    var referenced: [String: NoteImages.Image] = [:]
    for note in local where NoteImages.containsToken(note.body) {
      for match in NoteImages.matches(in: note.body as NSString) {
        var image = match.image
        image.width = nil
        referenced["\(image.id.uuidString).\(image.ext)"] = image
      }
    }
    for (name, image) in referenced.sorted(by: { $0.key < $1.key }) {
      if localImages.contains(name), !folderImages.contains(name) { plan.uploads.append(image) }
      if !localImages.contains(name), folderImages.contains(name) { plan.downloads.append(image) }
    }
    return plan
  }

  /// 库被退回去了吗（时间机器从旧备份恢复了整个数据目录）：哪一版（各子文件夹里的，含自己的）里本机那一格的钟比库里
  /// 那条的大。返回这样的便签编号（空 = 没退回去）；本机没有的不算（照常合回来，宁可多一条）
  static func regressed(local: [Note], folder: Folder, device: String) -> Set<String> {
    let mine = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
    var found: Set<String> = []
    for other in folder.devices.values {
      for (id, version) in other.notes {
        guard let note = mine[id] else { continue }
        if (version.clock[device] ?? 0) > (note.clock[device] ?? 0) { found.insert(id) }
      }
    }
    return found
  }
}
