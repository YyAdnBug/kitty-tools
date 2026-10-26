// 在 Mac 上生成「和 Mac 互通的同步」（PLAN-v5）要逐字节对上的样本：swift windows/tools/sync-golden.swift <输出文件>
// mac 版的全局同步按「内容的字节」算哈希、比改没改（macos/KittyTools/Storage/SyncRecords.swift）：Windows 编出来的 JSON
// 只要和 Swift 的 JSONEncoder（.sortedKeys + .withoutEscapingSlashes）差一个字节，两边就会互相当成对方改过、来回改个不停。
// 这里用和 mac 一样的结构和编码器设置，把四类内容（片段 / 收藏、收藏夹、生词、网页搜索）、顺序记录、版本钟写法、整份文件
// 和一批容易出错的字符串编出来，连同哈希写进样本；Windows 的单测从 input 自己编一遍，和 json / hash / text 逐字节比。
// 结构和字段名照 mac：ClipboardStore 的 SyncedClip / SyncedGroup、HistoryStore 的 SyncedWord、WebSearchSync 的 Synced、
// SyncRecords 的 Stored、NoteSync.text(of:)。mac 那边改了结构，这里跟着改、重新生成。
import CryptoKit
import Foundation

struct SyncedClip: Codable { var text: String; var favorite: Bool; var snippet: Bool; var note: String?; var group: String? }
struct SyncedGroup: Codable { var name: String; var created: Int64 }
struct SyncedWord: Codable { var source: String; var target: String; var result: String; var service: String; var created: Int64 }
struct SyncedEngine: Codable { var name: String; var keyword: String; var url: String; var fallback: Bool }
struct StoredItem: Codable { var id: String; var clock: String; var modified: Int64; var value: String }
struct StoredGone: Codable { var id: String; var clock: String }
struct Stored: Codable { var format: Int; var kind: String; var records: [StoredItem]; var erased: [StoredGone] }

let encoder: JSONEncoder = {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  return encoder
}()
func json(_ value: some Encodable) -> String { String(decoding: try! encoder.encode(value), as: UTF8.self) }
func hash(_ value: String) -> String {
  SHA256.hash(data: Data(value.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
}
func clockText(_ clock: [String: Int]) -> String {
  clock.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")
}

let tricky = [
  "hello", "", "你好，世界", "emoji 😀👍🏽🇨🇳", "quote \" backslash \\ slash /", "line1\nline2\tTab\rCR",
  "ctrl \u{0001}\u{0008}\u{000C}\u{001F}\u{007F}", "sep \u{2028}\u{2029}", "e\u{0301} vs \u{00E9}",
  "<b>&amp;</b> 'single'", "https://example.com/a?b=1&c=2#x", "\u{FEFF}bom", "tab\t\tend ",
]

struct Case: Encodable {
  var kind: String
  var input: [String: Value]
  var json: String?
  var hash: String?
  var text: String?
}
enum Value: Encodable {
  case s(String), b(Bool), i(Int64), n, list([String]), map([String: Int])
  func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .s(let v): try c.encode(v)
    case .b(let v): try c.encode(v)
    case .i(let v): try c.encode(v)
    case .n: try c.encodeNil()
    case .list(let v): try c.encode(v)
    case .map(let v): try c.encode(v)
    }
  }
}

var cases: [Case] = []
for (index, text) in tricky.enumerated() {
  let note: String? = index % 3 == 0 ? nil : tricky[(index + 4) % tricky.count]
  let group: String? = index % 2 == 0 ? nil : "0F8FAD5B-D9CB-469F-A165-70867728950E"  // 条目里只写收藏夹的编号；"group:" 前缀只在收藏夹那条记录自己的编号上
  let clip = SyncedClip(text: text, favorite: index % 2 == 0, snippet: index % 3 == 1, note: note, group: group)
  let value = json(clip)
  cases.append(Case(kind: "clip", input: [
    "text": .s(text), "favorite": .b(clip.favorite), "snippet": .b(clip.snippet),
    "note": note.map(Value.s) ?? .n, "group": group.map(Value.s) ?? .n,
  ], json: value, hash: hash(value)))
  let word = SyncedWord(source: text, target: index % 2 == 0 ? "en" : "zh-Hans", result: tricky[(index + 2) % tricky.count],
                        service: index % 2 == 0 ? "zhipu" : "ai:1a2b3c4d", created: 1_761_300_000_000 + Int64(index))
  let wordValue = json(word)
  cases.append(Case(kind: "word", input: [
    "source": .s(word.source), "target": .s(word.target), "result": .s(word.result),
    "service": .s(word.service), "created": .i(word.created),
  ], json: wordValue, hash: hash(wordValue)))
}
for (index, name) in ["收藏", "工作 / Work", "emoji 🐱", "\"quoted\""].enumerated() {
  let group = SyncedGroup(name: name, created: 1_761_000_000_000 + Int64(index) * 1000)
  let value = json(group)
  cases.append(Case(kind: "group", input: ["name": .s(name), "created": .i(group.created)], json: value, hash: hash(value)))
}
for engine in [
  SyncedEngine(name: "Google", keyword: "g", url: "https://www.google.com/search?q={query}", fallback: false),
  SyncedEngine(name: "百度", keyword: "bd", url: "https://www.baidu.com/s?wd={query}", fallback: true),
  SyncedEngine(name: "地图", keyword: "map", url: "maps://?q={query}&t=m", fallback: false),
] {
  let value = json(engine)
  cases.append(Case(kind: "engine", input: [
    "name": .s(engine.name), "keyword": .s(engine.keyword), "url": .s(engine.url), "fallback": .b(engine.fallback),
  ], json: value, hash: hash(value)))
}
for ids in [[String](), ["google", "bing"], ["group:0F8FAD5B-D9CB-469F-A165-70867728950E", "group:7C9E6679-7425-40DE-944B-E07FC1F90AE7"]] {
  let value = json(ids)
  cases.append(Case(kind: "order", input: ["ids": .list(ids)], json: value, hash: hash(value)))
}
for clock in [[:], ["MAC-1": 3], ["WIN-2": 1, "MAC-1": 12, "a-b-c": 7]] as [[String: Int]] {
  cases.append(Case(kind: "clock", input: ["clock": .map(clock)], json: nil, hash: nil, text: clockText(clock)))
}
// 整份文件：按编号排、键排好序（SyncRecords.data(of:kind:)）
let file = Stored(format: 1, kind: "clips", records: [
  StoredItem(id: "0F8FAD5B-D9CB-469F-A165-70867728950E", clock: clockText(["MAC-1": 2, "WIN-2": 1]), modified: 1_761_300_000_123,
             value: json(SyncedClip(text: "你好 / hi", favorite: true, snippet: false, note: nil, group: nil))),
  StoredItem(id: "~order", clock: clockText(["MAC-1": 1]), modified: 1_761_300_000_000, value: json(["group:7C9E6679-7425-40DE-944B-E07FC1F90AE7"])),
].sorted { $0.id < $1.id }, erased: [StoredGone(id: "7C9E6679-7425-40DE-944B-E07FC1F90AE7", clock: clockText(["WIN-2": 4]))])
let fileValue = json(file)
cases.append(Case(kind: "file", input: [:], json: fileValue, hash: hash(fileValue)))

let pretty = JSONEncoder()
pretty.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
let out = URL(fileURLWithPath: CommandLine.arguments[1])
struct Fixture: Encodable { var generatedBy: String; var cases: [Case] }
try pretty.encode(Fixture(generatedBy: "windows/tools/sync-golden.swift", cases: cases)).write(to: out)
print("\(cases.count) 个样本 → \(out.path)")
