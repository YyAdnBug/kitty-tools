// 更新日志的格式（第 8 批评审 F2）：changelog.json 里每条 change 一直是一条一行（`{ "type": …, "scope": …, "text": … }`），
// 不是展开成多行的对象——展开会让以后每个版本的 diff 难看、也冲掉 git blame。
// 读的是仓库里的源文件（#filePath），不是包里那份：它和打进 App 的是同一个文件。
// 设置 › 关于的「未来计划」（roadmap.json，2026-10-18）同一个写法，也锁在这里。

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

  /// 未来计划：一条一行；种类只有 improve（改进，已知的小毛病）/ feature（新功能），改进在前；范围和那句话不空；
  /// 写给用户看——没有 Markdown 记号、没有代码里的名字（反引号、ponytail、驼峰的类型名）；包里那份读得出来、条数一样。
  /// 都做完了可以是空的（`[]`，关于页不显示那一节）
  @Test func roadmapEntriesAreOneLineAndForUsers() throws {
    let url = root.appending(path: "KittyTools/Resources/roadmap.json")
    let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
      .filter { $0.contains("\"kind\":") }
    for line in lines {
      #expect(line.hasPrefix("  { \"kind\": \""), "每条是一行：\(line)")
      #expect(line.hasSuffix(" }") || line.hasSuffix(" },"), "每条是一行：\(line)")
    }
    let plans = try JSONDecoder().decode([AboutTab.Plan].self, from: Data(contentsOf: url))
    #expect(plans.count == lines.count)
    let kinds = plans.map(\.kind)
    #expect(kinds == kinds.filter { $0 == "improve" } + kinds.filter { $0 == "feature" })
    let identifier = try Regex("[A-Z][a-z]+[A-Z][a-z]")
    for plan in plans {
      #expect(!plan.scope.isEmpty && !plan.text.isEmpty)
      for mark in ["`", "**", "](", "ponytail", "TODO"] {
        #expect(!plan.text.contains(mark), "\(plan.text)")
      }
      #expect(plan.text.firstMatch(of: identifier) == nil, "\(plan.text)")
    }
    #expect(AboutTab.roadmap == plans)
  }
}
