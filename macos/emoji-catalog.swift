#!/usr/bin/env swift  // 启动器「emoji」的离线字符表生成器：Unicode Emoji 15.1（macOS 15.0 可显示）+ CLDR 46 中英文注释。
// 只生成文字数据，不借用别的 App 的代码或字符表。输入文件先下载到不入库的目录：
// emoji-test.txt：https://unicode.org/Public/emoji/15.1/emoji-test.txt
// annotations-{en,zh}.json / annotationsDerived-{en,zh}.json：
// https://raw.githubusercontent.com/unicode-org/cldr-json/46.0.0/cldr-json/
// cldr-annotations-full/annotations/<语言>/annotations.json（Derived 用 cldr-annotations-derived-full/annotationsDerived）
// LICENSE.txt：https://www.unicode.org/license.txt（随生成结果一同保留）
// 用法：swift macos/emoji-catalog.swift <输入目录> [输出目录，默认 macos/KittyTools/Resources]

import Foundation

struct Annotation: Decodable {
  let tts: [String]?
  let `default`: [String]?
}

struct Entry: Encodable {
  let glyph: String
  let name: String
  let english: String
  let keywords: [String]
  let pinyin: [String]
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard (1...2).contains(arguments.count) else {
  fatalError("用法：swift macos/emoji-catalog.swift <输入目录> [输出目录]")
}
let source = URL(fileURLWithPath: arguments[0])
let output = URL(
  fileURLWithPath: arguments.count == 2 ? arguments[1] : "macos/KittyTools/Resources")

func annotations(_ locale: String) throws -> [String: Annotation] {
  var result: [String: Annotation] = [:]
  for kind in ["annotationsDerived", "annotations"] {
    let data = try Data(contentsOf: source.appendingPathComponent("\(kind)-\(locale).json"))
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let root = json?[kind] as? [String: Any], let values = root["annotations"] else {
      fatalError("CLDR 文件格式不对：\(kind)-\(locale)")
    }
    let entries = try JSONDecoder().decode(
      [String: Annotation].self, from: JSONSerialization.data(withJSONObject: values))
    result.merge(entries) { _, newer in newer }
  }
  return result
}

let chinese = try annotations("zh")
let english = try annotations("en")
func annotation(_ glyph: String, in table: [String: Annotation]) -> Annotation? {
  table[glyph] ?? table[glyph.replacingOccurrences(of: "\u{FE0F}", with: "")]
}
func unique(_ words: [String]) -> [String] {
  var seen = Set<String>()
  return words.filter { !$0.isEmpty && seen.insert($0).inserted }
}
func pinyin(_ text: String) -> [String] {
  guard text.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }),
    let latin = text.applyingTransform(.mandarinToLatin, reverse: false)?
      .applyingTransform(.stripDiacritics, reverse: false)
  else { return [] }
  let words = latin.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
  return [words.joined(), String(words.compactMap(\.first))]
}
func entry(_ glyph: String, name fallback: String, extra: [String] = []) -> Entry {
  let zh = annotation(glyph, in: chinese)
  let en = annotation(glyph, in: english)
  let name = zh?.tts?.first ?? fallback
  let keywords = unique((zh?.default ?? []) + (en?.default ?? []) + extra)
  return Entry(
    glyph: glyph, name: name, english: fallback, keywords: keywords,
    pinyin: unique(([name] + (zh?.default ?? []) + extra).flatMap(pinyin)))
}

// Unicode 的 fully-qualified 序列保留 ZWJ / VS16；肤色变体一并保留，让「深肤色 点赞」「woman technologist」照常搜。
let text = try String(contentsOf: source.appendingPathComponent("emoji-test.txt"), encoding: .utf8)
guard text.contains("# Version: 15.1") else { fatalError("需要 Unicode Emoji 15.1 的 emoji-test.txt") }
var entries: [Entry] = []
for line in text.split(separator: "\n") {
  let parts = line.split(separator: "#", maxSplits: 1)
  guard parts.count == 2 else { continue }
  let fields = parts[0].split(separator: ";")
  guard fields.count == 2, fields[1].trimmingCharacters(in: .whitespaces) == "fully-qualified"
  else {
    continue
  }
  let scalars = fields[0].split(whereSeparator: \.isWhitespace).map {
    Unicode.Scalar(UInt32($0, radix: 16)!)!
  }
  let description = parts[1].split(separator: " ", maxSplits: 2)
  guard description.count == 3 else { fatalError("Unicode 行格式不对：\(line)") }
  entries.append(entry(String(String.UnicodeScalarView(scalars)), name: String(description[2])))
}

