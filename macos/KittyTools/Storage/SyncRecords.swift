// 全局同步（2026-10-23 拍板，PLAN §10「全局同步」）里「一条一条的数据」的合并规则和文件写法：片段和收藏、生词本、网页搜索
// 与快捷链接、翻译服务、启动器收藏、设置（一项一条）。纯函数：执行层（NoteSyncer）交进来本机现在的样子、账本、文件夹里
// 自己和别的电脑的那份，拿回要落到本机的改动、新的账本、自己那份要写成什么。便签不走这里（NoteSync：输的那版要另存，
// 还有状态、顺序几组）。版本钟的比法、写法和便签同一套（NoteSync.precedes / joined / text / clock）。
// - **本机改了什么靠账本比**（各个仓库不用自己记钟）：账本（Ledger）记着上一轮合完时每条的钟、内容的哈希、改于。这一轮
//   本机的内容（按字节）和账本里的哈希不一样 = 本机改了；账本里有、本机没了 = 本机删了（留墓碑）；账本里没有的 = 本机
//   新加的。改了、新加的：自己那一格取「账本、墓碑、文件夹里各版」里自己那一格的最大再 +1（账本退回去了、自己那份又读
//   不出来时也不撞号），改于取调用方给的这一条真正改的时刻（changed：设置记着每一项什么时候改的），没给的用现在，都不晚于
//   现在（退出、合盖之后才合到的改动，不该被记成「刚改的」翻掉别人后来改的）。
// - **合**（C1）：被别的版本盖过的、被墓碑压住的（钟每格都不超过它）丢掉；剩下谁都盖不住谁的，改于晚的赢（同一刻按内容的
//   哈希，几台挑出来的一样），不留旧版；合完的钟是所有版本和墓碑每格的最大（输的那台下一轮看到的是快进）。一条都不剩 = 删。
// - **删除**（C2）：墓碑只记被删那一版的钟，不过期；删了之后别处又改过的压不住，照常合回来（宁可多一条）。
// - **账本被退回去了**（时间机器）：自己那份里某条的钟**自己那一格**比账本里的大——先把账本那条的这一格追上（别的格不并：
//   并了的话退回去的旧内容会拿到和后来那版一样的钟，只剩按改于比，钟快的旧值赢遍每一台）。
// - **第一次合**（没有账本）：本机原有的、文件夹里有同一编号（或者只有它的墓碑）的不算改动——钟是空的，谁都盖得过它；
//   union 时本机新加的、内容（dedupe 键）和文件夹里别的编号还活着的那版一样的，只留文件夹那条（C4：同样的正文不重复）；
//   adopt（设置）时别的电脑已经有这一类，本机文件夹里没有活着的版本的那几项删掉（回到默认），整个跟着它们。这几种丢掉的
//   不留墓碑（从没发出去过）、不算删除、不进刹车。
// **执行层必须守住的**（不然本机没改的会被当成改了、没删的被当成删了，一路传到每一台）：账本记着的就是本机落下去的——
// 账本和数据**同一个事务**提交（片段、生词、启动器收藏的账本放进各自的库，设置的账本放在同一个偏好域），落改动没成就不存
// 账本；从备份恢复库时账本跟着一起退回去（引擎会追上）；关掉一类时不清它的账本（清了 = 重新加入，关着时本机改的会被盖回去）；
// 交进来的是本机落下的全部（另一台没装的 App 那种不显示的也交），编码稳定（编 → 落 → 再编，字节一样），值里不带只属于
// 这台电脑的东西。本机这一轮自己删了一大批（erasing，比如库被清空）先问再写出去。
// 文件（自己子文件夹里的 `<类别>.json`）：一份里是这台电脑眼里每条的最新样子 + 墓碑；内容（value）是调用方编好的 JSON 文本
// （键排好序：同样的内容同样的字节），原样存、原样比，不在这里解开。读得严：格式更新（结构对得上、版本号更大）另说，类别
// 不对、编号重复、钟写坏了或太长都算读不出来；文件多大由执行层先看。

import CryptoKit
import Foundation

