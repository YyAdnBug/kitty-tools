// 修复乱码文件名：几种常见的错法还原得对，正常的名字（西文重音字母、本来就是中文、纯英文）一律不动；在临时文件夹里改名再撤销。

import Foundation
import Testing

@testable import KittyTools

@MainActor struct NameRepairTests {
  @Test func garbledNamesAreRestored() {
    // GBK 被当成 CP437（tar / unzip）、MacRoman（ditto）、Latin-1 / CP1252
    #expect(NameRepair.repair("╓╨╬─├√.txt") == "中文名.txt")
    #expect(NameRepair.repair("±®∏Ê.txt") == "报告.txt")
    #expect(NameRepair.repair("ÖÐÎÄ") == "中文")
    #expect(NameRepair.repair("ËµÃ÷Êé.pdf") == "说明书.pdf")
    // UTF-8 被当成 Latin-1 / CP1252 / MacRoman
    for wrong in [String.Encoding.isoLatin1, .windowsCP1252, .macOSRoman] {
      let garbled = String(data: Data("项目资料 2024.docx".utf8), encoding: wrong)
      #expect(garbled.flatMap(NameRepair.repair) == "项目资料 2024.docx", "\(wrong)")
    }
  }

  @Test func normalNamesAreLeftAlone() {
    for name in [
      "Ångström.txt", "Résumé.pdf", "café", "Größe.xlsx", "Ñandú", "naïve", "报告.txt", "plain.txt",
      "Déjà vu.mp3", "", "Informações das Ações.pdf", "Atenção Situação",
      "Fiche créée et agréée.pdf",
      "Häät ja häät", "Ã©tÃ©", "Ã¤Ã¶Ã¼", "東京.txt", "서울.txt", "🐱.png",
    ] {
      #expect(NameRepair.repair(name) == nil, "\(name)")
    }
  }

  /// 改名、重名加「 2」，撤销改回去
  @Test func renameAndUndo() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "NameRepairTests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let garbled = root.appending(path: "ÖÐÎÄ.txt")
    let plain = root.appending(path: "plain.txt")
    try Data("x".utf8).write(to: garbled)
    try Data().write(to: plain)
    try Data().write(to: root.appending(path: "中文.txt"))
    let renamed = NameRepair.rename([garbled, plain])
    #expect(renamed.map(\.to.lastPathComponent) == ["中文 2.txt"])
    #expect(!FileMoves.occupied(garbled))
    #expect(NameRepair.undo(renamed) == 1)
    #expect(FileMoves.occupied(garbled))
    #expect(try String(contentsOf: garbled, encoding: .utf8) == "x")
  }
}
