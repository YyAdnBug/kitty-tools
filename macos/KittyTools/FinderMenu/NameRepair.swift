// 访达右键「修复乱码文件名」（2026-11-08 右键扩充拍板 D3）：访达 / 归档实用工具解开中文 Windows 打的 zip、有的网站下载下来，
// 文件名会变成「╓╨╬─.txt」「±®∏Ê.txt」「ÖÐÎÄ」「ä¸­æ–‡」这种——字节按错的编码读成了字。还原：按那个错的编码编回字节、
// 再按对的读（本机实测：ditto 解 GBK 名字的 zip 是按 MacRoman 读的，tar 是 CP437）。
// 只认几种常见的错法：UTF-8 被当成 CP1252 / Latin-1 / MacRoman（一个汉字三个错字），GBK 被当成 CP437 / MacRoman / CP1252 / Latin-1
// （一个汉字两个错字）。宁可不认，不乱改：原名里不能已经有中日韩文字；每一串连着的非 ASCII 字符个数得是 3（或 2）的倍数、
// 至少有一串够两个字连着（「Ångström」「Résumé」「Größe」，和「Informações」「créée」「Häät」这种成对的重音字母都过不了，
// 2026-11-08 评审）；GBK 这一路只认 GB2312 里的常用字（同一串乱码按 MacRoman、Latin-1 都能读出合法的 GBK，生僻字凑出来的那种
// 多半是错的），编回去的字节本身是合法 UTF-8 的不走这一路（那是西文的 UTF-8 被读错了，「Ã©tÃ©」不该变成汉字）；
// 还原出来的非 ASCII 字符必须全是中日韩文字、全角符号。「第1章」这种被数字隔开的单字认不出（宁可不认）。
// ponytail: 俄文 CP1251 的乱码（「ÌÎÑÊÂÀ」）、「ÀÁÂÃ」这种凑出来的名字仍会被当成 GBK 乱码；有人报了再加俄文这一路。
// 访达扩展里有一模一样的一份（它要看名字决定出不出这一项、自己又不能链 App 的代码），两份在 BEGIN / END 之间逐字比对（FinderLinkTests）。
// App 这边改名（fix）：在原来的文件夹里改成还原的名字，有人用了加「 2」，不覆盖（FileMoves.land）；刘海岛说一声、带「撤销」
// （改回原来的名字，原来的名字被占了的那几个不动）。只改选中的那几样，不往文件夹里面走。

import AppKit

// BEGIN NameRepair
nonisolated enum NameRepair {
  /// 名字像乱码、能还原成中日韩文字时给出还原后的名字；不像、还原不了是 nil
  static func repair(_ name: String) -> String? {
    let name = name.precomposedStringWithCanonicalMapping
    guard !name.unicodeScalars.contains(where: isCJK) else { return nil }
    var runs: [Int] = []
    var current = 0
    for scalar in name.unicodeScalars {
      if scalar.isASCII {
        if current > 0 { runs.append(current) }
        current = 0
      } else {
        current += 1
      }
    }
    if current > 0 { runs.append(current) }
    for (wrong, right, unit) in tries
    where runs.contains(where: { $0 >= 2 * unit }) && runs.allSatisfy({ $0 % unit == 0 }) {
      guard let bytes = name.data(using: wrong),
        right == .utf8 || String(data: bytes, encoding: .utf8) == nil,
        let fixed = String(data: bytes, encoding: right), fixed != name, looksRight(fixed)
      else { continue }
      return fixed
    }
    return nil
  }

  /// 还原出来的像样：有中日韩文字，非 ASCII 的全是中日韩文字和全角符号，没有控制字符、/、:
  private static func looksRight(_ name: String) -> Bool {
    let scalars = name.unicodeScalars
    return scalars.contains(where: isCJK)
      && scalars.allSatisfy { $0.isASCII ? $0.value >= 0x20 && $0 != "/" && $0 != ":" : isCJK($0) }
  }

  /// 中日韩文字、假名、谚文、中日韩标点、全角符号
  private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x3000...0x303F, 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF,
      0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x2FA1F:
      true
    default: false
    }
  }

  private static func encoding(_ cf: CFStringEncodings) -> String.Encoding {
    String.Encoding(
      rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cf.rawValue)))
  }

  /// 依次试：（被当成的错编码，本来的编码，一个字几个错字）。UTF-8 校验更严，先试；中文这一路按 GB2312（EUC-CN）读
  private static let tries: [(String.Encoding, String.Encoding, Int)] = {
    let gb2312 = encoding(.EUC_CN)
    let cp437 = encoding(.dosLatinUS)
    return [
      (.windowsCP1252, .utf8, 3), (.isoLatin1, .utf8, 3), (.macOSRoman, .utf8, 3),
      (cp437, gb2312, 2), (.macOSRoman, gb2312, 2), (.windowsCP1252, gb2312, 2),
      (.isoLatin1, gb2312, 2),
    ]
  }()
}
// END NameRepair

extension NameRepair {
  /// 改名修好 files 里像乱码的；返回改了的（原来在哪、现在在哪）
  @MainActor static func rename(_ files: [URL]) -> [(from: URL, to: URL)] {
    var renamed: [(from: URL, to: URL)] = []
    for file in files where FileMoves.occupied(file) {
      guard let fixed = repair(file.lastPathComponent) else { continue }
      let folder = file.deletingLastPathComponent()
      if let target = FileMoves.land(
        file, at: folder.appending(path: FileMoves.freeName(fixed, in: folder, used: [])))
      {
        renamed.append((file, target))
      }
    }
    return renamed
  }

  /// 改回去（倒着来）；返回改回了几个
  @MainActor static func undo(_ renamed: [(from: URL, to: URL)]) -> Int {
    renamed.reversed().filter {
      (try? FileManager.default.moveItem(at: $0.to, to: $0.from)) != nil
    }.count
  }

  @MainActor static func fix(_ files: [URL], island: Island?) {
    let renamed = rename(files)
    guard !renamed.isEmpty else {
      NSSound.beep()
      return
    }
    island?.show(
      renamed.count == 1 ? "已修复文件名" : "已修复 \(renamed.count) 个文件名",
      detail: renamed.count == 1 ? renamed[0].to.lastPathComponent : nil,
      actions: [
        Island.Action("撤销") {
          let back = undo(renamed)
          island?.show(
            back == renamed.count ? "已撤销" : "撤销了 \(back) 个，\(renamed.count - back) 个原来的名字被占了",
            tone: back == renamed.count ? .info : .warning)
        }
      ])
  }
}
