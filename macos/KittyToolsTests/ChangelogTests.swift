// 更新日志的格式（第 8 批评审 F2）：changelog.json 里每条 change 一直是一条一行（`{ "type": …, "scope": …, "text": … }`），
// 不是展开成多行的对象——展开会让以后每个版本的 diff 难看、也冲掉 git blame。
// 读的是仓库里的源文件（#filePath），不是包里那份：它和打进 App 的是同一个文件。

import Foundation
import Testing

@testable import KittyTools

struct ChangelogTests {
  private let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()

  @Test func everyChangeEntryStaysOnOneLine() throws {
    let url = root.appending(path: "KittyTools/Resources/changelog.json")
    let text = try String(contentsOf: url, encoding: .utf8)
    let lines = text.components(separatedBy: "\n")
    let changes = lines.filter { $0.contains("\"type\":") }
    #expect(changes.count > 100)
    for line in changes {
      #expect(line.hasPrefix("      { \"type\": \""), "每条 change 是一行：\(line)")
      #expect(line.hasSuffix(" }") || line.hasSuffix(" },"), "每条 change 是一行：\(line)")
    }
    // 不锁哪个版本在最前、有几条：下一版加条目时这条单测不该跟着红
    #expect(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) is [[String: Any]])
  }

  /// 关于页的更新日志一开始只展开当前版本；changelog 里没有当前版本号（开发中的新版本）就展开最新那条（最新在前）
  @Test func expandsCurrentReleaseOrLatest() {
    let releases = ["0.7.1", "0.7.0", "0.6.0"].map {
      AboutTab.Release(version: $0, date: "", summary: "", changes: [])
    }
    #expect(AboutTab.firstExpanded(in: releases, current: "0.7.0") == "0.7.0")
    #expect(AboutTab.firstExpanded(in: releases, current: "0.8.0") == "0.7.1")
    #expect(AboutTab.firstExpanded(in: [], current: "0.8.0") == nil)
  }
}
