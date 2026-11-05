// 在 Mac 上生成便签同步（PLAN-v13）要逐字节对上的样本：Windows 的 NoteSync / NoteSyncFolder / NoteFileHeader 照 mac 移植，
// 两边读写同一个同步文件夹，格式和合并规则差一点就会互相当成对方改过、来回另存。这里**直接编 mac 的源码**（macos 分支的
// Note、NoteSync、NoteSyncFolder、NotePaper（只要纸色那半）、NoteImages、NoteTasks），加最少的桩，跑一遍把输入和 mac 算出来的
// 结果写进 KittyTools.Tests/Fixtures/notes-sync-golden.json；Windows 的 NoteSyncTests 拿同样的输入自己算一遍、逐个比。
//
// 怎么跑（仓库根目录，Mac 上；不用切分支）：
//   T=$(mktemp -d)
//   for f in Note NoteSync NoteSyncFolder NotePaper NoteImages NoteTasks; do
//     git show macos:macos/KittyTools/Notes/$f.swift > $T/$f.swift; done
//   awk '/^nonisolated enum NoteColor/{exit} {print}' $T/NotePaper.swift > $T/p && mv $T/p $T/NotePaper.swift
//   swiftc -swift-version 6 -default-isolation MainActor -parse-as-library \
//     windows/tools/notes-sync-golden.swift $T/*.swift -o $T/golden
//   $T/golden windows/KittyTools.Tests/Fixtures/notes-sync-golden.json
//
// 桩（mac 那边改了这几个函数，这里跟着改、重新生成）：
// - Signing.hex、NoteImageStore.identifier(ofFileNamed:) / orphanDays：照抄 mac；
// - NoteMarkdownFiles.jsonString / jsonDecode：照抄 mac；iso 照抄，只是时区由样本给（mac 是 TimeZone.current，Windows 由调用方传）；
// - NoteMarkdown：只留 Note.swift / NoteTasks.swift 编得过要的空壳（显示标题、摘要不在样本里）；srgb：空壳（纸色的界面那半不用）。
// 随机生成的场景用固定种子，结果和 Swift 字典的遍历顺序无关（同一种内容的几版，另存那条用到的字段都由内容定）。

import AppKit
import CryptoKit
import Foundation

// MARK: 桩

nonisolated enum Signing {
  static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
    var digits: [UInt8] = []
    digits.reserveCapacity(digest.underestimatedCount * 2)
    func digit(_ nibble: UInt8) -> UInt8 { nibble < 10 ? 0x30 + nibble : 0x57 + nibble }
    for byte in digest {
      digits.append(digit(byte >> 4))
      digits.append(digit(byte & 0x0F))
    }
    return String(decoding: digits, as: UTF8.self)
  }
}

nonisolated enum NoteImageStore {
  static let orphanDays = 30
  static func identifier(ofFileNamed name: String) -> UUID? {
    let parts = name.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2, let id = UUID(uuidString: String(parts[0])) else { return nil }
    let ext = parts[1]
    guard (1...NoteImages.maxExtension).contains(ext.count),
      ext.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber) })
    else { return nil }
    return id
  }
}

nonisolated enum NoteMarkdown {
  enum Role { case open, content, close }
  struct CodeBlock {}
  static func codeBlocks(in text: NSString) -> [CodeBlock] { [] }
  static func role(at location: Int, in blocks: [CodeBlock]) -> Role? { nil }
  static func plain(_ text: String, blocks: Bool) -> String { text }
}

nonisolated func srgb(_ hex: Int) -> NSColor { NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1) }

nonisolated enum NoteMarkdownFiles {
  nonisolated(unsafe) static var zone = TimeZone(secondsFromGMT: 8 * 3600)!

  static func jsonString(_ value: String) -> String {
    guard let data = try? JSONEncoder().encode(value),
      let text = String(data: data, encoding: .utf8)
    else { return "\"\"" }
    return text
  }

  static func jsonDecode(_ raw: String) -> String? {
    guard let data = raw.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(String.self, from: data)
  }

  static func iso(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = zone
    return formatter.string(from: date)
  }
}

// MARK: 样本的 JSON

nonisolated indirect enum J: Encodable {
  case null, bool(Bool), int(Int64), string(String), array([J]), object([String: J])

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .int(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }
}

func ms(_ date: Date) -> Int64 { Note.milliseconds(date) }
func date(_ ms: Int64) -> Date { Note.date(milliseconds: ms) }
func opt(_ value: J?) -> J { value ?? .null }

func j(_ clock: [String: Int]) -> J { .object(clock.mapValues { .int(Int64($0)) }) }
func j(_ note: Note) -> J {
  .object([
    "id": .string(note.id), "title": .string(note.title), "body": .string(note.body),
    "color": .int(Int64(note.color)), "created": .int(ms(note.createdAt)),
    "modified": .int(ms(note.modifiedAt)), "revision": .int(Int64(note.revision)),
    "archived": .bool(note.isArchived), "pinned": .bool(note.isPinned),
    "orderBits": .string(String(note.order.bitPattern)),
    "deleted": opt(note.deletedAt.map { .int(ms($0)) }),
    "state": opt(note.stateChangedAt.map { .int(ms($0)) }),
    "ordered": opt(note.orderChangedAt.map { .int(ms($0)) }), "clock": j(note.clock),
  ])
}
func j(_ notes: [Note]) -> J { .array(notes.map(j)) }
func j(_ tombstone: NoteSync.Tombstone) -> J {
  .object(["clock": j(tombstone.clock), "state": .int(ms(tombstone.state))])
}
func j(_ tombstones: [String: NoteSync.Tombstone]) -> J { .object(tombstones.mapValues(j)) }
func j(_ merge: NoteSync.Merge) -> J {
  .object([
    "note": opt(merge.note.map(j)), "copies": j(merge.copies), "trashes": .bool(merge.trashes),
    "base": opt(merge.base.map { .int(Int64($0)) }),
  ])
}
func j(_ read: NoteSyncFolder.Tombstones) -> J {
  switch read {
  case .read(let entries): .object(["kind": .string("read"), "entries": j(entries)])
  case .unreadable: .object(["kind": .string("unreadable"), "entries": .object([:])])
  case .newer: .object(["kind": .string("newer"), "entries": .object([:])])
  }
}
func j(_ device: NoteSyncFolder.Device) -> J {
  .object([
    "name": opt(device.name.map(J.string)), "epoch": opt(device.epoch.map { .int(Int64($0)) }),
    "notes": .object(device.notes.mapValues(j)), "hashes": .object(device.hashes.mapValues(J.string)),
    "unreadable": .array(device.unreadable.sorted().map(J.string)), "erased": j(device.erased),
  ])
}
func j(_ folder: NoteSyncFolder.Folder) -> J {
  .object([
    "marker": opt(
      folder.marker.map {
        .object(["format": .int(Int64($0.format)), "library": .string($0.library)])
      }),
    "devices": .object(folder.devices.mapValues(j)),
    "images": .array(folder.images.sorted().map(J.string)),
  ])
}
func j(_ image: NoteImages.Image) -> J {
  .object([
    "id": .string(image.id.uuidString), "ext": .string(image.ext),
    "width": opt(image.width.map { .int(Int64($0)) }),
  ])
}
func j(_ strings: Set<String>) -> J { .array(strings.sorted().map(J.string)) }
func j(_ ledger: [String: Date]) -> J { .object(ledger.mapValues { .int(ms($0)) }) }

