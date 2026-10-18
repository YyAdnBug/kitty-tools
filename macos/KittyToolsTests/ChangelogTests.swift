// 更新日志的格式（第 8 批评审 F2）：changelog.json 里每条 change 一直是一条一行（`{ "type": …, "scope": …, "text": … }`），
// 不是展开成多行的对象——展开会让以后每个版本的 diff 难看、也冲掉 git blame。
// 读的是仓库里的源文件（#filePath），不是包里那份：它和打进 App 的是同一个文件。

import Foundation
import Testing

@testable import KittyTools

struct ChangelogTests {
  @Test func everyChangeEntryStaysOnOneLine() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let url = root.appending(path: "KittyTools/Resources/changelog.json")
    let text = try String(contentsOf: url, encoding: .utf8)
    let lines = text.components(separatedBy: "\n")
    let changes = lines.filter { $0.contains("\"type\":") }
    #expect(changes.count > 100)
    for line in changes {
      #expect(line.hasPrefix("      { \"type\": \""), "每条 change 是一行：\(line)")
      #expect(line.hasSuffix(" }") || line.hasSuffix(" },"), "每条 change 是一行：\(line)")
    }
    let versions = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
    #expect(versions.first?["version"] as? String == "0.5.0")
    // 这一批的四件事拆成四条，不是一条大杂烩
    #expect((versions.first?["changes"] as? [[String: Any]])?.count ?? 0 >= 21)
  }
}
