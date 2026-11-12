// 一键打码（2026-11-12 拍板 C5）：打码工具托盘上的「自动」。识出选区里的字（OCR.boxes），在每一行里找手机号、邮箱、
// 银行卡号、身份证号，各加一块打码标注（普通标注，能挪、能删、能 ⌘Z）。这里是找哪几段、换成哪几块的纯函数，配单测；
// 识字在 OCR，什么时候跑、结果落进标注列表归 SelectionView / ScrollCanvas。
// 只认格式明确的几类，宁可漏也不乱打：卡号 15–19 位、按卡组织号段开头、过 Luhn，身份证号的地区码、出生日期、
// 校验位都对得上——单靠 Luhn / 校验位，时间戳、订单号、雪花 ID 一成上下会碰巧过（评审随机实测）。
// 认出来的几段互相重叠时合成一段（隐私功能，宁可多盖，不能丢掉一段把号码露出半截）。

import CoreGraphics
import Foundation

enum Redaction {
  /// 一行字里要打码的那几段（按出现顺序，重叠的合成一段）。识字在主线程外跑，它跟着在那里调
  nonisolated static func ranges(in text: String) -> [Range<String.Index>] {
    var found: [Range<String.Index>] = []
    func add(_ range: Range<String.Index>) { found.append(range) }
    for match in text.matches(of: email) where !isAssetName(match.output) { add(match.range) }
    for match in text.matches(of: idNumber)
    where startsClean(match.range, in: text, letters: true) && isIDNumber(String(match.output)) {
      add(match.range)
    }
    for match in text.matches(of: cardNumber) where startsClean(match.range, in: text) {
      if isCardNumber(match.output.compactMap(\.wholeNumberValue)) { add(match.range) }
    }
    for match in text.matches(of: mobile) where startsClean(match.range, in: text) {
      add(match.range)
    }
    var merged: [Range<String.Index>] = []
    for range in found.sorted(by: { $0.lowerBound < $1.lowerBound }) {
      if let last = merged.last, last.overlaps(range) {
        merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
      } else {
        merged.append(range)
      }
    }
    return merged
  }

  /// 银行卡号：15–19 位，开头是卡组织的号段（3 开头的运通 / JCB / 大来、4 Visa、5 万事达、6 银联 / 发现，2221–2720 的
  /// 万事达新号段），过 Luhn。2 开头的日期式订单号、1 开头的时间戳都不认
  nonisolated static func isCardNumber(_ digits: [Int]) -> Bool {
    guard (15...19).contains(digits.count), let first = digits.first else { return false }
    let prefix = digits.prefix(4).reduce(0) { $0 * 10 + $1 }
    guard (3...6).contains(first) || (2221...2720).contains(prefix) else { return false }
    return passesLuhn(digits)
  }

  /// 图片资源名（icon@2x.png、AppIcon@3x.png）长得像邮箱：@ 后面是「数字 + x」的不算
  nonisolated private static func isAssetName(_ text: Substring) -> Bool {
    guard let at = text.firstIndex(of: "@") else { return false }
    let domain = text[text.index(after: at)...].prefix { $0 != "." }
    return domain.count >= 2 && domain.last == "x" && domain.dropLast().allSatisfy(\.isNumber)
  }

  /// 识字给的框（归一化、原点左下，相对识字的那块图）换成视图里的打码框：铺到 area（那块图在视图里的位置）上，
  /// 四周各放 3 点（框贴着字，留点边才盖得严），再夹回 area 里；已经被某块打码整个盖住的不要（连按两下不叠两层）。
  /// ponytail: 只按「整个盖住」去重，和已有打码只部分重叠的照样加一块；要合并就按并集重算
  static func areas(
    _ boxes: [CGRect], in area: CGRect, existing: [Annotation]
  ) -> [CGRect] {
    let covered = existing.compactMap { annotation -> CGRect? in
      if case .mosaic(let rect) = annotation.shape { rect } else { nil }
    }
    var result: [CGRect] = []
    for box in boxes {
      let text = CGRect(
        x: area.minX + box.minX * area.width, y: area.minY + box.minY * area.height,
        width: box.width * area.width, height: box.height * area.height)
      // 字框本身不到 2 点的是识错的碎渣；放了边、夹回区域后太窄的（字压在区域边上）也不要
      guard text.width >= 2, text.height >= 2 else { continue }
      let rect = text.insetBy(dx: -3, dy: -3).intersection(area)
      guard !rect.isNull, rect.width >= 3, rect.height >= 3,
        !(covered + result).contains(where: { $0.contains(rect) })
      else { continue }
      result.append(rect)
    }
    return result
  }