nonisolated struct Case: Encodable {
  var kind: String
  var input: J
  var output: J
}

var cases: [Case] = []
func add(_ kind: String, _ input: [String: J], _ output: J) {
  cases.append(Case(kind: kind, input: .object(input), output: output))
}

/// 线性同余（同 mac NoteSyncFuzzTests）
struct Seeded {
  var state: UInt64
  mutating func next(_ bound: Int) -> Int {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return Int((state >> 33) % UInt64(max(bound, 1)))
  }
  mutating func chance(_ odds: Int) -> Bool { next(odds) == 0 }
  mutating func pick<T>(_ items: [T]) -> T { items[next(items.count)] }
}

let t0: Int64 = 1_800_000_000_000
func at(_ offset: Int64) -> Date { date(t0 + offset) }

let tricky = [
  "", "一行", "带\n换行\n", "引号\"和\\反斜杠 / 斜杠", "emoji 😀👍🏽🇨🇳", "---\n假的头\n---\n", "\r\n第二行\r\n",
  "e\u{0301} vs \u{00E9}", "![image](kitty-note-image://6F0C0B4E-3E3A-4C4C-9E2B-1A2B3C4D5E6F.png)", "  前后空格  ",
  "sep \u{2028}\u{2029}", "tab\there", "ctrl \u{0001}\u{0008}\u{000C}\u{001F}\u{007F}", "\u{FEFF}bom", "\n\n",
  "title: 假的\nsync-clock: A:1", "☐ 待办\n☑ 做完", "冒号:\u{0301}组合",
]
let colors = [
  0, 1, 2, 3, 4, 5, 6, 7, Note.custom(rgb: 0xC2DFF8), Note.custom(rgb: 0x112233),
  Note.custom(rgb: 0xFFFFFF), Note.custom(rgb: 0), Note.custom(rgb: 0xFCE795), Note.custom(rgb: 0x7F3FBF),
]
let devices = ["A", "B", "C", "3F9A0C11-2B44-4D6E-8F00-1234567890AB"]

func randomClock(_ random: inout Seeded) -> [String: Int] {
  var clock: [String: Int] = [:]
  for device in devices.prefix(3) where random.chance(2) { clock[device] = random.next(4) }
  if random.chance(6) { clock[devices[3]] = 1 + random.next(3) }
  return clock
}

/// 一种内容（标题、正文、颜色、建于、改于、顺序）由编号 content 定：同一种内容的几版另存出来一样（和遍历顺序无关）
func version(
  id: String, content: Int, random: inout Seeded, revision: Int? = nil
) -> Note {
  let deleted = random.chance(4) ? at(Int64(random.next(9)) * 1000) : nil
  return Note(
    id: id, title: content % 3 == 0 ? tricky[content % tricky.count] : "",
    body: tricky[(content * 7 + 1) % tricky.count] + "#\(content)", color: colors[content % colors.count],
    createdAt: at(-Int64(content % 5) * 1000), modifiedAt: at(Int64(content % 6) * 1000),
    revision: revision ?? random.next(5), isArchived: random.chance(4), isPinned: random.chance(4),
    order: [0, 1, -1, 0.5, 2.25, 1e-9][content % 6], deletedAt: deleted,
    stateChangedAt: random.chance(5) ? nil : at(Int64(random.next(9)) * 1000),
    orderChangedAt: random.chance(5) ? nil : at(Int64(random.next(9)) * 1000),
    clock: randomClock(&random))
}

func randomTombstone(_ random: inout Seeded) -> NoteSync.Tombstone {
  NoteSync.Tombstone(clock: randomClock(&random), state: at(Int64(random.next(9)) * 1000))
}

// MARK: 哈希、另存编号、钟

func clocksAndHashes() {
  var random = Seeded(state: 11)
  for index in 0..<40 {
    let note = version(id: "N\(index)", content: index, random: &random)
    add("contentHash", ["note": j(note)], .string(NoteSync.contentHash(note)))
  }
  for (id, hash) in [
    ("N", "abc"), ("N", "abd"), ("M", "abc"), ("6F0C0B4E-3E3A-4C4C-9E2B-1A2B3C4D5E6F", "0123456789abcdef0123456789abcdef"),
    ("", ""), ("中文编号", "😀"),
  ] {
    add("copyID", ["id": .string(id), "hash": .string(hash)], .string(NoteSync.copyID(of: id, content: hash)))
  }
  for clock in [
    [:], ["A": 1], ["B-2": 5, "A1": 3], ["a": 1, "B": 2, "A": 3, "b": 4, "0": 5, "-": 6],
    ["3F9A0C11-2B44-4D6E-8F00-1234567890AB": 1 << 40, "A": 0],
  ] as [[String: Int]] {
    add("clockText", ["clock": j(clock)], .string(NoteSync.text(of: clock)))
  }
  let longID = String(repeating: "x", count: 64)
  for text in [
    "", "A:1", "A1:3,B-2:5", "A:2,坏:1,B:0,C:-1,D:x,:3,E:1:2,F:4", "A:2,A:5", "A:5,A:2",
    "A:\(NoteSync.maxCount),B:\(NoteSync.maxCount + 1),C:\(Int.max)", "A::1", ":A:1", "A:1:", ",,A:1,,",
    "A:+3", "A: 3", " A:3", "A:3 ", "A:03", "A:1,\u{0301}B:2", "A:1\u{0301},B:2", "A:\u{0301}1,B:2",
    "\(longID):1,\(longID)y:2", "a_b:1,a.b:2,ä:3,A:１", "A:1\r\nB:2", "A:99999999999999999999", "A:-0,B:+0",
    "x:1,X:2,0:3", "A:1,B", "😀:1,C:7",
  ] {
    add("clockRead", ["text": .string(text)], j(NoteSync.clock(text: text)))
  }
  for (a, b) in [
    ([:], [:]), ([:], ["A": 1]), (["A": 1], ["A": 1]), (["A": 1], ["A": 2]), (["A": 2], ["A": 1]),
    (["A": 1], ["B": 1]), (["A": 0], [:]), ([:], ["A": 0]), (["A": 1, "B": 1], ["A": 1, "B": 2]),
  ] as [([String: Int], [String: Int])] {
    add("precedes", ["a": j(a), "b": j(b)], .bool(NoteSync.precedes(a, b)))
  }
}

// MARK: 文件头的写法

