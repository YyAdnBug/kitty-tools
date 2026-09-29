import AppKit
import SwiftUI
import Testing

@testable import KittyTools

/// 第 9 批：菜单栏图标可隐藏（M1）、可选彩色（M2）。不建真的 StatusItem（会往菜单栏里插一个图标），
/// 只测偏好默认值、样式 → 图片、彩色图标的出图和启动器里的「退出」；不写用户的偏好
struct StatusItemTests {
  /// 默认显示、单色（只读注册域）；没存过、认不得的样式都回落单色
  @Test func prefsDefaultToVisibleTemplate() {
    Prefs.registerDefaults()
    let registered = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)
    #expect(registered[Prefs.statusItemVisible] as? Bool == true)
    #expect(registered[Prefs.statusItemStyle] as? String == "template")
    #expect(StatusItem.IconStyle(pref: nil) == .template)
    #expect(StatusItem.IconStyle(pref: "rainbow") == .template)
    #expect(StatusItem.IconStyle(pref: "color") == .color)
    #expect(StatusItem.IconStyle.allCases.map(\.title) == ["单色", "彩色"])
  }

  /// 单色是模板图（跟着菜单栏反色）；彩色不是模板、16 pt 正方形、@1x / @2x 两张位图；读屏名都是 Kitty Tools
  @Test func styleImages() throws {
    let template = try #require(StatusItem.IconStyle.template.image)
    #expect(template.isTemplate && template.accessibilityDescription == "Kitty Tools")
    let color = try #require(StatusItem.IconStyle.color.image)
    #expect(!color.isTemplate && color.accessibilityDescription == "Kitty Tools")
    #expect(color.size == NSSize(width: 16, height: 16))
    #expect(color.representations.map(\.pixelsWide) == [16, 32])
    // 只画一次
    #expect(StatusItem.IconStyle.color.image === color)
  }

  /// 彩色取的是大图，不是 16 / 32 px 那两张手调简化版：假图标 32 px 红、1024 px 绿，出来是绿的
  @Test func colorIconUsesLargeRepresentation() throws {
    let icon = NSImage(size: NSSize(width: 32, height: 32))
    icon.addRepresentation(Self.solid(.red, pixels: 32))
    icon.addRepresentation(Self.solid(.green, pixels: 1024))
    let rep = try #require(
      StatusItem.menuBarImage(from: icon).representations.last as? NSBitmapImageRep)
    let center = try #require(rep.colorAt(x: 16, y: 16)?.usingColorSpace(.sRGB))
    #expect(center.greenComponent > 0.9 && center.redComponent < 0.1)
  }

  /// 真的 App 图标：只取圆角方块主体——四角透明（画布留白没带进来），一圈边上没有烘焙阴影的黑；
  /// 左边中间是粉底，下半中间是奶油色卡片，上半中间是黑猫
  @Test func colorIconIsTheWholeAppIcon() throws {
    let rep = try #require(StatusItem.colorIcon.representations.last as? NSBitmapImageRep)
    #expect(rep.pixelsWide == 32 && rep.pixelsHigh == 32)
    let pixel = { (x: Int, y: Int) in rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) }
    for (x, y) in [(0, 0), (31, 0), (0, 31), (31, 31)] {
      #expect((pixel(x, y)?.alphaComponent ?? 1) < 0.05, "角 \(x),\(y)")
    }
    for index in 0..<32 {
      for (x, y) in [(index, 0), (index, 31), (0, index), (31, index)] {
        guard let color = pixel(x, y), color.alphaComponent > 0.1 else { continue }
        #expect(color.redComponent > 0.55, "边 \(x),\(y)")
      }
    }
    let pink = try #require(pixel(1, 14))
    #expect(pink.redComponent > 0.85 && pink.greenComponent < 0.6 && pink.blueComponent < 0.7)
    let cream = try #require(pixel(16, 27))
    #expect(cream.redComponent > 0.9 && cream.greenComponent > 0.85 && cream.blueComponent > 0.8)
    let cat = try #require(pixel(16, 11))
    #expect(cat.redComponent < 0.35 && cat.greenComponent < 0.3)
  }

  /// 启动器内置动作最后是「退出 Kitty Tools」（菜单栏图标隐藏时只剩这里能退出），符号 power、通用家族灰
  @Test func launcherCanQuit() throws {
    let quit = try #require(LauncherItem.actions().last)
    #expect(quit.target == "quit" && quit.title == "退出 Kitty Tools" && quit.symbol == "power")
    #expect(MenuExtra.quit.color == Style.Family.general && MenuExtra.quit.section == nil)
    #expect(
      LauncherMatch.score("quit", item: quit) > 0 && LauncherMatch.score("tuichu", item: quit) > 0)
    #expect(
      LauncherItem.actions(.init(checksUpdates: true)).suffix(2).map(\.target) == [
        "updates", "quit",
      ])
    // 图标隐藏后搜「Kitty Tools」是想回设置：App 那一行要比「退出 Kitty Tools」「关于 Kitty Tools」排得靠前
    let app = AppCatalog.item(path: "/Applications/Kitty Tools.app")
    for query in ["kitty", "kitty tools", "Kitty Tools"] {
      #expect(
        LauncherMatch.score(query, item: app) > LauncherMatch.score(query, item: quit), "\(query)")
    }
  }

  /// 「退出 Kitty Tools」↩ 不确认、不记使用：同分时排在系统命令和 App 后面——「退出」「tuichu」先是要再按一次确认的
  /// 「全部退出」，「qu」「qui」先是标题更长的 QuickTime Player（假路径，只看名字）
  @Test func quitRanksLastOnTies() throws {
    let quit = try #require(LauncherItem.actions().last)
    let quickTime = AppCatalog.item(path: "/Applications/QuickTime Player.app")
    let items = [quit, quickTime] + SystemCommands.items
    let expected = [
      ("退出", "quitall"), ("tuichu", "quitall"), ("qu", quickTime.target), ("qui", quickTime.target),
    ]
    for (query, first) in expected {
      let ranked = LauncherMatch.rank(items, query: query) { _ in (0, 0) }
      #expect(ranked.first?.target == first, "\(query)")
      #expect(ranked.contains { $0.target == "quit" }, "\(query)")
    }
  }

  /// 设置侧栏搜「菜单栏」「状态栏」「图标」「隐藏」「彩色」都能到通用页
  @Test func sidebarSearchFindsMenuBarIcon() {
    for word in ["菜单栏", "状态栏", "图标", "隐藏", "彩色"] {
      #expect(SettingsPage.general.matches(word), "\(word)")
    }
  }

  private static func solid(_ color: NSColor, pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    color.setFill()
    NSRect(x: 0, y: 0, width: pixels, height: pixels).fill()
    NSGraphicsContext.restoreGraphicsState()
    rep.size = NSSize(width: 32, height: 32)
    return rep
  }
}