  /// 前面不紧挨着数字（letters：也不挨着字母）：Swift 的正则不支持往回看，匹配完再查前一个字
  nonisolated private static func startsClean(
    _ range: Range<String.Index>, in text: String, letters: Bool = false
  ) -> Bool {
    guard range.lowerBound > text.startIndex else { return true }
    let previous = text[text.index(before: range.lowerBound)]
    return !(previous.isASCII && (previous.isNumber || letters && previous.isLetter))
  }

  /// Luhn 校验（银行卡号）：从右往左每隔一位乘 2，各位相加能被 10 整除
  nonisolated static func passesLuhn(_ digits: [Int]) -> Bool {
    var sum = 0
    for (index, digit) in digits.reversed().enumerated() {
      let value = index.isMultiple(of: 2) ? digit : digit * 2
      sum += value > 9 ? value - 9 : value
    }
    return !digits.isEmpty && sum.isMultiple(of: 10)
  }

  /// 18 位身份证号（GB 11643）：地区码首位 1–8，第 7–14 位是 1900 年到今年之间真有的日子，
  /// 校验位对（前 17 位乘权重求和模 11，对应 1 0 X 9 8 7 6 5 4 3 2）
  nonisolated static func isIDNumber(_ text: String) -> Bool {
    let characters = Array(text.uppercased())
    guard characters.count == 18, let region = characters[0].wholeNumberValue,
      (1...8).contains(region), isBirthday(String(characters[6..<14]))
    else { return false }
    let weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]
    var sum = 0
    for (character, weight) in zip(characters.prefix(17), weights) {
      guard let digit = character.wholeNumberValue else { return false }
      sum += digit * weight
    }
    return Array("10X98765432")[sum % 11] == characters[17]
  }

  /// yyyyMMdd 是不是 1900 年到今年之间真有的一天（按公历，不管时区）
  nonisolated private static func isBirthday(_ text: String) -> Bool {
    guard let value = Int(text) else { return false }
    let (year, month, day) = (value / 10000, value / 100 % 100, value % 100)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let thisYear = calendar.component(.year, from: .now)
    guard (1900...thisYear).contains(year),
      let date = calendar.date(from: DateComponents(year: year, month: month, day: day))
    else { return false }
    let back = calendar.dateComponents([.year, .month, .day], from: date)
    return back.year == year && back.month == month && back.day == day
  }

  // Regex 不是 Sendable，存成静态常量过不了 Swift 6 的并发检查，每次现做一个（同 OCR.wordPattern）

  nonisolated private static var email: Regex<Substring> {
    /[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}/
  }

  /// 中国大陆手机号：1 开头 11 位，可带 +86，可按 3-4-4 用空格或横线隔开；前后不能紧挨别的数字（前面见 startsClean）
  nonisolated private static var mobile: Regex<Substring> {
    /(?:\+?86[ \-]?)?1[3-9][0-9](?:[ \-]?[0-9]{4}){2}(?![0-9])/
  }

  nonisolated private static var idNumber: Regex<Substring> {
    /[0-9]{17}[0-9Xx](?![0-9A-Za-z])/
  }

  /// 卡号的写法：连着写 15–19 位，或四位一组用空格 / 横线隔开（最后一组 1–4 位）；后面不能紧挨数字（前面见 startsClean）。
  /// 不许任意两位之间都能断开：不然一行里按空格分组的两个手机号会被连成一串「卡号」
  nonisolated private static var cardNumber: Regex<Substring> {
    /(?:[0-9]{15,19}|[0-9]{4}(?:[ \-][0-9]{4}){2,3}(?:[ \-][0-9]{1,4})?)(?![0-9])/
  }
}