func headerWriting() {
  var random = Seeded(state: 23)
  var instants: [Int64] = [
    0, -1, 1, 999, 1000, -1001, 1_700_000_000_123, 1_800_000_000_000, 1_800_000_000_001, 1_761_300_000_007,
    253_402_300_799_999, -30_610_224_000_000, -12_219_292_800_000, 951_782_400_000, 1_710_054_000_000,
  ]
  for _ in 0..<150 { instants.append(Int64(random.next(1 << 30)) * 3_000 + Int64(random.next(1000))) }
  for zone in [8 * 3600, 0, -(5 * 3600 + 30 * 60), 5 * 3600 + 45 * 60, -10 * 3600] {
    NoteMarkdownFiles.zone = TimeZone(secondsFromGMT: zone)!
    for instant in instants {
      add("iso", ["ms": .int(instant), "offset": .int(Int64(zone))], .string(NoteMarkdownFiles.iso(date(instant))))
    }
  }
  NoteMarkdownFiles.zone = TimeZone(secondsFromGMT: 8 * 3600)!
  var numbers: [Double] = [
    0, -0.0, 1, -1, 0.5, 0.1, -0.1 + 1e-9, 1e15, 1e16, 1e17, 9_007_199_254_740_992, 9_007_199_254_740_994,
    9.5e15, -9.5e15, 1e-4, 0.000099999, 1e-5, 0.0001234, 5e-324, 1.7976931348623157e308, 100, 1.5e300,
    2.0 / 3.0, 12_345_678.9, 123.456, 1e21, 1e100, 0.00010000000000000002, 3.0e-5, 4096, 1e22, 1e23,
    .infinity, -.infinity, .nan,
  ]
  for _ in 0..<200 {
    let mantissa = Double(random.next(1 << 30)) / Double(1 << 30) + 1
    let exponent = random.next(80) - 40
    let sign: Double = random.chance(3) ? -1 : 1
    numbers.append(sign * mantissa * pow(2, Double(exponent)))
  }
  for _ in 0..<60 { numbers.append(Double(random.next(1 << 20)) / Double(1 << random.next(40))) }
  for _ in 0..<60 {
    numbers.append(Double(bitPattern: UInt64(random.next(1 << 31)) << 33 | UInt64(random.next(1 << 31))))
  }
  for value in numbers {
    add("number", ["bits": .string(String(value.bitPattern))], .string("\(value)"))
  }
  for value in tricky + ["/", "\\/", "\u{0000}", "\u{001F}", "😀", "\u{FFFF}", "#C2DFF8", "a\"b"] {
    add("jsonString", ["value": .string(value)], .string(NoteMarkdownFiles.jsonString(value)))
  }
  for raw in [
    #""a\/b""#, #""\u00e9""#, #""\ud83d\ude00""#, #""\ud800""#, #""\udc00x""#, #"" x""#, #""a"  "#, "\"a\"\r",
    "\"tab\tin\"", "'a'", #""\x""#, "\u{FEFF}\"bom\"", "\"a\" \"b\"", "123", "null", "\"\"", "\"\\u0000\"",
    "\"unterminated", "\"中文\"", "\"\\n\\r\\t\\b\\f\"", "  \"lead\"", "\"a\"\n", "[\"a\"]", "\"\u{007F}\"",
    "\"\\uD83D\\uDE00\"", "\"\\u00\"", "\"a\u{2028}b\"",
  ] {
    add("jsonDecode", ["raw": .string(raw)], opt(NoteMarkdownFiles.jsonDecode(raw).map(J.string)))
  }
}

// MARK: 便签文件

