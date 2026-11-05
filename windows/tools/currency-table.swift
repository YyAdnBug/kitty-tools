// 在 Mac 上生成 Windows 版启动器汇率换算用的货币表：swift windows/tools/currency-table.swift（PLAN-v12 N1）
// Windows 的 RegionInfo 只给得出本地区货币的名字，给不出每种货币的中文名；这里借 macOS 的 Locale（和 mac 版
// Launcher/ExchangeRates.swift 同一套：Locale.commonISOCurrencyCodes，159 种，没有加密货币、停用的旧货币和贵金属），
// 写进 windows/KittyTools.Core/Resources/currencies.txt，一行一种，制表符隔开：
// 代码  小数位（en_US 的货币格式）  简体名  繁体名  英文名  简体名的全拼（小写、不带空格，候选里拿它搜）
// 系统升级后货币名变了再跑一次；两边的名字就一字不差。
import Foundation

let simplified = Locale(identifier: "zh_Hans")
let traditional = Locale(identifier: "zh_Hant")
let english = Locale(identifier: "en_US")

func fractionDigits(_ code: String) -> Int {
  let formatter = NumberFormatter()
  formatter.locale = english
  formatter.numberStyle = .currency
  formatter.currencyCode = code
  return formatter.maximumFractionDigits
}

func pinyin(_ text: String) -> String {
  let mutable = NSMutableString(string: text)
  CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
  CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
  return (mutable as String).lowercased().filter { !$0.isWhitespace }
}

func clean(_ text: String?) -> String {
  (text ?? "").replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
}

var lines: [String] = []
for code in Set(Locale.commonISOCurrencyCodes).sorted() {
  let zh = clean(simplified.localizedString(forCurrencyCode: code))
  lines.append(
    [
      code, String(fractionDigits(code)), zh.isEmpty ? code : zh,
      clean(traditional.localizedString(forCurrencyCode: code)),
      clean(english.localizedString(forCurrencyCode: code)), pinyin(zh),
    ].joined(separator: "\t"))
}

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let out = here.appendingPathComponent("../KittyTools.Core/Resources/currencies.txt").standardized
try (lines.joined(separator: "\n") + "\n").write(to: out, atomically: true, encoding: .utf8)
print("wrote \(lines.count) currencies to \(out.path)")
