// 功能图标（自画的 kitty.* 自定义符号）：源文件、资源目录、代码里用到的名字三边对得上，并且真是符号图
// （跟着字号缩放、模板图能上色）。改了 icons/feature/ 忘了跑 swift icons/build-icons.swift mac 时这里先挂

import AppKit
import Testing

@testable import KittyTools

struct SymbolImageTests {
  /// 仓库根（本文件在 macos/KittyToolsTests/ 下）
  private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

  private static func names(in folder: String, suffix: String) throws -> Set<String> {
    let files = try FileManager.default.contentsOfDirectory(
      atPath: root.appending(path: folder).path)
    return Set(files.filter { $0.hasSuffix(suffix) }.map { String($0.dropLast(suffix.count)) })
  }

  @Test func sourcesAndAssetsMatch() throws {
    let sources = try Self.names(in: "icons/feature", suffix: ".svg")
    let assets = try Self.names(
      in: "macos/KittyTools/Resources/Assets.xcassets/FeatureIcons", suffix: ".symbolset")
    #expect(sources.count == 26)
    #expect(sources == assets)
    for name in sources {
      let image = try #require(NSImage.symbol(name), "\(name)")
      #expect(image.isTemplate, "\(name)")
      // 是符号图：跟着字号缩放（普通图片套了符号配置尺寸不变；符号的尺寸取整到点，10 pt 时 12 → 13）
      let config = { (size: CGFloat) in
        NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
      }
      let small = try #require(image.withSymbolConfiguration(config(10)))
      let large = try #require(image.withSymbolConfiguration(config(20)))
      #expect(large.size.width > small.size.width * 1.6, "\(name) \(small.size) \(large.size)")
    }
  }

  @Test func everyUsedNameResolves() {
    let names =
      HotKeyAction.allCases.map(\.symbol) + SettingsPage.allCases.map(\.symbol) + ["gearshape"]
    for name in names {
      #expect(NSImage.symbol(name) != nil, "\(name)")
    }
    #expect(NSImage.symbol("kitty.nope") == nil)
    // 带描述时拷一份，别改了资源目录里共用的那张
    let described = NSImage.symbol("kitty.clipboard", accessibilityDescription: "剪贴板")
    #expect(described?.accessibilityDescription == "剪贴板")
    #expect(NSImage(named: "kitty.clipboard")?.accessibilityDescription != "剪贴板")
  }
}