func noteFiles() {
  var random = Seeded(state: 37)
  var notes: [Note] = []
  var tricky1 = Note(
    id: "6F0C0B4E-3E3A-4C4C-9E2B-1A2B3C4D5E6F",
    body: "\n\n---\n第一行 \r\n---\u{2028}☐ 待办\n![image](kitty-note-image://6F0C0B4E-3E3A-4C4C-9E2B-1A2B3C4D5E6F.png)\n\n",
    createdAt: date(1_700_000_000_123), modifiedAt: at(10_000), revision: 42, isArchived: true,
    isPinned: true, order: -0.1 + 1e-9, deletedAt: at(30_000), stateChangedAt: at(30_000),
    orderChangedAt: at(10_000), clock: ["A": 3, "B-2": 7])
  tricky1.title = "  "
  tricky1.color = Note.custom(rgb: 0xC2DFF8)
  notes.append(tricky1)
  var plain = Note(
    id: "0F8FAD5B-D9CB-469F-A165-70867728950E", body: "一行", createdAt: at(0), modifiedAt: at(10_000),
    revision: 1, stateChangedAt: at(10_000), orderChangedAt: at(10_000), clock: ["A": 1])
  plain.title = "标题：带「引号」\"和\\反斜杠\"\n换行 / 斜杠"
  notes.append(plain)
  notes.append(
    Note(id: "7C9E6679-7425-40DE-944B-E07FC1F90AE7", createdAt: at(0), modifiedAt: at(0)))
  var huge = Note(
    id: "A1B2C3D4-0000-4000-8000-000000000001", body: "x", createdAt: date(1 << 53),
    modifiedAt: date(-(1 << 53)), revision: Note.maxRevision + 5, order: 1e300, clock: [:])
  huge.revision = -3
  notes.append(huge)
  for index in 0..<40 {
    notes.append(
      version(id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index))!.uuidString,
        content: index + 3, random: &random))
  }
  for note in notes {
    let text = NoteSyncFolder.text(of: note)
    add("noteText", ["note": j(note)], .string(text))
    let parsed = NoteSyncFolder.parse(text, fileID: note.id)
    add(
      "noteParse", ["text": .string(text), "fileID": .string(note.id)],
      opt(parsed.map { .object(["note": j($0.note), "hash": .string($0.hash)]) }))
  }
  // 被动过的、认不出的
  let good = NoteSyncFolder.text(of: plain)
  var tampered: [String] = [
    good + "\n", good.replacingOccurrences(of: "一行", with: "一"), "随便什么", "",
    good.replacingOccurrences(of: "---\nkitty-note", with: "---\ntitle: 没引号\nkitty-note"),
    good.replacingOccurrences(of: "color: 0", with: "color: 9"),
    good.replacingOccurrences(of: "color: 0", with: "color: -1"),
    good.replacingOccurrences(of: "sync-clock:", with: "sync-deleted: 坏\nsync-clock:"),
    good.replacingOccurrences(of: "pinned: false", with: "pinned: false\npinned: true"),
    good.replacingOccurrences(of: "pinned: false", with: "pinned: 否"),
    good.replacingOccurrences(of: "pinned: false", with: "pinned: False"),
    good.replacingOccurrences(of: "pinned: false", with: "pinned:false"),
    good.replacingOccurrences(of: "pinned: false", with: "\tpinned \t:  false\t"),
    good.replacingOccurrences(of: "pinned: false", with: "pinned\u{0301}: false"),
    good.replacingOccurrences(of: "pinned: false", with: "pinned:\u{0301} false"),
    good.replacingOccurrences(of: "pinned: false", with: "pinned: false\nunknown-key: 随便"),
    good.replacingOccurrences(of: "pinned: false", with: "pinned: false\n没有冒号"),
    good.replacingOccurrences(of: "\n", with: "\r\n"),
    good.replacingOccurrences(of: "pinned: false\n", with: "pinned: false\r\n"),
    good.replacingOccurrences(of: "revision: 1", with: "revision: +1"),
    good.replacingOccurrences(of: "revision: 1", with: "revision: 1.0"),
    good.replacingOccurrences(of: "revision: 1", with: "revision: 99999999999"),
    good.replacingOccurrences(of: "revision: 1", with: "revision: -7"),
    good.replacingOccurrences(of: "order: 0.0", with: "order: 1e-3"),
    good.replacingOccurrences(of: "order: 0.0", with: "order: .5"),
    good.replacingOccurrences(of: "order: 0.0", with: "order: inf"),
    good.replacingOccurrences(of: "order: 0.0", with: "order: nan"),
    good.replacingOccurrences(of: "order: 0.0", with: "order: 1e400"),
    good.replacingOccurrences(of: "order: 0.0", with: "order: 0,5"),
    good.replacingOccurrences(of: "sync-created: ", with: "sync-created: 9"),
    good.replacingOccurrences(of: "sync-created: ", with: "sync-created: 99999999"),
    good.replacingOccurrences(of: "sync-created: ", with: "sync-created: -99999999"),
    good.replacingOccurrences(of: "sync-created: ", with: "sync-created:  "),
    good.replacingOccurrences(of: "sync-clock: A:1", with: "sync-clock: A:1,坏:2,B:0"),
    good.replacingOccurrences(of: "sync-clock: A:1", with: "sync-clock: "),
    good.replacingOccurrences(
      of: "sync-clock: A:1", with: "sync-clock: " + (0..<1100).map { "D\($0):1" }.joined(separator: ",")),
    good.replacingOccurrences(
      of: "sync-clock: A:1", with: "sync-clock: " + (0..<1024).map { "D\($0):1" }.joined(separator: ",")),
    good.replacingOccurrences(of: "kitty-note: ", with: "kitty-note: x"),
    good.replacingOccurrences(of: "kitty-note: 0F8FAD5B", with: "kitty-note: 0f8fad5b"),
    good.replacingOccurrences(of: "---\n", with: "---\n\n"),
    good.replacingOccurrences(of: "title: ", with: "title: \u{FEFF}"),
    good.replacingOccurrences(of: "title: ", with: "title:"),
    "---\nkitty-note: 0F8FAD5B-D9CB-469F-A165-70867728950E\nsync-clock: A:1\n",
    "---\r\n" + good.dropFirst(4),
    "---\n" + (0..<45).map { "k\($0): 1\n" }.joined() + "---\n",
  ]
  // 头很长（40 行里没收尾）、40 行正好收尾
  let lines = good.components(separatedBy: "\n")
  tampered.append(
    lines[0] + "\n" + (0..<22).map { "pad\($0): 1" }.joined(separator: "\n") + "\n"
      + lines[1...].joined(separator: "\n"))
  tampered.append(
    lines[0] + "\n" + (0..<25).map { "pad\($0): 1" }.joined(separator: "\n") + "\n"
      + lines[1...].joined(separator: "\n"))
  // 带了 tint、tint 写坏了
  let tinted = NoteSyncFolder.text(of: tricky1)
  tampered.append(tinted.replacingOccurrences(of: "tint: \"#C2DFF8\"", with: "tint: \"#c2dff8\""))
  tampered.append(tinted.replacingOccurrences(of: "tint: \"#C2DFF8\"", with: "tint: #C2DFF8"))
  tampered.append(tinted.replacingOccurrences(of: "tint: \"#C2DFF8\"", with: "tint: \"#C2DFF\""))
  tampered.append(tinted.replacingOccurrences(of: "sync-deleted: ", with: "sync-deleted: +"))
  for text in tampered {
    for fileID in ["0F8FAD5B-D9CB-469F-A165-70867728950E", "6F0C0B4E-3E3A-4C4C-9E2B-1A2B3C4D5E6F"] {
      let parsed = NoteSyncFolder.parse(text, fileID: fileID)
      add(
        "noteParse", ["text": .string(text), "fileID": .string(fileID)],
        opt(parsed.map { .object(["note": j($0.note), "hash": .string($0.hash)]) }))
    }
  }
  for text in [good, tinted, "---\nsync-clock: A:1", "x---\n\nsync-clock:", "---\n" + String(repeating: "字", count: 5000) + "\nsync-clock:", "---\r\nsync-clock:", "---\nkitty-note: x\r\nsync-clock: 1", "---\n\nsync-clock:"] {
    add("isSyncFile", ["text": .string(text)], .bool(NoteSyncFolder.isSyncFile(text)))
  }
  let id = "0F8FAD5B-D9CB-469F-A165-70867728950E"
  for name in [
    "\(id).md", "\(id.lowercased()).md", "\(id).txt", "笔记.md", "\(id).MD", "\(id).md.icloud", ".md", "\(id)\u{0301}.md",
    " \(id).md", "{\(id)}.md", "0F8FAD5BD9CB469FA16570867728950E.md",
  ] {
    add("noteID", ["name": .string(name)], opt(NoteSyncFolder.noteID(ofFileNamed: name).map(J.string)))
  }
  for name in [
    "\(id).png", "\(id.lowercased()).jpg", "\(id).PNG", "\(id).png.partial", "\(id)", "\(id).", "\(id).abcdefghijk",
    "\(id).abcdefghij", "\(id).h264", ".\(id).png", "不是图片.txt", "\(id).p\u{0301}ng", "\(id).png\u{0301}",
  ] {
    add("imageID", ["name": .string(name)], opt(NoteImageStore.identifier(ofFileNamed: name).map { .string($0.uuidString) }))
  }
}

// MARK: 墓碑文件、标记、图片的账