nonisolated enum SyncRecords {
  /// 一类数据（文件名、设置页那一行都按它）
  enum Kind: String, CaseIterable, Sendable {
    case clips, vocabulary, engines, services, launcher, settings, statuses

    /// 自己子文件夹里的文件名
    var fileName: String { "\(rawValue).json" }

    /// 设置页、提示里的叫法
    var title: String {
      switch self {
      case .clips: "片段和收藏"
      case .vocabulary: "生词本"
      case .engines: "网页搜索与快捷链接"
      case .services: "翻译服务"
      case .launcher: "启动器收藏"
      case .settings: "设置与快捷键"
      case .statuses: "状态屏的状态"
      }
    }
  }

  /// 一条
  struct Record: Equatable, Sendable {
    var value: String
    var clock: [String: Int]
    /// 改于（整数毫秒）：本机发现它变了的时刻；冲突里晚的赢
    var modified: Int64
  }

  /// 账本里的一条：上一轮合完时的钟、内容的哈希、改于
  struct Entry: Codable, Equatable, Sendable {
    var clock: [String: Int]
    var hash: String
    var modified: Int64
  }

  /// 一类数据的账本（本机的状态，跟着这台电脑走，不进文件夹）
  struct Ledger: Codable, Equatable, Sendable {
    var entries: [String: Entry] = [:]
    /// 墓碑（本机删的、从文件夹里读到的，并在一起）：编号 → 被删那一版的钟
    var erased: [String: [String: Int]] = [:]
  }

  /// 一台电脑子文件夹里的那份
  struct File: Equatable, Sendable {
    var records: [String: Record] = [:]
    var erased: [String: [String: Int]] = [:]
  }

  /// 第一次合（没有账本）时本机原有的怎么办
  enum Join: Sendable {
    /// 并在一起；dedupe 给出内容的键（片段的正文这些），本机新加的和文件夹里别的编号键一样就只留文件夹那条
    case union(dedupe: @Sendable (String) -> String?)
    /// 别的电脑已经有这一类：整个跟着它们，本机多出来的删掉（设置：回到默认）
    case adopt
  }

  /// 合一轮的结果
  struct Outcome: Equatable, Sendable {
    /// 要落到本机的：编号 → 新的内容（nil = 删掉）
    var changes: [String: String?] = [:]
    var ledger = Ledger()
    /// 自己子文件夹那份要写成这样
    var own = File()
    /// 本机原来有、这一轮要删掉的有几条；本机一共有几条（刹车，NoteSyncFolder.brakes）
    var trashing = 0
    var alive = 0
    /// 本机自己这一轮删了几条（账本里有、本机没了：要写出去墓碑的）——一大批时执行层先问
    var erasing = 0
  }

  /// 文件格式的版本（读到更大的：这一类整轮不合，说先更新）
  static let format = 1
  /// 文件里一条的编号最长多少（设置的键、UUID 都远在这以内）
  static let maxIDLength = 256

  // MARK: 给仓库用的两样

  /// 一张有序列表（网页搜索、翻译服务、启动器收藏、收藏夹）的**顺序单独一条记录**：编号 orderID，内容是编号数组，整条后改的赢
  /// ——改一条的内容和挪顺序不互相盖掉（顺序写在每条里的话，挪一下就改到后面每一条，和别处同时改它们的冲突）
  static let orderID = "~order"

  static func orderValue(_ ids: [String]) -> String {
    (try? encoder.encode(ids)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
  }

  /// 按顺序排：在顺序里的按顺序（同一个编号出现几次按第一次），不在的排在后面、按编号（几台排出来的一样）
  static func arranged(_ ids: some Sequence<String>, by order: [String]) -> [String] {
    var index: [String: Int] = [:]
    for (position, id) in order.enumerated() where index[id] == nil { index[id] = position }
    return ids.sorted { (index[$0] ?? .max, $0) < (index[$1] ?? .max, $1) }
  }

  /// 解开一条内容，**编回去要一字不差**：更新版本写的（多了这一版不认识的字段）解得开但编回去会丢字段——落下去再发出去就把
  /// 别人的字段删了，所以当成解不出来（仓库返回 .newer，这一类停下说先更新）
  static func decodeExact<Value: Codable>(_ type: Value.Type, from value: String) -> Value? {
    guard let decoded = try? JSONDecoder().decode(type, from: Data(value.utf8)),
      let again = try? encoder.encode(decoded),
      String(decoding: again, as: UTF8.self) == value
    else { return nil }
    return decoded
  }

  /// 内容的哈希：比「两版一不一样」、同一刻时定先后
  static func hash(_ value: String) -> String {
    Signing.hex(SHA256.hash(data: Data(value.utf8)).prefix(16))
  }

  /// 两段字按字节一样吗（String 的 == 按 Unicode 等价：合成的「é」和 e + 组合重音算一样，只换了写法的改动会被当成没变）
  static func sameBytes(_ a: String, _ b: String) -> Bool {
    guard a.utf8.count == b.utf8.count else { return false }
    var a = a
    var b = b
    return a.withUTF8 { x in
      b.withUTF8 { y in x.isEmpty || memcmp(x.baseAddress!, y.baseAddress!, x.count) == 0 }
    }
  }

  /// 钟每格都不超过墓碑：被它压住了
  static func buried(_ clock: [String: Int], by tombstone: [String: Int]?) -> Bool {
    guard let tombstone else { return false }
    return clock.allSatisfy { $0.value <= (tombstone[$0.key] ?? 0) }
  }

  /// 合一轮。local：本机现在的（编号 → 内容）；changed：本机知道的每条真正改的时刻（毫秒，没有的用 now）；ledger：上一轮合完
  /// 的账本（nil = 第一次合）；own：自己子文件夹里读到的（还没有、读不出来 = nil）；others：别的电脑的；me：本机的电脑编号；
  /// now：现在（毫秒）
  static func round(
    local: [String: String], changed: [String: Int64] = [:], ledger old: Ledger?, own: File?,
    others: [File], me: String, now: Int64, join: Join
  ) -> Outcome {
    assert(NoteSyncDisk.isDeviceName(me), "电脑编号写出去要读得回来")
    var ledger = old ?? Ledger()
    let joining = old == nil
    let remotes = (own.map { [$0] } ?? []) + others
    // 墓碑：账本里的和各份文件里的并起来
    for file in remotes {
      for (id, clock) in file.erased {
        ledger.erased[id] = NoteSync.joined([ledger.erased[id] ?? [:], clock])
      }
    }
    // 账本被退回去了：自己那份里本机那一格追上（不改内容和哈希：本机没改的那条照样算没改）
    for (id, record) in own?.records ?? [:] {
      guard var entry = ledger.entries[id], let count = record.clock[me],
        count > (entry.clock[me] ?? 0)
      else { continue }
      entry.clock[me] = count
      ledger.entries[id] = entry
    }
    var outcome = Outcome(alive: local.count)
    var versions: [String: [Record]] = [:]
    for file in remotes {
      for (id, record) in file.records { versions[id, default: []].append(record) }
    }
    /// 还活着的版本：没被墓碑压住、也没被别的（内容不一样的）版本盖过
    func standing(_ list: [Record], tombstone: [String: Int]?) -> [Record] {
      let alive = list.filter { !buried($0.clock, by: tombstone) }
      let hashes = alive.map { hash($0.value) }
      return alive.indices.filter { i in
        !alive.indices.contains { j in
          hashes[j] != hashes[i] && NoteSync.precedes(alive[i].clock, alive[j].clock)
        }
      }.map { alive[$0] }
    }
    func liveVersions(_ id: String) -> [Record] {
      standing(versions[id] ?? [], tombstone: ledger.erased[id])
    }

    // 第一次合时本机原有、直接丢掉的（见文件头：不留墓碑、不算删除）
    var dropped: Set<String> = []
    if joining {
      switch join {
      case .union(let dedupe):
        var keys: [String: String] = [:]
        for id in versions.keys.sorted() {
          for record in liveVersions(id) { if let key = dedupe(record.value) { keys[key] = id } }
        }
        for (id, value) in local where versions[id] == nil && ledger.erased[id] == nil {
          if let key = dedupe(value), let kept = keys[key], kept != id { dropped.insert(id) }
        }
      case .adopt:
        if others.contains(where: { !$0.records.isEmpty || !$0.erased.isEmpty }) {
          dropped = Set(local.keys.filter { liveVersions($0).isEmpty })
        }
      }
    }

    // 本机这一版（本机各条的哈希记下来，后面比「本机要不要换」时不再算）
    var mine: [String: Record] = [:]
    var localHashes: [String: String] = [:]
    for (id, value) in local where !dropped.contains(id) {
      let digest = hash(value)
      localHashes[id] = digest
      if let entry = ledger.entries[id], entry.hash == digest {
        mine[id] = Record(value: value, clock: entry.clock, modified: entry.modified)
      } else if ledger.entries[id] == nil, joining,
        versions[id] != nil || ledger.erased[id] != nil
      {
        // 第一次合、文件夹里有这一编号（或它的墓碑）：跟着文件夹，本机的不算改动（空钟谁都盖得过、墓碑也压得住）
        mine[id] = Record(value: value, clock: [:], modified: 0)
      } else {
        // 本机改了 / 新加的：钟从账本那条（没有就从墓碑）起，自己那一格接着见过的最大往上数
        var clock = ledger.entries[id]?.clock ?? ledger.erased[id] ?? [:]
        let seen =
          (versions[id] ?? []).map { $0.clock[me] ?? 0 } + [
            clock[me] ?? 0, ledger.erased[id]?[me] ?? 0,
          ]
        clock[me] = (seen.max() ?? 0) + 1
        mine[id] = Record(value: value, clock: clock, modified: min(changed[id] ?? now, now))
      }
    }
    // 账本里有、本机没了：本机删了
    for (id, entry) in ledger.entries where local[id] == nil {
      ledger.erased[id] = NoteSync.joined([ledger.erased[id] ?? [:], entry.clock])
      outcome.erasing += 1
    }
    for id in dropped {
      outcome.changes[id] = .some(nil)
      ledger.entries[id] = nil
    }

    for id in Set(mine.keys).union(versions.keys).union(ledger.entries.keys).subtracting(dropped) {
      let tombstone = ledger.erased[id]
      let all = (mine[id].map { [$0] } ?? []) + (versions[id] ?? [])
      let alive = all.filter { !buried($0.clock, by: tombstone) }
      let candidates = standing(alive, tombstone: nil)
      // 同 (改于, 哈希) 比；哈希只在同一刻时才算（每比一次都算两个，几千条一轮要几十毫秒）
      let winner = candidates.max {
        $0.modified != $1.modified ? $0.modified < $1.modified : hash($0.value) < hash($1.value)
      }
      guard var merged = winner else {
        ledger.entries[id] = nil
        if local[id] != nil {
          outcome.changes[id] = .some(nil)
          outcome.trashing += 1
        }
        continue
      }
      merged.clock = NoteSync.joined(alive.map(\.clock) + (tombstone.map { [$0] } ?? []))
      let digest = hash(merged.value)
      ledger.entries[id] = Entry(clock: merged.clock, hash: digest, modified: merged.modified)
      outcome.own.records[id] = merged
      // 按字节比（Swift 的字符串相等按 Unicode 等价：两种写法的「é」算一样，哈希不一样，会两台来回改）
      // （本机没有这条 = nil，和哪个哈希都不一样：加上）
      if (localHashes[id] ?? local[id].map(hash)) != digest {
        outcome.changes[id] = .some(merged.value)
      }
    }
    outcome.ledger = ledger
    outcome.own.erased = ledger.erased
    return outcome
  }

  // MARK: 文件

  private struct Stored: Codable {
    struct Item: Codable {
      var id: String
      var clock: String
      var modified: Int64
      var value: String
    }
    struct Gone: Codable {
      var id: String
      var clock: String
    }
    var format: Int
    var kind: String
    var records: [Item]
    var erased: [Gone]
  }

  static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }()

  /// 写成文件：按编号排、键排好序（内容一样就是同样的字节）
  static func data(of file: File, kind: Kind) -> Data {
    let stored = Stored(
      format: format, kind: kind.rawValue,
      records: file.records.sorted { $0.key < $1.key }.map {
        Stored.Item(
          id: $0.key, clock: NoteSync.text(of: $0.value.clock), modified: $0.value.modified,
          value: $0.value.value)
      },
      erased: file.erased.sorted { $0.key < $1.key }.map {
        Stored.Gone(id: $0.key, clock: NoteSync.text(of: $0.value))
      })
    return (try? encoder.encode(stored)) ?? Data()
  }

  /// 读文件的结果
  enum Read: Equatable, Sendable {
    case read(File)
    /// 更新版本的 Kitty Tools 写的
    case newer
    /// 读不出来（写坏了、不是这一类、编号重复、钟太长）
    case unreadable
  }

  static func file(from data: Data, kind: Kind) -> Read {
    /// 结构对得上的才算「更新版本写的」（随便一个 format 大的 JSON 不算：整类会停下来）
    struct Header: Decodable {
      var format: Int
      var kind: String
      var records: [Stored.Item]?
      var erased: [Stored.Gone]?
    }
    guard let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
      if let header = try? JSONDecoder().decode(Header.self, from: data),
        header.format > format, header.kind == kind.rawValue
      {
        return .newer
      }
      return .unreadable
    }
    guard stored.kind == kind.rawValue else { return .unreadable }
    guard stored.format <= format else { return .newer }
    var file = File()
    func valid(_ id: String) -> Bool {
      (1...maxIDLength).contains(id.count) && !id.unicodeScalars.contains { $0.value < 0x20 }
    }
    /// 钟：每一格都要读得出来（写坏的格子不跳过：读得严）、不重复、不太长
    func clock(_ text: String) -> [String: Int]? {
      guard text.utf8.count <= NoteSyncFolder.maxClockText else { return nil }
      let cells =
        text.isEmpty ? 0 : text.split(separator: ",", omittingEmptySubsequences: false).count
      let clock = NoteSync.clock(text: text)
      return clock.count == cells && clock.count <= NoteSyncFolder.maxClockCells ? clock : nil
    }
    for item in stored.records {
      guard valid(item.id), file.records[item.id] == nil, let clock = clock(item.clock),
        (0...NoteSyncFolder.maxMilliseconds).contains(item.modified)
      else { return .unreadable }
      file.records[item.id] = Record(value: item.value, clock: clock, modified: item.modified)
    }
    for gone in stored.erased {
      guard valid(gone.id), file.erased[gone.id] == nil, let clock = clock(gone.clock) else {
        return .unreadable
      }
      file.erased[gone.id] = clock
    }
    return .read(file)
  }
}
