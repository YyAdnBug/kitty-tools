// 在 Mac 上生成 Windows 版启动器用的拼音表：swift windows/tools/pinyin-table.swift
// Windows 没有现成的汉字转拼音接口，这里借 macOS 的 CFStringTransform（和 mac 版 AppCatalog.pinyin 同一个变换）
// 把 CJK 统一汉字基本区 U+4E00–U+9FFF 逐字转成不带声调的拼音，按读音分组写进
// windows/KittyTools.Core/Resources/pinyin.txt：一行一个读音，「读音 空格 这个读音的所有字」。
// ponytail: 逐字转、多音字只取系统给的那一个读音（重庆 → zhongqing），整词上下文要换成词表时再升级。
import Foundation

var groups: [String: String] = [:]
for code in 0x4E00...0x9FFF {
  let char = String(UnicodeScalar(code)!)
  let text = NSMutableString(string: char)
  CFStringTransform(text, nil, kCFStringTransformMandarinLatin, false)
  CFStringTransform(text, nil, kCFStringTransformStripDiacritics, false)
  let pinyin = (text as String).lowercased().trimmingCharacters(in: .whitespaces)
  guard pinyin != char, !pinyin.isEmpty, pinyin.allSatisfy({ $0 >= "a" && $0 <= "z" }) else { continue }
  groups[pinyin, default: ""] += char
}
let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let out = here.appendingPathComponent("../KittyTools.Core/Resources/pinyin.txt").standardized
let lines = groups.keys.sorted().map { "\($0) \(groups[$0]!)" }
try (lines.joined(separator: "\n") + "\n").write(to: out, atomically: true, encoding: .utf8)
print("\(lines.count) 个读音，\(groups.values.reduce(0) { $0 + $1.count }) 个字 → \(out.path)")