func tombstoneFiles() {
  let a = "0F8FAD5B-D9CB-469F-A165-70867728950E"
  let b = "7C9E6679-7425-40DE-944B-E07FC1F90AE7"
  let sets: [[String: NoteSync.Tombstone]] = [
    [:], [a: NoteSync.Tombstone(clock: ["A": 2, "B": 1], state: at(5_000))],
    [
      b: NoteSync.Tombstone(clock: [:], state: date(-5)), a: NoteSync.Tombstone(clock: ["X-1": 9], state: date(0)),
      "09AB0000-0000-0000-0000-000000000000": NoteSync.Tombstone(clock: ["A": 1], state: date(1 << 53)),
    ],
  ]
  for set in sets {
    add("erasedData", ["tombstones": j(set)], .string(String(decoding: NoteSyncFolder.data(of: set), as: UTF8.self)))
  }
  for raw in [
    String(decoding: NoteSyncFolder.data(of: sets[2]), as: UTF8.self), "坏了", #"{"format": 99, "erased": {}}"#,
    #"{"format": 1, "erased": {"不是编号": {"clock": "A:1", "state": 5}}}"#,
    """
    {"format": 1, "erased": {"\(a)": {"clock": "A:2", "state": 5}, "\(a.lowercased())": {"clock": "B:3", "state": 9}}}
    """,
    #"{"format": 1.0, "erased": {}}"#, #"{"format": 1e0, "erased": {}}"#, #"{"format": -3, "erased": {}}"#,
    #"{"format": 1, "erased": null}"#, #"{"format": 1}"#, #"{"erased": {}}"#, #"{"format": true, "erased": {}}"#,
    #"[1]"#, #"{"format": 1, "erased": {}}x"#, " {\"format\": 1, \"erased\": {}} ",
    #"{"format": 1, "erased": {}, "format": 2}"#,
    "{\"format\": 1, \"erased\": {\"\(a)\": {\"clock\": \"A:1\", \"state\": 5}, \"\(a)\": {\"clock\": \"B:1\", \"state\": 7}}}",
    "{\"format\": 1, \"erased\": {\"\(a)\": {\"clock\": \"A:1\", \"state\": 1.0}}}",
    "{\"format\": 1, \"erased\": {\"\(a)\": {\"clock\": \"A:1\", \"state\": 1.5}}}",
    "{\"format\": 1, \"erased\": {\"\(a)\": {\"clock\": \"A:1\", \"state\": 9223372036854775807}}}",
    "{\"format\": 1, \"erased\": {\"\(a)\": {\"clock\": \"A:1\", \"state\": 9223372036854775808}}}",
    "{\"format\": 1, \"erased\": {\"\(a)\": {\"clock\": \"A:1\", \"state\": -9223372036854775808}}}",
    "{\"format\": 1, \"erased\": {\"\(a)\": {\"clock\": \"A:1\", \"state\": 1e3}}}",
    "{\"format\": 1, \"erased\": {\"\(a)\": {\"clock\": \"A:1\", \"state\": 9.2233720368547758e18}}}",
    "{\"format\": 1, \"erased\": {\"\(a)\": {\"clock\": null, \"state\": 1}}}",
    "{\"format\": 1, \"erased\": {\"\(a)\": {\"clock\": \"A:1\"}}}",
    "{\"format\": 1, \"erased\": {\"\(a)\": {\"clock\": \"A:1\", \"state\": 1, \"more\": [1, {}]}}, \"extra\": 1}",
    "{\"format\": 1, \"erased\": {\"\(a)\": {\"clock\": \"" + String(repeating: "A:1,", count: 17000) + "\", \"state\": 1}}}",
    "{\"format\": 1, \"erased\": {\"\(a)\": {\"clock\": \"坏:1,A:2,A:0\", \"state\": 1}, \"\(b)\": 5}}",
    "\u{FEFF}{\"format\": 1, \"erased\": {}}",
    "{\"format\": 1, \"erased\": {\"\(a)\": {\"clock\": \"\\ud800\", \"state\": 1}}}",
    "{\"format\": 1, \"erased\": {\"\(a)\": {\"clock\": \"A:1\", \"state\": 1}}, // 注释\n}",
    "{\"format\": 1, \"erased\": {\"\(a)\": {\"clock\": \"A:1\", \"state\": 1},}}",
    "{\"format\": 1, \"erased\": {\"\(a)\": {\"clock\": \"A:1\", \"state\": 99999999999999999}}}",
  ] {
    add("erasedRead", ["raw": .string(raw)], j(NoteSyncFolder.tombstones(from: Data(raw.utf8))))
  }
  for raw in [
    #"{"kind": "kitty-notes-sync", "format": 1, "library": "L"}"#, #"{"format": 1, "library": "L"}"#,
    #"{"kind": "别的", "format": 2, "library": "L"}"#, #"{"kind": "kitty-notes-sync", "format": 1}"#,
    #"{"kind": "kitty-notes-sync", "format": 1.0, "library": "L", "x": 1}"#, "坏了",
    #"{"kind": 1, "format": 1, "library": "L"}"#, #"{"kind": "kitty-notes-sync","format":1,"library":"L","library":"M"}"#,
    String(decoding: try! NoteSyncFolder.encoder.encode(NoteSyncFolder.Marker(library: "3F9A")), as: UTF8.self),
  ] {
    let marker = try? JSONDecoder().decode(NoteSyncFolder.Marker.self, from: Data(raw.utf8))
    add(
      "markerRead", ["raw": .string(raw)],
      opt(marker.map { .object(["format": .int(Int64($0.format)), "library": .string($0.library)]) }))
  }
  for ledger in [
    [:], ["\(a).png": at(0)], ["\(b).jpg": date(-1), "\(a).png": at(86_400_000), "z/斜杠.png": date(7)],
  ] as [[String: Date]] {
    add("ledgerText", ["ledger": j(ledger)], .string(NoteSyncFolder.ledgerText(ledger)))
  }
  for text in [
    nil, "乱写的", "{}", "{\"a.png\": 5}", "{\"a.png\": 5.0, \"b.png\": 99999999999999999}", "{\"a.png\": \"5\"}",
    "[1]", "{\"a.png\": 5, \"a.png\": 6}", NoteSyncFolder.ledgerText(["\(a).png": at(0)]),
  ] as [String?] {
    add(
      "ledgerRead", ["text": opt(text.map(J.string))],
      j(NoteSyncFolder.ledger(fromText: text)))
  }
  for (trashing, alive) in [(21, 1000), (20, 1000), (4, 5), (5, 10), (6, 20), (7, 20), (0, 0), (5, 16), (5, 17), (21, 0)] {
    add(
      "brakes", ["trashing": .int(Int64(trashing)), "alive": .int(Int64(alive))],
      .bool(NoteSyncFolder.brakes(trashing: trashing, alive: alive)))
  }
}

// MARK: 合一条

func fixed(
  _ body: String, at seconds: Int64, clock: [String: Int], id: String = "N", state: Int64? = nil,
  deleted: Int64? = nil, pinned: Bool = false, archived: Bool = false, revision: Int = 1
) -> Note {
  Note(
    id: id, body: body, createdAt: at(0), modifiedAt: at(seconds * 1000), revision: revision,
    isArchived: archived, isPinned: pinned, deletedAt: deleted.map { at($0 * 1000) },
    stateChangedAt: at((state ?? seconds) * 1000), orderChangedAt: at((state ?? seconds) * 1000),
    clock: clock)
}

func addMerge(
  _ local: Note?, _ remotes: [Note], _ tombstone: NoteSync.Tombstone?, now: Date, hashes: [String?] = []
) {
  let merge = NoteSync.merge(local: local, remotes: remotes, tombstone: tombstone, now: now, hashes: hashes)
  add(
    "merge",
    [
      "local": opt(local.map(j)), "remotes": j(remotes), "tombstone": opt(tombstone.map(j)),
      "now": .int(ms(now)), "hashes": .array(hashes.map { opt($0.map(J.string)) }),
    ], j(merge))
}