// ponytail: 普通符号先收日常输入用的这些；需要更多时在这里补，不把整个 Unicode 字库塞进搜索结果。
let symbols: [(String, String, String)] = [
  ("←", "left arrow", "左箭头 返回"), ("→", "right arrow", "右箭头 向右"),
  ("↑", "up arrow", "上箭头 向上"), ("↓", "down arrow", "下箭头 向下"),
  ("↔", "left right arrow", "左右箭头 双向"), ("↕", "up down arrow", "上下箭头 双向"),
  ("↗", "up right arrow", "右上箭头"), ("↘", "down right arrow", "右下箭头"),
  ("↙", "down left arrow", "左下箭头"), ("↖", "up left arrow", "左上箭头"),
  ("⇒", "implies", "推出 蕴含 双箭头"), ("⇔", "equivalent", "等价 当且仅当"),
  ("✓", "check mark", "对勾 勾 完成 正确"), ("✗", "cross mark", "叉号 错误"),
  ("©", "copyright", "版权"), ("®", "registered trademark", "注册商标"), ("™", "trademark", "商标"),
  ("§", "section sign", "章节"), ("¶", "paragraph sign", "段落"), ("№", "number sign", "编号 序号"),
  ("•", "bullet", "项目符号 圆点"), ("·", "middle dot", "间隔号 中点"),
  ("…", "ellipsis", "省略号"), ("—", "em dash", "破折号"), ("–", "en dash", "连接号"),
  ("°", "degree", "度 温度 角度"), ("℃", "celsius", "摄氏度 温度"), ("℉", "fahrenheit", "华氏度 温度"),
  ("±", "plus minus", "正负 加减"), ("×", "multiplication", "乘号 乘法"),
  ("÷", "division", "除号 除法"), ("−", "minus", "减号 减法"),
  ("≠", "not equal", "不等于"), ("≈", "approximately equal", "约等于 近似"),
  ("≤", "less than or equal", "小于等于"), ("≥", "greater than or equal", "大于等于"),
  ("∞", "infinity", "无穷 无限"), ("√", "square root", "平方根 根号"),
  ("∑", "summation", "求和"), ("∏", "product", "连乘 积"), ("∫", "integral", "积分"),
  ("∂", "partial derivative", "偏导数"), ("∈", "element of", "属于"),
  ("∉", "not element of", "不属于"), ("∩", "intersection", "交集"), ("∪", "union", "并集"),
  ("∅", "empty set", "空集"), ("π", "pi", "圆周率 派"), ("Ω", "omega ohm", "欧姆"),
  ("µ", "micro", "微"), ("‰", "per mille", "千分号"),
  ("½", "one half", "二分之一"), ("¼", "one quarter", "四分之一"), ("¾", "three quarters", "四分之三"),
  ("€", "euro", "欧元"), ("£", "pound", "英镑"), ("¥", "yen yuan", "人民币 日元"),
  ("₩", "won", "韩元"), ("₹", "rupee", "卢比"), ("₿", "bitcoin", "比特币"), ("¢", "cent", "美分"),
  ("⌘", "command key", "命令键"), ("⌥", "option alt key", "选项键"),
  ("⌃", "control key", "控制键"), ("⇧", "shift key", "换挡键"), ("⇪", "caps lock", "大写锁定"),
  ("⎋", "escape key", "退出键"), ("↩", "return key", "回车键"), ("⇥", "tab key", "制表符"),
  ("⌫", "delete backspace key", "退格键 删除"), ("⌦", "forward delete key", "向前删除"),
  ("□", "empty square", "空心方框"), ("■", "filled square", "实心方框"),
  ("○", "empty circle", "空心圆"), ("●", "filled circle", "实心圆"),
  ("☆", "empty star", "空心星星"), ("★", "filled star", "实心星星"),
  ("※", "reference mark", "参考标记"), ("「", "left corner bracket", "左直角引号"),
  ("」", "right corner bracket", "右直角引号"), ("《", "left book title bracket", "左书名号"),
  ("》", "right book title bracket", "右书名号"),
]
for (glyph, name, keywords) in symbols {
  // 文字符号和 emoji 变体（© / ©️）各自保留，复制出去的表示不同。
  var symbol = entry(glyph, name: name, extra: keywords.split(separator: " ").map(String.init))
  if symbol.name == name {
    symbol = Entry(
      glyph: glyph, name: String(keywords.split(separator: " ")[0]), english: name,
      keywords: symbol.keywords, pinyin: symbol.pinyin)
  }
  entries.append(symbol)
}
guard entries.count > 3700, Set(entries.map(\.glyph)).count == entries.count else {
  fatalError("字符表缺失或重复")
}
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
try encoder.encode(entries).write(
  to: output.appendingPathComponent("emoji-catalog.json"), options: .atomic)
try Data(contentsOf: source.appendingPathComponent("LICENSE.txt")).write(
  to: output.appendingPathComponent("unicode-LICENSE.txt"), options: .atomic)
print("已生成 \(entries.count) 个表情与符号：\(output.path)/emoji-catalog.json")