func merges() {
  let now = at(100_000)
  addMerge(fixed("本机", at: 10, clock: ["A": 1]), [fixed("对面改的", at: 20, clock: ["A": 1, "B": 1])], nil, now: now)
  addMerge(
    fixed("本机新的", at: 30, clock: ["A": 3, "B": 1]), [fixed("对面旧的", at: 50, clock: ["A": 1, "B": 1], state: 20)],
    nil, now: now)
  let mine = fixed("A 改的", at: 20, clock: ["A": 2, "B": 1])
  let theirs = fixed("B 改的", at: 30, clock: ["A": 1, "B": 2])
  addMerge(mine, [theirs], nil, now: now)
  addMerge(theirs, [mine], nil, now: at(200_000))
  addMerge(fixed("A 的", at: 500, clock: ["A": 1]), [fixed("B 在 A 之上改的", at: 100, clock: ["A": 1, "B": 1])], nil, now: now)
  addMerge(fixed("0.5.0 里改过", at: 40, clock: [:]), [fixed("另一台的", at: 30, clock: [:])], nil, now: now)
  addMerge(fixed("一样的字", at: 40, clock: [:]), [fixed("一样的字", at: 10, clock: ["B": 1])], nil, now: now)
  let x = fixed("X", at: 10, clock: ["A": 1])
  let y = fixed("Y", at: 20, clock: ["B": 1])
  let z = fixed("Z", at: 30, clock: ["A": 2])
  for order in [[x, y, z], [z, y, x], [y, x, z], [y, z, x]] {
    addMerge(order[0], Array(order.dropFirst()), nil, now: now)
  }
  addMerge(fixed("本机", at: 99, clock: ["A": 2]), [fixed("钟快了的那台", at: 99_999, clock: ["B": 1])], nil, now: now)
  addMerge(
    fixed("本机改的字", at: 50, clock: ["A": 2, "B": 1], state: 10),
    [fixed("旧字", at: 5, clock: ["A": 1, "B": 1], state: 40, pinned: true)], nil, now: now)
  let edited = fixed("删之后又改了", at: 60, clock: ["A": 2], state: 10)
  let deleted = fixed("原来的", at: 5, clock: ["A": 1], state: 50, deleted: 50)
  addMerge(edited, [deleted], nil, now: now)
  addMerge(deleted, [edited], nil, now: now)
  let tombstone = NoteSync.Tombstone(clock: ["A": 1], state: at(30_000))
  let trashed = fixed("在最近删除里", at: 10, clock: ["A": 1], state: 20, deleted: 20)
  let stale = fixed("旧文件夹里没删的那份", at: 10, clock: ["A": 1], state: 5)
  let restored = fixed("对面放回了", at: 10, clock: ["A": 1], state: 40)
  addMerge(trashed, [], tombstone, now: now)
  addMerge(stale, [], tombstone, now: now)
  addMerge(nil, [stale], tombstone, now: now)
  addMerge(fixed("删了之后又改", at: 40, clock: ["A": 2], state: 20, deleted: 20), [], tombstone, now: now)
  addMerge(nil, [restored], tombstone, now: now)
  addMerge(trashed, [restored], tombstone, now: now)
  addMerge(
    nil, [fixed("对面删前改过的", at: 25, clock: ["A": 3, "B": 1], state: 25)],
    NoteSync.Tombstone(clock: ["A": 5], state: at(30_000)), now: now)
  var moved = fixed("一条", at: 5, clock: ["A": 1], state: 5)
  moved.order = 3
  moved.orderChangedAt = at(60_000)
  addMerge(moved, [fixed("一条", at: 5, clock: ["A": 1], state: 50, deleted: 50)], nil, now: now)
  addMerge(nil, [fixed("新来的", at: 10, clock: ["B": 1], revision: 7)], nil, now: now)
  addMerge(nil, [], nil, now: now)
  addMerge(nil, [], tombstone, now: now)
  // 给了内容哈希的（一轮里读文件时核对过的）：照给的用，没给的现算
  addMerge(
    mine, [theirs, fixed("第三版", at: 40, clock: ["C": 1])], nil, now: now,
    hashes: [NoteSync.contentHash(theirs)])
  addMerge(mine, [theirs], nil, now: now, hashes: ["00000000000000000000000000000000"])
  addMerge(mine, [theirs], nil, now: now, hashes: [nil])

  // 随机的：几版的钟、状态、顺序、墓碑随便来
  var random = Seeded(state: 41)
  for _ in 0..<120 {
    let id = random.pick(["N", "6F0C0B4E-3E3A-4C4C-9E2B-1A2B3C4D5E6F"])
    let local = random.chance(5) ? nil : version(id: id, content: random.next(6), random: &random)
    let remotes = (0..<random.next(4)).map { _ in version(id: id, content: random.next(6), random: &random) }
    let tombstone = random.chance(3) ? randomTombstone(&random) : nil
    let hashes: [String?] = random.chance(3) ? remotes.map { random.chance(2) ? NoteSync.contentHash($0) : nil } : []
    addMerge(local, remotes, tombstone, now: at(Int64(random.next(20)) * 1000), hashes: hashes)
  }
}

// MARK: 一轮、写出去、退回去、共用图片

func addRound(
  _ local: [Note], _ erased: [String: NoteSync.Tombstone], _ folder: NoteSyncFolder.Folder,
  library: String = "L", now: Date
) {
  let result = NoteSyncFolder.round(local: local, erased: erased, folder: folder, library: library, now: now)
  // 和字典的遍历顺序无关：换一种插入顺序再合一遍，必须一样
  var shuffled = NoteSyncFolder.Folder(marker: folder.marker, images: folder.images)
  for key in folder.devices.keys.sorted().reversed() { shuffled.devices[key] = folder.devices[key] }
  precondition(
    NoteSyncFolder.round(local: Array(local.reversed()), erased: erased, folder: shuffled, library: library, now: now)
      == result)
  let output: J
  switch result {
  case .failure(let stop):
    let kind: String
    var device: String?
    switch stop {
    case .notTheFolder: kind = "notTheFolder"
    case .newerFormat: kind = "newerFormat"
    case .unreadableTombstones(let name):
      kind = "unreadableTombstones"
      device = name
    }
    output = .object(["stop": .object(["kind": .string(kind), "device": opt(device.map(J.string))])])
  case .success(let round):
    output = .object([
      "stop": .null, "merges": .object(round.merges.mapValues(j)), "tombstones": j(round.tombstones),
      "trashing": .int(Int64(round.trashing)), "alive": .int(Int64(round.alive)), "skipped": j(round.skipped),
      "brakes": .bool(round.brakes),
    ])
  }
  add(
    "round",
    [
      "local": j(local), "erased": j(erased), "folder": j(folder), "library": .string(library),
      "now": .int(ms(now)),
    ], output)
}

func noteID(_ index: Int) -> String {
  UUID(uuidString: String(format: "10000000-0000-4000-8000-%012d", index))!.uuidString
}

func rounds() {
  let now = at(100_000)
  let marker = NoteSyncFolder.Marker(library: "L")
  // 停：没标记、编号不对、格式更新、墓碑读不出来、墓碑更新
  let local = [fixed("本机", at: 10, clock: ["A": 1], id: noteID(0))]
  addRound(local, [:], NoteSyncFolder.Folder(), now: now)
  addRound(local, [:], NoteSyncFolder.Folder(marker: NoteSyncFolder.Marker(library: "别的")), now: now)
  addRound(local, [:], NoteSyncFolder.Folder(marker: NoteSyncFolder.Marker(format: 2, library: "L")), now: now)
  addRound(local, [:], NoteSyncFolder.Folder(marker: NoteSyncFolder.Marker(format: 0, library: "L")), now: now)
  addRound(
    local, [:],
    NoteSyncFolder.Folder(
      marker: marker,
      devices: ["C": NoteSyncFolder.Device(erased: .unreadable), "B": NoteSyncFolder.Device(erased: .newer)]),
    now: now)
  addRound(
    local, [:],
    NoteSyncFolder.Folder(
      marker: marker,
      devices: ["B": NoteSyncFolder.Device(erased: .unreadable), "C": NoteSyncFolder.Device(erased: .newer)]),
    now: now)
  // mac 单测里那两个
  let same = fixed("没变的", at: 10, clock: ["A": 1], id: noteID(1))
  let changed = fixed("本机旧的", at: 10, clock: ["A": 1], id: noteID(2))
  var theirs = changed
  theirs.body = "对面改的"
  theirs.clock = ["A": 1, "B": 1]
  theirs.modifiedAt = at(20_000)
  let incoming = fixed("新来的", at: 10, clock: ["B": 1], id: noteID(3))
  let blocked = fixed("这条那边没下载完", at: 10, clock: ["A": 1], id: noteID(4))
  let orphan = fixed("自己文件夹里有、本机没有", at: 10, clock: ["A": 2], id: noteID(5))
  addRound(
    [same, changed, blocked], [:],
    NoteSyncFolder.Folder(
      marker: marker,
      devices: [
        "A": NoteSyncFolder.Device(notes: [same.id: same, orphan.id: orphan]),
        "B": NoteSyncFolder.Device(
          notes: [same.id: same, changed.id: theirs, incoming.id: incoming], unreadable: [blocked.id]),
      ]), now: now)
  let deletedThere = fixed("对面删了", at: 10, clock: ["A": 1], id: noteID(6))
  var gone = deletedThere
  gone.deletedAt = at(50_000)
  gone.stateChangedAt = at(50_000)
  let buried = fixed("对面永久删了", at: 10, clock: ["A": 1], id: noteID(7))
  let alreadyTrashed = fixed("本机早就删了", at: 10, clock: ["A": 1], id: noteID(8), deleted: 5)
  var theirsToo = alreadyTrashed
  theirsToo.deletedAt = at(60_000)
  theirsToo.stateChangedAt = at(60_000)
  addRound(
    [deletedThere, buried, alreadyTrashed], [:],
    NoteSyncFolder.Folder(
      marker: marker,
      devices: [
        "B": NoteSyncFolder.Device(
          notes: [deletedThere.id: gone, alreadyTrashed.id: theirsToo],
          erased: .read([buried.id: NoteSync.Tombstone(clock: ["A": 1], state: at(70_000))]))
      ]), now: now)
  // 刹车：对面删了 6 条（本机 10 条）
  let many = (0..<10).map { fixed("第 \($0) 条", at: 10, clock: ["A": 1], id: noteID(20 + $0)) }
  var deletedMany: [String: Note] = [:]
  for note in many.prefix(6) {
    var copy = note
    copy.deletedAt = at(50_000)
    copy.stateChangedAt = at(50_000)
    deletedMany[note.id] = copy
  }
  addRound(many, [:], NoteSyncFolder.Folder(marker: marker, devices: ["B": NoteSyncFolder.Device(notes: deletedMany)]), now: now)
  // 冲突另存出来的那条本机已经有了 / 有墓碑：不算新的
  let mineV = fixed("A 改的", at: 20, clock: ["A": 2, "B": 1], id: noteID(40))
  let theirsV = fixed("B 改的", at: 30, clock: ["A": 1, "B": 2], id: noteID(40))
  let merged = NoteSync.merge(local: mineV, remotes: [theirsV], tombstone: nil, now: now)
  if let winner = merged.note, let copy = merged.copies.first {
    addRound(
      [winner, copy], [:],
      NoteSyncFolder.Folder(marker: marker, devices: ["B": NoteSyncFolder.Device(notes: [theirsV.id: theirsV])]),
      now: now)
    addRound(
      [winner], [copy.id: NoteSync.Tombstone(clock: [:], state: now)],
      NoteSyncFolder.Folder(marker: marker, devices: ["B": NoteSyncFolder.Device(notes: [mineV.id: mineV])]), now: now)
  }

  // 随机的几台：内容由编号定（见 version），状态、钟随机
  var random = Seeded(state: 53)
  for _ in 0..<40 {
    let ids = (0..<(2 + random.next(6))).map { noteID(100 + $0) }
    var local: [Note] = []
    for id in ids where !random.chance(4) {
      local.append(version(id: id, content: random.next(5), random: &random))
    }
    var erased: [String: NoteSync.Tombstone] = [:]
    for id in ids where random.chance(6) { erased[id] = randomTombstone(&random) }
    var folder = NoteSyncFolder.Folder(marker: random.chance(12) ? nil : marker)
    for device in ["A", "B", "C"] where !random.chance(4) {
      var other = NoteSyncFolder.Device(name: device, epoch: random.next(3))
      for id in ids where random.chance(2) {
        if random.chance(8) {
          other.unreadable.insert(id)
        } else {
          let note = version(id: id, content: random.next(5), random: &random)
          other.notes[id] = note
          if random.chance(2) { other.hashes[id] = NoteSync.contentHash(note) }
        }
      }
      if random.chance(15) {
        other.erased = .unreadable
      } else if random.chance(3) {
        var theirs: [String: NoteSync.Tombstone] = [:]
        for id in ids where random.chance(3) { theirs[id] = randomTombstone(&random) }
        other.erased = .read(theirs)
      }
      folder.devices[device] = other
    }
    addRound(local, erased, folder, now: at(Int64(random.next(20)) * 1000))
  }
}

func addPublish(
  _ local: [Note], _ erased: [String: NoteSync.Tombstone], own: NoteSyncFolder.Device?,
  localImages: Set<String>, folderImages: Set<String>
) {
  let plan = NoteSyncFolder.publish(
    local: local, erased: erased, own: own, localImages: localImages, folderImages: folderImages)
  add(
    "publish",
    [
      "local": j(local), "erased": j(erased), "own": opt(own.map(j)), "localImages": j(localImages),
      "folderImages": j(folderImages),
    ],
    .object([
      "writes": .array(plan.writes.map { .string($0.id) }), "deletes": .array(plan.deletes.map(J.string)),
      "erased": opt(plan.erased.map(j)), "uploads": .array(plan.uploads.map(j)),
      "downloads": .array(plan.downloads.map(j)), "isEmpty": .bool(plan.isEmpty),
      "touchesNotes": .bool(plan.touchesNotes),
    ]))
}

func publishing() {
  let image = NoteImages.Image(id: UUID(uuidString: "6F0C0B4E-3E3A-4C4C-9E2B-1A2B3C4D5E6F")!, ext: "png", width: 240)
  let other = NoteImages.Image(id: UUID(uuidString: "7C9E6679-7425-40DE-944B-E07FC1F90AE7")!, ext: "jpg", width: nil)
  let both = NoteImages.Image(id: UUID(uuidString: "0F8FAD5B-D9CB-469F-A165-70867728950E")!, ext: "heic", width: 120)
  let synced = fixed("没变的", at: 10, clock: ["A": 1], id: noteID(1), revision: 3)
  let edited = fixed("改过的", at: 10, clock: ["A": 1], id: noteID(2), revision: 5)
  var stale = edited
  stale.revision = 4
  let missing = fixed("文件被人删了", at: 10, clock: ["A": 1], id: noteID(3), revision: 2)
  let broken = fixed("自己那份写坏了", at: 10, clock: ["A": 1], id: noteID(4), revision: 2)
  let pictured = fixed(
    "图 \(NoteImages.token(image)) 和 \(NoteImages.token(other)) 还有 \(NoteImages.token(both))\(NoteImages.token(image))",
    at: 10, clock: ["A": 1], id: noteID(5), deleted: 3)
  let goneID = noteID(6)
  let strayID = noteID(7)
  let own = NoteSyncFolder.Device(
    notes: [synced.id: synced, edited.id: stale, goneID: fixed("永久删了的", at: 10, clock: ["A": 1], id: goneID)],
    unreadable: [broken.id, strayID])
  let tombstones = [goneID: NoteSync.Tombstone(clock: ["A": 1], state: at(9_000))]
  addPublish(
    [synced, edited, missing, broken, pictured], tombstones, own: own,
    localImages: ["\(image.id.uuidString).png", "\(both.id.uuidString).heic"],
    folderImages: ["\(other.id.uuidString).jpg", "\(both.id.uuidString).heic"])
  addPublish([synced], [:], own: NoteSyncFolder.Device(notes: [synced.id: synced]), localImages: [], folderImages: [])
  addPublish([synced], [:], own: nil, localImages: [], folderImages: [])
  addPublish([], [:], own: NoteSyncFolder.Device(erased: .unreadable), localImages: [], folderImages: [])
  addPublish([], [:], own: NoteSyncFolder.Device(erased: .newer), localImages: [], folderImages: [])
  addPublish(
    [synced], tombstones, own: NoteSyncFolder.Device(notes: [synced.id: synced], erased: .read(tombstones)),
    localImages: ["x.png"], folderImages: ["y.png"])
  addPublish(
    [synced], tombstones,
    own: NoteSyncFolder.Device(
      notes: [synced.id: synced],
      erased: .read([goneID: NoteSync.Tombstone(clock: ["A": 1, "B": 1], state: at(9_000))])),
    localImages: [], folderImages: [])

  // 退回去了
  let current = fixed("现在的", at: 10, clock: ["A": 3, "B": 2], id: noteID(1))
  var ahead = current
  ahead.clock = ["A": 5, "B": 2]
  var otherAhead = current
  otherAhead.clock = ["A": 3, "B": 9]
  let vanished = fixed("后来建的", at: 10, clock: ["A": 1], id: noteID(2))
  let marker = NoteSyncFolder.Marker(library: "L")
  for devices in [
    ["A": NoteSyncFolder.Device(notes: [current.id: current])],
    ["A": NoteSyncFolder.Device(notes: [current.id: otherAhead])],
    ["A": NoteSyncFolder.Device(notes: [current.id: ahead])],
    ["B": NoteSyncFolder.Device(notes: [current.id: ahead, vanished.id: vanished])],
    ["A": NoteSyncFolder.Device(notes: [vanished.id: vanished])],
  ] {
    let folder = NoteSyncFolder.Folder(marker: marker, devices: devices)
    add(
      "regressed", ["local": j([current]), "folder": j(folder), "device": .string("A")],
      j(NoteSyncFolder.regressed(local: [current], folder: folder, device: "A")))
  }

  // 共用图片：同 mac 单测，加几张随机的
  let (gone, kept, used) = (image.id, other.id, both.id)
  let names: Set<String> = Set([gone, kept, used].map { "\($0.uuidString).png" }).union(["不是图片.txt"])
  func addPurge(_ ledger: [String: Date], _ now: Int64, _ readable: Bool, folder: Set<String> = names) {
    let purge = NoteSyncFolder.imagePurge(
      folderImages: folder, referenced: [used], localImages: [kept], ledger: ledger, readable: readable, now: at(now))
    add(
      "imagePurge",
      [
        "folderImages": j(folder), "referenced": .array([.string(used.uuidString)]),
        "localImages": .array([.string(kept.uuidString)]), "ledger": j(ledger), "readable": .bool(readable),
        "now": .int(ms(at(now))),
      ],
      .object([
        "deletes": .array(purge.deletes.map(J.string)), "ledger": j(purge.ledger),
        "due": opt(purge.due.map { .int(ms($0)) }),
      ]))
  }
  let first = NoteSyncFolder.imagePurge(
    folderImages: names, referenced: [used], localImages: [kept], ledger: [:], readable: true, now: at(0))
  addPurge([:], 0, true)
  addPurge(first.ledger, 86_399_999, true)
  addPurge(first.ledger, 86_400_000, true)
  addPurge(first.ledger, 30 * 86_400_000, true)
  addPurge(first.ledger, 40 * 86_400_000, false)
  addPurge([:], 40 * 86_400_000, false)
  addPurge(first.ledger.merging(["\(used.uuidString).png": at(0), "别的.png": at(5)]) { a, _ in a }, 5, true)
  addPurge(first.ledger, 40 * 86_400_000, true, folder: ["\(kept.uuidString).png"])
}

nonisolated struct Fixture: Encodable {
  var generatedBy: String
  var note: String
  var cases: [Case]
}

@main enum Golden {
  static func main() throws {
    clocksAndHashes()
    headerWriting()
    noteFiles()
    tombstoneFiles()
    merges()
    rounds()
    publishing()
    let pretty = JSONEncoder()
    pretty.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let out = URL(fileURLWithPath: CommandLine.arguments[1])
    try pretty.encode(
      Fixture(
        generatedBy: "windows/tools/notes-sync-golden.swift（编的是 macos 分支的 Notes/*.swift）",
        note: "时间是整数毫秒；orderBits 是 Double 的位；noteText 的时区固定 UTC+8；iso 的 offset 是秒",
        cases: cases)
    ).write(to: out)
    var counts: [String: Int] = [:]
    for item in cases { counts[item.kind, default: 0] += 1 }
    print("\(cases.count) 个样本 → \(out.path)")
    print(counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
  }
}
